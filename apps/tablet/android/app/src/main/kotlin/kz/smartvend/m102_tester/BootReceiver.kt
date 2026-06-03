package kz.smartvend.m102_tester

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-launches the vending app right after the device finishes booting.
 *
 * The vending machine has no operator on-site to tap an icon after a
 * power outage — without this the kiosk would just sit on the lock screen
 * until someone physically interacted with it. Catches:
 *   • BOOT_COMPLETED — standard cold boot
 *   • LOCKED_BOOT_COMPLETED — direct-boot devices, fires before user unlock
 *   • QUICKBOOT_POWERON — vendor-specific "fast boot" alias used by some
 *     tablet OEMs (e.g. HTC, some Chinese ROMs); harmless on devices that
 *     don't broadcast it.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        when (action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                val launch = Intent(context, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                    )
                }
                context.startActivity(launch)
            }
        }
    }
}
