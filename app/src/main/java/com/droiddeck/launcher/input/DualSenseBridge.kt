package com.droiddeck.launcher.input

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import android.os.SystemClock

/**
 * Receives DualSense / DualSense Edge input from the companion "DualSense Edge Bridge" app
 * and feeds it into DroidDeck's pad pipeline.
 *
 *  sticks / triggers / D-pad / face + shoulder buttons -> PadBridge.applyExternal
 *  Edge paddles (L/R)  -> Deck grips L4 / R4;  Edge Fn (L/R) -> L5 / R5
 *  touchpad            -> right Deck trackpad (+ click)
 *  gyro / accel        -> FakeInputWriter.writeMotion (slot 0)
 *
 * Usage:  DualSenseBridge.attach(context, padBridge)  when the session starts,
 *         DualSenseBridge.detach()                    when it stops.
 */
object DualSenseBridge {
    private const val BRIDGE_PKG = "com.example.dsedge"
    private const val BRIDGE_ACTION = "com.example.dsedge.BRIDGE"
    private const val MSG_REGISTER = 1
    private const val MSG_UNREGISTER = 2
    private const val MSG_OUTPUT = 3
    private const val MSG_FRAME = 10
    private const val MSG_STATUS = 11

    // ---- Tunables (verify on device) ----
    private const val DEAD_ZONE = 0.12f              // same as PadBridge
    private const val MIN_AXIS_INTERVAL_MS = 8L      // don't flood the input ring with stick jitter
    private const val GYRO_LSB_PER_DPS = 16.384f     // Steam Deck IMU: 2000 dps full scale (assumed)
    private const val ACCEL_LSB_PER_G = 16384f       // Steam Deck IMU: 2 g full scale (assumed)
    private val GYRO_SIGN = floatArrayOf(1f, 1f, 1f) // flip an entry to -1f if an axis feels inverted
    private val ACCEL_SIGN = floatArrayOf(1f, 1f, 1f)
    private const val MAP_TOUCHPAD = true

    // bridge mask bit -> PadState button
    private val BUTTONS = mapOf(
        0 to PadState.A, 1 to PadState.B, 2 to PadState.X, 3 to PadState.Y,
        4 to PadState.LB, 5 to PadState.RB,
        8 to PadState.SELECT, 9 to PadState.START,
        10 to PadState.L3, 11 to PadState.R3,
        12 to PadState.GUIDE, 14 to PadState.QAM,
    )
    // bridge mask bit -> Deck grip bit
    private val GRIPS = mapOf(
        19 to DeckControls.L4, 20 to DeckControls.R4,
        21 to DeckControls.L5, 22 to DeckControls.R5,
    )

    private var appContext: Context? = null
    private var pad: PadBridge? = null
    private var server: Messenger? = null
    private var bound = false

    private var lastMask = 0
    private val lastAxes = FloatArray(6)
    private var lastApplyMs = 0L
    private var lastTouchKey = -1

    private val inbox = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(m: Message) {
            when (m.what) {
                MSG_FRAME -> onFrame(m.data)
                MSG_STATUS -> if (m.data.getString("text")?.startsWith("Connected") != true) release()
            }
        }
    })

    private val conn = object : ServiceConnection {
        override fun onServiceConnected(n: ComponentName, b: IBinder) {
            server = Messenger(b)
            send(Message.obtain(null, MSG_REGISTER).apply { replyTo = inbox })
        }
        override fun onServiceDisconnected(n: ComponentName) { server = null; release() }
    }

    /** @return false if the bridge app is not installed / not bindable. */
    @JvmStatic
    @Synchronized
    fun attach(context: Context, padBridge: PadBridge): Boolean {
        pad = padBridge
        if (bound) return true
        val app = context.applicationContext
        appContext = app
        bound = try {
            app.bindService(Intent(BRIDGE_ACTION).setPackage(BRIDGE_PKG), conn, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) { false }
        return bound
    }

    @JvmStatic
    @Synchronized
    fun detach() {
        if (bound) {
            send(Message.obtain(null, MSG_UNREGISTER).apply { replyTo = inbox })
            try { appContext?.unbindService(conn) } catch (_: IllegalArgumentException) {}
            bound = false
        }
        release()
        pad = null
        server = null
    }

    /** Forward game rumble (0..255 each) to the physical controller. */
    @JvmStatic
    fun rumble(strong: Int, weak: Int) =
        send(Message.obtain(null, MSG_OUTPUT).apply {
            data = Bundle().apply { putInt("rl", strong.coerceIn(0, 255)); putInt("rr", weak.coerceIn(0, 255)) }
        })

    private fun send(m: Message) { try { server?.send(m) } catch (_: RemoteException) {} }

    // ---------------- frame handling ----------------

    private fun stick(v: Int): Float {
        val f = ((v - 128) / 127f).coerceIn(-1f, 1f)
        return if (Math.abs(f) < DEAD_ZONE) 0f else f
    }

    private fun onFrame(b: Bundle) {
        val p = pad ?: return
        val mask = b.getInt("mask")
        val ax = floatArrayOf(
            stick(b.getInt("lx")), stick(b.getInt("ly")), stick(b.getInt("rx")), stick(b.getInt("ry")),
            b.getInt("l2") / 255f, b.getInt("r2") / 255f,
        )
        val now = SystemClock.elapsedRealtime()
        val prev = lastMask
        val buttonsChanged = mask != prev
        val axesChanged = !ax.contentEquals(lastAxes)
        if (buttonsChanged || (axesChanged && now - lastApplyMs >= MIN_AXIS_INTERVAL_MS)) {
            lastMask = mask
            ax.copyInto(lastAxes)
            lastApplyMs = now
            p.applyExternal({ s: PadState -> fill(s, mask, ax) }, true)
            if (buttonsChanged) {
                val diff = mask xor prev
                for ((bit, grip) in GRIPS) if (((diff shr bit) and 1) != 0) {
                    DeckControls.setGrip(grip, ((mask shr bit) and 1) != 0)
                }
                if (MAP_TOUCHPAD && ((diff shr 13) and 1) != 0) DeckControls.setClick(true, ((mask shr 13) and 1) != 0)
            }
        }
        if (MAP_TOUCHPAD) touch(b.getIntArray("touch"))
        val g = b.getFloatArray("gyro")
        val a = b.getFloatArray("accel")
        if (g != null && a != null) {
            FakeInputWriter.writeMotion(0, shorts(a, ACCEL_LSB_PER_G, ACCEL_SIGN), shorts(g, GYRO_LSB_PER_DPS, GYRO_SIGN))
        }
    }

    private fun fill(s: PadState, mask: Int, ax: FloatArray) {
        for ((bit, btn) in BUTTONS) s.press(btn, ((mask shr bit) and 1) != 0)
        s.up = ((mask shr 15) and 1) != 0
        s.down = ((mask shr 16) and 1) != 0
        s.left = ((mask shr 17) and 1) != 0
        s.right = ((mask shr 18) and 1) != 0
        s.leftX = ax[0]; s.leftY = ax[1]; s.rightX = ax[2]; s.rightY = ax[3]
        s.leftTrigger = ax[4]; s.rightTrigger = ax[5]
    }

    private fun touch(t: IntArray?) {
        val touching = t != null && t.size >= 3
        val key = if (touching) ((t!![1] shr 4) shl 16) or (t[2] shr 4) else -1
        if (key == lastTouchKey) return
        lastTouchKey = key
        if (touching) DeckControls.setPad(true, true, t!![1] / 1919f * 2f - 1f, t[2] / 1079f * 2f - 1f)
        else DeckControls.setPad(true, false)
    }

    private fun shorts(v: FloatArray, scale: Float, sign: FloatArray) =
        ShortArray(3) { (v[it] * scale * sign[it]).coerceIn(-32768f, 32767f).toInt().toShort() }

    /** Neutral state: called when the bridge disconnects so nothing stays stuck. */
    private fun release() {
        val p = pad ?: return
        lastMask = 0
        lastAxes.fill(0f)
        lastTouchKey = -1
        p.applyExternal({ s: PadState -> fill(s, 0, FloatArray(6)) }, false)
        for (grip in GRIPS.values) DeckControls.setGrip(grip, false)
        if (MAP_TOUCHPAD) { DeckControls.setPad(true, false); DeckControls.setClick(true, false) }
    }
}
