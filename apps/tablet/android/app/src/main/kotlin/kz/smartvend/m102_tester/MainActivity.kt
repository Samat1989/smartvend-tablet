package kz.smartvend.m102_tester

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
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
 *  • Lock task, device-owner only. We attempt [startLockTask] on resume when
 *    — and only when — the app owns the device, which gives the silent
 *    LOCKED mode. Without owner Android offers PINNED instead, and PINNED
 *    hands the customer a navigation bar plus a notice explaining how to
 *    escape with it; see [tryEnterLockTask].
 *  • On SHENGMA/RY firmware the system bars are not ours to hide at all —
 *    two framework properties decide, and the app only nudges them for the
 *    next boot. See docs/05_SYSTEM_BARS_AND_AUTOSTART.md.
 */
private const val TAG_KIOSK = "SmartvendKiosk"

/**
 * Broadcasts the SHENGMA "RY" (锐翊) firmware listens for, lifted verbatim
 * from the factory app's `ApiSmRySystem`. They are handled inside
 * system_server — `cmd package query-receivers` finds no app receiver —
 * so any app can send them: no permission, no root, no device owner.
 *
 * STATUSBAR_ON / STATUSBAR_OFF flip two framework properties read by
 * `services.jar` when a display initialises:
 *
 *     persist.sys.navbar.disabled      navigation bar
 *     persist.sys.statusbar.disabled   status bar
 *
 * Both take effect **only on the next boot** — sending the broadcast
 * changes nothing on the running system. That single fact is what makes
 * the factory "show nav bar" toggle behave the way it does, and it is the
 * whole design of [MainActivity.showNavBarAndReboot].
 *
 * On any other tablet (K80 and friends) nobody is listening and the
 * sendBroadcast is a silent no-op — which is why every caller treats these
 * as a best-effort layer, never as the only path.
 */
private const val ACTION_VENDOR_STATUSBAR_ON =
    "android.intent.action.shouhj.STATUSBAR_ON"
private const val ACTION_VENDOR_STATUSBAR_OFF =
    "android.intent.action.shouhj.STATUSBAR_OFF"
private const val ACTION_VENDOR_REBOOT =
    "android.intent.action.shouhj.REBOOT"

/**
 * The property whose existence tells us the RY firmware is underneath.
 *
 * We probe this rather than matching `Build.DISPLAY` against "SHENGMA",
 * because it tests the thing we actually depend on: a framework that reads
 * this property when a display initialises. A rebranded build of the same
 * ROM still answers; an unrelated tablet that happens to carry a similar
 * name does not.
 *
 * Defined even on a freshly wiped tablet — a factory-reset unit reads back
 * `false`, not empty — so this is safe to probe before anything has ever
 * written to it.
 */
private const val PROP_NAVBAR_DISABLED = "persist.sys.navbar.disabled"

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

    /** Main-thread handler for the immersive ticker. */
    private val uiHandler = Handler(Looper.getMainLooper())

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

    /*
     * There used to be a watchdog here: a once-a-second tick that dragged
     * the app back to the front whenever it was off screen, as a fallback
     * kiosk for tablets with no device owner.
     *
     * It is gone, and the reason is the same one that killed screen pinning
     * a few lines below. On SHENGMA/RY firmware the system bars are removed
     * by the framework itself, so a customer has no Home, no Overview and no
     * Back to leave with — there is nothing for a watchdog to recover from.
     * What it did instead was make the tablet unserviceable: an operator who
     * reached Settings was thrown out of it every second or two, and the only
     * cure was force-stopping the app over adb.
     *
     * It also dragged [ensureOverlayPermission] along with it — a first-run
     * detour into a Settings screen that existed solely to make these ticks
     * land. The SYSTEM_ALERT_WINDOW *permission* stays in the manifest, since
     * that is what lets BootReceiver start us at boot, but nothing asks the
     * operator for the app-op any more.
     */

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
                        // The operator asked to be let out. Nothing chases
                        // them any more, so this is simply: stop locking,
                        // open Settings, stay out of the way until they
                        // bring us back.
                        suppressLockOnce = true
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
                        // Whole-tablet reboot: device owner first, then the
                        // RY firmware broadcast for tablets we never owned.
                        if (rebootTablet()) {
                            result.success(null)
                        } else {
                            result.error(
                                "reboot_failed",
                                "Neither device owner nor vendor reboot available",
                                null,
                            )
                        }
                    }
                    "showNavBarAndReboot" -> {
                        // Service-mode escape hatch: bars for one session.
                        // The vendor check happens first and synchronously,
                        // so a tablet that cannot do this says so instead of
                        // pretending; past that point we answer before the
                        // reboot, since the Dart side gets no second chance
                        // once the screen goes black.
                        if (showNavBarAndReboot()) {
                            result.success(null)
                        } else {
                            result.error(
                                "unsupported_firmware",
                                "System bars are not controlled by this firmware",
                                null,
                            )
                        }
                    }
                    "clearDeviceOwner" -> {
                        // Hand the device back. `dpm remove-active-admin`
                        // refuses to touch a non-test-only owner, so for a
                        // release build this is the only way out short of a
                        // factory reset — and a factory reset costs the Wi-Fi,
                        // the developer options and the adb key along with it.
                        //
                        // Needed whenever a tablet changes machines or goes
                        // back to the shelf: without it the package cannot
                        // even be uninstalled.
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
                            // Lock task outlives the owner check otherwise and
                            // leaves the app pinned with nothing able to unpin
                            // it.
                            try { stopLockTask() } catch (_: Throwable) {}
                            @Suppress("DEPRECATION")
                            dpm.clearDeviceOwnerApp(packageName)
                            Log.i(TAG_KIOSK, "device owner cleared")
                            result.success(null)
                        } catch (t: Throwable) {
                            Log.e(TAG_KIOSK, "clearDeviceOwnerApp failed", t)
                            result.error("clear_failed", t.message, null)
                        }
                    }
                    "firmwareCapabilities" -> {
                        // What this particular tablet can actually be asked
                        // to do. The service menu greys out what is missing
                        // and says why, rather than offering a button that
                        // quietly does nothing.
                        result.success(
                            mapOf(
                                "vendorBars" to hasVendorFirmware,
                                "vendorReboot" to hasVendorFirmware,
                                "deviceOwner" to isDeviceOwner(),
                                "firmware" to (Build.DISPLAY ?: ""),
                            ),
                        )
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

        // Re-arm the firmware's bar properties on every single start, the
        // way the factory app does. Costs one broadcast and is what makes
        // the service menu's "show nav bar" expire by itself.
        applyVendorBarPolicy(hidden = true)

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
        applyImmersive()
        tryEnterLockTask()
        applyGestureExclusion()
    }

    override fun onPause() {
        // Nothing to fight over while we are off screen, and a ticker
        // running behind the APK-install dialog would poke the very bars
        // the installer needs. Whatever took the foreground — Settings, the
        // installer, the operator — is now left alone until they come back.
        stopImmersiveTicker()
        super.onPause()
    }

    private fun isDeviceOwner(): Boolean {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
        return dpm?.isDeviceOwnerApp(packageName) == true
    }

    /**
     * Read a system property the way a shell would.
     *
     * `android.os.SystemProperties` is hidden API and blocked for us, but
     * `/system/bin/getprop` is a plain executable any app may run. Undefined
     * properties come back as an empty line, which is exactly the signal we
     * need — no exception, no ambiguity.
     */
    private fun readSystemProperty(name: String): String? = try {
        val process = ProcessBuilder("/system/bin/getprop", name)
            .redirectErrorStream(true)
            .start()
        val value = process.inputStream.bufferedReader().use { it.readText() }.trim()
        process.waitFor()
        value.ifEmpty { null }
    } catch (t: Throwable) {
        Log.w(TAG_KIOSK, "getprop $name failed: ${t.message}")
        null
    }

    /**
     * Whether this tablet's firmware owns the system bars and answers the RY
     * broadcasts.
     *
     * Probed once — it forks a process — and cached for the life of the
     * activity, since a ROM does not change under a running app.
     *
     * Everything vendor-specific hangs off this: the bar policy, the reboot
     * broadcast, and which service-menu tiles are offered at all. On any
     * other tablet the answer is false and those paths are simply not taken,
     * rather than fired into a void where `sendBroadcast` would report a
     * cheerful success nobody could act on.
     */
    private val hasVendorFirmware: Boolean by lazy {
        val value = readSystemProperty(PROP_NAVBAR_DISABLED)
        val present = value != null
        Log.i(
            TAG_KIOSK,
            "vendor firmware: $present ($PROP_NAVBAR_DISABLED=$value, " +
                "build=${Build.DISPLAY})",
        )
        present
    }

    /**
     * Ask the RY firmware to keep both system bars off from the next boot.
     *
     * Called on every start, exactly as the factory app does — its log reads
     * `Android系统--setSystemBar：false` / `锐翊主板--隐藏导航栏状态栏` on each
     * launch. Sending it unconditionally is what makes the service-mode
     * "show nav bar" a **one-session** loan: the operator turns the bars on,
     * reboots into them, does the work, and the reboot after that comes back
     * clean because this line already re-armed the properties.
     *
     * Nothing happens on the running system; see [ACTION_VENDOR_STATUSBAR_ON].
     */
    private fun applyVendorBarPolicy(hidden: Boolean): Boolean {
        if (!hasVendorFirmware) return false
        val action =
            if (hidden) ACTION_VENDOR_STATUSBAR_OFF else ACTION_VENDOR_STATUSBAR_ON
        return try {
            sendBroadcast(Intent(action))
            Log.i(TAG_KIOSK, "vendor bars: sent $action (applies on next boot)")
            true
        } catch (t: Throwable) {
            Log.w(TAG_KIOSK, "vendor bar broadcast refused: ${t.message}")
            false
        }
    }

    /**
     * Reboot the tablet, best path first.
     *
     * 1. [DevicePolicyManager.reboot] — clean, synchronous, needs device owner.
     * 2. The RY firmware broadcast — no permission at all, and the only path
     *    left on a tablet that was never provisioned. This is what the factory
     *    app uses for every one of its restarts.
     *
     * Returns false when neither path was available, so the caller can fall
     * back to [scheduleRelaunchAndKill] and at least restart the process.
     */
    private fun rebootTablet(): Boolean {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE)
            as? DevicePolicyManager
        if (dpm != null && dpm.isDeviceOwnerApp(packageName)) {
            try {
                dpm.reboot(KioskAdminReceiver.componentName(this))
                Log.i(TAG_KIOSK, "reboot via DevicePolicyManager")
                return true
            } catch (t: Throwable) {
                // DPM.reboot refuses outright while a call is active, and
                // some OEM builds throw here for reasons of their own — the
                // vendor broadcast below is unbothered by both.
                Log.w(TAG_KIOSK, "DPM reboot failed, trying vendor: ${t.message}")
            }
        }
        // Only where somebody is listening. sendBroadcast succeeds whether or
        // not a receiver exists, so firing this blind would report a reboot
        // that never happens and leave the operator watching a live screen,
        // wondering whether the tap registered.
        if (!hasVendorFirmware) {
            Log.w(TAG_KIOSK, "no reboot path: not device owner, not RY firmware")
            return false
        }
        return try {
            sendBroadcast(Intent(ACTION_VENDOR_REBOOT))
            Log.i(TAG_KIOSK, "reboot via vendor broadcast")
            true
        } catch (t: Throwable) {
            Log.e(TAG_KIOSK, "vendor reboot broadcast failed", t)
            false
        }
    }

    /**
     * Hand the operator a tablet with visible system bars for one servicing
     * session, mirroring the factory app's «показать навбар» switch.
     *
     * Sends STATUSBAR_ON (properties → false), then reboots. The bars come
     * back on that boot; [applyVendorBarPolicy] then re-arms the properties
     * during startup, so the *following* reboot returns the tablet to a bare
     * kiosk with no second visit to the service menu.
     */
    private fun showNavBarAndReboot(): Boolean {
        if (!applyVendorBarPolicy(hidden = false)) return false
        // The property write happens inside system_server as it handles the
        // broadcast. Rebooting in the same breath can outrun it, so let the
        // handler land before pulling the floor out.
        uiHandler.postDelayed({ rebootTablet() }, VENDOR_BAR_SETTLE_MS)
        return true
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            applyImmersive()
            applyGestureExclusion()
        } else {
            // Losing window focus while still resumed means something is
            // covering us without replacing us — on a kiosk that is almost
            // always the notification shade, and onPause never fires for it.
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
        if (now < suppressLockUntilMs) return
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
     * Enter lock task — but only the silent, device-owner flavour.
     *
     * Android has two lock-task modes and they are not two grades of the
     * same thing:
     *
     *  * LOCKED  — device owner. Silent, no dialog, and with
     *              `setLockTaskFeatures(0)` it takes the notification shade
     *              away too. This is the one we want.
     *  * PINNED  — everyone else. The system posts "Приложение закреплено —
     *              чтобы открепить, нажмите и удерживайте «Назад» и «Обзор»"
     *              and keeps the navigation bar on screen to host those two
     *              buttons, because they are now the documented way out.
     *
     * PINNED therefore *undoes* what we came for: it puts back the very bar
     * the firmware properties removed, and advertises the escape route to
     * the customer. On a tablet that was never provisioned we are better off
     * not asking — the bars are already gone at the framework level, which
     * is a stronger lock than pinning ever was.
     *
     * Still wrapped in try/catch: [startLockTask] throws when the caller is
     * not on the lock-task allowlist, and a provisioning that half-succeeded
     * should not take the app down with it.
     */
    private fun tryEnterLockTask() {
        if (!isDeviceOwner()) {
            // Not owned → pinning is the only mode on offer, and it costs
            // more than it buys. If we somehow arrived here already pinned,
            // leave: the toast and the nav bar go with it.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                val state = am?.lockTaskModeState
                    ?: ActivityManager.LOCK_TASK_MODE_NONE
                if (state == ActivityManager.LOCK_TASK_MODE_PINNED) {
                    try {
                        stopLockTask()
                        Log.i(TAG_KIOSK, "left PINNED mode (no device owner)")
                    } catch (t: Throwable) {
                        Log.w(TAG_KIOSK, "stopLockTask (unpin) failed: ${t.message}")
                    }
                }
            }
            return
        }
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
        // Already locked? Leave it alone. This runs from every onResume, and
        // a redundant startLockTask is at best wasted work — historically it
        // was worse than that, re-showing the pinning dialog on every USB
        // replug back when we still called it without owner.
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
        // Deliberately NOT the HOME app — we match the factory machine.
        //
        // We used to pin ourselves as the persistent launcher, because
        // BootReceiver's startActivity looked like it was being refused by
        // the Android 10+ background-activity-start rules. Watching a
        // factory tablet boot showed what actually happens there:
        //
        //   START {cat=[HOME] cmp=com.android.launcher3/.Launcher3QuickStepGo}
        //   Start proc com.shengma.shouhj.sy.world for broadcast BootReceiver
        //   START {cmp=.../ShanpingYeActivity} from uid 10131
        //   W/ActivityTaskManager: Background activity start for
        //       com.shengma.shouhj.sy.world allowed because
        //       SYSTEM_ALERT_WINDOW permission is granted.
        //
        // Declaring SYSTEM_ALERT_WINDOW is enough on its own: it carries the
        // `appop` protection flag, so the permission is granted at install
        // and `hasSystemAlertWindowPermission()` falls back to that grant
        // when the app-op is still MODE_DEFAULT. Nobody has to tick
        // "Display over other apps" — the earlier blocked boot was the
        // Android 14 tablet, where this exemption no longer applies.
        //
        // The cost is honest: the stock launcher is on screen for the ~6 s
        // it takes us to come up, exactly as on the factory machine. The
        // gain is a tablet that can still be reached when the kiosk will not
        // start, which on a machine standing in a mall is worth more.
        //
        // Clearing matters as much as not adding: a tablet provisioned by an
        // earlier build already carries the HOME binding, and it survives
        // reinstalls. Without this it would quietly keep winning.
        try {
            dpm.clearPackagePersistentPreferredActivities(admin, packageName)
            Log.i(TAG_KIOSK, "cleared persistent HOME binding (factory parity)")
        } catch (t: Throwable) {
            Log.e(TAG_KIOSK, "clearPackagePersistentPreferredActivities failed", t)
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

        /**
         * Grace between the STATUSBAR_ON broadcast and the reboot that makes
         * it visible. system_server writes the property while handling the
         * broadcast; reboot too early and the write is lost, leaving the
         * operator staring at the same bare screen they just asked to change.
         */
        private const val VENDOR_BAR_SETTLE_MS = 700L

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
