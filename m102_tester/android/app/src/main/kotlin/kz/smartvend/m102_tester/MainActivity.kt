package kz.smartvend.m102_tester

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.view.View
import android.view.WindowManager
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KIOSK_CHANNEL)
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
    }

    override fun onResume() {
        super.onResume()
        applyImmersive()
        tryEnterLockTask()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            applyImmersive()
        }
    }

    private fun applyImmersive() {
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
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
        try {
            startLockTask()
        } catch (_: Throwable) {
            // Not allowed on this device / not pinned. Ignore.
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
            as? DevicePolicyManager ?: return
        if (!dpm.isDeviceOwnerApp(packageName)) return
        val admin = KioskAdminReceiver.componentName(this)
        try {
            dpm.setLockTaskPackages(admin, arrayOf(packageName))
        } catch (_: SecurityException) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // 0 == LOCK_TASK_FEATURE_NONE — hides every system surface
            // (status bar, nav bar, notifications, keyguard, recents).
            try {
                dpm.setLockTaskFeatures(admin, 0)
            } catch (_: Throwable) {
                // Older OEM builds occasionally throw — ignore so the
                // base lock-task still applies.
            }
        }
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
