package com.micromart

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbManager
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager

class UsbController(private val context: Context) {

    private val ACTION_USB_PERMISSION = "com.micromart.USB_PERMISSION"
    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager

    // Sends "OPEN_DOOR\n" to ESP32 and returns result via callback on main thread
    fun openDoor(onResult: (success: Boolean, message: String) -> Unit) {
        val drivers = UsbSerialProber.getDefaultProber().findAllDrivers(usbManager)
        if (drivers.isEmpty()) {
            onResult(false, "ESP32 не подключён")
            return
        }

        val driver = drivers.first()
        val device = driver.device

        if (!usbManager.hasPermission(device)) {
            val permissionIntent = PendingIntent.getBroadcast(
                context, 0,
                Intent(ACTION_USB_PERMISSION),
                PendingIntent.FLAG_IMMUTABLE
            )

            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    context.unregisterReceiver(this)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        sendCommand(driver.ports.first(), onResult)
                    } else {
                        onResult(false, "Нет разрешения на USB")
                    }
                }
            }
            context.registerReceiver(receiver, IntentFilter(ACTION_USB_PERMISSION),
                Context.RECEIVER_NOT_EXPORTED)
            usbManager.requestPermission(device, permissionIntent)
        } else {
            sendCommand(driver.ports.first(), onResult)
        }
    }

    private fun sendCommand(
        port: com.hoho.android.usbserial.driver.UsbSerialPort,
        onResult: (Boolean, String) -> Unit
    ) {
        try {
            val connection = usbManager.openDevice(port.driver.device)
                ?: return onResult(false, "Не удалось открыть USB")

            port.open(connection)
            port.setParameters(115200, 8,
                com.hoho.android.usbserial.driver.UsbSerialPort.STOPBITS_1,
                com.hoho.android.usbserial.driver.UsbSerialPort.PARITY_NONE)

            // Critical for ESP32/Arduino: setting DTR/RTS and waiting for boot
            port.dtr = true
            port.rts = true
            Thread.sleep(1000) // Ждем инициализации контроллера после открытия порта

            // Отправляем команду открытия (только один вариант)
            port.write("1\n".toByteArray(Charsets.UTF_8), 500)

            // Читаем ответ STATUS:OPENED
            val buffer = ByteArray(64)
            val len = runCatching { port.read(buffer, 2000) }.getOrDefault(0)
            val response = String(buffer, 0, len).trim()

            port.close()

            if (response.contains("STATUS:OPENED")) {
                onResult(true, "Замок успешно открыт")
            } else {
                // Если ответ не содержит STATUS:OPENED, но команда ушла без ошибок
                onResult(true, "Команда отправлена. Ответ контроллера: $response")
            }
        } catch (e: Exception) {
            runCatching { port.close() }
            onResult(false, "Ошибка USB соединения: ${e.message}")
        }
    }
}
