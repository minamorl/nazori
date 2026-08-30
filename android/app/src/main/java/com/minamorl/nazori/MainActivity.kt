package com.minamorl.nazori

import android.app.AlertDialog
import android.content.Context
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.SeekBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

class MainActivity : AppCompatActivity() {

    private lateinit var pen: PenSurfaceView
    private lateinit var status: TextView
    private lateinit var prefs: android.content.SharedPreferences
    private lateinit var transport: Transport

    private val buf = Wire.newBuffer()
    private var areaLabel = ""
    private var linkLabel = "未接続"
    private var sent = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = getSharedPreferences("nazori", Context.MODE_PRIVATE)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        goImmersive()

        pen = findViewById(R.id.pen)
        status = findViewById(R.id.status)
        findViewById<Button>(R.id.settings).setOnClickListener { showSettings() }

        transport = Transport(
            onState = { s ->
                linkLabel = s.detail
                runOnUiThread { redrawStatus() }
            },
            onHello = { hello ->
                runOnUiThread { pen.hostAspect = hello.widthPx / hello.heightPx }
            },
        )

        pen.onStatus = { s -> areaLabel = s; runOnUiThread { redrawStatus() } }
        pen.onSample = { type, flags, seq, tNanos, x, y, pressure, tiltX, tiltY, twist ->
            Wire.encodeInto(buf, type, flags, seq, tNanos, x, y, pressure, tiltX, tiltY, twist)
            transport.offer(buf)
            sent++
            if (sent % 240L == 0L) runOnUiThread { redrawStatus() }
        }

        applyPrefs()
    }

    private fun applyPrefs() {
        pen.trail.fadeNanos = prefs.getInt("fadeMs", 1400).toLong() * 1_000_000L
        pen.hostAspect = prefs.getFloat("aspect", 16f / 10f)
        val mode = if (prefs.getString("mode", "usb") == "usb") Transport.Mode.USB else Transport.Mode.WIFI
        transport.start(mode, prefs.getString("host", "192.168.1.10")!!, prefs.getInt("port", Wire.DEFAULT_PORT))
    }

    private fun redrawStatus() {
        val d = transport.droppedCount()
        val drops = if (d > 0) "  drop:$d" else ""
        status.text = "nazori   $linkLabel   $areaLabel   sent:$sent$drops"
    }

    private fun showSettings() {
        val ctx = this
        val box = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 32, 48, 8)
        }

        val group = RadioGroup(ctx)
        val usb = RadioButton(ctx).apply { text = "USB (adb reverse)" }
        val wifi = RadioButton(ctx).apply { text = "Wi-Fi (UDP)" }
        group.addView(usb); group.addView(wifi)
        if (prefs.getString("mode", "usb") == "usb") usb.isChecked = true else wifi.isChecked = true
        box.addView(group)

        val host = EditText(ctx).apply {
            hint = "ホスト IP (Wi-Fi のとき)"
            inputType = InputType.TYPE_CLASS_TEXT
            setText(prefs.getString("host", "192.168.1.10"))
        }
        box.addView(host)

        val port = EditText(ctx).apply {
            hint = "ポート"
            inputType = InputType.TYPE_CLASS_NUMBER
            setText(prefs.getInt("port", Wire.DEFAULT_PORT).toString())
        }
        box.addView(port)

        val fadeLabel = TextView(ctx)
        val fade = SeekBar(ctx).apply {
            max = 5000
            progress = prefs.getInt("fadeMs", 1400)
        }
        fun label() { fadeLabel.text = "軌跡が消えるまで ${fade.progress} ms" }
        label()
        fade.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                label()
                pen.trail.fadeNanos = p.toLong() * 1_000_000L
            }
            override fun onStartTrackingTouch(sb: SeekBar?) {}
            override fun onStopTrackingTouch(sb: SeekBar?) {}
        })
        box.addView(fadeLabel)
        box.addView(fade)

        AlertDialog.Builder(ctx)
            .setTitle("nazori")
            .setView(box)
            .setPositiveButton("保存") { _, _ ->
                prefs.edit()
                    .putString("mode", if (usb.isChecked) "usb" else "wifi")
                    .putString("host", host.text.toString().trim())
                    .putInt("port", port.text.toString().toIntOrNull() ?: Wire.DEFAULT_PORT)
                    .putInt("fadeMs", fade.progress)
                    .apply()
                applyPrefs()
                goImmersive()
            }
            .setNegativeButton("やめる") { _, _ -> goImmersive() }
            .show()
    }

    private fun goImmersive() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) goImmersive()
    }

    override fun onDestroy() {
        transport.stop()
        super.onDestroy()
    }
}
