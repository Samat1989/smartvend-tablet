package kz.smartvend.m102_tester

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log

/**
 * Status sink for [PackageInstaller] sessions. The OS broadcasts the
 * outcome (success / failure with reason) when an install completes;
 * we just log it. On success the process is replaced before this even
 * fires, so the failure paths are the important ones.
 */
class InstallReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "InstallReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Non-owner devices show a confirm dialog. Launch it.
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(confirm)
                }
            }
            PackageInstaller.STATUS_SUCCESS ->
                Log.i(TAG, "install succeeded")
            else ->
                Log.e(TAG, "install failed: status=$status msg=$msg")
        }
    }
}
