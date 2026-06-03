package com.micromart

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.*
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class CommandListener(
    private val context: Context,
    private val machineNumber: String
) {
    private val client = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    private var webSocket: WebSocket? = null
    private var marketUuid: String? = null
    private val handler = Handler(Looper.getMainLooper())
    private var isStarted = false
    private val processedCommandIds = mutableSetOf<String>()

    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            sendHeartbeat()
            handler.postDelayed(this, 25000)
        }
    }

    private val fallbackPollingRunnable = object : Runnable {
        override fun run() {
            if (isStarted) {
                checkCommandsManually()
                handler.postDelayed(this, 15000) // Раз в 15 секунд
            }
        }
    }

    private fun showToast(msg: String) {
        handler.post {
            android.widget.Toast.makeText(context, msg, android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    fun start() {
        if (isStarted) return
        isStarted = true
        connect()
        handler.postDelayed(fallbackPollingRunnable, 5000)
    }

    fun stop() {
        isStarted = false
        handler.removeCallbacks(heartbeatRunnable)
        handler.removeCallbacks(fallbackPollingRunnable)
        webSocket?.close(1000, "Stopped by user")
        webSocket = null
    }

    private fun connect() {
        Thread {
            marketUuid = SupabaseApi.findMicromarketUuid(machineNumber)
            if (marketUuid == null) {
                Log.e("CommandListener", "Could not find UUID for machine $machineNumber")
                showToast("Ошибка: Аппарат $machineNumber не найден в БД")
                handler.postDelayed({ if (isStarted) connect() }, 10000)
                return@Thread
            }

            val wsUrl = "${SupabaseApi.getBaseUrl().replace("https://", "wss://")}/realtime/v1/websocket?apikey=${SupabaseApi.getAnonKey()}&vsn=1.0.0"
            val request = Request.Builder().url(wsUrl).build()

            webSocket = client.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    Log.i("CommandListener", "WebSocket Connected")
                    showToast("Удаленное управление: Подключено")
                    joinChannel()
                    handler.post(heartbeatRunnable)
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    handleMessage(text)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    Log.e("CommandListener", "WebSocket Failure: ${t.message}")
                    showToast("Связь Supabase: Ошибка. Переподключение...")
                    if (isStarted) {
                        handler.postDelayed({ connect() }, 10000)
                    }
                }
            })
        }.start()
    }

    private fun checkCommandsManually() {
        val uuid = marketUuid ?: return
        Thread {
            val pending = SupabaseApi.fetchPendingCommands(uuid)
            for (cmd in pending) {
                val commandId = cmd.optString("id")
                if (processedCommandIds.contains(commandId)) continue
                
                val type = cmd.optString("command_type")
                if (type == "open") {
                    Log.i("CommandListener", "Polling found OPEN command: $commandId")
                    executeOpen(commandId)
                }
            }
        }.start()
    }

    private fun joinChannel() {
        val joinMsg = JSONObject().apply {
            put("topic", "realtime:public:commands")
            put("event", "phx_join")
            put("payload", JSONObject().apply {
                put("config", JSONObject().apply {
                    val change = JSONObject().apply {
                        put("event", "INSERT")
                        put("schema", "public")
                        put("table", "commands")
                        put("filter", "micromarket_id=eq.$marketUuid")
                    }
                    put("postgres_changes", org.json.JSONArray().put(change))
                })
            })
            put("ref", "join_ref")
        }
        webSocket?.send(joinMsg.toString())
    }

    private fun sendHeartbeat() {
        val hb = JSONObject().apply {
            put("topic", "phoenix")
            put("event", "heartbeat")
            put("payload", JSONObject())
            put("ref", "hb_ref")
        }
        webSocket?.send(hb.toString())
    }

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)
            val event = json.optString("event")
            
            if (event == "postgres_changes") {
                val payload = json.optJSONObject("payload") ?: return
                val data = payload.optJSONObject("data") ?: return
                
                val commandId = data.optString("id")
                if (processedCommandIds.contains(commandId)) return

                val type = data.optString("command_type")
                val status = data.optString("status")

                if (type == "open" && status == "pending") {
                    Log.i("CommandListener", "WS received OPEN command: $commandId")
                    executeOpen(commandId)
                }
            }
        } catch (e: Exception) {
            Log.e("CommandListener", "Error parsing message: ${e.message}")
        }
    }

    private fun executeOpen(commandId: String) {
        if (processedCommandIds.contains(commandId)) return
        processedCommandIds.add(commandId)
        
        // Очищаем историю старых ID каждые 100 команд, чтобы не раздувать память
        if (processedCommandIds.size > 100) {
            val sorted = processedCommandIds.toList()
            processedCommandIds.clear()
            processedCommandIds.addAll(sorted.takeLast(50))
        }

        showToast("Получена команда: ОТКРЫТЬ")
        // Trigger relay
        UsbController(context).openDoor { success, msg ->
            Thread {
                val finalStatus = if (success) "completed" else "failed"
                SupabaseApi.updateCommandStatus(commandId, finalStatus)
                Log.i("CommandListener", "Command $commandId finished with $finalStatus ($msg)")
            }.start()
        }
    }
}
