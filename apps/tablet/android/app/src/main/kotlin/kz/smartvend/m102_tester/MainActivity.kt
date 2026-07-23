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
                    "exitToAndroid" -> {
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
    private fun requestUsbPermissionForCh340(): String {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
            ?: return "no_device"
        var sawDevice = false
        for ((_, device) in usbManager.deviceList) {
            if (device.vendorId == 0x1A86 && device.productId == 0x7523) {
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
                usbManager.requestPermission(device, pi)
                return "requested"
            }
        }
        Log.w(TAG_KIOSK, "No CH340 found (deviceList size=${usbManager.deviceList.size})")
        return if (sawDevice) "requested" else "no_device"
    }

    override fun onDestroy() {
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
        applyImmersive()
        tryEnterLockTask()
        applyGestureExclusion()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            applyImmersive()
            applyGestureExclusion()
        }
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
        // Fully disable the status bar — swipe-down does nothing, no
        // notification panel, no quick settings. Survives even if the
        // operator briefly leaves lock-task via «Выйти в Android».
        try {
            dpm.setStatusBarDisabled(admin, true)
            Log.i(TAG_KIOSK, "setStatusBarDisabled(true) OK")
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

    companion object {
        private const val KIOSK_CHANNEL = "kz.smartvend/kiosk"
    }
}
