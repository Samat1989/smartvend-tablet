package kz.smartvend.m102_tester

import android.app.admin.DeviceAdminReceiver
import android.content.ComponentName
import android.content.Context

/**
 * Empty admin receiver — its only job is to exist so the package
 * can be provisioned as device owner via:
 *
 *   adb shell dpm set-device-owner \
 *     kz.smartvend.m102_tester/.KioskAdminReceiver
 *
 * Once that succeeds, [MainActivity] adds itself to the lock-task
 * allowlist with [android.app.admin.DevicePolicyManager.setLockTaskPackages]
 * and [android.app.admin.DevicePolicyManager.setLockTaskFeatures], and
 * subsequent `startLockTask` calls silently pin the app without the
 * Android "App is pinned" confirmation dialog and without leaving the
 * navigation bar visible.
 */
class KioskAdminReceiver : DeviceAdminReceiver() {
    companion object {
        fun componentName(context: Context): ComponentName =
            ComponentName(context, KioskAdminReceiver::class.java)
    }
}
