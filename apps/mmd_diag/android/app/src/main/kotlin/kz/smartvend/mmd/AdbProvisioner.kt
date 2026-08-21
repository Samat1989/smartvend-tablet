package kz.smartvend.mmd

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
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
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

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
    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null

    private val nsd by lazy {
        context.getSystemService(Context.NSD_SERVICE) as NsdManager
    }

    /** Guards against a second pairing run while one is still hunting. */
    private val pairing = AtomicBoolean(false)
    private var discoveryListener: NsdManager.DiscoveryListener? = null

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
            "cancelPairing" -> {
                stopDiscovery()
                pairing.set(false)
                result.success(null)
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
        emit("qr", "Покажите QR планшету")
        beginDiscovery(name, password)
        result.success(mapOf("qr" to payload, "name" to name))
    }

    private fun beginDiscovery(expectedName: String, password: String) {
        stopDiscovery()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                emit("discovering", "Жду планшет в сети")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
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
            val connected = manager().connectTls(context, CONNECT_TIMEOUT_MS)
            if (connected) {
                emit("connected", "Подключено к планшету")
            } else {
                emit("error", "Сопряжение прошло, но подключиться не удалось")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "pairing failed", t)
            emit("error", t.message ?: t.toString())
        } finally {
            pairing.set(false)
        }
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

    private fun shell(command: String): String {
        manager().openStream("shell:$command").use { stream ->
            return stream.readAllText()
        }
    }

    /**
     * Copy the APK across and install it.
     *
     * `exec:` rather than `sync:` on purpose: sync is a framed protocol with
     * its own quirks, while exec is a raw pipe with no line-ending mangling —
     * which for an APK is the whole requirement. Costs one temp file that we
     * clean up after.
     */
    private fun installApk(apk: File): String {
        if (!apk.isFile) throw IllegalArgumentException("APK не найден: ${apk.path}")
        emit("install", "Передаю APK (${apk.length() / 1024} КБ)")
        manager().openStream("exec:cat > $REMOTE_APK").use { stream ->
            apk.inputStream().use { input -> input.copyTo(stream.openOutputStream()) }
        }
        emit("install", "Устанавливаю")
        val out = shell("pm install -r -g $REMOTE_APK")
        shell("rm -f $REMOTE_APK")
        if (!out.contains("Success")) {
            throw IllegalStateException("Установка не прошла: ${out.trim()}")
        }
        emit("installed", "Приложение установлено")
        return out.trim()
    }

    /**
     * Hand the kiosk its device-owner rights.
     *
     * Fails loudly on the two conditions that actually bite in the field, so
     * the technician reads a fix rather than a stack trace: an account on the
     * tablet, and a ROM that refuses once setup has been completed.
     */
    private fun setDeviceOwner(component: String): String {
        emit("owner", "Выдаю права администратора")
        val out = shell("dpm set-device-owner $component")
        if (!out.contains("Success")) {
            val hint = when {
                out.contains("accounts on the device") ->
                    "На планшете есть аккаунт. Удалите его в Настройках и повторите."
                out.contains("already set") ->
                    "Права уже выданы этому или другому приложению."
                out.contains("several users") ->
                    "На планшете больше одного пользователя. Удалите лишних."
                else -> out.trim()
            }
            throw IllegalStateException(hint)
        }
        emit("done", "Готово — планшет управляется приложением")
        return out.trim()
    }

    // ============================ Plumbing ==================================

    private fun manager(): AbsAdbConnectionManager = MmdAdbManager.getInstance(context)

    private fun randomHex(bytes: Int): String {
        val buf = ByteArray(bytes)
        SecureRandom().nextBytes(buf)
        return buf.joinToString("") { "%02x".format(it) }
    }

    private fun AdbStream.readAllText(): String =
        openInputStream().bufferedReader().use { it.readText() }

    companion object {
        private const val TAG = "MmdAdb"
        const val CHANNEL = "kz.smartvend/adb"
        const val EVENTS = "kz.smartvend/adb_events"

        private const val PAIRING_SERVICE = "_adb-tls-pairing._tcp."
        private const val REMOTE_APK = "/data/local/tmp/mmd-kiosk.apk"
        private const val CONNECT_TIMEOUT_MS = 10_000L
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
        setApi(Build.VERSION.SDK_INT)
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
