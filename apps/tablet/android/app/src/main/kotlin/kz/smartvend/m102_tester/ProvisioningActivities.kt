package kz.smartvend.m102_tester

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Intent
import android.os.Bundle
import android.util.Log

/**
 * Provisioning hand-shake activities required by Android 11+.
 *
 * Up to Android 10 a QR provisioning payload was enough on its own:
 * ManagedProvisioning downloaded the APK, granted device owner and was
 * done. From API 30 the flow asks the DPC two questions instead of
 * assuming the answers, and a DPC that targets 30 or higher and cannot
 * answer them fails the whole provisioning right after the scan — which
 * is exactly the error seen on the K80 (targetSdk 36).
 *
 * Neither screen has anything to show a human, hence Theme.NoDisplay and
 * an immediate finish(): we answer and get out of the setup wizard's way.
 *
 * Both are protected by BIND_DEVICE_ADMIN so only the system can start
 * them — without that, any app could launch them and, on the compliance
 * side, fake a finished provisioning.
 */
class ProvisioningModeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // "Fully managed device", never a work profile: this is a vending
        // tablet, and the whole point is that we own the device rather
        // than live in a container on someone's phone.
        val result = Intent().putExtra(
            DevicePolicyManager.EXTRA_PROVISIONING_MODE,
            DevicePolicyManager.PROVISIONING_MODE_FULLY_MANAGED_DEVICE,
        )
        Log.i(TAG, "GET_PROVISIONING_MODE -> fully managed device")
        setResult(RESULT_OK, result)
        finish()
    }

    private companion object {
        const val TAG = "SmartvendProvision"
    }
}

/**
 * Launched once provisioning has finished, so the DPC can walk the
 * operator through anything still outstanding before the device is
 * handed over.
 *
 * We have nothing to ask for: the kiosk policies are applied by
 * [MainActivity.configureDeviceOwnerKiosk] on the next start, and machine
 * pairing happens later in the service menu with a PIN. So we simply
 * report success and let the setup wizard finish — the launcher that
 * comes up afterwards is already ours.
 */
class PolicyComplianceActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i("SmartvendProvision", "ADMIN_POLICY_COMPLIANCE -> ok")
        setResult(RESULT_OK)
        finish()
    }
}
