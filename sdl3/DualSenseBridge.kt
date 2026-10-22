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
    private const val MSG_PAD_GONE = 12
    private const val SLOTS = 4

    // ---- Tunables (verify on device) ----
    private const val DEAD_ZONE = 0.12f              // same as PadBridge
    private const val MIN_AXIS_INTERVAL_MS = 4L      // don't flood the input ring with stick jitter
    private const val GYRO_LSB_PER_DPS = 16.384f     // Steam Deck IMU: 2000 dps full scale (assumed)
    private const val ACCEL_LSB_PER_G = 16384f       // Steam Deck IMU: 2 g full scale (assumed)
    private val GYRO_SIGN = floatArrayOf(1f, 1f, 1f) // flip an entry to -1f if an axis feels inverted
    private val ACCEL_SIGN = floatArrayOf(1f, 1f, 1f)
    private const val GYRO_GAIN = 1f                 // multiplies gyro only; raise if motion is too slow
    // Touchpad orientation on the DroidDeck side (the bridge app has the same settings; use one or the other, not both).
    private const val TOUCH_INV_X = false
    private const val TOUCH_INV_Y = false
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
    // Per bridge slot (0 = player 1 with all features, 1..3 = extra controllers: buttons, sticks, triggers, gyro, rumble).
    private val vidS = IntArray(SLOTS)
    private val pidS = IntArray(SLOTS)
    private val frameMsS = LongArray(SLOTS)
    private val ddSlot = intArrayOf(0, -1, -1, -1)       // bridge slot -> DroidDeck player slot (-1 = not claimed)
    private val maskS = IntArray(SLOTS)
    private val axesS = Array(SLOTS) { FloatArray(6) }
    private val applyMsS = LongArray(SLOTS)
    private val lastTouchKey = intArrayOf(-1, -1)  // [left, right]
    private var clickSide = -1                     // -1 none, 0 left, 1 right

    // DeckControls bit layout (those constants are private over there)
    private const val DC_LEFT_TOUCH = 16
    private const val DC_RIGHT_TOUCH = 32
    private const val DC_LEFT_CLICK = 64
    private const val DC_RIGHT_CLICK = 128

    // Separate-controller mode: the DualSense becomes its OWN DroidDeck controller slot (its own entry in Steam),
    // with full back buttons, both trackpads and gyro, instead of driving the Steam Deck pad.
    private var sepSlot = -1
    private var sepMs = 0L
    private var sepVid = 0
    private var sepPid = 0
    private var sepMask = 0
    private val sepAxes = FloatArray(6)
    private var sepApplyMs = 0L
    private var lastPadType = 0
    private var lastSepControls = -1
    private val lastSepPads = ShortArray(4)
    private val lastSepPressure = ShortArray(2)

    private val worker = android.os.HandlerThread("ds-bridge", android.os.Process.THREAD_PRIORITY_DISPLAY).apply { start() }
    private val inbox = Messenger(object : Handler(worker.looper) {
        override fun handleMessage(m: Message) {
            when (m.what) {
                MSG_FRAME -> onFrame(m.data)
                MSG_STATUS -> if (m.data.getString("text")?.startsWith("Connected") != true) release()
                MSG_PAD_GONE -> padGone(m.data.getInt("slot"))
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

    /** Forward game rumble (0..255 each) to the physical controller of player 1. */
    // Per-bridge-slot pending auto-stop. The bridge's rumble is level-based (stays on until set to 0),
    // so we must stop it ourselves after the effect's duration — exactly as RumbleComponent does with its
    // one-shots. Without this a single "ping" (one 2000 ms buzz) would rumble the controller forever.
    private val rumbleTimer = Handler(worker.looper)
    private val rumbleStop = arrayOfNulls<Runnable>(SLOTS)
    private const val RUMBLE_HOLD_MS = 0xFFFF   // matches RumbleComponent.HOLD_MS
    private const val HOLD_SAFETY_MS = 30_000L

    @JvmStatic
    fun rumble(strong: Int, weak: Int) = rumble(0, strong, weak, RUMBLE_HOLD_MS)

    @JvmStatic
    fun rumble(deckSlot: Int, strong: Int, weak: Int) = rumble(deckSlot, strong, weak, RUMBLE_HOLD_MS)

    /**
     * Rumble for a DroidDeck player slot (0 = player 1), honoring the effect duration [ms].
     * HOLD effects (0xFFFF) play until the explicit stop that follows them (30 s safety cap); a timed
     * one-shot (e.g. the controller "ping") plays for its own duration and then stops.
     */
    @JvmStatic
    fun rumble(deckSlot: Int, strong: Int, weak: Int, ms: Int) {
        rumbleTimer.post {
            val bridgeSlot = (0 until SLOTS).firstOrNull { ddSlot[it] == deckSlot } ?: return@post
            rumbleStop[bridgeSlot]?.let { rumbleTimer.removeCallbacks(it); rumbleStop[bridgeSlot] = null }
            sendRumble(bridgeSlot, strong, weak)
            if (strong == 0 && weak == 0) return@post
            // HOLD = play until the game's/Steam's explicit stop (they always send one); the long cap is only a
            // safety net in case that stop is lost (e.g. the game crashes mid-rumble).
            val hold = if (ms == RUMBLE_HOLD_MS || ms <= 0) HOLD_SAFETY_MS else ms.toLong().coerceIn(1L, 5000L)
            val stop = Runnable { sendRumble(bridgeSlot, 0, 0); rumbleStop[bridgeSlot] = null }
            rumbleStop[bridgeSlot] = stop
            rumbleTimer.postDelayed(stop, hold)
        }
    }

    private fun sendRumble(bridgeSlot: Int, strong: Int, weak: Int) {
        send(Message.obtain(null, MSG_OUTPUT).apply {
            data = Bundle().apply {
                putInt("slot", bridgeSlot)
                putInt("rl", strong.coerceIn(0, 255)); putInt("rr", weak.coerceIn(0, 255))
            }
        })
    }

    private fun send(m: Message) { try { server?.send(m) } catch (_: RemoteException) {} }

    // ---------------- frame handling ----------------

    private fun stick(v: Int): Float {
        val f = ((v - 128) / 127f).coerceIn(-1f, 1f)
        return if (Math.abs(f) < DEAD_ZONE) 0f else f
    }

    /** True while player 1's controller is streaming; PadMotion uses this to stop writing the phone's gyro. */
    @JvmStatic
    fun isActive(): Boolean = frameMsS[0] != 0L && SystemClock.elapsedRealtime() - frameMsS[0] < 1000L

    /**
     * True when [dev] is the same physical controller the SDL3 bridge is currently streaming (any player slot).
     * Android reports that controller too (basic input), so DroidDeck's own gamepad handling must
     * ignore it while the bridge is active, otherwise every press arrives twice.
     */
    @JvmStatic
    fun isBridged(dev: InputDevice?): Boolean {
        if (dev == null) return false
        val now = SystemClock.elapsedRealtime()
        for (i in 0 until SLOTS) {
            if (vidS[i] != 0 && frameMsS[i] != 0L && now - frameMsS[i] < 1000L &&
                dev.vendorId == vidS[i] && dev.productId == pidS[i]) return true
        }
        if (sepVid != 0 && sepMs != 0L && now - sepMs < 1000L &&
            dev.vendorId == sepVid && dev.productId == sepPid) return true
        return false
    }

    /** True when DroidDeck player [deckSlot] is currently driven by a bridge controller (for rumble routing). */
    @JvmStatic
    fun isBridgedSlot(deckSlot: Int): Boolean {
        val now = SystemClock.elapsedRealtime()
        for (i in 0 until SLOTS) {
            if (ddSlot[i] == deckSlot && frameMsS[i] != 0L && now - frameMsS[i] < 1000L) return true
        }
        return false
    }

    /**
     * Called first thing in RumbleComponent.buzz(). Returns true when the effect was sent to a bridged
     * controller (and must NOT also go to the phone / an Android pad).
     *
     *  - slot 0..3: a DroidDeck player slot -> its bridged controller, if one drives it.
     *  - slot >= PadBridge.SLOTS (e.g. 16): a game rumbling Steam's VIRTUAL pad. Upstream sends that to the
     *    "last active Android controller", which is nobody while the bridge holds the pad, so it fell back to
     *    the phone's vibrator. Route it to player 1's bridged controller instead (unless a real Android pad is
     *    the active one, or it is a SteamVR Joy-Con hand slot).
     */
    @JvmStatic
    fun routeRumble(slot: Int, strong: Int, weak: Int, ms: Int): Boolean {
        val deckSlot = when {
            slot in 0 until PadBridge.SLOTS -> if (isBridgedSlot(slot)) slot else return false
            JoyCon.vrRumbleDevice(slot) != null -> return false
            !isBridgedSlot(0) -> return false
            else -> {
                val id = PadBridge.activeControllerId()
                if (id != PadBridge.NO_CONTROLLER) {
                    val dev = InputDevice.getDevice(id)
                    // a real Android pad with motors is in use: leave it to upstream
                    if (dev != null && !isBridged(dev) && hasMotors(dev)) return false
                }
                0
            }
        }
        val on = (strong != 0 || weak != 0) && ms != 0   // ms == 0 is a stop, as in RumbleComponent
        if (on != rumbleLogged) {
            rumbleLogged = on
            android.util.Log.i("SessionService", "rumble: slot $slot -> SDL3 bridge (player ${deckSlot + 1}) ${if (on) "on ${strong shr 8}/${weak shr 8} ${ms}ms" else "off"}")
        }
        if (on) rumble(deckSlot, strong shr 8, weak shr 8, ms) else rumble(deckSlot, 0, 0, 0)
        return true
    }
    @Volatile private var rumbleLogged = false

    private fun hasMotors(dev: InputDevice): Boolean = try {
        if (android.os.Build.VERSION.SDK_INT >= 31) dev.vibratorManager.vibratorIds.isNotEmpty()
        else @Suppress("DEPRECATION") dev.vibrator.hasVibrator()
    } catch (_: Exception) { false }

    @JvmStatic fun isBridged(e: KeyEvent): Boolean = isBridged(e.device)
    @JvmStatic fun isBridged(e: MotionEvent): Boolean = isBridged(e.device)

    /** A controller in bridge slot [slot] was unplugged. */
    private fun padGone(slot: Int) {
        if (slot !in 0 until SLOTS) return
        if (slot == 0) { release(); return }
        val p = pad
        val dd = ddSlot[slot]
        if (p != null && dd > 0) {
            p.applyExternalSlot(dd, { s: PadState -> fill(s, 0, FloatArray(6)) }, false)
            p.releaseBridgeSlot(dd)
        }
        ddSlot[slot] = -1
        frameMsS[slot] = 0L
        vidS[slot] = 0; pidS[slot] = 0
        maskS[slot] = 0; axesS[slot].fill(0f)
    }

    /** Extra controllers (bridge slots 1..3) become DroidDeck players 2..4: plain gamepad plus gyro. */
    private fun onExtraFrame(slot: Int, b: Bundle) {
        val p = pad ?: return
        val now = SystemClock.elapsedRealtime()
        frameMsS[slot] = now
        vidS[slot] = b.getInt("vid"); pidS[slot] = b.getInt("pid")
        var dd = ddSlot[slot]
        if (dd <= 0) {
            dd = p.claimBridgeSlot()
            if (dd <= 0) return                      // all DroidDeck player slots are taken
            ddSlot[slot] = dd
        }
        val mask = b.getInt("mask")
        val ax = floatArrayOf(
            stick(b.getInt("lx")), stick(b.getInt("ly")), stick(b.getInt("rx")), stick(b.getInt("ry")),
            b.getInt("l2") / 255f, b.getInt("r2") / 255f,
        )
        val buttonsChanged = mask != maskS[slot]
        val axesChanged = !ax.contentEquals(axesS[slot])
        if (buttonsChanged || (axesChanged && now - applyMsS[slot] >= MIN_AXIS_INTERVAL_MS)) {
            maskS[slot] = mask
            ax.copyInto(axesS[slot])
            applyMsS[slot] = now
            p.applyExternalSlot(dd, { s: PadState -> fill(s, mask, ax) }, buttonsChanged)
        }
        val g = b.getFloatArray("gyro")
        val a = b.getFloatArray("accel")
        if (g != null && a != null) {
            FakeInputWriter.writeMotion(dd, shorts(a, ACCEL_LSB_PER_G, ACCEL_SIGN), shorts(g, GYRO_LSB_PER_DPS * GYRO_GAIN, GYRO_SIGN))
        }
    }

    private fun axisS(v: Float): Short = (v.coerceIn(-1f, 1f) * 32767f).toInt().toShort()

    /** The DualSense as its own full-featured DroidDeck controller (separate Steam entry). */
    private fun onSeparateFrame(b: Bundle) {
        val p = pad ?: return
        val now = SystemClock.elapsedRealtime()
        sepMs = now
        sepVid = b.getInt("vid"); sepPid = b.getInt("pid")
        if (sepSlot <= 0) {
            sepSlot = p.claimBridgeSlot()
            if (sepSlot <= 0) return                 // no free DroidDeck slot
            lastSepControls = -1
        }
        val mask = b.getInt("mask")
        val ax = floatArrayOf(
            stick(b.getInt("lx")), stick(b.getInt("ly")), stick(b.getInt("rx")), stick(b.getInt("ry")),
            b.getInt("l2") / 255f, b.getInt("r2") / 255f,
        )
        val buttonsChanged = mask != sepMask
        val axesChanged = !ax.contentEquals(sepAxes)
        if (buttonsChanged || (axesChanged && now - sepApplyMs >= MIN_AXIS_INTERVAL_MS)) {
            sepMask = mask
            ax.copyInto(sepAxes)
            sepApplyMs = now
            p.applyExternalSlot(sepSlot, { s: PadState -> fill(s, mask, ax) }, buttonsChanged)
        }

        // back buttons + trackpads + clicks -> this slot's Deck controls
        var controls = 0
        if (((mask shr 19) and 1) != 0) controls = controls or DeckControls.L4
        if (((mask shr 20) and 1) != 0) controls = controls or DeckControls.R4
        if (((mask shr 21) and 1) != 0) controls = controls or DeckControls.L5
        if (((mask shr 22) and 1) != 0) controls = controls or DeckControls.R5
        val pads = ShortArray(4)
        val padL = b.getFloatArray("padL")
        val padR = b.getFloatArray("padR")
        if (padL != null && padL.size >= 3 && padL[0] > 0.5f) {
            val xy = orientPad(padL[1], padL[2]); controls = controls or DC_LEFT_TOUCH
            pads[0] = axisS(xy[0]); pads[1] = axisS(xy[1])
        }
        if (padR != null && padR.size >= 3 && padR[0] > 0.5f) {
            val xy = orientPad(padR[1], padR[2]); controls = controls or DC_RIGHT_TOUCH
            pads[2] = axisS(xy[0]); pads[3] = axisS(xy[1])
        }
        val pressure = ShortArray(2)
        when (b.getInt("padClick", -1)) {
            0 -> { controls = controls or DC_LEFT_CLICK; pressure[0] = Short.MAX_VALUE }
            1 -> { controls = controls or DC_RIGHT_CLICK; pressure[1] = Short.MAX_VALUE }
        }
        if (controls != lastSepControls || !pads.contentEquals(lastSepPads) || !pressure.contentEquals(lastSepPressure)) {
            FakeInputWriter.writeDeckControls(sepSlot, controls, pads, pressure)
            lastSepControls = controls
            pads.copyInto(lastSepPads)
            pressure.copyInto(lastSepPressure)
        }

        val g = b.getFloatArray("gyro")
        val a = b.getFloatArray("accel")
        if (g != null && a != null) {
            FakeInputWriter.writeMotion(sepSlot, shorts(a, ACCEL_LSB_PER_G, ACCEL_SIGN), shorts(g, GYRO_LSB_PER_DPS * GYRO_GAIN, GYRO_SIGN))
        }
    }

    private fun orientPad(x0: Float, y0: Float): FloatArray {
        var x = x0; var y = y0
        if (TOUCH_SWAP) { val t = x; x = y; y = t }
        if (TOUCH_INV_X) x = -x
        if (TOUCH_INV_Y) y = -y
        return floatArrayOf(x, y)
    }

    private fun releaseSep() {
        val p = pad
        if (p != null && sepSlot > 0) {
            FakeInputWriter.writeDeckControls(sepSlot, 0, ShortArray(4), ShortArray(2))
            p.applyExternalSlot(sepSlot, { s: PadState -> fill(s, 0, FloatArray(6)) }, false)
            p.releaseBridgeSlot(sepSlot)
        }
        sepSlot = -1; sepMs = 0L; sepVid = 0; sepPid = 0; sepMask = 0; sepAxes.fill(0f)
        lastSepControls = -1; lastSepPads.fill(0); lastSepPressure.fill(0)
    }

    /**
     * Switch the emulated controller type exactly the way DroidDeck's own QAM does: first show the
     * right hidraw node (creates /sys/class/hidraw symlink, removes the others) so Steam can enumerate
     * it, THEN flip the shared pad_type. Without showPad() setPadType alone only changes the report
     * format, so Steam never sees the new device and keeps the Steam Deck pad.
     */
    private fun applyPadType(pt: Int) {
        try { com.droiddeck.launcher.session.SteamDeckPad.showPad(pt) } catch (t: Throwable) { }
        FakeInputWriter.setPadType(pt)
    }

    private fun onFrame(b: Bundle) {
        val slot = b.getInt("slot", 0).coerceIn(0, SLOTS - 1)
        if (slot != 0) { onExtraFrame(slot, b); return }
        val pt = b.getInt("ptype", 0)
        if (pt != lastPadType) { lastPadType = pt; applyPadType(pt) }  // Deck / DualSense / DS4
        val p = pad ?: return
        frameMsS[0] = SystemClock.elapsedRealtime()
        vidS[0] = b.getInt("vid"); pidS[0] = b.getInt("pid")
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
        val key = if (touching) (((p[1] * 1023f).toInt() and 0x7FF) shl 11) or ((p[2] * 1023f).toInt() and 0x7FF) else -1
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
        frameMsS[0] = 0L
        if (lastPadType != 0) { lastPadType = 0; applyPadType(0) }
        for (k in 1 until SLOTS) padGone(k)
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
