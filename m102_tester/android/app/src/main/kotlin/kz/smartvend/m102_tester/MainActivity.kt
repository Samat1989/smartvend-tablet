package kz.smartvend.m102_tester

import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the display on while the activity is in the foreground.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

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
        try {
            startLockTask()
        } catch (_: Throwable) {
            // Not allowed on this device / not pinned. Ignore.
        }
    }
}
