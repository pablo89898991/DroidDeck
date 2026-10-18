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
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent

/**
 * Receives controller input (DualSense / Edge with full features, any other SDL3-supported pad) from the companion SDL3 bridge app
 * and feeds it into DroidDeck's pad pipeline.
 *
 *  sticks / triggers / D-pad / face + shoulder buttons -> PadBridge.applyExternal
 *  Edge paddles (L/R)  -> Deck grips L4 / R4;  Edge Fn (L/R) -> L5 / R5
 *  touchpad            -> decoupled by the bridge: left half = left Deck trackpad, right half = right trackpad (+ click)
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
    private const val GYRO_GAIN = 1f                 // multiplies gyro only; raise if motion is too slow
    // Touchpad orientation on the DroidDeck side (the bridge app has the same settings; use one or the other, not both).
    private const val TOUCH_INV_X = true
    private const val TOUCH_INV_Y = true
    private const val TOUCH_SWAP = false
    private const val MAP_TOUCHPAD = true            // left half = left trackpad, right half = right trackpad
    private const val TOUCH_HALF = 960               // DualSense touchpad is 1920 x 1080
    private const val TOUCH_H = 1079f

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
    @Volatile private var lastFrameMs = 0L
    @Volatile private var bridgedVid = 0
    @Volatile private var bridgedPid = 0
    private val lastTouchKey = intArrayOf(-1, -1)  // [left, right]
    private var clickSide = -1                     // -1 none, 0 left, 1 right

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

    /** True while the DualSense is streaming; PadMotion uses this to stop writing the phone's gyro. */
    @JvmStatic
    fun isActive(): Boolean = lastFrameMs != 0L && SystemClock.elapsedRealtime() - lastFrameMs < 1000L

    /**
     * True when [dev] is the same physical controller the SDL3 bridge is currently streaming.
     * Android reports that controller too (basic input), so DroidDeck's own gamepad handling must
     * ignore it while the bridge is active, otherwise every press arrives twice.
     * Hook it where DroidDeck handles gamepad key / motion events, e.g.
     *     if (DualSenseBridge.isBridged(event.device)) return true
     */
    @JvmStatic
    fun isBridged(dev: InputDevice?): Boolean =
        dev != null && isActive() && bridgedVid != 0 &&
            dev.vendorId == bridgedVid && dev.productId == bridgedPid

    @JvmStatic fun isBridged(e: KeyEvent): Boolean = isBridged(e.device)
    @JvmStatic fun isBridged(e: MotionEvent): Boolean = isBridged(e.device)

    private fun onFrame(b: Bundle) {
        val p = pad ?: return
        lastFrameMs = SystemClock.elapsedRealtime()
        bridgedVid = b.getInt("vid"); bridgedPid = b.getInt("pid")
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
                if (MAP_TOUCHPAD && !b.containsKey("padL") && ((diff shr 13) and 1) != 0) {
                    if (((mask shr 13) and 1) != 0) {
                        val sides = sidesOf(b.getIntArray("touch"))
                        clickSide = if (sides == 1) 0 else 1   // only left finger -> left click, else right
                        DeckControls.setClick(clickSide == 1, true)
                    } else if (clickSide >= 0) {
                        DeckControls.setClick(clickSide == 1, false)
                        clickSide = -1
                    }
                }
            }
        }
        if (MAP_TOUCHPAD && !decoupledTouch(b)) touch(b.getIntArray("touch"))
        val g = b.getFloatArray("gyro")
        val a = b.getFloatArray("accel")
        if (g != null && a != null) {
            FakeInputWriter.writeMotion(0, shorts(a, ACCEL_LSB_PER_G, ACCEL_SIGN), shorts(g, GYRO_LSB_PER_DPS * GYRO_GAIN, GYRO_SIGN))
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

    /**
     * Newer bridge builds split the touchpad themselves (see the bridge's Touchpad layout setting):
     * padL / padR = [down, x, y] with x and y already in -1..1 for that trackpad, padClick = -1 / 0 (left) / 1 (right).
     * @return false when the bridge does not send this data (older bridge), so the caller falls back to raw fingers.
     */
    private fun decoupledTouch(b: Bundle): Boolean {
        val l = b.getFloatArray("padL") ?: return false
        val r = b.getFloatArray("padR") ?: return false
        if (l.size < 3 || r.size < 3) return false
        decoupledPad(false, l)
        decoupledPad(true, r)
        val c = b.getInt("padClick", -1)
        if (c != clickSide) {
            if (clickSide >= 0) DeckControls.setClick(clickSide == 1, false)
            if (c >= 0) DeckControls.setClick(c == 1, true)
            clickSide = c
        }
        return true
    }

    private fun decoupledPad(right: Boolean, p: FloatArray) {
        val slot = if (right) 1 else 0
        val touching = p[0] > 0.5f
        val key = if (touching) (((p[1] * 127f).toInt() and 0xFF) shl 8) or ((p[2] * 127f).toInt() and 0xFF) else -1
        if (key == lastTouchKey[slot]) return
        lastTouchKey[slot] = key
        if (touching) {
            var x = p[1]; var y = p[2]
            if (TOUCH_SWAP) { val t = x; x = y; y = t }
            if (TOUCH_INV_X) x = -x
            if (TOUCH_INV_Y) y = -y
            DeckControls.setPad(right, true, x, y)
        } else DeckControls.setPad(right, false)
    }

    /** Bit 0 = a finger on the left half, bit 1 = a finger on the right half. */
    private fun sidesOf(t: IntArray?): Int {
        var r = 0
        var i = 0
        while (t != null && i + 2 < t.size) { r = r or (if (t[i + 1] < TOUCH_HALF) 1 else 2); i += 3 }
        return r
    }

    private fun touch(t: IntArray?) {
        var left: IntArray? = null
        var right: IntArray? = null
        var i = 0
        while (t != null && i + 2 < t.size) {
            val pt = intArrayOf(t[i + 1], t[i + 2])
            if (pt[0] < TOUCH_HALF) { if (left == null) left = pt } else { if (right == null) right = pt }
            i += 3
        }
        pad(false, left)
        pad(true, right)
    }

    private fun pad(right: Boolean, pt: IntArray?) {
        val slot = if (right) 1 else 0
        val key = if (pt != null) ((pt[0] shr 4) shl 16) or (pt[1] shr 4) else -1
        if (key == lastTouchKey[slot]) return
        lastTouchKey[slot] = key
        if (pt == null) { DeckControls.setPad(right, false); return }
        val local = if (right) pt[0] - TOUCH_HALF else pt[0]
        DeckControls.setPad(right, true, local / TOUCH_HALF.toFloat() * 2f - 1f, pt[1] / TOUCH_H * 2f - 1f)
    }

    private fun shorts(v: FloatArray, scale: Float, sign: FloatArray) =
        ShortArray(3) { (v[it] * scale * sign[it]).coerceIn(-32768f, 32767f).toInt().toShort() }

    /** Neutral state: called when the bridge disconnects so nothing stays stuck. */
    private fun release() {
        lastFrameMs = 0L
        val p = pad ?: return
        lastMask = 0
        lastAxes.fill(0f)
        lastTouchKey.fill(-1)
        clickSide = -1
        p.applyExternal({ s: PadState -> fill(s, 0, FloatArray(6)) }, false)
        for (grip in GRIPS.values) DeckControls.setGrip(grip, false)
        if (MAP_TOUCHPAD) {
            DeckControls.setPad(false, false); DeckControls.setPad(true, false)
            DeckControls.setClick(false, false); DeckControls.setClick(true, false)
        }
    }
}
