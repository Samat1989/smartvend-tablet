package com.micromart

import android.content.ClipData
import android.content.ComponentName
import android.content.Intent
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import android.graphics.Canvas
import android.graphics.BitmapFactory
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class QrActivity : AppCompatActivity() {

    private val PAYMENT_URL = "https://levending.smartvend.kz/payment_request"
    private val RESULT_URL  = "https://levending.smartvend.kz/payment_result"
    private val SOFTPOS_REQUEST_CODE = 200

    private val handler = Handler(Looper.getMainLooper())
    private var pollingRunnable: Runnable? = null

    private lateinit var machid: String
    private lateinit var appkey: String

    data class PaymentRequest(
        val twocode: String,
        val orderid: String,
        val torderid: String,
        val curl: String
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_qr)

        val tvProductName  = findViewById<TextView>(R.id.tvProductName)
        val tvProductPrice = findViewById<TextView>(R.id.tvProductPrice)
        val layoutKaspi    = findViewById<View>(R.id.layoutKaspi)
        val layoutCard     = findViewById<View>(R.id.layoutCard)
        val cardKaspi      = findViewById<View>(R.id.cardKaspi)
        val cardCard       = findViewById<View>(R.id.cardCard)
        val btnGenerateQr  = findViewById<Button>(R.id.btnGenerateQr)
        val ivQrCode       = findViewById<ImageView>(R.id.ivQrCode)
        val progressBar    = findViewById<ProgressBar>(R.id.progressBar)
        val tvStatus       = findViewById<TextView>(R.id.tvStatus)

        val prefs = getSharedPreferences("micromart_prefs", Context.MODE_PRIVATE)
        machid = prefs.getString("device_number", "") ?: ""
        appkey = prefs.getString("secret", "") ?: ""

        val productName  = intent.getStringExtra("product_name") ?: "Товар"
        val productPrice = intent.getIntExtra("product_price", 0)

        tvProductName.text  = productName
        tvProductPrice.text = "${productPrice / 100} ₸"

        findViewById<Button>(R.id.btnBack).setOnClickListener { finish() }

        fun startQrGeneration() {
            val priceInCents = productPrice
            if (priceInCents <= 0) {
                Toast.makeText(this, "Неверная цена товара", Toast.LENGTH_SHORT).show()
                return
            }

            stopPolling()
            ivQrCode.visibility = View.GONE
            tvStatus.text = ""
            progressBar.visibility = View.VISIBLE
            btnGenerateQr.isEnabled = false

            Thread {
                val result = runCatching { requestPaymentQr(priceInCents, productName) }
                runOnUiThread {
                    progressBar.visibility = View.GONE
                    btnGenerateQr.isEnabled = true
                    result.fold(
                        onSuccess = { payment ->
                            val bitmap = generateQrCode(payment.twocode)
                            if (bitmap != null) {
                                ivQrCode.setImageBitmap(bitmap)
                                ivQrCode.visibility = View.VISIBLE
                            }
                            tvStatus.setTextColor(0xFF757575.toInt())
                            tvStatus.text = "Ожидание оплаты..."
                            startPolling(payment.orderid, payment.torderid, tvStatus, ivQrCode, btnGenerateQr)
                        },
                        onFailure = { e ->
                            tvStatus.setTextColor(0xFFD32F2F.toInt())
                            tvStatus.text = "Ошибка: ${e.message}"
                        }
                    )
                }
            }.start()
        }

        // Выбор способа оплаты
        cardKaspi.setOnClickListener {
            cardKaspi.visibility = View.GONE
            cardCard.visibility  = View.GONE
            layoutKaspi.visibility = View.VISIBLE
            startQrGeneration()
        }
        
        cardCard.setOnClickListener {
            startSoftPosPayment()
        }
        
        findViewById<Button>(R.id.btnCardBack).setOnClickListener {
            layoutCard.visibility  = View.GONE
            layoutKaspi.visibility = View.GONE
            cardKaspi.visibility = View.VISIBLE
            cardCard.visibility  = View.VISIBLE
        }

        btnGenerateQr.setOnClickListener {
            startQrGeneration()
        }
    }

    private fun startSoftPosPayment() {
        try {
            val inputJson = prepareSoftPosJson()
            val intent = Intent()
            
            // Пробуем запустить через SplashActivity, как вы указывали
            intent.component = ComponentName(
                "ru.m4bank.softpos.halyk", 
                "ru.m4bank.basempos.splash.SplashActivity"
            )
            intent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            intent.putExtra("EXTERNAL_OPERATION_TYPE_KEY", "PAYMENT")
            intent.putExtra("EXTERNAL_INPUT_DATA_KEY", inputJson)
            
            // Проверяем, существует ли такая активность в системе
            val packageManager = packageManager
            if (intent.resolveActivity(packageManager) != null) {
                startActivityForResult(intent, SOFTPOS_REQUEST_CODE)
            } else {
                Toast.makeText(this, "Терминал HalykPOS не настроен или не поддерживает этот метод вызова", Toast.LENGTH_LONG).show()
                // Как запасной вариант, если Splash не сработал - пробуем стандартный
                intent.component = ComponentName(
                    "ru.m4bank.softpos.halyk", 
                    "ru.m4bank.feature.externalapplication.ExternalApplicationActivity"
                )
                if (intent.resolveActivity(packageManager) != null) {
                    startActivityForResult(intent, SOFTPOS_REQUEST_CODE)
                } else {
                    Toast.makeText(this, "Приложение HalykPOS не найдено", Toast.LENGTH_LONG).show()
                }
            }
        } catch (e: Exception) {
            Toast.makeText(this, "Критическая ошибка запуска: ${e.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun prepareSoftPosJson(): String {
        val root = JSONObject()
        root.put("amount", CartManager.getTotal()) // В тиынах (минимальных единицах)
        root.put("currency", "KZT")
        
        val goodsJson = JSONArray()
        CartManager.getItems().forEach { (product, qty) ->
            val item = JSONObject()
            item.put("name", product.name)
            item.put("price", product.price)
            item.put("quantity", qty)
            item.put("tax_rate", 0) // Ставка 0% или по умолчанию
            goodsJson.put(item)
        }
        root.put("goods", goodsJson)
        return root.toString()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SOFTPOS_REQUEST_CODE) {
            if (resultCode == RESULT_OK && data != null) {
                val resultJson = data.getStringExtra("EXTERNAL_RESULT_DATA_KEY")
                if (!resultJson.isNullOrEmpty()) {
                    val json = JSONObject(resultJson)
                    val status = json.optString("status", "error")
                    if (status.lowercase() == "success") {
                        handlePaymentSuccess("Оплата картой одобрена")
                    } else {
                        val msg = json.optString("result_message", "Ошибка транзакции")
                        Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                    }
                }
            } else {
                Toast.makeText(this, "Оплата картой отменена", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun handlePaymentSuccess(initialMsg: String) {
        val tvStatus = findViewById<TextView>(R.id.tvStatus)
        val ivQrCode = findViewById<ImageView>(R.id.ivQrCode)
        val btnGenerateQr = findViewById<Button>(R.id.btnGenerateQr)
        
        // Показываем статус, если скрыт
        findViewById<View>(R.id.cardKaspi).visibility = View.GONE
        findViewById<View>(R.id.cardCard).visibility = View.GONE
        findViewById<View>(R.id.layoutKaspi).visibility = View.VISIBLE
        
        tvStatus.setTextColor(0xFF388E3C.toInt())
        tvStatus.text = "$initialMsg! Открываем замок..."
        ivQrCode.visibility = View.GONE
        btnGenerateQr.isEnabled = false

        UsbController(this).openDoor { usbSuccess, usbMsg ->
            runOnUiThread {
                tvStatus.text = if (usbSuccess)
                    "Успешно! $usbMsg\nСохраняем заказ..."
                else
                    "Оплата принята. Ошибка замка: $usbMsg\nСохраняем заказ..."

                val itemsCopy = CartManager.getItems().toMap()
                Thread {
                    val saleSaved = SupabaseApi.processSale(machid, appkey, itemsCopy)
                    runOnUiThread {
                        if (saleSaved) {
                            tvStatus.text = "Заказ успешно сохранен!"
                            CartManager.getItems().forEach { (product, qty) ->
                                ProductStore.decreaseStock(this, product.id, qty)
                            }
                            CartManager.clear()
                            
                            handler.postDelayed({
                                val intent = Intent(this, ProductsActivity::class.java)
                                intent.flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                                startActivity(intent)
                                finish()
                            }, 1500)
                        } else {
                            tvStatus.setTextColor(0xFFD32F2F.toInt())
                            tvStatus.text = "Ошибка сохранения заказа в облаке.\nСвяжитесь с поддержкой."
                            btnGenerateQr.isEnabled = true
                        }
                    }
                }.start()
            }
        }
    }

    private fun startPolling(
        orderid: String,
        torderid: String,
        tvStatus: TextView,
        ivQrCode: ImageView,
        btnGenerateQr: Button
    ) {
        val startTime = System.currentTimeMillis()
        val maxDuration = 5 * 60 * 1000L // 5 минут

        pollingRunnable = object : Runnable {
            override fun run() {
                if (System.currentTimeMillis() - startTime > maxDuration) {
                    tvStatus.setTextColor(0xFFD32F2F.toInt())
                    tvStatus.text = "Время ожидания истекло"
                    ivQrCode.visibility = View.GONE
                    btnGenerateQr.isEnabled = true
                    return
                }
                Thread {
                    val code = runCatching { pollPaymentResult(orderid, torderid) }.getOrNull()
                    runOnUiThread {
                        when (code) {
                            1 -> {
                                stopPolling()
                                handlePaymentSuccess("Оплата прошла успешно")
                            }
                            2 -> handler.postDelayed(this, 3000)
                            3 -> {
                                tvStatus.setTextColor(0xFFD32F2F.toInt())
                                tvStatus.text = "Транзакция истекла"
                                ivQrCode.visibility = View.GONE
                                btnGenerateQr.isEnabled = true
                            }
                            4 -> {
                                tvStatus.setTextColor(0xFFD32F2F.toInt())
                                tvStatus.text = "Транзакция закрыта"
                                ivQrCode.visibility = View.GONE
                                btnGenerateQr.isEnabled = true
                            }
                            5 -> {
                                tvStatus.setTextColor(0xFF388E3C.toInt())
                                tvStatus.text = "Транзакция завершена"
                                ivQrCode.visibility = View.GONE
                                btnGenerateQr.isEnabled = true
                            }
                            else -> handler.postDelayed(this, 3000)
                        }
                    }
                }.start()
            }
        }
        handler.postDelayed(pollingRunnable!!, 3000)
    }

    private fun stopPolling() {
        pollingRunnable?.let { handler.removeCallbacks(it) }
        pollingRunnable = null
    }

    // Returns payment result code: 1=success, 2=waiting, 3=expired, 4=closed, 5=completed
    private fun pollPaymentResult(orderid: String, torderid: String): Int {
        val timestamp = SimpleDateFormat("yyyyMMddHHmmss", Locale.getDefault()).format(Date())
        val randstr = generateRandStr()
        val sign = generateSign(appkey, randstr, timestamp)

        val fields = listOf(
            "ver" to "v1",
            "orderid" to orderid,
            "torderid" to torderid,
            "machid" to machid,
            "channelid" to "36",
            "randstr" to randstr,
            "timestamp" to timestamp,
            "sign" to sign
        )
        val formBody = fields.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }

        val conn = URL(RESULT_URL).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        conn.connectTimeout = 10000
        conn.readTimeout = 10000
        OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(formBody) }

        val response = conn.inputStream.bufferedReader(Charsets.UTF_8).readText()
        return JSONObject(response).optString("code").toIntOrNull() ?: 2
    }

    private fun requestPaymentQr(priceInCents: Int, name: String): PaymentRequest {
        val timestamp = SimpleDateFormat("yyyyMMddHHmmss", Locale.getDefault()).format(Date())
        val randstr = generateRandStr()
        val sign = generateSign(appkey, randstr, timestamp)
        val orderid = (machid + timestamp + randstr.take(6)).take(59)

        val fields = listOf(
            "ver" to "v1",
            "orderid" to orderid,
            "machid" to machid,
            "trackno" to "01",
            "name" to name,
            "price" to priceInCents.toString(),
            "channelid" to "36",
            "randstr" to randstr,
            "timestamp" to timestamp,
            "sign" to sign
        )
        val formBody = fields.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }
        val curl = "curl -X POST '$PAYMENT_URL' \\\n  -d '$formBody'"

        val conn = URL(PAYMENT_URL).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        conn.connectTimeout = 15000
        conn.readTimeout = 15000
        OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(formBody) }

        val httpCode = conn.responseCode
        val stream = if (httpCode in 200..299) conn.inputStream else conn.errorStream
        val response = stream.bufferedReader(Charsets.UTF_8).readText()

        if (httpCode !in 200..299) throw Exception("HTTP $httpCode: $response")

        val json = JSONObject(response)
        val code = json.optString("code")
        val msg  = json.optString("msg")

        if (code != "1") throw Exception("Сервер: $msg (code=$code)")

        return PaymentRequest(
            twocode  = json.optString("twocode"),
            orderid  = json.optString("orderid"),
            torderid = json.optString("torderid"),
            curl     = curl
        )
    }

    private fun buildCurl(priceInCents: Int, name: String): String {
        val timestamp = SimpleDateFormat("yyyyMMddHHmmss", Locale.getDefault()).format(Date())
        val randstr = generateRandStr()
        val sign = generateSign(appkey, randstr, timestamp)
        val orderid = (machid + timestamp + randstr.take(6)).take(59)
        val encodedName = URLEncoder.encode(name, "UTF-8")
        val formBody = "ver=v1&orderid=$orderid&machid=$machid&trackno=01" +
                "&name=$encodedName&price=$priceInCents" +
                "&channelid=36&randstr=$randstr&timestamp=$timestamp&sign=$sign"
        return "curl -X POST '$PAYMENT_URL' \\\n  -d '$formBody'"
    }

    private fun generateSign(appkey: String, randstr: String, timestamp: String): String {
        val combined = listOf(appkey, randstr, timestamp).sorted().joinToString("")
        return MessageDigest.getInstance("SHA-1")
            .digest(combined.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun generateRandStr(): String {
        val chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return (1..16).map { chars.random() }.joinToString("")
    }

    private fun generateQrCode(content: String): Bitmap? {
        return try {
            val bitMatrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, 512, 512)
            val qrBitmap = Bitmap.createBitmap(512, 512, Bitmap.Config.RGB_565)
            for (x in 0 until 512) {
                for (y in 0 until 512) {
                    qrBitmap.setPixel(x, y, if (bitMatrix[x, y]) Color.BLACK else Color.WHITE)
                }
            }

            qrBitmap
        } catch (e: Exception) {
            null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopPolling()
    }
}
