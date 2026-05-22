package kz.smartvend.m102_tester

import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                    else -> result.notImplemented()
                }
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

    companion object {
        private const val KIOSK_CHANNEL = "kz.smartvend/kiosk"
    }
}
