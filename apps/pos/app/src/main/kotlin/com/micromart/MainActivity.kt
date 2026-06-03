package com.micromart

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    companion object {
        const val PREFS_NAME        = "micromart_prefs"
        const val KEY_DEVICE_NUMBER = "device_number"
        const val KEY_SECRET        = "secret"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // Очищаем кеш тестовых товаров при каждом старте из MainActivity
        // (если настройки ещё не заполнены — значит это первый запуск или сброс)
        getSharedPreferences("product_store", Context.MODE_PRIVATE).edit().clear().apply()

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        // Если всё настроено — сразу на витрину
        val savedNumber = prefs.getString(KEY_DEVICE_NUMBER, "")
        val savedSecret = prefs.getString(KEY_SECRET, "")
        if (!savedNumber.isNullOrEmpty() && !savedSecret.isNullOrEmpty()) {
            startActivity(Intent(this, ProductsActivity::class.java))
            finish()
            return
        }

        val etDeviceNumber = findViewById<EditText>(R.id.etDeviceNumber)
        val etSecret       = findViewById<EditText>(R.id.etSecret)
        val btnSave        = findViewById<Button>(R.id.btnSave)

        btnSave.setOnClickListener {
            val deviceNumber = etDeviceNumber.text.toString().trim()
            val secret       = etSecret.text.toString().trim()

            when {
                deviceNumber.isEmpty() -> Toast.makeText(this, "Введите ID микромаркета", Toast.LENGTH_SHORT).show()
                secret.isEmpty()       -> Toast.makeText(this, "Введите API секрет", Toast.LENGTH_SHORT).show()
                else -> {
                    prefs.edit()
                        .putString(KEY_DEVICE_NUMBER, deviceNumber)
                        .putString(KEY_SECRET, secret)
                        .apply()
                    startActivity(Intent(this, ProductsActivity::class.java))
                    finish()
                }
            }
        }
    }
}
