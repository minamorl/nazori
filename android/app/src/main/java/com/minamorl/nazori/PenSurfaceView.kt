package com.minamorl.nazori

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.os.HandlerThread
import android.util.AttributeSet
import android.view.Choreographer
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.input.motionprediction.MotionEventPredictor
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan

/**
 * The pen surface.
 *
 * Two jobs, deliberately kept apart. Capture turns every stylus sample --
 * including the historical ones Android batches into a single MotionEvent --
 * into a wire record and hands it straight to [Transport]. Rendering draws a
 * fading afterimage so the surface is not a black void; that afterimage never
 * leaves the device.
 *
 * Fingers are ignored on purpose. This is a tablet, not a touchscreen.
 */
class PenSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : SurfaceView(context, attrs), SurfaceHolder.Callback {

    /** Emits a wire-ready record; set by the activity. */
    var onSample: ((type: Byte, flags: Int, seq: Int, tNanos: Long,
                    x: Float, y: Float, pressure: Float,
                    tiltX: Float, tiltY: Float, twist: Float) -> Unit)? = null

    var onStatus: ((String) -> Unit)? = null

    /** Host display aspect (w/h). The active area is letterboxed to match it. */
    @Volatile var hostAspect: Float = 16f / 10f
        set(value) { field = value; recomputeActiveArea(); requestFrame() }

    val trail = Trail()

    private val active = RectF()
    private val lock = Object()

    private val bgPaint = Paint().apply { color = Color.rgb(0x0B, 0x0B, 0x0D) }
    private val framePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f
        color = Color.argb(0x50, 0x9A, 0xC8, 0xFF)
    }
    private val hoverPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f
        color = Color.argb(0xA0, 0x9A, 0xC8, 0xFF)
    }

    private var predictor: MotionEventPredictor? = null
    private var seq = 0
    private var hoverX = -1f
    private var hoverY = -1f
    private var hovering = false
    private var contact = false

    private var renderThread: HandlerThread? = null
    private var choreographer: Choreographer? = null
    @Volatile private var frameScheduled = false
    @Volatile private var idleFrames = 0

    init {
        holder.addCallback(this)
        isFocusable = true
    }

    // ---------------------------------------------------------------- capture

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isPen(event)) return false
        if (predictor == null) predictor = MotionEventPredictor.newInstance(this)
        predictor?.record(event)

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // Ask the framework to stop batching: we want every sample the
                // digitizer produces, not one bundle per frame.
                requestUnbufferedDispatch(event)
                contact = true
                synchronized(lock) { trail.dropPredicted(); trail.beginStroke() }
                emitAll(event, Wire.DOWN)
            }
            MotionEvent.ACTION_MOVE -> {
                synchronized(lock) { trail.dropPredicted() }
                emitAll(event, Wire.MOVE)
                addPrediction()
            }
            MotionEvent.ACTION_UP -> {
                contact = false
                synchronized(lock) { trail.dropPredicted() }
                emitAll(event, Wire.UP)
            }
            MotionEvent.ACTION_CANCEL -> {
                contact = false
                synchronized(lock) { trail.dropPredicted(); trail.cancelStroke() }
                emit(event, Wire.CANCEL, -1)
            }
            else -> return false
        }
        requestFrame()
        return true
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        if (!isPen(event)) return false
        predictor?.record(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER -> {
                hovering = true
                emit(event, Wire.PROXIMITY_IN, -1)
            }
            MotionEvent.ACTION_HOVER_MOVE -> {
                hovering = true
                emit(event, Wire.HOVER, -1)
            }
            MotionEvent.ACTION_HOVER_EXIT -> {
                hovering = false
                emit(event, Wire.PROXIMITY_OUT, -1)
            }
            else -> return false
        }
        hoverX = event.x
        hoverY = event.y
        requestFrame()
        return true
    }

    private fun isPen(event: MotionEvent): Boolean {
        val t = event.getToolType(0)
        return t == MotionEvent.TOOL_TYPE_STYLUS || t == MotionEvent.TOOL_TYPE_ERASER
    }

    /** Emits the batched historical samples first, then the current one. */
    private fun emitAll(event: MotionEvent, type: Byte) {
        for (h in 0 until event.historySize) emit(event, type, h)
        emit(event, type, -1)
    }

    private fun emit(event: MotionEvent, type: Byte, history: Int) {
        val px: Float
        val py: Float
        val pressure: Float
        val tiltRad: Float
        val orientRad: Float
        val tNanos: Long
        if (history >= 0) {
            px = event.getHistoricalX(history)
            py = event.getHistoricalY(history)
            pressure = event.getHistoricalPressure(history)
            tiltRad = event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, 0, history)
            orientRad = event.getHistoricalOrientation(history)
            tNanos = if (Build.VERSION.SDK_INT >= 34) {
                event.getHistoricalEventTimeNanos(history)
            } else {
                event.getHistoricalEventTime(history) * 1_000_000L
            }
        } else {
            px = event.x
            py = event.y
            pressure = event.pressure
            tiltRad = event.getAxisValue(MotionEvent.AXIS_TILT)
            orientRad = event.orientation
            tNanos = if (Build.VERSION.SDK_INT >= 34) {
                event.eventTimeNanos
            } else {
                event.eventTime * 1_000_000L
            }
        }

        val nx = ((px - active.left) / active.width()).coerceIn(0f, 1f)
        val ny = ((py - active.top) / active.height()).coerceIn(0f, 1f)
        val p = pressure.coerceIn(0f, 1f)

        // Android gives a polar pair (lean from the normal, azimuth); the host
        // side wants the Cartesian pair that NSEvent and Pointer Events use.
        val leanX = sin(orientRad)
        val leanY = -cos(orientRad)
        val tanTilt = tan(tiltRad.coerceIn(0f, 1.5533f))
        val tiltXDeg = Math.toDegrees(atan(leanX * tanTilt).toDouble()).toFloat()
        val tiltYDeg = Math.toDegrees(atan(leanY * tanTilt).toDouble()).toFloat()

        var flags = 0
        if (event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) flags = flags or Wire.FLAG_BARREL
        if (event.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER) flags = flags or Wire.FLAG_ERASER

        onSample?.invoke(type, flags, seq++, tNanos, nx, ny, p, tiltXDeg, tiltYDeg, 0f)

        if (type == Wire.DOWN || type == Wire.MOVE) {
            synchronized(lock) { trail.add(px, py, p, System.nanoTime()) }
        }
    }

    /**
     * Extends the head of the trail with the framework's predicted sample so
     * the ink stays under the nib. Predicted points are drawn and then thrown
     * away; they are never sent to the host.
     */
    private fun addPrediction() {
        val predicted = predictor?.predict() ?: return
        try {
            val now = System.nanoTime()
            synchronized(lock) {
                for (h in 0 until predicted.historySize) {
                    trail.add(
                        predicted.getHistoricalX(h),
                        predicted.getHistoricalY(h),
                        predicted.getHistoricalPressure(h),
                        now,
                        isPredicted = true,
                    )
                }
                trail.add(predicted.x, predicted.y, predicted.pressure, now, isPredicted = true)
            }
        } finally {
            predicted.recycle()
        }
    }

    // ---------------------------------------------------------------- surface

    override fun surfaceCreated(holder: SurfaceHolder) {
        val t = HandlerThread("nazori-render")
        t.start()
        renderThread = t
        android.os.Handler(t.looper).post {
            choreographer = Choreographer.getInstance()
            requestFrame()
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        recomputeActiveArea()
        requestFrame()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        renderThread?.quitSafely()
        renderThread = null
        choreographer = null
    }

    private fun recomputeActiveArea() {
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return
        val margin = 0.02f * minOf(w, h)
        val availW = w - margin * 2
        val availH = h - margin * 2
        var aw = availW
        var ah = aw / hostAspect
        if (ah > availH) {
            ah = availH
            aw = ah * hostAspect
        }
        active.set((w - aw) / 2f, (h - ah) / 2f, (w + aw) / 2f, (h + ah) / 2f)
        onStatus?.invoke("有効領域 ${aw.toInt()}x${ah.toInt()}px")
    }

    private fun requestFrame() {
        idleFrames = 0
        if (frameScheduled) return
        val c = choreographer ?: return
        frameScheduled = true
        c.postFrameCallback(frameCallback)
    }

    private val frameCallback: Choreographer.FrameCallback = Choreographer.FrameCallback { frameTimeNanos ->
        frameScheduled = false
        val alive = drawFrame(frameTimeNanos)
        // Keep pumping for a few frames after the trail dies so the final clear
        // actually reaches the screen, then stop burning the display.
        if (alive || hovering || idleFrames < 3) {
            if (!alive && !hovering) idleFrames++
            frameScheduled = true
            choreographer?.postFrameCallback(frameCallback)
        }
    }

    private fun drawFrame(nowNanos: Long): Boolean {
        val h = holder
        if (!h.surface.isValid) return false
        val locked: Canvas? = try {
            h.lockHardwareCanvas()
        } catch (e: Exception) {
            null
        }
        val canvas: Canvas = locked ?: return false
        var alive = false
        try {
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), bgPaint)
            canvas.drawRoundRect(active, 8f, 8f, framePaint)
            synchronized(lock) {
                alive = trail.draw(canvas, nowNanos)
                trail.prune(nowNanos)
            }
            if (hovering && !contact) {
                canvas.drawCircle(hoverX, hoverY, 10f, hoverPaint)
            }
        } finally {
            h.unlockCanvasAndPost(canvas)
        }
        return alive
    }
}
