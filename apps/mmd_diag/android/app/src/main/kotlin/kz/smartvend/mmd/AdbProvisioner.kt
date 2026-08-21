package kz.smartvend.mmd

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.AdbStream
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.io.IOException
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Turns this phone into an ADB host so a technician can provision a brand-new
 * tablet in the field with nothing but the two devices.
 *
 * The sequence it drives is the one Android Studio drives over Wi-Fi:
 *
 *     show a pairing QR  ->  tablet scans it  ->  pair  ->  connect
 *                        ->  push and install the kiosk APK
 *                        ->  dpm set-device-owner
 *
 * Direction of the QR is the part that surprises people: **this phone shows
 * it and the tablet's camera reads it**. Scanning tells the tablet a service
 * name and a password; the tablet then advertises `_adb-tls-pairing._tcp`
 * under that name, and we go to it. So the QR is not a credential we send —
 * it is a rendezvous we both agree on.
 *
 * What this cannot do, and no amount of code will: get onto a tablet whose
 * owner has not enabled Wireless debugging by hand. Android demands proof of
 * physical possession before it hands out a debugging channel, which is the
 * only reason a stranger on the same Wi-Fi cannot do all of the above to
 * someone else's tablet. The saving here is the laptop, not the visit.
 */
class AdbProvisioner(private val context: Context) : MethodChannel.MethodCallHandler {

    private val io = Executors.newSingleThreadExecutor()

    /** Separate from [io] so a wedged shell can be abandoned, not queued behind. */
    private val shellPool = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null

    private val nsd by lazy {
        context.getSystemService(Context.NSD_SERVICE) as NsdManager
    }

    /**
     * Address of the service [discoverDebugPort] settled on.
     *
     * Needed because the port alone is not enough to connect, and the
     * address we end up using is not always the one we paired with: on a
     * reconnect there is no paired address at all, and on a dual-stack
     * network the tablet can answer on a different family than it paired on.
     */
    private var lastAddress: String? = null

    /** Where we are currently connected, for [reconnectSameTarget]. */
    private var connectedHost: String? = null
    private var connectedPort: Int = 0

    /** Guards against a second pairing run while one is still hunting. */
    private val pairing = AtomicBoolean(false)
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    /**
     * Held for the duration of a discovery run.
     *
     * Android drops multicast frames not addressed to the device unless a
     * lock is held — a battery measure that silently makes mDNS discovery
     * find nothing at all. The symptom is not an error but an empty search
     * that runs forever, which is exactly how this failed the first time.
     */
    private var multicastLock: WifiManager.MulticastLock? = null

    val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
            events = sink
        }

        override fun onCancel(arguments: Any?) {
            events = null
        }
    }

    // ======================= Flutter entry points ===========================

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startPairing" -> startPairing(result)
            "reconnect" -> {
                io.execute {
                    try {
                        emit("discovering", "Ключ телефона ${keyFingerprint()} — ищу планшет")
                        acquireMulticast()
                        if (connectWithRetry(null)) {
                            emit("connected", "Подключено к планшету")
                        } else {
                            emit("needPairing", "Готового соединения нет — нужен QR")
                        }
                    } catch (t: Throwable) {
                        emit("needPairing", t.message ?: t.toString())
                    } finally {
                        releaseMulticast()
                    }
                }
                result.success(null)
            }
            "connectDirect" -> {
                val host = call.argument<String>("host")
                val port = call.argument<Int>("port")
                if (host == null || port == null) {
                    result.error("args", "host и port обязательны", null)
                } else {
                    io.execute {
                        try {
                            emit("connecting", "Подключаюсь к $host:$port")
                            try { manager().disconnect() } catch (_: Throwable) {}
                            if (manager().connect(host, port)) {
                                connectedHost = host
                                connectedPort = port
                                emit("connected", "Подключено к планшету")
                            } else {
                                emit("error", "Планшет не принял подключение")
                            }
                        } catch (t: Throwable) {
                            Log.e(TAG, "direct connect failed", t)
                            emit("error", t.message ?: t.toString())
                        }
                    }
                    result.success(null)
                }
            }
            "cancelPairing" -> {
                stopDiscovery()
                releaseMulticast()
                pairing.set(false)
                result.success(null)
            }
            "pairManual" -> {
                val host = call.argument<String>("host")
                val port = call.argument<Int>("port")
                val code = call.argument<String>("code")
                if (host == null || port == null || code == null) {
                    result.error("args", "host, port и code обязательны", null)
                } else {
                    pairManual(host, port, code)
                    result.success(null)
                }
            }
            "shell" -> {
                val cmd = call.argument<String>("command")
                if (cmd == null) {
                    result.error("args", "command is required", null)
                } else {
                    runAsync(result) { shell(cmd) }
                }
            }
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("args", "path is required", null)
                } else {
                    runAsync(result) { installApk(File(path)) }
                }
            }
            "setDeviceOwner" -> {
                val component = call.argument<String>("component")
                if (component == null) {
                    result.error("args", "component is required", null)
                } else {
                    runAsync(result) { setDeviceOwner(component) }
                }
            }
            "verifyOwner" -> runAsync(result) { verifyOwner() }
            "removeAccounts" -> runAsync(result) { removeSystemAccounts() }
            "tabletState" -> runAsync(result) { tabletState() }
            "reboot" -> runAsync(result) {
                // Fire and forget: the tablet drops the connection as it goes
                // down, so waiting for a reply would only ever time out.
                try {
                    manager().openStream("shell:reboot").close()
                } catch (_: Throwable) {
                }
                emit("done", "Планшет перезагружается")
                "rebooting"
            }
            "disconnect" -> runAsync(result) {
                manager().disconnect()
                "disconnected"
            }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(result: MethodChannel.Result, body: () -> String) {
        io.execute {
            try {
                val out = body()
                main.post { result.success(out) }
            } catch (t: Throwable) {
                Log.e(TAG, "adb call failed", t)
                main.post { result.error("adb", t.message ?: t.toString(), null) }
            }
        }
    }

    private fun emit(stage: String, message: String) {
        Log.i(TAG, "$stage: $message")
        main.post { events?.success(mapOf("stage" to stage, "message" to message)) }
    }

    // ============================ Pairing ===================================

    /**
     * Mint a rendezvous, hand the QR back for display, and start hunting for
     * the tablet that scans it.
     *
     * Returns immediately with the payload — the actual pairing happens off
     * the main thread and reports through the event channel, because it
     * cannot start until a human has pointed a camera at the screen.
     */
    private fun startPairing(result: MethodChannel.Result) {
        if (!pairing.compareAndSet(false, true)) {
            result.error("busy", "Сопряжение уже идёт", null)
            return
        }
        val name = "mmd-" + randomHex(8)
        val password = randomHex(16)
        // Exactly the format Android's pairing scanner expects. The T:ADB is
        // what tells it this is a debugging rendezvous and not a Wi-Fi network.
        val payload = "WIFI:T:ADB;S:$name;P:$password;;"
        emit("qr", "Ключ телефона ${keyFingerprint()} — покажите QR планшету")
        beginDiscovery(name, password)
        result.success(mapOf("qr" to payload, "name" to name))
    }

    private fun beginDiscovery(expectedName: String, password: String) {
        stopDiscovery()
        acquireMulticast()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                emit("discovering", "Жду планшет в сети")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                // Reported even when it is not ours: when this search comes
                // up empty the only useful question is whether it saw
                // anything at all, and the answer has to be visible on the
                // phone, in a shop, with no logcat attached.
                emit("scan", "Вижу: ${info.serviceName}")
                // Every tablet in range that is pairing right now shows up
                // here. The name from our QR is what tells ours apart — and
                // it is why the name is random per run rather than fixed.
                if (info.serviceName != expectedName) return
                emit("found", "Планшет найден, сопрягаюсь")
                resolveAndPair(info, password)
            }

            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                emit("error", "Поиск не запустился (код $errorCode)")
                pairing.set(false)
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        discoveryListener = listener
        nsd.discoverServices(PAIRING_SERVICE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun resolveAndPair(info: NsdServiceInfo, password: String) {
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                emit("error", "Не удалось получить адрес планшета (код $errorCode)")
                pairing.set(false)
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val host = serviceInfo.host?.hostAddress
                val port = serviceInfo.port
                if (host == null) {
                    emit("error", "Планшет без адреса")
                    pairing.set(false)
                    return
                }
                stopDiscovery()
                io.execute { pairAndConnect(host, port, password) }
            }
        })
    }

    private fun pairAndConnect(host: String, port: Int, password: String) {
        try {
            emit("pairing", "Сопряжение с $host:$port")
            val ok = manager().pair(host, port, password)
            if (!ok) {
                emit("error", "Планшет отклонил сопряжение")
                return
            }
            emit("paired", "Сопряжено, подключаюсь")
            // The pairing port dies with the handshake; the debugging port is
            // advertised separately, so let the library rediscover it rather
            // than assuming the two are related.
            if (connectWithRetry(host)) {
                emit("connected", "Подключено к планшету")
            } else {
                emit("error", "Сопряжение прошло, но подключиться не удалось")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "pairing failed", t)
            emit("error", t.message ?: t.toString())
        } finally {
            releaseMulticast()
            pairing.set(false)
        }
    }

    private fun acquireMulticast() {
        if (multicastLock != null) return
        try {
            val wifi = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("mmd-adb-pairing").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (t: Throwable) {
            emit("error", "Не удалось включить multicast: ${t.message}")
        }
    }

    private fun releaseMulticast() {
        try {
            multicastLock?.takeIf { it.isHeld }?.release()
        } catch (_: Throwable) {
            // Already gone; nothing to undo.
        }
        multicastLock = null
    }

    /**
     * Pair from the numbers the tablet prints, skipping discovery entirely.
     *
     * The QR route depends on mDNS, and mDNS depends on a hostile stack of
     * multicast filtering, OEM power management and whatever the shop's
     * router does to broadcast traffic. "Pair device with pairing code" puts
     * an address and six digits on the tablet's own screen, so this path
     * needs none of it — worth having on a device someone drove to.
     */
    private fun pairManual(host: String, port: Int, code: String) {
        io.execute {
            try {
                emit("pairing", "Сопряжение с $host:$port")
                if (!manager().pair(host, port, code)) {
                    emit("error", "Планшет отклонил код")
                    return@execute
                }
                emit("paired", "Сопряжено, подключаюсь")
                acquireMulticast()
                val connected = connectWithRetry(host)
                emit(
                    if (connected) "connected" else "error",
                    if (connected) "Подключено к планшету"
                    else "Сопряжение прошло, но подключиться не удалось",
                )
            } catch (t: Throwable) {
                Log.e(TAG, "manual pairing failed", t)
                emit("error", t.message ?: t.toString())
            } finally {
                releaseMulticast()
            }
        }
    }

    /**
     * Find the debugging port ourselves and connect to it.
     *
     * The library's own `connectTls` runs an mDNS search internally, and here
     * that search reliably timed out — while the identical search we run for
     * the pairing service, moments earlier, always succeeds. NsdManager does
     * not take kindly to a discovery being started while another is still
     * tearing down, and pairing has only just stopped one. Rather than race
     * it, we reuse the discovery path already proven to work on this phone
     * and hand the library a host and port it does not have to look for.
     *
     * Retried because adbd rebuilds its TLS listener the moment a new peer is
     * trusted and re-advertises afterwards, so a first miss means little.
     */
    private fun connectWithRetry(host: String?): Boolean {
        // Let the pairing discovery finish dying before starting another.
        Thread.sleep(SETTLE_MS)
        for (attempt in 1..CONNECT_ATTEMPTS) {
            lastAddress = null
            val port = discoverDebugPort(host)
            val target = lastAddress
            if (port == null || target == null) {
                emit("connecting", "Попытка $attempt: порт отладки ещё не объявлен")
            } else {
                emit("connecting", "Порт отладки $port, подключаюсь")
                try {
                    // A connection object left over from a dead session
                    // refuses instantly rather than redialling, which reads
                    // exactly like the tablet rejecting our key.
                    try { manager().disconnect() } catch (_: Throwable) {}
                    if (manager().connect(target, port)) {
                        connectedHost = target
                        connectedPort = port
                        return true
                    }
                    // connect() answers false as readily as it throws, and a
                    // silent false here was indistinguishable from having
                    // found nothing at all — the log jumped straight from
                    // "connecting" to "no debugging advertised", which sent
                    // the search off after the wrong problem entirely.
                    emit("connecting", "Попытка $attempt: планшет отклонил подключение")
                } catch (t: Throwable) {
                    emit("connecting", "Попытка $attempt: ${t.message}")
                }
            }
            Thread.sleep(CONNECT_RETRY_DELAY_MS)
        }
        return false
    }

    /**
     * Find the debugging port for [host], reporting everything seen on the
     * way.
     *
     * Three things went wrong here before it worked, and all three produced
     * the same useless "not found":
     *
     * Parallel resolves. NsdManager services one at a time and answers the
     * rest with FAILURE_ALREADY_ACTIVE, so they are done serially now.
     *
     * Stopping at the first hit. The first record to arrive is always this
     * phone's own adbd — it is on the same host, so it needs no network at
     * all — and the tablet's arrives later. Waiting the full window instead
     * of a beat after the first is what actually makes the tablet visible.
     *
     * Trusting a lone candidate. When nothing matched, the old code took
     * "the only tablet" — which was this phone, advertising as
     * `adb-<own serial>-XXXX`. It then tried to adb into itself, failed, and
     * blamed the tablet. Anything on one of our own addresses is now
     * discarded before it can be chosen.
     */
    private fun discoverDebugPort(host: String?): Int? {
        val found = mutableListOf<NsdServiceInfo>()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                emit("connecting", "Поиск порта не запустился (код $errorCode)")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(found) { found.add(info) }
            }
        }

        try {
            nsd.discoverServices(CONNECT_SERVICE, NsdManager.PROTOCOL_DNS_SD, listener)
            // The whole window, not until the first answer: ours comes first
            // and the tablet's comes after.
            Thread.sleep(DISCOVERY_TIMEOUT_MS)
        } catch (t: Throwable) {
            emit("connecting", "Поиск порта: ${t.message}")
        } finally {
            try {
                nsd.stopServiceDiscovery(listener)
            } catch (_: Throwable) {
                // Never started, or already stopped.
            }
        }

        val services = synchronized(found) { found.toList() }
        if (services.isEmpty()) {
            emit("connecting", "Планшет не объявляет отладку")
            return null
        }

        val mine = localAddresses()
        var fallback: Int? = null
        var others = 0
        // Serial on purpose: NsdManager resolves one at a time.
        for (info in services) {
            val resolved = resolveOnce(info) ?: continue
            val (addr, port) = resolved
            if (addr in mine) {
                emit("connecting", "Пропускаю себя: ${info.serviceName}")
                continue
            }
            emit("connecting", "Служба ${info.serviceName}: $addr:$port")
            if (host != null && addr == host) {
                lastAddress = addr
                return port
            }
            if (fallback == null) lastAddress = addr
            fallback = fallback ?: port
            others++
        }
        if (others == 1 && fallback != null) {
            if (host != null) {
                emit("connecting", "Адрес не совпал с $host, но планшет один — беру его")
            }
            return fallback
        }
        if (others > 1) {
            emit("connecting", "Планшетов в отладке несколько — нужен QR, чтобы выбрать нужный")
        } else {
            emit("connecting", "Кроме этого телефона в отладке никого")
        }
        return null
    }

    /** Every address this phone answers on, so we never adb into ourselves. */
    private fun localAddresses(): Set<String> = try {
        java.net.NetworkInterface.getNetworkInterfaces()
            .asSequence()
            .flatMap { it.inetAddresses.asSequence() }
            .mapNotNull { it.hostAddress }
            .toSet()
    } catch (t: Throwable) {
        emptySet()
    }

    /** Blocking resolve of a single service, with failures made visible. */
    private fun resolveOnce(info: NsdServiceInfo): Pair<String, Int>? {
        val latch = CountDownLatch(1)
        val out = AtomicReference<Pair<String, Int>?>(null)
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(si: NsdServiceInfo, errorCode: Int) {
                emit("connecting", "Не разобрал ${si.serviceName} (код $errorCode)")
                latch.countDown()
            }

            override fun onServiceResolved(si: NsdServiceInfo) {
                val addr = si.host?.hostAddress
                if (addr != null) out.set(addr to si.port)
                latch.countDown()
            }
        })
        latch.await(RESOLVE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        return out.get()
    }

    private fun stopDiscovery() {
        discoveryListener?.let {
            try {
                nsd.stopServiceDiscovery(it)
            } catch (_: Throwable) {
                // Already stopped, or never started — nothing to undo.
            }
        }
        discoveryListener = null
    }

    // ============================ ADB services ==============================

    /**
     * Run one shell command, refusing to wait forever.
     *
     * The unbounded version wedged: `pm install` returned but the stream
     * never reported EOF, and the app sat on "installing" for minutes with
     * nothing to show. A stuck stream now surfaces as an error the
     * technician can act on instead of a screen that looks busy.
     */
    private fun shell(command: String): String = try {
        shellOnce(command)
    } catch (first: Throwable) {
        // Installing an APK ends by closing a stream the daemon was still
        // writing to, and that can take the whole connection down with it —
        // which is why the very next command, granting device owner, used to
        // die instantly. Rebuild and try once more before reporting failure.
        emit("connecting", "Связь оборвалась, восстанавливаю")
        if (!reconnectSameTarget()) throw first
        shellOnce(command)
    }

    /**
     * Run one shell command, refusing to wait forever — and reporting what
     * actually went wrong.
     *
     * The first version wrapped every failure as "command did not respond",
     * including failures that arrived in a quarter of a second. That turned a
     * broken connection into an imaginary timeout and cost an evening.
     */
    private fun shellOnce(command: String): String {
        val task = shellPool.submit<String> {
            manager().openStream("shell:$command").use { stream ->
                stream.readUntilClosed()
            }
        }
        return try {
            task.get(SHELL_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            task.cancel(true)
            throw IllegalStateException(
                "Команда не ответила за ${SHELL_TIMEOUT_MS / 1000} с: $command",
            )
        } catch (e: ExecutionException) {
            val cause = e.cause ?: e
            Log.e(TAG, "shell failed: $command", cause)
            throw IllegalStateException(cause.message ?: cause.toString(), cause)
        }
    }

    /**
     * Read a command's output to the end, treating the daemon hanging up as
     * the end rather than as a failure.
     *
     * adbd closes the stream when the command finishes, and this library
     * surfaces that as IOException("Stream closed.") instead of EOF. So a
     * command that answers instantly — `dpm set-device-owner` above all —
     * throws on the way out even though it worked, and the reply is thrown
     * away with the exception. Everything that arrived before the close is
     * the output; that is what we keep.
     *
     * Only IOException is swallowed, and only after the read has started:
     * a stream that never opens still fails loudly.
     */
    private fun AdbStream.readUntilClosed(): String {
        val text = StringBuilder()
        try {
            val reader = openInputStream().bufferedReader()
            val buf = CharArray(4096)
            while (true) {
                val n = reader.read(buf)
                if (n < 0) break
                text.append(buf, 0, n)
            }
        } catch (e: IOException) {
            Log.i(TAG, "stream ended: ${e.message}")
        }
        return text.toString()
    }

    private fun reconnectSameTarget(): Boolean {
        val host = connectedHost ?: return false
        return try {
            manager().connect(host, connectedPort)
        } catch (t: Throwable) {
            Log.e(TAG, "reconnect failed", t)
            false
        }
    }

    /**
     * Stream the APK straight into `pm install`.
     *
     * The first version copied the file to /data/local/tmp and installed it
     * with a second command. That is two long-running streams instead of
     * one, and the second reliably hung: pm had finished, but the read never
     * saw EOF. Handing pm the bytes directly — which is what `adb install`
     * itself does — leaves a single stream whose reply arrives the moment
     * the last byte lands, and leaves nothing behind on the tablet to clean
     * up if we are interrupted.
     *
     * The byte count in the service string is not optional: it is how pm
     * knows where the APK ends, since the stream stays open for its answer.
     */
    private fun installApk(apk: File): String {
        if (!apk.isFile) throw IllegalArgumentException("APK не найден: ${apk.path}")
        val size = apk.length()
        emit("install", "Передаю APK (${size / 1024} КБ)")
        manager().openStream("exec:pm install -r -g -S $size").use { stream ->
            val out = stream.openOutputStream()
            apk.inputStream().use { input ->
                val buf = ByteArray(64 * 1024)
                var sent = 0L
                var lastPercent = 0
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    sent += n
                    val percent = (sent * 100 / size).toInt()
                    if (percent >= lastPercent + 20) {
                        lastPercent = percent
                        emit("install", "Передано $percent%")
                    }
                }
            }
            out.flush()
            emit("install", "Устанавливаю, это до минуты")
            // Deliberately not closing the output stream: pm answers on this
            // same stream, and closing our half takes the reply with it.
            val reply = stream.readUntilClosed()
            if (!reply.contains("Success")) {
                throw IllegalStateException("Установка не прошла: ${reply.trim()}")
            }
            emit("installed", "Приложение установлено")
            // The APK stream ends by closing a channel the daemon is still
            // using, and that reliably leaves the connection unusable. Waiting
            // for the next command to discover it costs a full timeout, so
            // rebuild now while we know exactly where to reconnect.
            reconnectSameTarget()
            return reply.trim()
        }
    }

    /**
     * Ask the tablet who its device owner is, rather than trusting that our
     * own command worked.
     *
     * `dpm set-device-owner` printing Success is not quite proof: the
     * policy is written by a different service than the one that enforces
     * it, and a ROM that half-supports this would report the same thing.
     * Reading the state back costs one command and turns "probably" into
     * "yes".
     */
    private fun verifyOwner(): String {
        val line = ownerLine()
        return if (line.contains(OWNER_PACKAGE)) "ok" else "no: ${line.trim()}"
    }

    /**
     * The Device Owner block of `dumpsys device_policy`, and only it.
     *
     * Searching the whole dump for our package name reports success on a
     * tablet that merely has us registered as an active admin — a leftover
     * from an attempt that failed. That false positive told an operator the
     * rights were granted while an account was still blocking them, which is
     * the one combination Android does not allow.
     */
    private fun ownerLine(): String = shell("dumpsys device_policy")
        .lineSequence()
        .dropWhile { !it.contains("Device Owner:") }
        .take(4)
        .joinToString(" ")

    private fun isDeviceOwner(): Boolean = ownerLine().contains(OWNER_PACKAGE)

    /**
     * Hand the kiosk its device-owner rights.
     *
     * Two obstacles, and they need telling apart because only one of them
     * can be worked around.
     *
     * An account on the tablet is fatal. Android refuses device owner
     * outright, and the only cure is removing the account — so we look
     * first and say so, rather than letting dpm answer with a bare
     * "Can't set package ... as device owner."
     *
     * A completed setup wizard is not fatal, but it is why this fails on
     * anything newer than Android 11. Older builds only checked for
     * accounts; newer ones also insist provisioning has not finished, which
     * a tablet in a technician's hands always has. The flags saying so are
     * ordinary settings, so we lower them, grant, and raise them again —
     * in a finally, because a tablet left believing it is mid-setup would
     * relaunch the wizard on the next boot.
     */
    private fun setDeviceOwner(component: String): String {
        val blocking = blockingAccounts()
        if (blocking.isNotEmpty()) {
            throw IllegalStateException(
                "Мешает аккаунт: " + blocking.keys.joinToString(", ") +
                    ". Нажмите «Убрать аккаунт», дождитесь перезагрузки и " +
                    "подключитесь заново.",
            )
        }

        emit("owner", "Выдаю права администратора")
        val direct = shell("dpm set-device-owner $component")
        if (direct.contains("Success")) {
            emit("done", "Готово — планшет управляется приложением")
            return direct.trim()
        }

        // Not always the cause, so not always tried: on both tablets
        // provisioned so far the account was the only obstacle and a
        // finished setup wizard did not matter. Reach for this only after
        // dpm has actually refused.
        emit("owner", "Отказ — пробую обойти завершённую настройку")
        val retry = try {
            shell("settings put secure user_setup_complete 0")
            shell("settings put global device_provisioned 0")
            shell("dpm set-device-owner $component")
        } finally {
            // Unconditionally: a tablet left thinking it is mid-setup
            // relaunches the wizard on the next boot, which is worse than
            // simply lacking the rights.
            shell("settings put secure user_setup_complete 1")
            shell("settings put global device_provisioned 1")
        }

        if (!retry.contains("Success")) {
            val hint = when {
                retry.contains("already set") ->
                    "Права уже выданы этому или другому приложению."
                retry.contains("several users") ->
                    "На планшете больше одного пользователя. Удалите лишних."
                else -> retry.trim().lineSequence().firstOrNull() ?: "неизвестная причина"
            }
            throw IllegalStateException(hint)
        }
        emit("done", "Готово — планшет управляется приложением")
        return retry.trim()
    }

    /**
     * Accounts currently standing between us and device owner, mapped to the
     * package that registered each.
     *
     * Android refuses device owner while any account exists, and on the
     * Unisoc tablets we buy that account is nobody's Google login: the ROM
     * registers sprd.com.android.account.phone — "contacts stored on the
     * device" — from com.android.contacts before the tablet is first
     * switched on. Skipping Google sign-in during setup does nothing about
     * it, so the operator does everything right and is still refused.
     *
     * A type with no known package maps to an empty string rather than being
     * dropped: an account we cannot attribute still blocks provisioning, and
     * hiding it would make the refusal inexplicable.
     */
    private fun blockingAccounts(): Map<String, String> {
        val dump = try {
            shell("dumpsys account")
        } catch (t: Throwable) {
            emit("owner", "Проверку аккаунтов пропускаю: ${t.message}")
            return emptyMap()
        }
        val owners = AUTHENTICATOR_RE.findAll(dump)
            .associate { it.groupValues[1] to it.groupValues[2] }
        return ACCOUNT_RE.findAll(dump)
            .map { it.groupValues[1] }
            .distinct()
            .associateWith { owners[it] ?: "" }
    }

    /**
     * Remove the packages behind the ROM's own accounts, reporting what each
     * removal actually said.
     *
     * The first cut fired `pm uninstall` and threw the reply away, so a
     * refusal was indistinguishable from success — the tablet rebooted, the
     * account was still there, and the next pass removed it again. Forever.
     *
     * Only packages on [REMOVABLE_AUTHENTICATORS] are touched. A real Google
     * account is named and left alone: removing the package behind it would
     * take Play services with it, and whoever added an account can remove it
     * in Settings.
     */
    private fun removeSystemAccounts(): String {
        val blocking = blockingAccounts()
        if (blocking.isEmpty()) {
            emit("done", "Аккаунтов нет — можно выдавать права")
            return "clean"
        }

        val stuck = blocking.filterValues { it !in REMOVABLE_AUTHENTICATORS }
        if (stuck.isNotEmpty()) {
            throw IllegalStateException(
                "Этот аккаунт убрать автоматически нельзя: " +
                    stuck.keys.joinToString(", ") +
                    ". Удалите его в Настройках → Аккаунты.",
            )
        }

        for (pkg in blocking.values.toSet()) {
            // Disable first. Uninstalling alone left the account in place on
            // a Unisoc Android 13; disabling the authenticator before
            // removing it is what made the boot-time purge notice.
            val disabled = shell("pm disable-user --user 0 $pkg").trim()
            emit("owner", "Отключаю $pkg: ${disabled.ifBlank { "нет ответа" }}")
            val removed = shell("pm uninstall --user 0 $pkg").trim()
            emit("owner", "Удаляю $pkg: ${removed.ifBlank { "нет ответа" }}")
            if (!removed.contains("Success")) {
                throw IllegalStateException("Не удалось убрать $pkg: $removed")
            }
        }

        emit("owner", "Перезагружаю — аккаунты чистятся при старте")
        try {
            manager().openStream("shell:reboot").close()
        } catch (_: Throwable) {
        }
        return "rebooting"
    }

    /** What the tablet looks like right now, in one screenful. */
    private fun tabletState(): String {
        val android = shell("getprop ro.build.version.release").trim()
        val abi = shell("getprop ro.product.cpu.abi").trim()
        val accounts = blockingAccounts()
        val owner = if (isDeviceOwner()) "есть" else "нет"
        val setup = shell("settings get secure user_setup_complete").trim()
        return buildString {
            append("Android $android, $abi\n")
            append("Права администратора: $owner\n")
            append(
                if (accounts.isEmpty()) "Аккаунтов: нет"
                else "Аккаунты: " + accounts.entries.joinToString(", ") {
                    it.key + " (" + it.value.ifBlank { "поставщик неизвестен" } + ")"
                },
            )
            append("\nПервичная настройка завершена: ")
            append(if (setup == "1") "да" else "нет")
        }
    }

    // ============================ Plumbing ==================================

    private fun manager(): AbsAdbConnectionManager = MmdAdbManager.getInstance(context)

    /**
     * Fingerprint of the ADB identity this phone presents.
     *
     * The tablet remembers a paired phone by this key, so if it ever changes
     * every tablet in the fleet silently stops trusting us — and the symptom
     * is an instant refusal that looks like a network fault. Logged on every
     * connection attempt so a changed key is visible rather than deduced.
     */
    private fun keyFingerprint(): String = try {
        // Read from the file we wrote rather than from the manager:
        // getCertificate() is protected, and this is the same bytes.
        val der = File(context.filesDir, "adb_cert").readBytes()
        java.security.MessageDigest.getInstance("SHA-256").digest(der)
            .take(4).joinToString("") { "%02x".format(it) }
    } catch (t: Throwable) {
        "?"
    }

    private fun randomHex(bytes: Int): String {
        val buf = ByteArray(bytes)
        SecureRandom().nextBytes(buf)
        return buf.joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val TAG = "MmdAdb"
        const val CHANNEL = "kz.smartvend/adb"
        const val EVENTS = "kz.smartvend/adb_events"

        private const val PAIRING_SERVICE = "_adb-tls-pairing._tcp."
        private const val CONNECT_SERVICE = "_adb-tls-connect._tcp."
        private const val OWNER_PACKAGE = "kz.smartvend.m102_tester"

        private val ACCOUNT_RE = Regex("Account \\{name=[^,]*, type=([^}]+)\\}")
        private val AUTHENTICATOR_RE =
            Regex("AuthenticatorDescription \\{type=([^}]+)\\}, ComponentInfo\\{([^/]+)/")

        /**
         * Authenticator packages safe to remove in order to clear an account.
         *
         * Deliberately short. This one is the ROM's local contacts storage,
         * which a vending tablet has no use for. Anything else, Google above
         * all, is the operator's to deal with.
         */
        private val REMOVABLE_AUTHENTICATORS = setOf("com.android.contacts")
        /**
         * Every command we run answers in under a second when the link is
         * healthy — the APK no longer goes through here. Two minutes only
         * ever meant two minutes of staring at a dead connection.
         */
        private const val SHELL_TIMEOUT_MS = 30_000L
        private const val CONNECT_ATTEMPTS = 5
        private const val CONNECT_RETRY_DELAY_MS = 2_000L
        private const val DISCOVERY_TIMEOUT_MS = 6_000L
        private const val RESOLVE_TIMEOUT_MS = 4_000L

        /** Beat after the first hit, so siblings land before we stop listening. */
        private const val RESOLVE_GRACE_MS = 700L

        /** Grace for the pairing discovery to unwind before another starts. */
        private const val SETTLE_MS = 1_500L
    }
}

/**
 * The ADB identity this phone presents to tablets.
 *
 * Generated once and kept, not minted per run: the key is what a tablet
 * remembers after pairing, so regenerating it would turn every visit into a
 * fresh pairing and quietly fill the tablet's key store with dead entries.
 */
class MmdAdbManager private constructor(context: Context) : AbsAdbConnectionManager() {

    private val privateKey: PrivateKey
    private val certificate: Certificate

    init {
        // The API level of the *tablet*, not of this phone.
        //
        // It decides the protocol version and max payload written into the
        // CONNECT packet, and the library's own docs only sanction
        // Build.VERSION.SDK_INT "if the daemon and the client are located in
        // the same device". Ours never are. Announcing this phone's level
        // (Android 13) to an Android 11 daemon made it drop the TLS
        // handshake, which surfaced as "ADB pairing is required" — an error
        // about certificates for a fault that had nothing to do with them.
        //
        // R rather than the tablet's true level on purpose: wireless
        // debugging does not exist below it, so it is the floor for anything
        // we can reach, and claiming lower than the daemon is the safe
        // direction. Claiming higher is what broke.
        setApi(Build.VERSION_CODES.R)
        val keyFile = File(context.filesDir, "adb_key")
        val certFile = File(context.filesDir, "adb_cert")
        if (keyFile.isFile && certFile.isFile) {
            privateKey = KeyFactory.getInstance("RSA")
                .generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
            certificate = CertificateFactory.getInstance("X.509")
                .generateCertificate(certFile.inputStream())
        } else {
            val pair = KeyPairGenerator.getInstance("RSA")
                .apply { initialize(2048) }
                .generateKeyPair()
            val subject = X500Name("CN=SmartVend MMD")
            val now = System.currentTimeMillis()
            val cert = JcaX509v3CertificateBuilder(
                subject,
                BigInteger.valueOf(now),
                Date(now - 86_400_000L),
                Date(now + 10L * 365L * 86_400_000L),
                subject,
                pair.public,
            ).build(JcaContentSignerBuilder("SHA512withRSA").build(pair.private))
            privateKey = pair.private
            certificate = JcaX509CertificateConverter().getCertificate(cert)
            keyFile.writeBytes(privateKey.encoded)
            certFile.writeBytes(certificate.encoded)
        }
    }

    override fun getPrivateKey(): PrivateKey = privateKey

    override fun getCertificate(): Certificate = certificate

    override fun getDeviceName(): String = "SmartVend MMD"

    companion object {
        @Volatile
        private var instance: MmdAdbManager? = null

        fun getInstance(context: Context): MmdAdbManager =
            instance ?: synchronized(this) {
                instance ?: MmdAdbManager(context.applicationContext).also { instance = it }
            }
    }
}
