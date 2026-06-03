package com.micromart

import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

object SupabaseApi {
    private const val SUPABASE_URL = "https://cgvfhtvdtdjsyluhlcbq.supabase.co"
    private const val ANON_KEY = "sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD"
    private const val EDGE_FUNCTION_URL = "$SUPABASE_URL/functions/v1/process_kiosk_sale"

    fun getBaseUrl() = SUPABASE_URL
    fun getAnonKey() = ANON_KEY

    // Шаг 1: Получаем UUID микромаркета по числовому machine_number
    fun findMicromarketUuid(machineNumber: String): String? {
        try {
            val url = URL("$SUPABASE_URL/rest/v1/micromarkets?id=eq.$machineNumber&select=id&limit=1")
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "GET"
            conn.setRequestProperty("apikey", ANON_KEY)
            conn.setRequestProperty("Authorization", "Bearer $ANON_KEY")
            conn.connectTimeout = 10000
            conn.readTimeout = 10000

            val httpCode = conn.responseCode
            if (httpCode in 200..299) {
                val response = conn.inputStream?.bufferedReader()?.readText() ?: "[]"
                val arr = JSONArray(response)
                if (arr.length() > 0) {
                    return arr.getJSONObject(0).getString("id")
                }
            }
            return null
        } catch (e: Exception) {
            return null
        }
    }

    // Обновляем статус команды
    fun updateCommandStatus(commandId: String, status: String): Boolean {
        try {
            val url = URL("$SUPABASE_URL/rest/v1/commands?id=eq.$commandId")
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "PATCH"
            conn.setRequestProperty("apikey", ANON_KEY)
            conn.setRequestProperty("Authorization", "Bearer $ANON_KEY")
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("Prefer", "return=minimal")
            conn.doOutput = true

            val body = JSONObject().put("status", status).toString()
            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use {
                it.write(body)
                it.flush()
            }

            return conn.responseCode in 200..299
        } catch (e: Exception) {
            return false
        }
    }

    // Загружаем список невыполненных команд
    fun fetchPendingCommands(marketUuid: String): List<JSONObject> {
        try {
            val url = URL("$SUPABASE_URL/rest/v1/commands?micromarket_id=eq.$marketUuid&status=eq.pending")
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "GET"
            conn.setRequestProperty("apikey", ANON_KEY)
            conn.setRequestProperty("Authorization", "Bearer $ANON_KEY")
            conn.connectTimeout = 10000
            conn.readTimeout = 10000

            if (conn.responseCode in 200..299) {
                val response = conn.inputStream?.bufferedReader()?.readText() ?: "[]"
                val arr = JSONArray(response)
                val list = mutableListOf<JSONObject>()
                for (i in 0 until arr.length()) {
                    list.add(arr.getJSONObject(i))
                }
                return list
            }
        } catch (e: Exception) {
            // Ignore
        }
        return emptyList()
    }

    // Загружаем товары по machine_number (числовой номер аппарата)
    fun fetchInventory(machineNumber: String): Pair<List<Product>?, String?> {
        if (machineNumber.isEmpty()) return Pair(null, "Номер аппарата пустой")

        val marketUuid = findMicromarketUuid(machineNumber)
            ?: return Pair(null, "Аппарат $machineNumber не найден в базе")

        try {
            val url = URL("$SUPABASE_URL/rest/v1/inventory?micromarket_id=eq.$marketUuid&select=*")
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "GET"
            conn.setRequestProperty("apikey", ANON_KEY)
            conn.setRequestProperty("Authorization", "Bearer $ANON_KEY")
            conn.connectTimeout = 10000
            conn.readTimeout = 10000

            val httpCode = conn.responseCode
            if (httpCode in 200..299) {
                val response = conn.inputStream?.bufferedReader()?.readText() ?: "[]"
                val jsonArray = JSONArray(response)
                val products = mutableListOf<Product>()

                for (i in 0 until jsonArray.length()) {
                    val obj = jsonArray.getJSONObject(i)
                    val dbPrice = obj.optDouble("price", 0.0)
                    products.add(
                        Product(
                            id        = obj.optString("id", java.util.UUID.randomUUID().toString()),
                            name      = obj.optString("name", "Unknown"),
                            price     = (dbPrice * 100).toInt(),
                            emoji     = "🛒",
                            stock     = obj.optInt("stock", 0),
                            imagePath = if (obj.isNull("image_url")) null else obj.getString("image_url")
                        )
                    )
                }
                return Pair(products, null)
            } else {
                val body = conn.errorStream?.bufferedReader()?.readText() ?: "no body"
                return Pair(null, "HTTP $httpCode: $body")
            }
        } catch (t: Throwable) {
            return Pair(null, t.message ?: "Exception")
        }
    }

    // Отправляем продажи в Edge Function (machid = machine_number, secret = api_secret)
    fun processSale(
        machid: String,
        secret: String,
        cartItems: Map<Product, Int>
    ): Boolean {
        try {
            val url = URL(EDGE_FUNCTION_URL)
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("Authorization", "Bearer $ANON_KEY")
            conn.doOutput = true

            val root = JSONObject()
            root.put("machid", machid.toLongOrNull() ?: machid) // передаём число
            root.put("secret", secret.trim())                   // trim на случай \r\n

            val salesArray = JSONArray()
            cartItems.forEach { (product, qty) ->
                val item = JSONObject()
                item.put("product_id", product.id)
                item.put("amount", product.price * qty / 100.0)
                item.put("qty", qty)
                salesArray.put(item)
            }
            root.put("sales", salesArray)

            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use {
                it.write(root.toString())
                it.flush()
            }

            val httpCode = conn.responseCode
            return httpCode in 200..299
        } catch (e: Exception) {
            return false
        }
    }
}
