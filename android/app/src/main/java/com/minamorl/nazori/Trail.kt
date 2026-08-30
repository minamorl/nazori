package com.minamorl.nazori

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint

/**
 * The visible afterimage of the pen.
 *
 * This is feedback, not artwork: nothing here is ever sent to the host and
 * nothing is persisted. Points live in a ring buffer keyed by wall time and
 * are drawn with an alpha that decays to zero over [fadeNanos], which is why
 * the whole trail is redrawn every frame rather than appended to a front
 * buffer -- a fade has to touch old pixels, so front-buffered ink would be
 * the wrong tool.
 */
class Trail(private val capacity: Int = 8192) {
    private val xs = FloatArray(capacity)
    private val ys = FloatArray(capacity)
    private val ps = FloatArray(capacity)
    private val ts = LongArray(capacity)
    private val stroke = IntArray(capacity)
    private val predicted = BooleanArray(capacity)

    private var head = 0
    private var count = 0
    private var currentStroke = 0

    var fadeNanos: Long = 1_400_000_000L
    var maxWidthPx: Float = 14f
    var minWidthPx: Float = 1.5f
    var color: Int = Color.rgb(0xE8, 0xF4, 0xFF)

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    fun beginStroke() {
        currentStroke++
    }

    /** Drops every point belonging to the newest stroke, for ACTION_CANCEL. */
    fun cancelStroke() {
        while (count > 0) {
            val i = (head - 1 + capacity) % capacity
            if (stroke[i] != currentStroke) break
            head = i
            count--
        }
    }

    fun add(x: Float, y: Float, pressure: Float, tNanos: Long, isPredicted: Boolean = false) {
        xs[head] = x
        ys[head] = y
        ps[head] = pressure
        ts[head] = tNanos
        stroke[head] = currentStroke
        predicted[head] = isPredicted
        head = (head + 1) % capacity
        if (count < capacity) count++
    }

    /** Predicted points are re-derived every frame, so last frame's are dropped first. */
    fun dropPredicted() {
        while (count > 0) {
            val i = (head - 1 + capacity) % capacity
            if (!predicted[i]) break
            head = i
            count--
        }
    }

    fun isEmpty(): Boolean = count == 0

    /** True while any point is still visible, i.e. while the surface must keep redrawing. */
    fun draw(canvas: Canvas, nowNanos: Long): Boolean {
        if (count == 0) return false
        var alive = false
        val tail = (head - count + capacity) % capacity
        var prev = -1
        for (n in 0 until count) {
            val i = (tail + n) % capacity
            val age = nowNanos - ts[i]
            if (age >= fadeNanos || age < 0) { prev = -1; continue }
            alive = true
            if (prev >= 0 && stroke[prev] == stroke[i]) {
                // Fade on a curve rather than linearly: the head of the trail
                // should stay bright well past the halfway point.
                val f = 1f - age.toFloat() / fadeNanos
                paint.color = color
                paint.alpha = (255f * f * f).toInt().coerceIn(0, 255)
                paint.strokeWidth = minWidthPx + (maxWidthPx - minWidthPx) * ps[i]
                canvas.drawLine(xs[prev], ys[prev], xs[i], ys[i], paint)
            }
            prev = i
        }
        return alive
    }

    /** Forgets points that can no longer be seen. */
    fun prune(nowNanos: Long) {
        while (count > 0) {
            val tail = (head - count + capacity) % capacity
            if (nowNanos - ts[tail] < fadeNanos) break
            count--
        }
    }
}
