package kz.smartvend.m102_tester

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.IntentSender
import android.content.pm.PackageInstaller
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.WindowManager
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import kotlin.system.exitProcess

/**
 * Kiosk-mode host activity.
 *
 * Behaviour we layer on top of the default [FlutterActivity]:
 *  • Screen always on (FLAG_KEEP_SCREEN_ON) — important: the device may stand
 *    idle for hours between purchases, and a black screen looks broken to
 *    customers and stops the touch panel from waking quickly.
 *  • Sticky immersive mode — both system bars (status + nav) stay hidden.
 *    Sticky means a swipe makes them appear briefly, then they auto-hide
 *    again, so customers can't easily pull up notifications or back-gesture
 *    out of the app.
 *  • Show on lock screen + turn screen on — handled in the manifest, this
 *    keeps the activity visible when the device wakes from boot or sleep.
 *  • Best-effort lock task ("screen pinning"). On a non-rooted device this
 *    only sticks if the app was provisioned as a device-owner OR the
 *    operator manually pinned via Recents → "pin this app". We attempt
 *    [startLockTask] on resume; the call is a no-op if the OS hasn't
 *    granted that permission, so it never crashes.
 */
private const val TAG_KIOSK = "SmartvendKiosk"

class MainActivity : FlutterActivity() {

    /**
     * When true, [onResume] will not re-enter lock task. Set by the
     * `exitToAndroid` channel call so that an operator who just pressed
     * "Exit to Android" in service mode isn't immediately re-locked when
     * the Settings activity starts and our onResume fires (which it does
     * once before we lose focus).
     *
     * The flag is cleared on the *next* resume that follows the operator
     * coming back to the app, so subsequent customer sessions re-lock as
     * usual.
     */
    private var suppressLockOnce = false

    /**
     * Monotonic deadline before which [onResume] must NOT re-enter lock
     * task. Set by [installApk] on non-owner devices: the
     * PackageInstaller confirm dialog arrives asynchronously (via
     * [InstallReceiver]) after we stopLockTask(), and an onResume firing
     * in that gap used to re-pin the screen — the operator saw the
     * system "navigation buttons are blocked" pinning notice and the
     * install dialog was killed by lock task, so the update silently
     * never started. A one-shot flag isn't enough here because resume /
     * focus can cycle more than once before the dialog lands. If the
     * install fails or is cancelled, kiosk re-pins on the first resume
     * after the window lapses (successful installs replace the process,
     * so the relaunch pins immediately as usual).
     */
    private var suppressLockUntilMs = 0L

    /** Main-thread handler for the immersive ticker and the watchdog. */
    private val uiHandler = Handler(Looper.getMainLooper())

    /**
     * Deadline before which the watchdog must stay quiet.
     *
     * Set whenever the operator deliberately leaves for Android — the
     * service menu's exit, or the overlay-permission screen — because a
     * watchdog that snatches the screen back once a second makes changing
     * the Wi-Fi impossible.
     *
     * A deadline rather than a plain flag, so a service session someone
     * walked away from cannot leave the machine open indefinitely.
     * [onResume] clears it the moment the operator comes back; if they
     * never do, it lapses on its own.
     */
    private var watchdogSuppressUntilMs = 0L

    /** One overlay prompt per process, so a refusal does not become a loop. */
    private var overlayAsked = false

    /** Throttles watchdog logging; the tick itself runs once a second. */
    private var watchdogAttempts = 0

    /**
     * When [dismissShadeIfNeeded] last fired.
     *
     * Closing the shade changes window focus, which calls
     * [onWindowFocusChanged] again — and the first build of this went into
     * a focus-change storm that wedged the main thread into an ANR within
     * seconds. The broadcast is cheap; being asked to send it hundreds of
     * times a second is not.
     */
    private var lastShadeDismissMs = 0L

    /**
     * Drags the app back to the front once a second while it is off screen
     * — the fallback kiosk for tablets that have no device owner.
     *
     * With device owner this never starts, and should not: lock task
     * refuses to let anything else take the foreground at all, which is a
     * guarantee rather than a race. Without it the OS offers only screen
     * pinning, which a customer can leave with back + overview, and this is
     * the crude answer to that.
     *
     * Crude is the word. Android 10 blocks background activity starts, so
     * every tick here is refused unless SYSTEM_ALERT_WINDOW has been
     * granted — see [ensureOverlayPermission]. Even granted, it recovers
     * *after* the escape instead of preventing it, leaving a second in
     * which Settings is reachable. Provisioning device owner stops this
     * whole path from running.
     */
    private val watchdogTicker = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val quiet = now < watchdogSuppressUntilMs || now < suppressLockUntilMs
            if (!quiet) bringSelfToFront()
            uiHandler.postDelayed(this, WATCHDOG_TICK_MS)
        }
    }

    /**
     * Ticker that keeps the system bars shut.
     *
     * [installInsetsRehideListener] only fires when the window insets
     * change, and a *transient* bar — the empty strip a swipe from the
     * screen edge pulls in — deliberately leaves insets alone so the
     * app's layout does not jump underneath it. The listener therefore
     * never sees it, and the strip sits over the catalog for the three
     * seconds the system allows before retracting on its own.
     *
     * Three seconds is plenty of time to tap something. Asking the
     * controller to hide again cancels the transient state at once, so
     * we simply keep asking on a short period while resumed. Cheap: one
     * call into the insets controller, and no relayout when the bars are
     * already hidden.
     */
    private val immersiveTicker = object : Runnable {
        override fun run() {
            hideSystemBars()
            uiHandler.postDelayed(this, IMMERSIVE_TICK_MS)
        }
    }

    /** Reference to the kiosk MethodChannel kept on the activity so the
     *  USB permission BroadcastReceiver can call back into Flutter when
     *  the user accepts/denies the system dialog. */
    private var kioskChannel: MethodChannel? = null

    /** Custom action used as the PendingIntent target for
     *  [UsbManager.requestPermission]. Receiver below converts the
     *  result into a `usbPermissionResult` MethodChannel callback so
     *  [BoardClient] can retry the open immediately on grant. */
    private val usbPermissionAction get() = "$packageName.USB_PERMISSION"

    private val usbPermissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != usbPermissionAction) return
            val granted = intent.getBooleanExtra(
                UsbManager.EXTRA_PERMISSION_GRANTED, false,
            )
            val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            Log.i(
                TAG_KIOSK,
                "USB permission result: granted=$granted device=${device?.deviceName}",
            )
            runOnUiThread {
                kioskChannel?.invokeMethod(
                    "usbPermissionResult",
                    mapOf(
                        "granted" to granted,
                        "deviceName" to device?.deviceName,
                        "vendorId" to device?.vendorId,
                        "productId" to device?.productId,
                    ),
                )
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register the USB permission broadcast receiver once per engine
        // attach. Internal action, scoped to our package, RECEIVER_NOT_EXPORTED
        // so other apps can't spoof grant results.
        val filter = IntentFilter(usbPermissionAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbPermissionReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(usbPermissionReceiver, filter)
        }

        kioskChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KIOSK_CHANNEL)
        kioskChannel!!
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Stable per-device identifier for the machine claim.
                    // ANDROID_ID is scoped to (device, signing key, user):
                    // it survives an app reinstall — so a technician
                    // re-flashing the APK on the same tablet keeps the
                    // claim — and only changes on a factory reset. No
                    // permission needed, unlike Build.getSerial() or IMEI.
                    // Dart falls back to a generated UUID if this returns
                    // null, which some ROMs do.
                    "androidId" -> {
                        try {
                            result.success(
                                Settings.Secure.getString(
                                    contentResolver,
                                    Settings.Secure.ANDROID_ID,
                                ),
                            )
                        } catch (t: Throwable) {
                            result.success(null)
                        }
                    }
                    "exitToAndroid" -> {
                        suppressLockOnce = true
                        // The operator asked to be let out; hold the
                        // watchdog off until they come back, or until the
                        // grace period lapses if they forget to.
                        watchdogSuppressUntilMs =
                            SystemClock.elapsedRealtime() + SERVICE_EXIT_GRACE_MS
                        try { stopLockTask() } catch (_: Throwable) {}
                        try {
                            startActivity(
                                Intent(Settings.ACTION_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                            result.success(null)
                        } catch (t: Throwable) {
                            result.error("settings_unavailable", t.message, null)
                        }
                    }
                    "restartApp" -> {
                        // Schedule a relaunch via AlarmManager, then kill
                        // our own process. The factory app uses this same
                        // pattern to clear stuck CH340 / USB-driver state
                        // when the board has been silent too long.
                        result.success(null)
                        scheduleRelaunchAndKill()
                    }
                    "rebootDevice" -> {
                        // Whole-tablet reboot via DevicePolicyManager.
                        // Requires the app to be device-owner (which we
                        // already need for the silent kiosk pinning).
                        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE)
                            as? DevicePolicyManager
                        if (dpm == null || !dpm.isDeviceOwnerApp(packageName)) {
                            result.error(
                                "not_device_owner",
                                "App is not provisioned as device owner",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            val admin = KioskAdminReceiver.componentName(this)
                            dpm.reboot(admin)
                            result.success(null)
                        } catch (t: Throwable) {
                            result.error("reboot_failed", t.message, null)
                        }
                    }
                    "requestUsbPermission" -> {
                        // Force-show the "Allow USB access?" dialog for the
                        // CH340 device. Returns:
                        //   "granted"   — permission already held, no dialog
                        //   "requested" — dialog shown, result will arrive
                        //                 via the receiver above
                        //   "no_device" — CH340 not currently plugged in
                        try {
                            val state = requestUsbPermissionForCh340()
                            result.success(state)
                        } catch (t: Throwable) {
                            result.error("usb_request_failed", t.message, null)
                        }
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(path)
                            result.success(null)
                        } catch (t: Throwable) {
                            result.error("install_failed", t.message, null)
                        }
                    }
                    "openApk" -> {
                        // Manual-install path: same system UI as opening
                        // the APK from a file manager.
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            openApkViaSystemInstaller(path)
                            result.success(null)
                        } catch (t: Throwable) {
                            result.error("open_failed", t.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Trigger the system "Allow this app to access USB device?" dialog
     * for the CH340 if it's plugged in but permission hasn't been
     * granted yet.
     *
     * Returns "granted" if permission was already held (no dialog
     * shown), "requested" if the dialog was opened (result arrives
     * via [usbPermissionReceiver] later), or "no_device" if no CH340
     * is currently attached.
     *
     * In kiosk / lock-task mode the dialog still appears as a system
     * overlay — lock-task only prevents leaving the app, not
     * interacting with system surfaces.
     */
    /**
     * Vendors that ship USB-to-UART bridges we might be plugged into. Matched
     * by vendor alone, not by (vid, pid): this used to demand CH340's exact
     * 0x1A86/0x7523, and the micromarket relay board — a CH9102, same vendor,
     * different product — fell straight through to "no_device". The dialog the
     * operator eventually saw came from usb_serial's own implicit request
     * inside open(), which defeats the point of asking first.
     *
     * Same list as BoardClient.knownUsbSerialVids on the Dart side; keep them
     * in step.
     */
    private val usbSerialVendors = setOf(
        0x1A86, // QinHeng: CH340 / CH341 / CH9102
        0x0403, // FTDI
        0x10C4, // Silicon Labs: CP210x
        0x067B, // Prolific: PL2303
    )

    private fun requestUsbPermissionForCh340(): String {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
            ?: return "no_device"
        var sawDevice = false
        for ((_, device) in usbManager.deviceList) {
            if (device.vendorId in usbSerialVendors) {
                sawDevice = true
                if (usbManager.hasPermission(device)) {
                    Log.i(TAG_KIOSK, "USB permission already granted for ${device.deviceName}")
                    return "granted"
                }
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val intent = Intent(usbPermissionAction).setPackage(packageName)
                val pi = PendingIntent.getBroadcast(this, 0, intent, flags)
                Log.i(TAG_KIOSK, "Requesting USB permission for ${device.deviceName}")
                // The system USB dialog is exactly the kind of thing
                // dismissShadeIfNeeded would swat away, so claim the same
                // grace window the installer uses before raising it.
                suppressLockUntilMs = maxOf(
                    suppressLockUntilMs,
                    SystemClock.elapsedRealtime() + USB_PROMPT_GRACE_MS,
                )
                usbManager.requestPermission(device, pi)
                return "requested"
            }
        }
        Log.w(TAG_KIOSK, "No USB-serial bridge found (deviceList size=${usbManager.deviceList.size})")
        return if (sawDevice) "requested" else "no_device"
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        stopImmersiveTicker()
        stopWatchdog()
        try {
            unregisterReceiver(usbPermissionReceiver)
        } catch (_: Throwable) {
            // never registered / already unregistered — ignore
        }
        super.onDestroy()
    }

    /**
     * Silently install [path] using the OS [PackageInstaller]. Works
     * without user prompts when the app is provisioned as
     * device-owner (which our kiosk setup already does — see
     * [configureDeviceOwnerKiosk]). On non-owner devices the OS shows
     * the standard "Allow this app to install unknown apps?" dialog
     * once, after which the install proceeds.
     *
     * The session sends a status broadcast back to [InstallReceiver]
     * which logs the result. Since the install replaces our own APK,
     * Android kills + relaunches the process on success — there's no
     * "great success" code path here, only error paths.
     */
    private fun installApk(path: String) {
        val file = File(path)
        require(file.exists() && file.canRead()) { "APK not readable: $path" }

        // Non-device-owner installs need the system "Install?" confirm
        // dialog, which lock-task (kiosk) mode blocks ("Lock Task Mode
        // violation") — so the update silently never lands. Drop out of lock
        // task first so the dialog can appear; a successful install replaces
        // the process and re-enters kiosk on relaunch. Device-owner installs
        // are silent (no dialog), so we keep kiosk intact for them.
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
        if (dpm?.isDeviceOwnerApp(packageName) != true) {
            // Keep onResume from re-pinning while the confirm dialog is
            // still in flight — see [suppressLockUntilMs].
            suppressLockUntilMs = SystemClock.elapsedRealtime() + 120_000L
            try {
                val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                if (am?.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE) {
                    stopLockTask()
                    Log.i(TAG_KIOSK, "left lock task so the install dialog can show")
                }
            } catch (e: Exception) {
                Log.w(TAG_KIOSK, "stopLockTask before install failed: ${e.message}")
            }
            // Non-owner installs are gated on the per-app "Install unknown
            // apps" grant (API 26+). Without it the session's confirm
            // dialog never surfaces on these ROMs — the update downloads
            // and then nothing visibly happens. Fail loud AND open the
            // exact settings toggle so the operator can flip it and retry.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                Log.w(TAG_KIOSK, "canRequestPackageInstalls=false — opening settings")
                try {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                } catch (t: Throwable) {
                    Log.w(TAG_KIOSK, "open unknown-sources settings failed: ${t.message}")
                }
                throw IllegalStateException("no_install_permission")
            }
        }

        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        )
        // INSTALL_REPLACE_EXISTING is implicit in MODE_FULL_INSTALL.
        params.setAppPackageName(packageName)
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            FileInputStream(file).use { input ->
                session.openWrite("update.apk", 0, file.length()).use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        output.write(buf, 0, n)
                    }
                    session.fsync(output)
                }
            }

            val intent = Intent(this, InstallReceiver::class.java)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pi = PendingIntent.getBroadcast(this, sessionId, intent, flags)
            session.commit(pi.intentSender)
        }
    }

    /**
     * Manual-install fallback: hand the APK to the system
     * package-installer activity via ACTION_VIEW — byte-for-byte the
     * flow of tapping the file in a file manager, which is proven to
     * work on the ROMs where a PackageInstaller-session confirm dialog
     * never surfaces. The installer activity itself walks the operator
     * through the "unknown sources" grant if it's missing.
     */
    private fun openApkViaSystemInstaller(path: String) {
        val file = File(path)
        require(file.exists() && file.canRead()) { "APK not readable: $path" }
        // Same kiosk handling as the session flow — the installer UI
        // can't show while we're pinned.
        suppressLockUntilMs = SystemClock.elapsedRealtime() + 120_000L
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            if (am?.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE) {
                stopLockTask()
            }
        } catch (t: Throwable) {
            Log.w(TAG_KIOSK, "stopLockTask before openApk failed: ${t.message}")
        }
        val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } else {
            @Suppress("DEPRECATION")
            Uri.fromFile(file)
        }
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK,
                ),
        )
        Log.i(TAG_KIOSK, "opened system installer for $path")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        // Keep the display on while the activity is in the foreground.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Configure device-owner-only kiosk features (no-op if we
        // haven't been provisioned via `adb shell dpm set-device-owner`).
        configureDeviceOwnerKiosk()

        // Show over keyguard / wake the screen for boot-launches.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }

        // Tell the framework we're drawing edge-to-edge so the system bars
        // can be properly hidden by the WindowInsetsController below.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        applyImmersive()
        installInsetsRehideListener()
    }

    /**
     * Aggressive re-hide loop. On OEM builds where `setStatusBarDisabled`
     * is ignored (observed on Unisoc Go), the system spontaneously
     * toggles the status bar visible — we need to fight it on every
     * inset change. The listener fires whenever any system bar starts
     * to appear; we ask the [WindowInsetsControllerCompat] to hide it
     * again immediately. Combined with [applyGestureExclusion] this
     * prevents the bar from ever staying on screen long enough for
     * the customer to tap a back button.
     */
    private fun installInsetsRehideListener() {
        val decor = window.decorView
        ViewCompat.setOnApplyWindowInsetsListener(decor) { v, insets ->
            val barsVisible = insets.isVisible(WindowInsetsCompat.Type.systemBars())
            if (barsVisible) {
                WindowInsetsControllerCompat(window, v)
                    .hide(WindowInsetsCompat.Type.systemBars())
            }
            insets
        }
    }

    override fun onResume() {
        super.onResume()
        // Back on screen: nothing to drag forward, and whatever suppression
        // the operator earned by leaving has served its purpose. Cleared
        // before ensureOverlayPermission, which may open a fresh window of
        // its own — order matters, because that call sends us to Settings.
        stopWatchdog()
        watchdogSuppressUntilMs = 0
        applyImmersive()
        tryEnterLockTask()
        applyGestureExclusion()
        ensureOverlayPermission()
    }

    override fun onPause() {
        // Nothing to fight over while we are off screen, and a ticker
        // running behind the APK-install dialog would poke the very bars
        // the installer needs.
        stopImmersiveTicker()
        startWatchdogIfNeeded()
        super.onPause()
    }

    private fun isDeviceOwner(): Boolean {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
        return dpm?.isDeviceOwnerApp(packageName) == true
    }

    /** Only ever armed on a tablet with no device owner — see [watchdogTicker]. */
    private fun startWatchdogIfNeeded() {
        if (isDeviceOwner()) return
        watchdogAttempts = 0
        uiHandler.removeCallbacks(watchdogTicker)
        uiHandler.postDelayed(watchdogTicker, WATCHDOG_TICK_MS)
        Log.i(TAG_KIOSK, "watchdog armed (no device owner)")
    }

    private fun stopWatchdog() {
        uiHandler.removeCallbacks(watchdogTicker)
    }

    private fun bringSelfToFront() {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return
        intent.addFlags(
            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK,
        )
        try {
            startActivity(intent)
        } catch (t: Throwable) {
            // Logged for the first few ticks only: this runs once a second,
            // and a blocked background start fails the same way every time.
            if (watchdogAttempts < 3) {
                Log.w(TAG_KIOSK, "watchdog start refused: " + t.message)
            }
        }
        watchdogAttempts++
    }

    /**
     * Ask for "display over other apps" — once per process, and only where
     * there is no device owner to make it unnecessary.
     *
     * Without this permission [watchdogTicker] is inert: Android 10 refuses
     * activity starts from an app with no visible window, and our
     * `excludeFromRecents` closes the other way out, since that exemption
     * wants a task on the Recents screen. SYSTEM_ALERT_WINDOW is what makes
     * the watchdog work at all.
     *
     * The prompt is a system screen, so we have to leave for it — which
     * trips both lock task and the very watchdog it is about to enable.
     * Both get the same kind of grace window the APK installer uses.
     */
    private fun ensureOverlayPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (overlayAsked || isDeviceOwner()) return
        if (Settings.canDrawOverlays(this)) return
        overlayAsked = true
        val until = SystemClock.elapsedRealtime() + OVERLAY_PROMPT_GRACE_MS
        watchdogSuppressUntilMs = until
        suppressLockUntilMs = until
        try {
            stopLockTask()
        } catch (_: Throwable) {
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + packageName),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            Log.i(TAG_KIOSK, "asking for SYSTEM_ALERT_WINDOW")
        } catch (t: Throwable) {
            Log.w(TAG_KIOSK, "overlay permission screen unavailable: " + t.message)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            applyImmersive()
            applyGestureExclusion()
        } else {
            // Losing window focus while still resumed means something is
            // covering us without replacing us — on a kiosk that is almost
            // always the notification shade. onPause never fires for it, so
            // the watchdog would sleep straight through the one escape route
            // a customer is most likely to find.
            dismissShadeIfNeeded()
        }
    }

    /**
     * Collapse whatever is covering the app, on tablets with no device
     * owner.
     *
     * CLOSE_SYSTEM_DIALOGS is the only lever an ordinary app has here:
     * StatusBarManager.collapsePanels() is hidden API and blocked, and an
     * app cannot inject a back press. Android 12 closed this broadcast to
     * non-system callers, but these are Android 11 tablets and it works —
     * which is precisely why this is a stopgap for unprovisioned machines
     * and not the plan. With device owner, lock task refuses to open the
     * shade at all and none of this runs.
     *
     * The suppression window matters more than usual here, because the
     * broadcast also dismisses legitimate system dialogs — the USB
     * permission prompt above all, which the board needs to work.
     */
    private fun dismissShadeIfNeeded() {
        if (isDeviceOwner()) return
        val now = SystemClock.elapsedRealtime()
        if (now < watchdogSuppressUntilMs || now < suppressLockUntilMs) return
        if (now - lastShadeDismissMs < SHADE_DISMISS_MIN_GAP_MS) return
        lastShadeDismissMs = now
        try {
            @Suppress("DEPRECATION")
            sendBroadcast(Intent(Intent.ACTION_CLOSE_SYSTEM_DIALOGS))
        } catch (t: Throwable) {
            Log.w(TAG_KIOSK, "could not close system dialogs: " + t.message)
        }
    }

    /** Just the hide call — what [immersiveTicker] repeats. */
    private fun hideSystemBars() {
        WindowInsetsControllerCompat(window, window.decorView)
            .hide(WindowInsetsCompat.Type.systemBars())
    }

    private fun startImmersiveTicker() {
        uiHandler.removeCallbacks(immersiveTicker)
        uiHandler.postDelayed(immersiveTicker, IMMERSIVE_TICK_MS)
    }

    private fun stopImmersiveTicker() {
        uiHandler.removeCallbacks(immersiveTicker)
    }

    private fun applyImmersive() {
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        // Sticky immersive: bars stay hidden, swipe shows them as
        // transparent overlay that auto-hides. This is the original
        // behaviour that paints them as a translucent layer over the
        // catalog (instead of as a solid white opaque bar that BEHAVIOR_DEFAULT
        // gives on this OEM Unisoc Go ROM). The forced re-hide
        // listener below catches transient appearances and snaps them
        // shut quickly.
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
        startImmersiveTicker()
        // Ensure the bar surfaces themselves are transparent so the
        // catalog shows through whenever they do appear.
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
    }

    /**
     * Attempt to enter screen-pinning. Wrapped in try/catch because on most
     * consumer devices [startLockTask] only succeeds when the app is on the
     * lock-task allowlist — otherwise it throws IllegalStateException. The
     * intent is best-effort: if the OS denies, we still have manifest-level
     * `excludeFromRecents` and HOME-category to make escape harder.
     */
    private fun tryEnterLockTask() {
        if (suppressLockOnce) {
            // Operator just chose "Exit to Android" — don't fight them.
            suppressLockOnce = false
            return
        }
        if (SystemClock.elapsedRealtime() < suppressLockUntilMs) {
            // An APK install is mid-flight — pinning now would block the
            // system confirm dialog (Lock Task Mode violation).
            Log.i(TAG_KIOSK, "lock task suppressed: install in progress")
            return
        }
        // Already pinned? Then leave it alone. startLockTask() was called from
        // every onResume, and on a tablet that is not device-owner each call
        // re-shows the system "App is pinned" confirmation. With a flaky USB
        // contact that turned into a dialog on every replug: the attach fires
        // our USB intent-filter, the activity resumes, and up it came again.
        //
        // LOCKED is the device-owner path (silent), PINNED is the user-confirmed
        // one — in both we are already where we want to be.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            val state = am?.lockTaskModeState ?: ActivityManager.LOCK_TASK_MODE_NONE
            if (state != ActivityManager.LOCK_TASK_MODE_NONE) return
        }
        try {
            startLockTask()
            Log.i(TAG_KIOSK, "startLockTask OK")
        } catch (t: Throwable) {
            Log.w(TAG_KIOSK, "startLockTask failed: ${t.message}")
        }
    }

    /**
     * If this package is the device owner, whitelist itself for
     * lock-task and clear all system-UI features so a subsequent
     * [startLockTask] silently pins the app — no "App is pinned"
     * confirmation, no navigation bar, no status bar, no notification
     * shade. If we aren't device owner this is a no-op; the OS will
     * fall back to the standard pinning confirmation flow.
     */
    private fun configureDeviceOwnerKiosk() {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE)
            as? DevicePolicyManager
        if (dpm == null) {
            Log.w(TAG_KIOSK, "no DevicePolicyManager — skipping kiosk setup")
            return
        }
        val isOwner = dpm.isDeviceOwnerApp(packageName)
        Log.i(TAG_KIOSK, "isDeviceOwnerApp($packageName) = $isOwner")
        if (!isOwner) return
        val admin = KioskAdminReceiver.componentName(this)
        try {
            // Whitelist us + com.android.systemui so the OS can launch
            // the "Allow USB access?" dialog (UsbPermissionActivity) on
            // top of our kiosk. Without systemui on the list, lock-task
            // throws START_RETURN_LOCK_TASK_MODE_VIOLATION every time
            // we call UsbManager.requestPermission() and the operator
            // can never grant access. The packages here can launch
            // *activities*; they still can't leave kiosk mode.
            dpm.setLockTaskPackages(admin, arrayOf(packageName, "com.android.systemui"))
            Log.i(TAG_KIOSK, "setLockTaskPackages OK for $packageName + systemui")
        } catch (t: SecurityException) {
            Log.e(TAG_KIOSK, "setLockTaskPackages SecurityException", t)
            return
        } catch (t: Throwable) {
            Log.e(TAG_KIOSK, "setLockTaskPackages other failure", t)
            return
        }
        // Make the kiosk the persistent HOME/launcher. After a reboot the
        // system launches HOME — which is now us — so the machine returns
        // straight to the catalog with no operator on-site. This is the
        // reliable path: BootReceiver's startActivity is blocked by Android
        // 10+ background-activity-start restrictions (observed: device booted
        // to the stock launcher instead of the kiosk), but the HOME route is
        // not subject to that.
        try {
            val homeFilter = IntentFilter(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                addCategory(Intent.CATEGORY_DEFAULT)
            }
            dpm.addPersistentPreferredActivity(
                admin,
                homeFilter,
                ComponentName(this, MainActivity::class.java),
            )
            Log.i(TAG_KIOSK, "addPersistentPreferredActivity(HOME) OK")
        } catch (t: Throwable) {
            Log.e(TAG_KIOSK, "addPersistentPreferredActivity failed", t)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                dpm.setLockTaskFeatures(admin, 0)
                Log.i(TAG_KIOSK, "setLockTaskFeatures(0) OK")
            } catch (t: Throwable) {
                Log.e(TAG_KIOSK, "setLockTaskFeatures failed", t)
            }
        }
        // Hand the status bar back, deliberately.
        //
        // setStatusBarDisabled(true) reads like the strongest possible
        // lockdown, and it does kill the shade — but it kills it by
        // blanking the bar, not by removing it. SystemUI keeps ownership
        // of the window, so the app's request to hide it is refused:
        // dumpsys showed ITYPE_STATUS_BAR and ITYPE_NAVIGATION_BAR both
        // requested mVisible=false while two opaque grey strips sat on
        // screen, one empty and one holding a lone back arrow, with the
        // catalog squeezed between them.
        //
        // Lock task already blocks the shade on its own:
        // setLockTaskFeatures(0) clears LOCK_TASK_FEATURE_NOTIFICATIONS,
        // and the pull-down is refused at the window manager rather than
        // swallowed afterwards. Dropping the DPM flag returns inset
        // control to us, so immersive can hide both bars outright — which
        // is what we wanted from the beginning.
        //
        // The one thing given up is shade suppression *outside* lock task,
        // i.e. after «Выйти в Android». That is a servicing operator with
        // the PIN, and taking the shade away from them was never the point.
        try {
            dpm.setStatusBarDisabled(admin, false)
            Log.i(TAG_KIOSK, "setStatusBarDisabled(false) OK — lock task guards the shade")
        } catch (t: Throwable) {
            Log.e(TAG_KIOSK, "setStatusBarDisabled failed", t)
        }
    }

    /**
     * Tell the OS that the edges of our window are NOT system-gesture
     * areas. Without this, gesture-navigation Android (10+) treats a
     * swipe-up from the bottom as "go home" and a swipe-in from either
     * side as "back" — even in lock-task. With these rects claimed,
     * the gestures land on our Flutter view and do nothing.
     *
     * Re-applied on every onResume / window-focus because the OS clears
     * the list when an activity loses focus.
     */
    private fun applyGestureExclusion() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val decor = window.decorView
        val w = decor.width
        val h = decor.height
        if (w == 0 || h == 0) {
            // First call — layout hasn't happened yet. Defer.
            decor.post { applyGestureExclusion() }
            return
        }
        // Cover the full bottom edge (home swipe) and both side edges
        // (back swipe) with our own gesture zones. 60-dp tall / 30-dp
        // wide stripes — enough to swallow the system gesture without
        // breaking our own touch handling further inside the screen.
        val density = resources.displayMetrics.density
        val bottomStripe = (60 * density).toInt()
        val sideStripe = (30 * density).toInt()
        val exclusions = listOf(
            android.graphics.Rect(0, h - bottomStripe, w, h),
            android.graphics.Rect(0, 0, sideStripe, h),
            android.graphics.Rect(w - sideStripe, 0, w, h),
        )
        decor.systemGestureExclusionRects = exclusions
    }

    /**
     * Schedule [MainActivity] to launch ~250 ms from now via the
     * system [AlarmManager], then [Process.killProcess] ourselves so
     * Android tears down the old process. The launch intent is
     * exactly what the launcher icon would do — single-instance, no
     * special flags — so the relaunch goes through the same boot
     * sequence as a normal start.
     *
     * Used by the BoardClient escalation when the bus has been
     * unrecoverable for several reconnect cycles and the most likely
     * culprit is stuck USB-Serial driver state inside our own
     * process that a fresh process erases.
     */
    private fun scheduleRelaunchAndKill() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: return
        launchIntent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TASK,
        )
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_CANCEL_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent, pendingFlags,
        )
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.set(
            AlarmManager.RTC,
            System.currentTimeMillis() + 250,
            pendingIntent,
        )
        Handler(Looper.getMainLooper()).postDelayed({
            Process.killProcess(Process.myPid())
            exitProcess(0)
        }, 80)
    }

    /**
     * Push a PackageInstaller session status into Flutter so the update
     * screen can show WHY an install stalled instead of sitting on
     * "Загрузка…" forever. Called by [InstallReceiver]; safe from any
     * thread. Status values are [PackageInstaller.EXTRA_STATUS]
     * constants (-1 pending-user-action, 0 success, 1..7 failures).
     */
    fun notifyInstallStatus(status: Int, message: String?) {
        runOnUiThread {
            try {
                kioskChannel?.invokeMethod(
                    "installStatus",
                    mapOf("status" to status, "message" to (message ?: "")),
                )
            } catch (t: Throwable) {
                Log.w(TAG_KIOSK, "notifyInstallStatus failed: ${t.message}")
            }
        }
    }

    companion object {
        private const val KIOSK_CHANNEL = "kz.smartvend/kiosk"

        /**
         * How often to re-hide the system bars. Short enough that a
         * transient bar is gone before it can be aimed at, long enough
         * to be invisible on the CPU.
         */
        private const val IMMERSIVE_TICK_MS = 600L

        /** Watchdog period. Once a second, as specified. */
        private const val WATCHDOG_TICK_MS = 1000L

        /**
         * How long the service menu's exit buys the operator before the
         * watchdog takes the screen back. Long enough to redo the Wi-Fi
         * unhurried, short enough that a session someone walked away from
         * does not leave the machine open for the rest of the day.
         */
        private const val SERVICE_EXIT_GRACE_MS = 30L * 60L * 1000L

        /** Same idea for the overlay prompt, which is a much shorter errand. */
        private const val OVERLAY_PROMPT_GRACE_MS = 2L * 60L * 1000L

        /**
         * How long the system USB-permission dialog is protected from
         * [dismissShadeIfNeeded]. Generous: an operator has to read it and
         * find the checkbox, and swatting it away costs a board connection.
         */
        private const val USB_PROMPT_GRACE_MS = 90L * 1000L

        /**
         * Floor on the gap between two shade dismissals. Closing the shade
         * is itself a focus change, so without this the handler feeds
         * itself — observed as an ANR seconds after launch.
         */
        private const val SHADE_DISMISS_MIN_GAP_MS = 1500L

        /**
         * Live activity, for [InstallReceiver] — an activity context is
         * the reliable way to launch the install-confirm dialog (a
         * receiver-context startActivity is treated as a background
         * start on some ROMs and silently dropped), and the bridge for
         * [notifyInstallStatus].
         */
        @Volatile
        @JvmStatic
        var instance: MainActivity? = null
    }
}
