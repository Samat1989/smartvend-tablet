package kz.smartvend.mmd

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val provisioner = AdbProvisioner(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AdbProvisioner.CHANNEL,
        ).setMethodCallHandler(provisioner)
        // Pairing cannot report through the method channel: it waits on a
        // human pointing a camera, so progress arrives long after the call
        // that started it has returned.
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AdbProvisioner.EVENTS,
        ).setStreamHandler(provisioner.streamHandler)
    }
}
