package com.minamorl.nazori

import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import kotlin.concurrent.thread

/**
 * Ships pen records to the Mac.
 *
 * The pen thread must never block on the network, so [offer] only copies into
 * a fixed ring and wakes the sender. When the ring overflows the *oldest*
 * records are dropped: a stale sample is worth less than a fresh one, and the
 * receiver repairs a lost UP with its proximity timeout.
 */
class Transport(
    private val onState: (State) -> Unit,
    private val onHello: (Wire.Hello) -> Unit,
) {
    enum class Mode { USB, WIFI }

    data class State(val mode: Mode, val connected: Boolean, val detail: String)

    companion object {
        private const val TAG = "nazori.transport"
        private const val SLOTS = 2048
        private const val USB_HOST = "127.0.0.1"
        private const val HEARTBEAT_NANOS = 1_000_000_000L
    }

    private val lock = Object()

    /** Prebuilt so the idle path allocates nothing. */
    private val heartbeat: ByteArray = ByteArray(Wire.RECORD_BYTES).also { a ->
        val b = Wire.newBuffer()
        Wire.encodeInto(b, Wire.HEARTBEAT, 0, 0, 0L, 0f, 0f, 0f, 0f, 0f, 0f)
        b.get(a, 0, Wire.RECORD_BYTES)
    }
    private val ring = ByteArray(SLOTS * Wire.RECORD_BYTES)
    private var writeIdx = 0L
    private var readIdx = 0L
    private var dropped = 0L

    @Volatile private var running = false
    @Volatile private var mode = Mode.USB
    @Volatile private var wifiHost = ""
    @Volatile private var port = Wire.DEFAULT_PORT
    private var worker: Thread? = null

    fun start(mode: Mode, wifiHost: String, port: Int) {
        stop()
        this.mode = mode
        this.wifiHost = wifiHost
        this.port = port
        running = true
        worker = thread(name = "nazori-sender", isDaemon = true) {
            if (mode == Mode.USB) runTcp() else runUdp()
        }
    }

    fun stop() {
        running = false
        synchronized(lock) { lock.notifyAll() }
        worker?.join(500)
        worker = null
    }

    fun offer(buf: ByteBuffer) {
        synchronized(lock) {
            val slot = (writeIdx % SLOTS).toInt() * Wire.RECORD_BYTES
            buf.position(0)
            buf.get(ring, slot, Wire.RECORD_BYTES)
            buf.position(0)
            writeIdx++
            if (writeIdx - readIdx > SLOTS) {
                dropped += writeIdx - readIdx - SLOTS
                readIdx = writeIdx - SLOTS
            }
            lock.notify()
        }
    }

    fun droppedCount(): Long = synchronized(lock) { dropped }

    /** Returns 0 when nothing arrived within one short wait. */
    private fun drain(out: ByteArray): Int {
        synchronized(lock) {
            // One bounded wait, then hand control back even when empty: the
            // caller needs the idle moment to send a keepalive, and a loop that
            // waits until data exists never gives it one.
            if (running && readIdx == writeIdx) {
                try {
                    lock.wait(200)
                } catch (e: InterruptedException) {
                    return 0
                }
            }
            if (!running || readIdx == writeIdx) return 0
            var n = 0
            while (readIdx < writeIdx && n + Wire.RECORD_BYTES <= out.size) {
                val slot = (readIdx % SLOTS).toInt() * Wire.RECORD_BYTES
                System.arraycopy(ring, slot, out, n, Wire.RECORD_BYTES)
                n += Wire.RECORD_BYTES
                readIdx++
            }
            return n
        }
    }

    private fun runTcp() {
        val batch = ByteArray(64 * Wire.RECORD_BYTES)
        var backoffMs = 200L
        while (running) {
            var socket: Socket? = null
            try {
                onState(State(Mode.USB, false, "接続中 $USB_HOST:$port"))
                socket = Socket()
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(USB_HOST, port), 2000)
                val out: OutputStream = socket.getOutputStream()
                readHello(socket.getInputStream())
                onState(State(Mode.USB, true, "USB 接続済み"))
                backoffMs = 200L
                var idleSince = System.nanoTime()
                while (running) {
                    val n = drain(batch)
                    if (n == 0) {
                        // A link that is never written to is never discovered to
                        // be dead, and the UI would keep claiming "connected"
                        // while the first real stroke is spent finding out.
                        if (System.nanoTime() - idleSince >= HEARTBEAT_NANOS) {
                            out.write(heartbeat)
                            out.flush()
                            idleSince = System.nanoTime()
                        }
                        continue
                    }
                    out.write(batch, 0, n)
                    out.flush()
                    idleSince = System.nanoTime()
                }
            } catch (e: Exception) {
                Log.w(TAG, "tcp: ${e.message}")
                onState(State(Mode.USB, false, "未接続 — adb reverse は通っていますか"))
                sleepQuietly(backoffMs)
                backoffMs = (backoffMs * 2).coerceAtMost(3000L)
            } finally {
                try { socket?.close() } catch (_: Exception) {}
            }
        }
    }

    /**
     * The daemon answers a fresh connection with its display geometry, which is
     * how the device knows what shape to letterbox its active area into. A host
     * that stays silent just leaves the configured aspect in place.
     */
    private fun readHello(input: InputStream) {
        val buf = ByteArray(Wire.HELLO_BYTES)
        var got = 0
        while (got < Wire.HELLO_BYTES) {
            val n = input.read(buf, got, Wire.HELLO_BYTES - got)
            if (n < 0) return
            got += n
        }
        Wire.decodeHello(buf, got)?.let(onHello)
    }

    private fun runUdp() {
        val batch = ByteArray(16 * Wire.RECORD_BYTES)
        var socket: DatagramSocket? = null
        try {
            socket = DatagramSocket()
            val addr = InetAddress.getByName(wifiHost)
            onState(State(Mode.WIFI, true, "Wi-Fi $wifiHost:$port へ送信中"))
            while (running) {
                val n = drain(batch)
                if (n == 0) continue
                socket.send(DatagramPacket(batch, n, addr, port))
            }
        } catch (e: Exception) {
            Log.w(TAG, "udp: ${e.message}")
            onState(State(Mode.WIFI, false, "送信不能: ${e.message}"))
        } finally {
            try { socket?.close() } catch (_: Exception) {}
        }
    }

    private fun sleepQuietly(ms: Long) {
        try { Thread.sleep(ms) } catch (_: InterruptedException) {}
    }
}
