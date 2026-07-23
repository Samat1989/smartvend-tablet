package kz.smartvend.m102_tester

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log

/**
 * Status sink for [PackageInstaller] sessions. The OS broadcasts the
 * outcome (pending-user-action / success / failure with reason); we
 * launch the confirm dialog when asked and mirror every status into
 * Flutter via [MainActivity.notifyInstallStatus] so the update screen
 * can tell the operator WHY an install stalled instead of hanging on
 * "Загрузка…". On success the process is replaced before the UI could
 * show anything, so the pending/failure paths are the important ones.
 */
class InstallReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "InstallReceiver"

        /** Synthetic status for "confirm dialog failed to launch". */
        const val STATUS_CONFIRM_LAUNCH_FAILED = 100
    }

    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val activity = MainActivity.instance
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Non-owner devices show a confirm dialog. Prefer the live
                // activity context — receiver-context startActivity counts
                // as a background start on some ROMs and is silently
                // dropped, which looked like "download finishes, nothing
                // happens".
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm == null) {
                    Log.e(TAG, "pending user action but no confirm intent")
                    activity?.notifyInstallStatus(
                        STATUS_CONFIRM_LAUNCH_FAILED, "no confirm intent")
                    return
                }
                try {
                    if (activity != null) {
                        activity.startActivity(confirm)
                    } else {
                        confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(confirm)
                    }
                    Log.i(TAG, "launched install confirm dialog")
                    activity?.notifyInstallStatus(status, msg)
                } catch (t: Throwable) {
                    Log.e(TAG, "confirm dialog launch failed: ${t.message}")
                    activity?.notifyInstallStatus(
                        STATUS_CONFIRM_LAUNCH_FAILED, t.message)
                }
            }
            PackageInstaller.STATUS_SUCCESS ->
                Log.i(TAG, "install succeeded")
            else -> {
                Log.e(TAG, "install failed: status=$status msg=$msg")
                activity?.notifyInstallStatus(status, msg)
            }
        }
    }
}
