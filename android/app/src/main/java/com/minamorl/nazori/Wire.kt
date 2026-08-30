package com.minamorl.nazori

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The 40-byte record described in PROTOCOL.md, plus the host's HELLO reply.
 *
 * Everything here is allocation-free on the hot path: [encodeInto] writes into
 * a caller-owned buffer so the capture thread never touches the allocator
 * between two pen samples.
 */
object Wire {
    const val MAGIC: Byte = 0xA7.toByte()
    const val VERSION: Byte = 1
    const val RECORD_BYTES = 40
    const val HELLO_BYTES = 16
    const val DEFAULT_PORT = 40118

    // record types
    const val PROXIMITY_OUT: Byte = 0
    const val PROXIMITY_IN: Byte = 1
    const val HOVER: Byte = 2
    const val DOWN: Byte = 3
    const val MOVE: Byte = 4
    const val UP: Byte = 5
    const val CANCEL: Byte = 6

    /** Idle keepalive. Carries no pen state; the host drops it. */
    const val HEARTBEAT: Byte = 7

    // host -> device
    const val HELLO: Byte = 0x80.toByte()

    // flags
    const val FLAG_PREDICTED = 0x01
    const val FLAG_BARREL = 0x02
    const val FLAG_ERASER = 0x04

    fun newBuffer(): ByteBuffer =
        ByteBuffer.allocate(RECORD_BYTES).order(ByteOrder.LITTLE_ENDIAN)

    fun encodeInto(
        buf: ByteBuffer,
        type: Byte,
        flags: Int,
        seq: Int,
        tNanos: Long,
        x: Float,
        y: Float,
        pressure: Float,
        tiltX: Float,
        tiltY: Float,
        twist: Float,
    ) {
        buf.clear()
        buf.put(MAGIC)
        buf.put(VERSION)
        buf.put(type)
        buf.put(flags.toByte())
        buf.putInt(seq)
        buf.putLong(tNanos)
        buf.putFloat(x)
        buf.putFloat(y)
        buf.putFloat(pressure)
        buf.putFloat(tiltX)
        buf.putFloat(tiltY)
        buf.putFloat(twist)
        buf.flip()
    }

    /** Host display geometry, learned from the HELLO the daemon sends on connect. */
    data class Hello(val widthPx: Float, val heightPx: Float)

    /** Returns null if [bytes] is not a well-formed HELLO. */
    fun decodeHello(bytes: ByteArray, len: Int): Hello? {
        if (len < HELLO_BYTES) return null
        val b = ByteBuffer.wrap(bytes, 0, len).order(ByteOrder.LITTLE_ENDIAN)
        if (b.get() != MAGIC) return null
        if (b.get() != VERSION) return null
        if (b.get() != HELLO) return null
        b.get() // flags, reserved
        val w = b.float
        val h = b.float
        if (w <= 0f || h <= 0f) return null
        return Hello(w, h)
    }
}
