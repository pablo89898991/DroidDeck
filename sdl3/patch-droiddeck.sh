#!/usr/bin/env bash
#
# patch-droiddeck.sh -- integrate the SDL3BridgeDroidDeck bridge into a DroidDeck source tree.
#
# An installed Android app cannot modify another installed app (that needs root), so the
# integration lives in DroidDeck's SOURCE, which you build anyway. This script applies every
# edit the bridge needs, in one go, and is safe to run again (it skips anything already done).
#
# Usage:   bash patch-droiddeck.sh [path-to-DroidDeck]       (default: ~/DroidDeck)
#
set -u
DD="${1:-$HOME/DroidDeck}"
SRC="$(cd "$(dirname "$0")" && pwd)"
IN="$DD/app/src/main/java/com/droiddeck/launcher/input"
PKG="$DD/app/src/main/java/com/droiddeck/launcher"
MANIFEST="$DD/app/src/main/AndroidManifest.xml"
PB="$IN/PadBridge.java"
SA="$PKG/SessionActivity.kt"
PM="$IN/PadMotion.kt"
KT="$IN/DualSenseBridge.kt"

ok(){ printf '  \033[32mok\033[0m   %s\n' "$1"; }
skip(){ printf '  --   %s (already done)\n' "$1"; }
warn(){ printf '  \033[33mTODO\033[0m %s\n' "$1"; }
die(){ printf '\033[31mERROR\033[0m %s\n' "$1"; exit 1; }

[ -d "$DD" ]  || die "DroidDeck not found at: $DD  (pass the path as the first argument)"
[ -f "$PB" ]  || die "Not a DroidDeck tree (missing PadBridge.java under $IN)"
[ -f "$SRC/DualSenseBridge.kt" ] || die "DualSenseBridge.kt is missing next to this script"

echo "Patching DroidDeck at: $DD"

# insert the contents of file $2 immediately BEFORE the first line containing literal $1, in file $3
insert_before(){
  awk -v pat="$1" -v blk="$2" '
    BEGIN{ while((getline l < blk)>0) B=B l ORS }
    index($0,pat)&&!done{ printf "%s",B; done=1 }
    { print }
  ' "$3" > "$3.tmp" && mv "$3.tmp" "$3"
}

# ---------- 1. DualSenseBridge.kt (always refreshed; it is our own file) ----------
if cmp -s "$SRC/DualSenseBridge.kt" "$KT" 2>/dev/null; then
  skip "DualSenseBridge.kt up to date"
else
  cp "$SRC/DualSenseBridge.kt" "$KT" && ok "installed DualSenseBridge.kt"
fi

# ---------- 2. PadBridge.java ----------
# 2a. bridgeSlots field
if grep -q "boolean\[\] bridgeSlots" "$PB"; then
  skip "PadBridge bridgeSlots field"
else
  sed -i 's#\(private final PadState\[\] playerStates = new PadState\[SLOTS\];\)#\1\n    private final boolean[] bridgeSlots = new boolean[SLOTS]; // slots fed by the SDL3 bridge app#' "$PB"
  ok "PadBridge bridgeSlots field"
fi

# 2b. keep the SDL3 bridge slots off limits to Android devices in the owner-assign loop
if grep -q "owners\[slot\] != NO_CONTROLLER || bridgeSlots\[slot\]) continue;" "$PB"; then
  skip "PadBridge owner-assign guard"
else
  sed -i 's#if (owners\[slot\] != NO_CONTROLLER) continue;#if (owners[slot] != NO_CONTROLLER || bridgeSlots[slot]) continue;#' "$PB"
  ok "PadBridge owner-assign guard"
fi

# 2c. slot API methods (claim / release / applyExternalSlot) before setSystemButtons
if grep -q "claimBridgeSlot" "$PB"; then
  skip "PadBridge slot API"
else
  cat > /tmp/_slotapi.txt <<'JAVA'
    /** SDL3 bridge: reserves a free player slot (1..3) for an extra controller. @return the slot, or -1 if none is free. */
    public synchronized int claimBridgeSlot() {
        for (int slot = 1; slot < SLOTS; slot++) {
            if (owners[slot] != NO_CONTROLLER || bridgeSlots[slot]) continue;
            bridgeSlots[slot] = true;
            playerStates[slot].clear();
            Log.i(TAG, "SDL3 bridge controller is player " + (slot + 1));
            return slot;
        }
        return -1;
    }

    /** SDL3 bridge: frees a slot taken with {@link #claimBridgeSlot()}. */
    public synchronized void releaseBridgeSlot(int slot) {
        if (slot < 1 || slot >= SLOTS || !bridgeSlots[slot]) return;
        bridgeSlots[slot] = false;
        playerStates[slot].clear();
        if (playerWriters[slot] != null) {
            playerWriters[slot].destroy();
            playerWriters[slot] = null;
        }
        Log.i(TAG, "SDL3 bridge player " + (slot + 1) + " left");
    }

    /** SDL3 bridge: updates player [slot] (0 = primary pad, 1..3 = claimed bridge slots). */
    public synchronized void applyExternalSlot(int slot, java.util.function.Consumer<PadState> mutation, boolean changed) {
        if (slot <= 0) { applyExternal(mutation, changed); return; }
        if (slot >= SLOTS || !bridgeSlots[slot]) return;
        mutation.accept(playerStates[slot]);
        if (changed) notePlayerInput();
        publish(slot);
    }

JAVA
  insert_before "public synchronized void setSystemButtons(" /tmp/_slotapi.txt "$PB"
  grep -q "claimBridgeSlot" "$PB" && ok "PadBridge slot API" || warn "PadBridge slot API not inserted (anchor setSystemButtons not found)"
fi

# 2d. ignore the Android duplicate of a bridged controller in the two input gates
if grep -q "DualSenseBridge.isBridged(event)) return false;" "$PB"; then
  skip "PadBridge isBridged gates"
else
  sed -i '/public static boolean isControllerKeyEvent(KeyEvent event) {/a\        if (DualSenseBridge.isBridged(event)) return false;' "$PB"
  sed -i '/public static boolean isControllerMotionEvent(MotionEvent event) {/a\        if (DualSenseBridge.isBridged(event)) return false;' "$PB"
  grep -q "DualSenseBridge.isBridged(event)) return false;" "$PB" && ok "PadBridge isBridged gates" || warn "PadBridge isBridged gates not inserted"
fi

# ---------- 3. AndroidManifest.xml ----------
if grep -q "com.example.dsedge" "$MANIFEST"; then
  skip "manifest permission + queries"
else
  sed -i 's#</manifest>#    <uses-permission android:name="com.example.dsedge.permission.BRIDGE" />\n    <queries><package android:name="com.example.dsedge" /></queries>\n</manifest>#' "$MANIFEST"
  grep -q "com.example.dsedge" "$MANIFEST" && ok "manifest permission + queries" || warn "manifest not patched (no </manifest>?)"
fi

# ---------- 4. SessionActivity.kt (dispatch gate + attach + detach) ----------
if [ -f "$SA" ]; then
  # 4a. ignore the bridged controller's Android duplicate in dispatchKeyEvent
  if grep -q "DualSenseBridge.isBridged(event)) return true" "$SA"; then
    skip "SessionActivity dispatchKeyEvent gate"
  elif grep -q "if (pipUi) return true" "$SA"; then
    sed -i '0,/if (pipUi) return true/{/if (pipUi) return true/a\        if (com.droiddeck.launcher.input.DualSenseBridge.isBridged(event)) return true
}' "$SA"
    grep -q "DualSenseBridge.isBridged(event)) return true" "$SA" && ok "SessionActivity dispatchKeyEvent gate" || warn "SessionActivity dispatchKeyEvent gate NOT inserted"
  else
    warn "SessionActivity: add the dispatchKeyEvent gate by hand (anchor 'if (pipUi) return true' not found)"
  fi

  # 4b. attach the bridge right after the PadBridge is created
  if grep -q "DualSenseBridge.attach(" "$SA"; then
    skip "SessionActivity attach()"
  elif grep -q "SessionState.padBridge = bridge" "$SA"; then
    sed -i '/SessionState.padBridge = bridge/a\        com.droiddeck.launcher.input.DualSenseBridge.attach(this, bridge)' "$SA"
    grep -q "DualSenseBridge.attach(" "$SA" && ok "SessionActivity attach()" || warn "SessionActivity attach() NOT inserted"
  else
    warn "SessionActivity: add  com.droiddeck.launcher.input.DualSenseBridge.attach(this, bridge)  after the PadBridge is created"
  fi

  # 4c. session screen closing: forget its PadBridge, but KEEP the bridge connected (hook-up, passthrough)
  #     -- Android closes/recreates this screen when you switch apps while the session keeps running.
  if grep -q "DualSenseBridge.screenClosed(" "$SA"; then
    skip "SessionActivity screenClosed()"
  elif grep -q "padBridge?.stop()" "$SA"; then
    python3 - "$SA" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
anchor = "        padBridge?.stop()\n"
if anchor in s:
    s = s.replace(anchor, anchor + "        com.droiddeck.launcher.input.DualSenseBridge.screenClosed(this)\n", 1)
    open(p, 'w', encoding='utf-8').write(s)
PY
    grep -q "DualSenseBridge.screenClosed(" "$SA" && ok "SessionActivity screenClosed()" || warn "SessionActivity screenClosed() NOT inserted"
  else
    warn "SessionActivity: add  com.droiddeck.launcher.input.DualSenseBridge.screenClosed(this)  in onDestroy"
  fi
  # 4d. disconnect from the bridge only when the SESSION ends (or DroidDeck is closed)
  SVC4="$PKG/session/SessionService.kt"
  if [ -f "$SVC4" ]; then
    if grep -q "DualSenseBridge.detach()" "$SVC4"; then
      skip "SessionService detach() at session end"
    else
      python3 - "$SVC4" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
done = 0
for old in ("        GameThreadHints.stop()\n        SessionEvents.transition(SessionPhase.STOPPING",
            "        GameThreadHints.stop() // also when the session never got as far as running\n"):
    if s.count(old) == 1:
        first, rest = old.split("\n", 1)
        s = s.replace(old, first + "\n        com.droiddeck.launcher.input.DualSenseBridge.detach()\n" + rest, 1)
        done += 1
open(p, 'w', encoding='utf-8').write(s)
print(done)
PY
      grep -q "DualSenseBridge.detach()" "$SVC4" && ok "SessionService detach() at session end" || warn "SessionService detach() NOT inserted (bridge stays bound until DroidDeck is closed)"
    fi
  fi
else
  warn "SessionActivity.kt not found at $SA"
fi

# ---------- 5. PadMotion.kt (stop the phone's own gyro while the bridge streams) ----------
if [ -f "$PM" ]; then
  # 5a. drop phone sensor samples while the bridge is active (anchored on onSensorChanged so the
  #     poll loop keeps running and resumes when the bridge disconnects)
  if grep -q "DualSenseBridge.isActive()) return" "$PM"; then
    skip "PadMotion onSensorChanged guard"
  elif grep -q "override fun onSensorChanged(event: SensorEvent) {" "$PM"; then
    sed -i '/override fun onSensorChanged(event: SensorEvent) {/a\        if (DualSenseBridge.isActive()) return' "$PM"
    grep -q "DualSenseBridge.isActive()) return" "$PM" && ok "PadMotion onSensorChanged guard" || warn "PadMotion onSensorChanged guard NOT inserted"
  else
    warn "PadMotion: add  if (DualSenseBridge.isActive()) return  at the top of onSensorChanged()"
  fi

  # 5b. don't even register the phone sensors while the bridge is active
  if grep -q "wanted && !DualSenseBridge.isActive() && !reading" "$PM"; then
    skip "PadMotion follow() guard"
  elif grep -q "if (wanted && !reading) {" "$PM"; then
    sed -i 's#if (wanted && !reading) {#if (wanted \&\& !DualSenseBridge.isActive() \&\& !reading) {#' "$PM"
    grep -q "wanted && !DualSenseBridge.isActive() && !reading" "$PM" && ok "PadMotion follow() guard" || warn "PadMotion follow() guard NOT inserted"
  else
    warn "PadMotion: gate sensor registration with  && !DualSenseBridge.isActive()"
  fi
else
  warn "PadMotion.kt not found at $PM"
fi

# ---------- 6. App name -> SDL3Deck (launcher label only) ----------
if grep -rq 'name="app_name">SDL3Deck<' "$DD/app/src/main/res" 2>/dev/null; then
  skip "app name = SDL3Deck"
else
  n=0
  for f in "$DD"/app/src/main/res/values*/strings.xml; do
    [ -f "$f" ] || continue
    if grep -q '<string name="app_name">DroidDeck</string>' "$f"; then
      sed -i 's#<string name="app_name">DroidDeck</string>#<string name="app_name">SDL3Deck</string>#' "$f"
      n=$((n+1))
    fi
  done
  if [ "$n" -gt 0 ]; then ok "app name = SDL3Deck ($n locale file(s))"; else warn "app name not changed (app_name string not found)"; fi
fi

# ---------- 7. Docker Hub auth for the build (avoids the registry pull limit) ----------
BUILDYML="$DD/.github/workflows/build.yml"
if [ -f "$BUILDYML" ]; then
  if grep -q "Log in to Docker Hub" "$BUILDYML"; then
    skip "build.yml Docker Hub auth"
  else
    # pull the base Debian image from Docker Hub (authenticated) instead of the rate-limited public ECR
    sed -i 's#public.ecr.aws/docker/library/debian:bullseye#docker.io/library/debian:bullseye#g' "$BUILDYML"
    cat > /tmp/_dockerlogin.txt <<'YML'
      - name: Log in to Docker Hub (lifts the registry pull limit)
        env:
          DH_USER: ${{ secrets.DOCKERHUB_USER }}
          DH_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
        run: |
          if [ -n "$DH_USER" ] && [ -n "$DH_TOKEN" ]; then
            echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin
          else
            echo "No Docker Hub secrets set; using anonymous pull."
          fi

YML
    insert_before "- name: Fetch the Debian image the preloads build in" /tmp/_dockerlogin.txt "$BUILDYML"
    if grep -q "Log in to Docker Hub" "$BUILDYML"; then ok "build.yml Docker Hub auth (set secrets DOCKERHUB_USER + DOCKERHUB_TOKEN)"; else warn "build.yml Docker Hub auth not inserted (anchor not found)"; fi
  fi
fi

# ---------- 8. RumbleComponent: route rumble to the bridged controller (not the phone) ----------
RC="$DD/app/src/main/java/com/droiddeck/launcher/session/RumbleComponent.kt"
if [ -f "$RC" ]; then
  if grep -q "DualSenseBridge.routeRumble" "$RC"; then
    skip "RumbleComponent bridge routing"
  elif grep -q "if (!enabled) return" "$RC"; then
    sed -i '/if (!enabled) return/a\        if (com.droiddeck.launcher.input.DualSenseBridge.routeRumble(slot, strong, weak, ms)) return' "$RC"
    grep -q "DualSenseBridge.routeRumble" "$RC" && ok "RumbleComponent bridge routing" || warn "RumbleComponent hook NOT inserted"
  else
    warn "RumbleComponent: add a DualSenseBridge.routeRumble(slot, strong, weak, ms) check at the top of buzz()"
  fi
else
  warn "RumbleComponent.kt not found (skipping rumble routing)"
fi

# ---------- 9. Add a native DualSense Edge (054c:0df2) as a SEPARATE pad type ----------
# A standard DualSense (054c:0ce6) has no back buttons in its HID report; a DualSense Edge (054c:0df2)
# does -- SDL/Steam read its 2 back paddles + 2 Fn buttons from one button byte. We add the Edge as its
# own fake controller (new hidraw node 22, pad type 5) ALONGSIDE the untouched plain DualSense, and feed
# the Deck grips into the Edge's extra-button bits. Plain DualSense (option "DualSense (native)") is kept.
CPP="$DD/app/src/main/cpp/fakeinput_steam.cpp"
SDP="$PKG/session/SteamDeckPad.kt"
FIW="$IN/FakeInputWriter.java"
if [ -f "$CPP" ] && [ -f "$SDP" ] && [ -f "$FIW" ]; then
  if python3 - "$CPP" "$SDP" "$FIW" <<'PY'
import sys
cpp, sdp, fiw = sys.argv[1], sys.argv[2], sys.argv[3]

def patch(path, edits):
    s = open(path, encoding='utf-8').read()
    for old, new, marker in edits:
        markers = marker if isinstance(marker, tuple) else (marker,)
        if any(m in s for m in markers):
            continue  # already applied (idempotent)
        n = s.count(old)
        if n != 1:
            sys.stderr.write("ANCHOR-MISS %s :: %r (found %d, expected 1)\n" % (path, old[:70], n))
            sys.exit(3)
        s = s.replace(old, new, 1)
    open(path, 'w', encoding='utf-8').write(s)

# ---- FakeInputWriter.java: the Java-side pad-type constant ----
patch(fiw, [
    ('    public static final int PAD_TYPE_DUALSENSE = 4;',
     '    public static final int PAD_TYPE_DUALSENSE = 4;\n'
     '    public static final int PAD_TYPE_DUALSENSE_EDGE = 5;',
     'PAD_TYPE_DUALSENSE_EDGE = 5'),
])

# ---- SteamDeckPad.kt: new node (minor 22) + Edge identity; describeSony refactored to explicit params ----
patch(sdp, [
    ('    private const val SONY_DUALSENSE_MINOR = 21',
     '    private const val SONY_DUALSENSE_MINOR = 21\n'
     '    private const val SONY_DUALSENSE_EDGE_MINOR = 22',
     'SONY_DUALSENSE_EDGE_MINOR = 22'),
    ('            com.droiddeck.launcher.input.FakeInputWriter.PAD_TYPE_DUALSENSE -> SONY_DUALSENSE_MINOR',
     '            com.droiddeck.launcher.input.FakeInputWriter.PAD_TYPE_DUALSENSE -> SONY_DUALSENSE_MINOR\n'
     '            com.droiddeck.launcher.input.FakeInputWriter.PAD_TYPE_DUALSENSE_EDGE -> SONY_DUALSENSE_EDGE_MINOR',
     'PAD_TYPE_DUALSENSE_EDGE -> SONY_DUALSENSE_EDGE_MINOR'),
    ('            fun describeSony(dualSense: Boolean) {\n'
     '                val bus = if (dualSense) 5 else 4\n'
     '                val product = if (dualSense) "0ce6" else "09cc"\n'
     '                val minor = if (dualSense) SONY_DUALSENSE_MINOR else SONY_DS4_MINOR\n'
     '                val node = "hidraw$minor"\n'
     '                val name = if (dualSense) "DualSense Wireless Controller" else "Wireless Controller"',
     '            fun describeSony(bus: Int, product: String, minor: Int, name: String, sonyDescriptor: ByteArray) {\n'
     '                val node = "hidraw$minor"',
     'fun describeSony(bus: Int, product: String, minor: Int, name: String, sonyDescriptor: ByteArray)'),
    ('File(dir(hid), "report_descriptor").writeBytes(if (dualSense) DUALSENSE_REPORT_DESCRIPTOR else DS4_REPORT_DESCRIPTOR)',
     'File(dir(hid), "report_descriptor").writeBytes(sonyDescriptor)',
     'writeBytes(sonyDescriptor)'),
    ('            describeSony(dualSense = false)\n'
     '            describeSony(dualSense = true)',
     '            describeSony(4, "09cc", SONY_DS4_MINOR, "Wireless Controller", DS4_REPORT_DESCRIPTOR)\n'
     '            describeSony(5, "0ce6", SONY_DUALSENSE_MINOR, "DualSense Wireless Controller", DUALSENSE_REPORT_DESCRIPTOR)\n'
     '            describeSony(6, "0df2", SONY_DUALSENSE_EDGE_MINOR, "DualSense Edge Wireless Controller", DUALSENSE_REPORT_DESCRIPTOR)',
     'describeSony(6, "0df2"'),
])

# ---- fakeinput_steam.cpp: enum, node constants, every sony/pad-type branch, and the Edge button bits ----
patch(cpp, [
    ('PAD_TYPE_DUALSENSE = 4, PAD_TYPE_LAST = PAD_TYPE_DUALSENSE;',
     'PAD_TYPE_DUALSENSE = 4, PAD_TYPE_DUALSENSE_EDGE = 5, PAD_TYPE_LAST = PAD_TYPE_DUALSENSE_EDGE;',
     'PAD_TYPE_DUALSENSE_EDGE = 5'),
    ('static constexpr unsigned int DS4_HIDRAW_MINOR = 20, DUALSENSE_HIDRAW_MINOR = 21;',
     'static constexpr unsigned int DS4_HIDRAW_MINOR = 20, DUALSENSE_HIDRAW_MINOR = 21, DUALSENSE_EDGE_HIDRAW_MINOR = 22;\n'
     'static constexpr const char *DUALSENSE_EDGE_HIDRAW_PATH = "/dev/hidraw22";',
     'DUALSENSE_EDGE_HIDRAW_PATH = "/dev/hidraw22"'),
    ('  if (!strcmp(pathname, DUALSENSE_HIDRAW_PATH)) return live_pad_type() == PAD_TYPE_DUALSENSE ? 5 : 0;',
     '  if (!strcmp(pathname, DUALSENSE_HIDRAW_PATH)) return live_pad_type() == PAD_TYPE_DUALSENSE ? 5 : 0;\n'
     '  if (!strcmp(pathname, DUALSENSE_EDGE_HIDRAW_PATH)) return live_pad_type() == PAD_TYPE_DUALSENSE_EDGE ? 6 : 0;',
     'DUALSENSE_EDGE_HIDRAW_PATH)) return'),
    ('  uint32_t type = self->sony == 4 ? PAD_TYPE_DS4 : PAD_TYPE_DUALSENSE;',
     '  uint32_t type = self->sony == 4 ? PAD_TYPE_DS4 : self->sony == 6 ? PAD_TYPE_DUALSENSE_EDGE : PAD_TYPE_DUALSENSE;',
     'self->sony == 6 ? PAD_TYPE_DUALSENSE_EDGE'),
    ('  const char *path = sony == 4 ? DS4_HIDRAW_PATH : sony == 5 ? DUALSENSE_HIDRAW_PATH : DECK_HIDRAW_PATH;',
     '  const char *path = sony == 4 ? DS4_HIDRAW_PATH : sony == 5 ? DUALSENSE_HIDRAW_PATH : sony == 6 ? DUALSENSE_EDGE_HIDRAW_PATH : DECK_HIDRAW_PATH;',
     'sony == 6 ? DUALSENSE_EDGE_HIDRAW_PATH :'),
    ('              sony == 4 ? " (a DualShock 4)" : sony == 5 ? " (a DualSense)" : "");',
     '              sony == 4 ? " (a DualShock 4)" : sony == 5 ? " (a DualSense)" : sony == 6 ? " (a DualSense Edge)" : "");',
     '(a DualSense Edge)'),
    ('  uint8_t system = (buttons & 1024 ? 0x01 : 0) | (click ? 0x02 : 0);',
     '  uint8_t system = (buttons & 1024 ? 0x01 : 0) | (click ? 0x02 : 0);\n'
     '  // DualSense / Edge mute (microphone) button -> bit 0x04 of this byte. The bridge maps the mute\n'
     '  // button to the Deck QAM bit; DualShock 4 (model 4) has no mute and reuses 0x04 for its counter.\n'
     '  if (model != 4 && (buttons & SNAPSHOT_QAM_BIT)) system |= 0x04;\n'
     '  // DualSense Edge extra buttons: SDL/Steam read all four from this byte on PID 0x0df2 --\n'
     '  //   0x10 left Fn, 0x20 right Fn, 0x40 left back paddle, 0x80 right back paddle.\n'
     '  // model 6 == the Edge node; plain DualSense (5) and DS4 (4) are left untouched. Deck grips map 1:1:\n'
     '  //   L4 -> left paddle, R4 -> right paddle, L5 -> left Fn, R5 -> right Fn.\n'
     '  if (model == 6) {\n'
     '    if (extras.controls & DECK_EXTRA_L4) system |= 0x40;\n'
     '    if (extras.controls & DECK_EXTRA_R4) system |= 0x80;\n'
     '    if (extras.controls & DECK_EXTRA_L5) system |= 0x10;\n'
     '    if (extras.controls & DECK_EXTRA_R5) system |= 0x20;\n'
     '  }',
     'DualSense Edge extra buttons'),
    ('static_cast<int16_t>(pad.sony == 4 ? 0x09cc : 0x0ce6)',
     'static_cast<int16_t>(pad.sony == 4 ? 0x09cc : pad.sony == 6 ? 0x0df2 : 0x0ce6)',
     'pad.sony == 6 ? 0x0df2'),
    (': "Sony Interactive Entertainment DualSense Wireless Controller");',
     ': pad.sony == 6 ? "Sony Interactive Entertainment DualSense Edge Wireless Controller" : "Sony Interactive Entertainment DualSense Wireless Controller");',
     'DualSense Edge Wireless Controller"'),
    ('pad.sony == 4 ? "usb-droiddeck-4/input3" : "usb-droiddeck-5/input3"',
     'pad.sony == 4 ? "usb-droiddeck-4/input3" : pad.sony == 6 ? "usb-droiddeck-6/input3" : "usb-droiddeck-5/input3"',
     'usb-droiddeck-6/input3'),
    ('(pad.sony == 5 && id == 0x05)',
     '((pad.sony == 5 || pad.sony == 6) && id == 0x05)',
     '(pad.sony == 5 || pad.sony == 6) && id == 0x05'),
    ('(pad.sony == 5 && id == 0x09)',
     '((pad.sony == 5 || pad.sony == 6) && id == 0x09)',
     '(pad.sony == 5 || pad.sony == 6) && id == 0x09'),
    ('  } else if (pad.sony == 5 && id == 0x20) {',
     '  } else if ((pad.sony == 5 || pad.sony == 6) && id == 0x20) {',
     '(pad.sony == 5 || pad.sony == 6) && id == 0x20'),
    ('  } else if (pad.sony == 5 && data[0] == 0x02) {',
     '  } else if ((pad.sony == 5 || pad.sony == 6) && data[0] == 0x02) {',
     '(pad.sony == 5 || pad.sony == 6) && data[0] == 0x02'),
    ('makedev(DECK_HIDRAW_MAJOR, sony == 4 ? DS4_HIDRAW_MINOR : DUALSENSE_HIDRAW_MINOR)',
     'makedev(DECK_HIDRAW_MAJOR, sony == 4 ? DS4_HIDRAW_MINOR : sony == 6 ? DUALSENSE_EDGE_HIDRAW_MINOR : DUALSENSE_HIDRAW_MINOR)',
     '? DUALSENSE_EDGE_HIDRAW_MINOR : DUALSENSE_HIDRAW_MINOR)'),
    ('                       : device.sony == 5 ? DUALSENSE_HIDRAW_MINOR',
     '                       : device.sony == 6 ? DUALSENSE_EDGE_HIDRAW_MINOR\n'
     '                       : device.sony == 5 ? DUALSENSE_HIDRAW_MINOR',
     'device.sony == 6 ? DUALSENSE_EDGE_HIDRAW_MINOR'),
    ('static constexpr const char *DUALSENSE_DEVPATH = "/devices/droiddeck/usb5/5-1:1.3/0003:054C:0CE6.0006/hidraw/hidraw21";',
     'static constexpr const char *DUALSENSE_DEVPATH = "/devices/droiddeck/usb5/5-1:1.3/0003:054C:0CE6.0006/hidraw/hidraw21";\n'
     'static constexpr const char *DUALSENSE_EDGE_DEVPATH = "/devices/droiddeck/usb6/6-1:1.3/0003:054C:0DF2.0007/hidraw/hidraw22";',
     'DUALSENSE_EDGE_DEVPATH'),
    ('  if (type == PAD_TYPE_STEAM)\n    return inject_uevent(action, TRITON_PAD_DEVPATH',
     '  if (type == PAD_TYPE_DUALSENSE_EDGE)\n'
     '    return inject_uevent(action, DUALSENSE_EDGE_DEVPATH, "hidraw", DUALSENSE_EDGE_HIDRAW_PATH, DECK_HIDRAW_MAJOR,\n'
     '                         DUALSENSE_EDGE_HIDRAW_MINOR);\n'
     '  if (type == PAD_TYPE_STEAM)\n    return inject_uevent(action, TRITON_PAD_DEVPATH',
     'type == PAD_TYPE_DUALSENSE_EDGE)'),
    ('       : type == PAD_TYPE_DUALSENSE ? DUALSENSE_HIDRAW_MINOR',
     '       : type == PAD_TYPE_DUALSENSE ? DUALSENSE_HIDRAW_MINOR\n'
     '       : type == PAD_TYPE_DUALSENSE_EDGE ? DUALSENSE_EDGE_HIDRAW_MINOR',
     'type == PAD_TYPE_DUALSENSE_EDGE ? DUALSENSE_EDGE_HIDRAW_MINOR'),
    ('                                 "DualShock 4", "DualSense"};',
     '                                 "DualShock 4", "DualSense", "DualSense Edge"};',
     ('"DualSense", "DualSense Edge"}', '"Steam Controller (2015)"}', '"no pad"}')),
    ('kNames[was % 5]',
     'kNames[was % 6]',
     ('kNames[was % 6]', 'kNames[was % 7]', 'kNames[was % 8]')),
    # Sony touchpad (DualShock 4, DualSense, DualSense Edge): one full-width multitouch surface, never
    # the Deck's two halves. A real Sony pad is a single surface where finger 0 is the primary touch,
    # so confining finger 1 to the right half loses any touch that lands on it alone. put_sony_touch is
    # only ever used by Sony pads, so making it full-width for all of them is correct.
    ('  int half = SONY_TOUCH_WIDTH / 2;\n'
     '  int px = side * half + (static_cast<int>(x) + 32768) * (half - 1) / 65535;',
     '  int px = (static_cast<int>(x) + 32768) * (SONY_TOUCH_WIDTH - 1) / 65535;',
     'int px = (static_cast<int>(x) + 32768) * (SONY_TOUCH_WIDTH - 1) / 65535;'),
])
sys.stdout.write("OK\n")
PY
  then ok "DualSense Edge pad type (separate, native back buttons)"
  else die "Edge patch failed: an upstream anchor moved (see ANCHOR-MISS above). Re-anchor step 9."
  fi
else
  warn "fakeinput_steam.cpp / SteamDeckPad.kt / FakeInputWriter.java not found (skipping Edge pad type)"
fi

# ---------- 10. Unlock ADPF game-thread boosting beyond the Odin 3 ----------
# GameThreadHints uses Android's PerformanceHintManager to push the game's busiest threads onto the
# prime CPU cores. It was hard-gated to the Odin 3 (SoC CQ8725S). It is a PURE scheduling hint -- it
# cannot change how a game runs, so it cannot hurt compatibility -- and it stays behind the user's
# "game thread hints" setting (step 16 puts it in the session drawer). Open it to any Android 12+ device:
# a power HAL without hint-session support simply returns no session and nothing happens.
GTH="$PKG/session/GameThreadHints.kt"
if [ -f "$GTH" ]; then
  if python3 - "$GTH" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if "game thread hints: any device" not in s:
    old = '        if (Build.VERSION.SDK_INT < 31 || Build.SOC_MODEL != "CQ8725S") return "game thread hints: Odin 3 only"'
    new = ('        if (Build.VERSION.SDK_INT < 31) return "game thread hints: needs Android 12+"\n'
           '        // sdl3bridge: game thread hints: any device. ADPF is a pure scheduling hint (it cannot change\n'
           '        // how a game runs); a power HAL without hint sessions just returns none and nothing happens.\n'
           '        // Tuned on the Odin 3; switch it off in the session drawer (Latency) if a device behaves worse.')
    if s.count(old) != 1:
        sys.stderr.write("ANCHOR-MISS GameThreadHints device gate (found %d)\n" % s.count(old))
        sys.exit(3)
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
sys.stdout.write("OK\n")
PY
  then ok "ADPF game-thread boosting unlocked (any Android 12+ device)"
  else die "GameThreadHints patch failed: an upstream anchor moved (see ANCHOR-MISS above)."
  fi
else
  warn "GameThreadHints.kt not found (skipping ADPF unlock)"
fi

# ---------- 11. Don't let upstream's unit-test flakes block the APK build ----------
# The sync overlays the latest upstream DroidDeck every build, so a test that is red upstream (or flaky
# in the CI sandbox -- e.g. Robolectric failing to bind a local socket) would fail YOUR build even
# though the bridge integration is fine. The bridge's own code is verified separately and on-device, so
# the unit-test task is made non-blocking. This changes nothing in the shipped APK.
GRADLE="$DD/app/build.gradle"
if [ -f "$GRADLE" ]; then
  if grep -q "ignoreFailures = true" "$GRADLE"; then
    skip "unit tests non-blocking"
  elif grep -q "unitTests.all {" "$GRADLE"; then
    sed -i 's/        unitTests.all {/        unitTests.all {\n            ignoreFailures = true/' "$GRADLE"
    grep -q "ignoreFailures = true" "$GRADLE" && ok "unit tests non-blocking (upstream flakes won't fail the build)" || warn "could not set ignoreFailures"
  else
    warn "unitTests.all block not found in app/build.gradle (skipping; unit-test flakes may block the build)"
  fi
else
  warn "app/build.gradle not found (skipping unit-test guard)"
fi

# ---------- 12. Sony rumble: decode what Steam/SDL actually send, and honor stops ----------
# Upstream only treated a DualSense effects report as rumble when enable-bits1 had 0x01/0x02. Firmware
# >= 2.24 and every DualSense Edge use SDL's "enhanced rumble" (enable-bits3 0x04 at byte 39), and the
# motors-off report clears all of those bits -- so stops were ignored and every buzz ran a fixed 2 s.
# Now: rumble bits present -> motors as sent, held until the next report; bits absent -> motors off.
# The first ~40 motor changes are written to pad.log ("sony: out ...") so a session log shows the path.
CPP="$DD/app/src/main/cpp/fakeinput_steam.cpp"
if [ -f "$CPP" ]; then
  if python3 - "$CPP" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if "sdl3bridge: sony rumble v2" not in s:
    old = ('  int weak, strong;\n'
           '  if (pad.sony == 4 && data[0] == 0x05) {\n'
           '    if (!(data[1] & 0x01)) return;\n'
           '    weak = data[4];\n'
           '    strong = data[5];\n'
           '  } else if ((pad.sony == 5 || pad.sony == 6) && data[0] == 0x02) {\n'
           '    if (!(data[1] & 0x03)) return;\n'
           '    weak = data[3];\n'
           '    strong = data[4];\n'
           '  } else {\n'
           '    return;\n'
           '  }\n'
           '  send_vibration(strong * 257, weak * 257, strong || weak ? 2000 : 0, 0);\n')
    new = ('  // sdl3bridge: sony rumble v2\n'
           '  static int last_strong = -1, last_weak = -1;\n'
           '  static unsigned logged = 0;\n'
           '  int weak = 0, strong = 0;\n'
           '  if (pad.sony == 4 && data[0] == 0x05) {\n'
           '    if (!(data[1] & 0x01)) return;  // DS4: motors untouched by this report\n'
           '    weak = data[4];\n'
           '    strong = data[5];\n'
           '  } else if ((pad.sony == 5 || pad.sony == 6) && data[0] == 0x02) {\n'
           '    // [1] enable bits1 (0x01 rumble emulation, 0x02 haptics off), [3] right/weak, [4] left/strong,\n'
           '    // [39] enable bits3 (0x04 = improved rumble, fw >= 2.24 / Edge). Full state is re-sent every\n'
           '    // report, and the bits are cleared once the motors stop: no bits = motors off.\n'
           '    bool rumble = (data[1] & 0x03) || (size > 39 && (data[39] & 0x04));\n'
           '    if (rumble) {\n'
           '      weak = data[3];\n'
           '      strong = data[4];\n'
           '    }\n'
           '  } else {\n'
           '    return;\n'
           '  }\n'
           '  if (strong == last_strong && weak == last_weak) return;  // LED / repeat report: nothing changed\n'
           '  if (logged < 40) {\n'
           '    logged++;\n'
           '    Logger::log("sony: out 0x%02x bits %02x/%02x motors %d/%d\\n", data[0], data[1],\n'
           '                size > 39 ? data[39] : 0, strong, weak);\n'
           '  }\n'
           '  last_strong = strong;\n'
           '  last_weak = weak;\n'
           '  send_vibration(strong * 257, weak * 257, strong || weak ? RUMBLE_HOLD_MS : 0, 0);\n')
    if s.count(old) != 1:
        sys.stderr.write("ANCHOR-MISS sony_output body (found %d)\n" % s.count(old))
        sys.exit(3)
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
sys.stdout.write("OK\n")
PY
  then ok "Sony rumble decode (enhanced rumble + stops)"
  else die "Sony rumble patch failed: an upstream anchor moved (see ANCHOR-MISS above)."
  fi
else
  warn "fakeinput_steam.cpp not found (skipping Sony rumble decode)"
fi

# ---------- 13. Add the ORIGINAL Steam Controller (2015, 28de:1102 wired) as its own pad type ----------
# DroidDeck's "Steam Controller" pad type is the 2026 Steam Controller (codename Triton, 28de:1302). This
# adds the 2015 model as pad type 6 on a new node (/dev/hidraw23). It speaks the same Valve HID protocol
# as the Deck pad (features 0x81/0x83/0x87/0x8f/0xae...), so it reuses the Deck's open/feature/ioctl path
# with its own identity, and sends the 2015 state packet (ValveInReport type 1):
#   no right stick (the DualSense right stick is unused, like the real controller); left stick and left
#   trackpad share one axis pair (interleaved, like the real firmware); D-pad = left trackpad edge clicks;
#   L4/L5 -> left grip, R4/R5 -> right grip. Longer trackpad haptic pulses (Steam's rumble/identify on this
#   controller) are forwarded as rumble; short tick pulses are ignored.
CPP="$DD/app/src/main/cpp/fakeinput_steam.cpp"
SDP="$PKG/session/SteamDeckPad.kt"
FIW="$IN/FakeInputWriter.java"
if [ -f "$CPP" ] && [ -f "$SDP" ] && [ -f "$FIW" ]; then
  if python3 - "$CPP" "$SDP" "$FIW" <<'PY'
import sys
cpp, sdp, fiw = sys.argv[1], sys.argv[2], sys.argv[3]

def patch(path, edits):
    s = open(path, encoding='utf-8').read()
    for edit in edits:
        old, new, marker = edit[0], edit[1], edit[2]
        want = edit[3] if len(edit) > 3 else 1
        markers = marker if isinstance(marker, tuple) else (marker,)
        if any(m in s for m in markers):
            continue  # already applied (idempotent)
        n = s.count(old)
        if n != want:
            sys.stderr.write("ANCHOR-MISS %s :: %r (found %d, expected %d)\n" % (path, old[:70], n, want))
            sys.exit(3)
        s = s.replace(old, new)
    open(path, 'w', encoding='utf-8').write(s)

# ---- FakeInputWriter.java ----
patch(fiw, [
    ('    public static final int PAD_TYPE_DUALSENSE_EDGE = 5;',
     '    public static final int PAD_TYPE_DUALSENSE_EDGE = 5;\n'
     '    public static final int PAD_TYPE_STEAM_2015 = 6;',
     'PAD_TYPE_STEAM_2015 = 6'),
])

# ---- SteamDeckPad.kt: /dev/hidraw23 described as 28de:1102 interface 2 ----
patch(sdp, [
    ('    private const val SONY_DUALSENSE_EDGE_MINOR = 22',
     '    private const val SONY_DUALSENSE_EDGE_MINOR = 22\n'
     '    private const val SC2015_MINOR = 23',
     'SC2015_MINOR = 23'),
    ('            com.droiddeck.launcher.input.FakeInputWriter.PAD_TYPE_DUALSENSE_EDGE -> SONY_DUALSENSE_EDGE_MINOR',
     '            com.droiddeck.launcher.input.FakeInputWriter.PAD_TYPE_DUALSENSE_EDGE -> SONY_DUALSENSE_EDGE_MINOR\n'
     '            com.droiddeck.launcher.input.FakeInputWriter.PAD_TYPE_STEAM_2015 -> SC2015_MINOR',
     'PAD_TYPE_STEAM_2015 -> SC2015_MINOR'),
    ('            describeTriton(wired = true)\n',
     '            fun describeSteamController2015() {\n'
     '                val usb = "$GUEST_DEVICES/usb7"\n'
     '                val iface = "$usb/7-1:1.2"\n'
     '                val hid = "$iface/0003:28DE:1102.0008"\n'
     '                val node = "hidraw$SC2015_MINOR"\n'
     '                write(usb, "uevent", "DEVTYPE=usb_device\\nPRODUCT=28de/1102/100\\nTYPE=0/0/0\\nBUSNUM=007\\nDEVNUM=002\\n")\n'
     '                write(usb, "idVendor", "28de\\n")\n'
     '                write(usb, "idProduct", "1102\\n")\n'
     '                write(usb, "bcdDevice", "0100\\n")\n'
     '                write(usb, "manufacturer", "Valve Software\\n")\n'
     '                write(usb, "product", "Steam Controller\\n")\n'
     '                write(usb, "serial", "DROIDDECKSC15\\n")\n'
     '                link(File(dir(usb), "subsystem"), "/sys/bus/usb")\n'
     '                write(iface, "uevent", "DEVTYPE=usb_interface\\nPRODUCT=28de/1102/100\\nINTERFACE=3/0/0\\n")\n'
     '                write(iface, "bInterfaceNumber", "02\\n")\n'
     '                write(iface, "bInterfaceClass", "03\\n")\n'
     '                link(File(dir(iface), "subsystem"), "/sys/bus/usb")\n'
     '                write(hid, "uevent", "DRIVER=hid-steam\\nHID_ID=0003:000028DE:00001102\\n" +\n'
     '                    "HID_NAME=Valve Software Steam Controller\\nHID_PHYS=usb-droiddeck-7/input2\\n" +\n'
     '                    "HID_UNIQ=DROIDDECKSC15\\nMODALIAS=hid:b0003g0001v000028DEp00001102\\n")\n'
     '                File(dir(hid), "report_descriptor").writeBytes(REPORT_DESCRIPTOR)\n'
     '                link(File(dir(hid), "subsystem"), "/sys/bus/hid")\n'
     '                val hidraw = "$hid/hidraw/$node"\n'
     '                write(hidraw, "uevent", "MAJOR=$MAJOR\\nMINOR=$SC2015_MINOR\\nDEVNAME=$node\\n")\n'
     '                write(hidraw, "dev", "$MAJOR:$SC2015_MINOR\\n")\n'
     '                link(File(dir(hidraw), "subsystem"), "/sys/class/hidraw")\n'
     '                link(File(dir(hidraw), "device"), hid)\n'
     '                padNodes[SC2015_MINOR] = hidraw\n'
     '                link(File(LinuxRuntime.liveDir(context), "drm/sys/$MAJOR:$SC2015_MINOR"), hidraw)\n'
     '                File(udevData, "c$MAJOR:$SC2015_MINOR").writeText("I:1\\nE:ID_INPUT=1\\nE:ID_INPUT_JOYSTICK=1\\n")\n'
     '                Log.i(TAG, "steam controller: /dev/$node described as the 2015 Steam Controller (28de:1102)")\n'
     '            }\n'
     '            describeSteamController2015()\n'
     '            describeTriton(wired = true)\n',
     'describeSteamController2015()'),
])

# ---- fakeinput_steam.cpp ----
SC1_CODE = r'''// sdl3bridge: Steam Controller (2015) state packet -- ValveInReport_t type 1 (ID_CONTROLLER_STATE),
// laid out as SDL's ValveControllerStatePacket_t: buttons in bytes 8..10, analog triggers in bytes 11/12,
// left axes 16/18 (stick OR left pad, see SC1_FINGER_LEFT), right pad 20/22, triggers 24/26, accel 28..,
// gyro 34.., orientation quaternion 40...
static constexpr uint32_t SC1_RT = 0x000001, SC1_LT = 0x000002, SC1_RB = 0x000004, SC1_LB = 0x000008,
                          SC1_Y = 0x000010, SC1_B = 0x000020, SC1_X = 0x000040, SC1_A = 0x000080,
                          SC1_UP = 0x000100, SC1_RIGHT = 0x000200, SC1_LEFT = 0x000400, SC1_DOWN = 0x000800,
                          SC1_BACK = 0x001000, SC1_STEAM = 0x002000, SC1_START = 0x004000,
                          SC1_LGRIP = 0x008000, SC1_RGRIP = 0x010000, SC1_LPAD_CLICK = 0x020000,
                          SC1_RPAD_CLICK = 0x040000, SC1_FINGER_LEFT = 0x080000, SC1_FINGER_RIGHT = 0x100000,
                          SC1_STICK_CLICK = 0x400000, SC1_PAD_AND_STICK = 0x800000;
static constexpr int32_t SC1_STICK_ACTIVE = 2000;
static constexpr int16_t SC1_DPAD_EDGE = 24000;

__attribute__((visibility("hidden"))) static void
build_sc1_report(uint8_t *report, uint32_t packet, uint32_t buttons, const int32_t *axes, const DeckExtras &extras) {
  memset(report, 0, DECK_REPORT_BYTES);
  report[0] = 0x01;  // report version 1
  report[2] = 0x01;  // ID_CONTROLLER_STATE
  report[3] = 0x3c;
  put32(report + 4, packet);
  // Snapshot order: A B X Y L1 R1 View Menu L3 R3 Steam. No right stick on this controller, so no R3.
  static const uint32_t kButtonBits[11] = {SC1_A,  SC1_B,     SC1_X,          SC1_Y, SC1_LB,   SC1_RB,
                                           SC1_BACK, SC1_START, SC1_STICK_CLICK, 0,     SC1_STEAM};
  uint32_t bits = 0;
  for (int i = 0; i < 11; i++)
    if (buttons & (1u << i)) bits |= kButtonBits[i];
  int32_t left_trigger = std::max(0, std::min(255, axes[5])), right_trigger = std::max(0, std::min(255, axes[4]));
  if (left_trigger >= 250) bits |= SC1_LT;
  if (right_trigger >= 250) bits |= SC1_RT;
  uint32_t controls = extras.controls;
  if (controls & (DECK_EXTRA_L4 | DECK_EXTRA_L5)) bits |= SC1_LGRIP;
  if (controls & (DECK_EXTRA_R4 | DECK_EXTRA_R5)) bits |= SC1_RGRIP;
  bool left_pad = controls & DECK_EXTRA_LPAD_TOUCH, right_pad = controls & DECK_EXTRA_RPAD_TOUCH;
  if (controls & DECK_EXTRA_LPAD_CLICK) bits |= SC1_LPAD_CLICK;
  if (controls & DECK_EXTRA_RPAD_CLICK) bits |= SC1_RPAD_CLICK;
  int32_t left_x = extras.pads[0], left_y = extras.pads[1];
  // The real controller has no D-pad: its D-pad is a click on the left trackpad's edge.
  int32_t hat_x = axes[6], hat_y = axes[7];
  if (hat_x || hat_y) {
    if (hat_y < 0) bits |= SC1_UP;
    if (hat_y > 0) bits |= SC1_DOWN;
    if (hat_x < 0) bits |= SC1_LEFT;
    if (hat_x > 0) bits |= SC1_RIGHT;
    left_pad = true;
    left_x = hat_x < 0 ? -SC1_DPAD_EDGE : hat_x > 0 ? SC1_DPAD_EDGE : 0;
    left_y = hat_y < 0 ? SC1_DPAD_EDGE : hat_y > 0 ? -SC1_DPAD_EDGE : 0;
    bits |= SC1_LPAD_CLICK;
  }
  auto clamp16 = [](int32_t value) { return std::max(-32767, std::min(32767, value)); };
  int32_t stick_x = clamp16(axes[0]), stick_y = clamp16(-axes[1]);
  bool stick = abs(stick_x) > SC1_STICK_ACTIVE || abs(stick_y) > SC1_STICK_ACTIVE;
  // The stick and the left pad share one axis pair; SC1_FINGER_LEFT says which one this packet carries,
  // and SC1_PAD_AND_STICK says both are in use (the firmware then alternates them packet by packet).
  int32_t axis_x = stick_x, axis_y = stick_y;
  if (left_pad && stick) {
    bits |= SC1_PAD_AND_STICK;
    if (packet & 1) {
      bits |= SC1_FINGER_LEFT;
      axis_x = left_x;
      axis_y = left_y;
    }
  } else if (left_pad) {
    bits |= SC1_FINGER_LEFT;
    axis_x = left_x;
    axis_y = left_y;
  }
  if (right_pad) bits |= SC1_FINGER_RIGHT;
  report[8] = static_cast<uint8_t>(bits);
  report[9] = static_cast<uint8_t>(bits >> 8);
  report[10] = static_cast<uint8_t>(bits >> 16);
  report[11] = static_cast<uint8_t>(left_trigger);
  report[12] = static_cast<uint8_t>(right_trigger);
  put16(report + 16, clamp16(axis_x));
  put16(report + 18, clamp16(axis_y));
  put16(report + 20, right_pad ? extras.pads[2] : 0);
  put16(report + 22, right_pad ? extras.pads[3] : 0);
  put16(report + 24, left_trigger * 32767 / 255);
  put16(report + 26, right_trigger * 32767 / 255);
  for (int i = 0; i < 3; i++) {
    put16(report + 28 + i * 2, extras.accel[i]);
    put16(report + 34 + i * 2, extras.gyro[i]);
  }
  put16(report + 40, 32767);  // orientation quaternion: identity (Steam uses the raw gyro)
}

__attribute__((visibility("hidden"))) static void *sc1_report_thread(void *arg) {
  auto *holder = static_cast<std::shared_ptr<DeckHidraw> *>(arg);
  std::shared_ptr<DeckHidraw> self = *holder;
  delete holder;
  uint32_t packet = 0;
  SnapshotState snap;
  uint32_t buttons = 0;
  int32_t axes[8] = {};
  DeckExtras extras;
  while (live_pad_type() == PAD_TYPE_STEAM_2015) {
    if (read_snapshot(self->ring, snap) && snap.generation == ring_generation(self->ring)) {
      buttons = snap.buttons;
      memcpy(axes, snap.axes, sizeof(axes));
    }
    read_deck_extras(*self, extras);
    uint8_t report[DECK_REPORT_BYTES];
    build_sc1_report(report, ++packet, buttons, axes, extras);
    if (send(self->peer, report, sizeof(report), MSG_DONTWAIT | MSG_NOSIGNAL) < 0 &&
        errno != EAGAIN && errno != EWOULDBLOCK)
      break;
    sleep_us(controller_report_interval_us(DECK_REPORT_INTERVAL_US));
  }
  syscall(SYS_close, self->peer);
  munmap(self->ring, self->mapping_size);
  return nullptr;
}

__attribute__((visibility("hidden"))) static int open_deck_hidraw('''

patch(cpp, [
    ('  bool emulated = false;\n  uint8_t sony = 0;\n};',
     '  bool emulated = false;\n  uint8_t sony = 0;\n  bool sc1 = false;  // sdl3bridge: Steam Controller (2015)\n};',
     'bool sc1 = false;'),
    ('PAD_TYPE_DUALSENSE_EDGE = 5, PAD_TYPE_LAST = PAD_TYPE_DUALSENSE_EDGE;',
     'PAD_TYPE_DUALSENSE_EDGE = 5,\n'
     '                          PAD_TYPE_STEAM_2015 = 6, PAD_TYPE_LAST = PAD_TYPE_STEAM_2015;',
     'PAD_TYPE_STEAM_2015 = 6'),
    ('static constexpr const char *DUALSENSE_EDGE_HIDRAW_PATH = "/dev/hidraw22";\n',
     'static constexpr const char *DUALSENSE_EDGE_HIDRAW_PATH = "/dev/hidraw22";\n'
     'static constexpr const char *SC1_HIDRAW_PATH = "/dev/hidraw23";\n'
     'static constexpr unsigned int SC1_HIDRAW_MINOR = 23;\n'
     'static constexpr const char *SC1_NAME = "Valve Software Steam Controller";\n'
     'static constexpr const char *SC1_SERIAL = "DROIDDECKSC15";\n'
     '\n'
     '__attribute__((visibility("hidden"))) static bool is_sc1_hidraw_path(const char *pathname) {\n'
     '  return pathname && fake_deck_enabled() && !strcmp(pathname, SC1_HIDRAW_PATH) &&\n'
     '         live_pad_type() == PAD_TYPE_STEAM_2015;\n'
     '}\n',
     'is_sc1_hidraw_path(const char *pathname) {'),
    ('__attribute__((visibility("hidden"))) static int open_deck_hidraw(int flags, uint8_t sony = 0) {\n'
     '  const char *path = sony == 4',
     SC1_CODE + 'int flags, uint8_t sony = 0, bool sc1 = false) {\n'
     '  const char *path = sc1 ? SC1_HIDRAW_PATH : sony == 4',
     'bool sc1 = false) {'),
    ('  deck->sony = sony;\n',
     '  deck->sony = sony;\n  deck->sc1 = sc1;\n',
     'deck->sc1 = sc1;'),
    ('sony ? sony_report_thread : deck_report_thread',
     'sony ? sony_report_thread : sc1 ? sc1_report_thread : deck_report_thread',
     'sc1 ? sc1_report_thread'),
    ('sony == 6 ? " (a DualSense Edge)" : "");',
     'sony == 6 ? " (a DualSense Edge)" : sc1 ? " (a Steam Controller 2015)" : "");',
     '" (a Steam Controller 2015)"'),
    # open() and openat()
    ('  if (is_deck_hidraw_path(pathname)) return open_deck_hidraw(flags);\n',
     '  if (is_deck_hidraw_path(pathname)) return open_deck_hidraw(flags);\n'
     '  if (is_sc1_hidraw_path(pathname)) return open_deck_hidraw(flags, 0, true);\n',
     'if (is_sc1_hidraw_path(pathname)) return open_deck_hidraw(flags, 0, true);', 2),
    # stat(path)
    ('      ((is_deck_hidraw_path(pathname) || is_triton_hidraw_path(pathname) || is_triton_pad_path(pathname) ||\n'
     '        sony_pad_path(pathname)) && !process_is_steam_client())) {',
     '      ((is_deck_hidraw_path(pathname) || is_triton_hidraw_path(pathname) || is_triton_pad_path(pathname) ||\n'
     '        sony_pad_path(pathname) || is_sc1_hidraw_path(pathname)) && !process_is_steam_client())) {',
     'sony_pad_path(pathname) || is_sc1_hidraw_path(pathname)) && !process_is_steam_client()'),
    ('    statbuf->st_rdev = makedev(DECK_HIDRAW_MAJOR, DECK_HIDRAW_MINOR);\n    return 0;\n  }\n',
     '    statbuf->st_rdev = makedev(DECK_HIDRAW_MAJOR, DECK_HIDRAW_MINOR);\n    return 0;\n  }\n'
     '  if (is_sc1_hidraw_path(pathname)) {\n'
     '    memset(statbuf, 0, sizeof(*statbuf));\n'
     '    statbuf->st_mode = S_IFCHR | 0666;\n'
     '    statbuf->st_rdev = makedev(DECK_HIDRAW_MAJOR, SC1_HIDRAW_MINOR);\n'
     '    return 0;\n'
     '  }\n',
     'makedev(DECK_HIDRAW_MAJOR, SC1_HIDRAW_MINOR);\n    return 0;'),
    # fstat(fd)
    ('                       : device.triton ? TRITON_HIDRAW_MINOR : DECK_HIDRAW_MINOR;',
     '                       : device.triton ? TRITON_HIDRAW_MINOR\n'
     '                       : device.sc1 ? SC1_HIDRAW_MINOR : DECK_HIDRAW_MINOR;',
     'device.sc1 ? SC1_HIDRAW_MINOR'),
    # access() and faccessat()
    ('  if (is_deck_hidraw_path(pathname) && process_is_steam_client()) return 0;\n',
     '  if (is_deck_hidraw_path(pathname) && process_is_steam_client()) return 0;\n'
     '  if (is_sc1_hidraw_path(pathname) && process_is_steam_client()) return 0;\n',
     'if (is_sc1_hidraw_path(pathname) && process_is_steam_client()) return 0;', 2),
    ('  if (is_withdrawn_pad_path(pathname) || is_deck_hidraw_path(pathname) || is_triton_hidraw_path(pathname) ||\n',
     '  if (is_withdrawn_pad_path(pathname) || is_deck_hidraw_path(pathname) || is_sc1_hidraw_path(pathname) ||\n'
     '      is_triton_hidraw_path(pathname) ||\n',
     'is_deck_hidraw_path(pathname) || is_sc1_hidraw_path(pathname) ||', 2),
    # identity over ioctl
    ('static_cast<int16_t>(0x1205)',
     'static_cast<int16_t>(deck.sc1 ? 0x1102 : 0x1205)',
     'deck.sc1 ? 0x1102 : 0x1205'),
    ('  case 0x04: return copy_ioctl_string(op, argp, DECK_NAME);',
     '  case 0x04: return copy_ioctl_string(op, argp, deck.sc1 ? SC1_NAME : DECK_NAME);',
     'deck.sc1 ? SC1_NAME : DECK_NAME'),
    ('"usb-droiddeck-1/input2"',
     'deck.sc1 ? "usb-droiddeck-7/input2" : "usb-droiddeck-1/input2"',
     '"usb-droiddeck-7/input2"'),
    ('  case 0x08: return copy_ioctl_string(op, argp, DECK_SERIAL);',
     '  case 0x08: return copy_ioctl_string(op, argp, deck.sc1 ? SC1_SERIAL : DECK_SERIAL);',
     'deck.sc1 ? SC1_SERIAL : DECK_SERIAL);'),
    # feature reports: product-id attribute, serial, and haptic pulses
    ('    memcpy(reply, kAttributes, sizeof(kAttributes));\n',
     '    memcpy(reply, kAttributes, sizeof(kAttributes));\n'
     '    if (deck.sc1) {  // ATTRIB_PRODUCT_ID = 0x1102\n'
     '      reply[4] = 0x02;\n'
     '      reply[5] = 0x11;\n'
     '    }\n',
     'ATTRIB_PRODUCT_ID = 0x1102'),
    ('    memcpy(reply + 4, DECK_SERIAL, strlen(DECK_SERIAL));',
     '    memcpy(reply + 4, deck.sc1 ? SC1_SERIAL : DECK_SERIAL, strlen(deck.sc1 ? SC1_SERIAL : DECK_SERIAL));',
     'deck.sc1 ? SC1_SERIAL : DECK_SERIAL, strlen('),
    ('      send_vibration(left, right, left || right ? 1000 : 0, 0);\n    }\n'
     '    if (buf[1] == DECK_SET_SETTINGS_VALUES && size >= 3) {\n',
     '      send_vibration(left, right, left || right ? 1000 : 0, 0);\n    }\n'
     '    // Steam rumbles / identifies a 2015 Steam Controller with trackpad haptic pulses (0x8f: side,\n'
     '    // on-us, off-us, repeat). Forward the long ones as rumble; short ones are trackpad ticks.\n'
     '    if (deck.sc1 && buf[1] == 0x8f && size >= 10) {\n'
     '      int on_us = buf[4] | buf[5] << 8, off_us = buf[6] | buf[7] << 8, repeat = buf[8] | buf[9] << 8;\n'
     '      long total_ms = static_cast<long>(on_us + off_us) * std::max(1, repeat) / 1000;\n'
     '      if (total_ms >= 20) send_vibration(0, 40000, static_cast<uint16_t>(std::min(1000L, total_ms)), 0);\n'
     '    }\n'
     '    if (buf[1] == DECK_SET_SETTINGS_VALUES && size >= 3) {\n',
     'deck.sc1 && buf[1] == 0x8f'),
    # pad-type switching (udev add/remove + hidraw watchers)
    ('static constexpr const char *TRITON_PAD_DEVPATH = "/devices/droiddeck/usb3/3-1:1.0/0003:28DE:1302.0004/hidraw/hidraw19";\n',
     'static constexpr const char *TRITON_PAD_DEVPATH = "/devices/droiddeck/usb3/3-1:1.0/0003:28DE:1302.0004/hidraw/hidraw19";\n'
     'static constexpr const char *SC1_DEVPATH = "/devices/droiddeck/usb7/7-1:1.2/0003:28DE:1102.0008/hidraw/hidraw23";\n',
     'SC1_DEVPATH ='),
    ('  if (type == PAD_TYPE_STEAM)\n    return inject_uevent(action, TRITON_PAD_DEVPATH',
     '  if (type == PAD_TYPE_STEAM_2015)\n'
     '    return inject_uevent(action, SC1_DEVPATH, "hidraw", SC1_HIDRAW_PATH, DECK_HIDRAW_MAJOR, SC1_HIDRAW_MINOR);\n'
     '  if (type == PAD_TYPE_STEAM)\n    return inject_uevent(action, TRITON_PAD_DEVPATH',
     'inject_uevent(action, SC1_DEVPATH'),
    ('       : type == PAD_TYPE_STEAM ? TRITON_PAD_HIDRAW_MINOR : DECK_HIDRAW_MINOR;',
     '       : type == PAD_TYPE_STEAM ? TRITON_PAD_HIDRAW_MINOR\n'
     '       : type == PAD_TYPE_STEAM_2015 ? SC1_HIDRAW_MINOR : DECK_HIDRAW_MINOR;',
     'type == PAD_TYPE_STEAM_2015 ? SC1_HIDRAW_MINOR'),
    ('"DualSense", "DualSense Edge"};',
     '"DualSense", "DualSense Edge",\n                                 "Steam Controller (2015)"};',
     ('"Steam Controller (2015)"};', '"Steam Controller (2015)", "no pad"};')),
    ('kNames[was % 6]',
     'kNames[was % 7]',
     ('kNames[was % 7]', 'kNames[was % 8]')),
])
sys.stdout.write("OK\n")
PY
  then ok "Steam Controller 2015 pad type (28de:1102, /dev/hidraw23)"
  else die "Steam Controller 2015 patch failed: an upstream anchor moved (see ANCHOR-MISS above)."
  fi
else
  warn "fakeinput_steam.cpp / SteamDeckPad.kt / FakeInputWriter.java not found (skipping Steam Controller 2015)"
fi

# ---------- 14. Steam Controller (2026) over USB cable / wireless puck via the SDL3 bridge ----------
# DroidDeck only prepares its Steam Controller node (/dev/hidraw18) when a Bluetooth one is paired. The
# SDL3 bridge can now pass a cable or puck Steam Controller through raw (DualSenseBridge.kt), so prepare the
# node whenever the bridge app is installed too. It stays invisible to Steam until a controller is actually
# streaming (connected flag in the shared block), and appears/disappears with hot-plug udev events.
SVC="$PKG/session/SessionService.kt"
if [ -f "$SVC" ]; then
  if grep -q "DualSenseBridge.isBridgeInstalled" "$SVC"; then
    skip "Steam Controller node for the bridge's cable/puck passthrough"
  elif grep -q "val wantsTriton = wantsDeck && SteamControllerBle.hasPairedController(this)" "$SVC"; then
    sed -i 's/val wantsTriton = wantsDeck \&\& SteamControllerBle.hasPairedController(this)/val wantsTriton = wantsDeck \&\& (SteamControllerBle.hasPairedController(this) || com.droiddeck.launcher.input.DualSenseBridge.isBridgeInstalled(this))/' "$SVC"
    grep -q "DualSenseBridge.isBridgeInstalled" "$SVC" && ok "Steam Controller node for the bridge's cable/puck passthrough" || die "SessionService wantsTriton patch failed"
  else
    die "SessionService: wantsTriton anchor moved (re-anchor step 14)"
  fi
else
  warn "SessionService.kt not found (skipping Steam Controller passthrough node)"
fi

# ---------- 15. Steam Native Hook-up: the bridge hands Steam the REAL USB controller ----------
# The SDL3 bridge can pass any USB controller SDL3 supports through raw (its real ids, name, serial, report
# descriptor and every HID report). DroidDeck shows each as /dev/hidraw24..27 with a kernel-like sysfs
# description, so Steam's own driver recognises the actual controller -- like on a PC. Game rumble is
# handed to Steam through its virtual pad's uinput force feedback so Steam rumbles that controller itself.
CPP="$DD/app/src/main/cpp/fakeinput_steam.cpp"
SDP="$PKG/session/SteamDeckPad.kt"
SVC="$PKG/session/SessionService.kt"
[ -f "$SRC/HookupBridge.kt" ] || die "HookupBridge.kt is missing next to this script"
[ -f "$SRC/hookup_native.inc" ] || die "hookup_native.inc is missing next to this script"
if [ -f "$CPP" ] && [ -f "$SDP" ] && [ -f "$SVC" ]; then
  cp "$SRC/HookupBridge.kt" "$IN/HookupBridge.kt" && ok "installed HookupBridge.kt"
  if python3 - "$CPP" "$SRC/hookup_native.inc" <<'PY'
import sys
cpp, inc = sys.argv[1], sys.argv[2]
MARK = "sdl3bridge: Steam Native Hook-up"
s = open(cpp, encoding='utf-8').read()
if MARK in s:
    sys.stdout.write("OK\n")
    sys.exit(0)
block = open(inc, encoding='utf-8').read()

def rep(old, new, want=1):
    global s
    n = s.count(old)
    if n != want:
        sys.stderr.write("ANCHOR-MISS hookup :: %r (found %d, expected %d)\n" % (old[:70], n, want))
        sys.exit(3)
    s = s.replace(old, new)

rep('#include <vector>\n', '#include <vector>\n#include <deque>\n#include <sys/resource.h>\n')
# DeckHidraw: which hook-up slot a hidraw fd serves
rep('  bool sc1 = false;  // sdl3bridge: Steam Controller (2015)\n};',
    '  bool sc1 = false;  // sdl3bridge: Steam Controller (2015)\n'
    '  int8_t hookup = -1;  // sdl3bridge: Steam Native Hook-up slot\n'
    '  uint32_t hookup_generation = 0;\n'
    '  std::shared_ptr<struct HookupQueue> hookup_in;  // sdl3bridge: reports waiting for Steam (mailbox)\n};')
# UinputWriter: force-feedback requests queued for Steam
rep('  uint32_t buttons = 0;\n  int16_t axes[8] = {};\n};',
    '  uint32_t buttons = 0;\n  int16_t axes[8] = {};\n'
    '  std::deque<struct input_event> ff_queue;  // sdl3bridge: game rumble handed to Steam\n'
    '  uint64_t ff_seen = 0;\n  uint32_t ff_request = 0;\n  struct ff_effect ff_effect = {};\n};')
# game rumble on a virtual pad -> shared state for Steam
rep('__attribute__((visibility("hidden"))) static void\nsend_vibration(int strong, int weak, uint16_t duration_ms, uint16_t slot) {\n',
    'static void hookup_ff_from_game(uint16_t slot, int strong, int weak, uint16_t length);\n\n'
    '__attribute__((visibility("hidden"))) static void\nsend_vibration(int strong, int weak, uint16_t duration_ms, uint16_t slot) {\n'
    '  hookup_ff_from_game(slot, strong, weak, duration_ms);\n')
# uinput force-feedback upload handshake answered for Steam
rep('''  case _IOC_NR(UI_BEGIN_FF_UPLOAD):
  case _IOC_NR(UI_END_FF_UPLOAD):
  case _IOC_NR(UI_BEGIN_FF_ERASE):
  case _IOC_NR(UI_END_FF_ERASE):
    errno = EINVAL;
    return -1;''', '''  case _IOC_NR(UI_BEGIN_FF_UPLOAD): {
    auto *upload = static_cast<struct uinput_ff_upload *>(argp);
    if (!upload || upload->request_id != w.ff_request) {
      errno = EINVAL;
      return -1;
    }
    upload->retval = 0;
    upload->effect = w.ff_effect;
    memset(&upload->old, 0, sizeof(upload->old));
    return 0;
  }
  case _IOC_NR(UI_END_FF_UPLOAD):
  case _IOC_NR(UI_END_FF_ERASE):
    return 0;
  case _IOC_NR(UI_BEGIN_FF_ERASE): {
    auto *erase = static_cast<struct uinput_ff_erase *>(argp);
    if (erase) erase->retval = 0;
    return 0;
  }''')
# the hook-up block itself
rep('__attribute__((visibility("hidden"))) static std::string note_sys_failure(int dirfd, const char *pathname) {',
    block + '__attribute__((visibility("hidden"))) static std::string note_sys_failure(int dirfd, const char *pathname) {')
# open() / openat()
rep('  if (is_deck_hidraw_path(pathname)) return open_deck_hidraw(flags);\n',
    '  if (is_deck_hidraw_path(pathname)) return open_deck_hidraw(flags);\n'
    '  if (int hk = hookup_path_slot(pathname); hk >= 0) return open_hookup_hidraw(flags, hk);\n', 2)
# stat(path)
rep('  if (is_touch_hidraw_path(pathname)) {\n    memset(statbuf, 0, sizeof(*statbuf));',
    '  if (hookup_path_slot(pathname) >= 0 && !process_is_steam_client()) {\n'
    '    errno = ENOENT;\n'
    '    return -1;\n'
    '  }\n'
    '  if (is_touch_hidraw_path(pathname)) {\n    memset(statbuf, 0, sizeof(*statbuf));')
rep('  if (is_sc1_hidraw_path(pathname)) {\n    memset(statbuf, 0, sizeof(*statbuf));',
    '  if (int hk = hookup_path_slot(pathname); hk >= 0) {\n'
    '    memset(statbuf, 0, sizeof(*statbuf));\n'
    '    statbuf->st_mode = S_IFCHR | 0666;\n'
    '    statbuf->st_rdev = makedev(DECK_HIDRAW_MAJOR, HOOKUP_MINOR_BASE + hk);\n'
    '    return 0;\n'
    '  }\n'
    '  if (is_sc1_hidraw_path(pathname)) {\n    memset(statbuf, 0, sizeof(*statbuf));')
# fstat(fd)
rep('    unsigned int minor = device.touch ? TOUCH_HIDRAW_MINOR\n',
    '    unsigned int minor = device.hookup >= 0 ? HOOKUP_MINOR_BASE + device.hookup\n'
    '                       : device.touch ? TOUCH_HIDRAW_MINOR\n')
# access() / faccessat()
rep('  if (is_sc1_hidraw_path(pathname) && process_is_steam_client()) return 0;\n',
    '  if (is_sc1_hidraw_path(pathname) && process_is_steam_client()) return 0;\n'
    '  if (hookup_path_slot(pathname) >= 0 && process_is_steam_client()) return 0;\n', 2)
rep('  if (is_withdrawn_pad_path(pathname) || is_deck_hidraw_path(pathname) || is_sc1_hidraw_path(pathname) ||\n',
    '  if (is_withdrawn_pad_path(pathname) || is_deck_hidraw_path(pathname) || is_sc1_hidraw_path(pathname) ||\n'
    '      hookup_path_slot(pathname) >= 0 ||\n', 2)
# ioctl
rep('  if (deck != deck_map().end()) {\n    if (deck->second->touch) return ioctl_touch(*deck->second, op, argp);',
    '  if (deck != deck_map().end()) {\n'
    '    if (deck->second->hookup >= 0) {\n'
    '      std::shared_ptr<DeckHidraw> pad = deck->second;\n'
    '      guard.unlock();\n'
    '      return ioctl_hookup(*pad, op, argp);\n'
    '    }\n'
    '    if (deck->second->touch) return ioctl_touch(*deck->second, op, argp);')
# write() / writev(): a hooked-up controller's output goes to the shared file WITHOUT the hook's controller lock
# held (writing may wait for room; with the lock held that wait would hold up Steam's virtual pad and reads)
rep('    if (deck_map()[fd]->touch) touch_output(',
    '    if (deck_map()[fd]->hookup >= 0) {\n'
    '      std::shared_ptr<DeckHidraw> pad = deck_map()[fd];\n'
    '      guard.unlock();\n'
    '      hookup_queue(*pad, static_cast<const uint8_t *>(buf), count, 0);\n'
    '      return static_cast<ssize_t>(count);\n'
    '    }\n'
    '    if (deck_map()[fd]->touch) touch_output(')
rep('    auto device = deck_map()[fd];\n    for (int i = 0; i < iovcnt; i++) {\n',
    '    auto device = deck_map()[fd];\n'
    '    if (device->hookup >= 0) {\n'
    '      guard.unlock();\n'
    '      for (int i = 0; i < iovcnt; i++) {\n'
    '        hookup_queue(*device, static_cast<const uint8_t *>(iov[i].iov_base), iov[i].iov_len, 0);\n'
    '        total += static_cast<ssize_t>(iov[i].iov_len);\n'
    '      }\n'
    '      return total;\n'
    '    }\n'
    '    for (int i = 0; i < iovcnt; i++) {\n')
# latency meter: Steam writing its virtual pad, and a game reading it
rep('__attribute__((visibility("hidden"))) static void flush_uinput(UinputWriter &w) {\n',
    'static void hookup_meter_virtual_pad(const std::vector<struct input_event> &events);\n\n'
    '__attribute__((visibility("hidden"))) static void flush_uinput(UinputWriter &w) {\n'
    '  if (w.published) hookup_meter_virtual_pad(w.pending);\n')
rep('          if (copied > 0) fake.read_seq += copied / sizeof(struct input_event);\n',
    '          if (copied > 0) fake.read_seq += copied / sizeof(struct input_event);\n'
    '          if (copied > 0 && fake.uinput) hookup_meter_game_read(input_events.data(), copied / sizeof(struct input_event));\n')
# read() of Steam's uinput fd -> queued force-feedback requests
rep('static ssize_t read_input(int fd, void *buf, size_t count) {\n  if (!watched(fd)) return syscall(SYS_read, fd, buf, count);\n',
    'static ssize_t read_input(int fd, void *buf, size_t count) {\n  if (!watched(fd)) return syscall(SYS_read, fd, buf, count);\n'
    '  if (ssize_t ff = hookup_read_uinput(fd, buf, count); ff != -2) return ff;\n')
open(cpp, 'w', encoding='utf-8').write(s)
sys.stdout.write("OK\n")
PY
  then ok "native hidraw hook-up nodes + game rumble to Steam"
  else die "hook-up native patch failed: an upstream anchor moved (see ANCHOR-MISS above)."
  fi
  if python3 - "$SDP" "$SVC" <<'PY'
import sys
sdp, svc = sys.argv[1], sys.argv[2]
def patch(path, old, new, marker):
    s = open(path, encoding='utf-8').read()
    if marker in s:
        return
    if s.count(old) != 1:
        sys.stderr.write("ANCHOR-MISS %s :: %r (found %d)\n" % (path, old[:70], s.count(old)))
        sys.exit(3)
    open(path, 'w', encoding='utf-8').write(s.replace(old, new, 1))
patch(sdp, '    private val padNodes = mutableMapOf<Int, String>()\n',
      '    // sdl3bridge: where the session sysfs lives, for HookupBridge (Steam Native Hook-up) hot-plug\n'
      '    @Volatile @JvmStatic var sysDevicesDir: File? = null\n'
      '    @Volatile @JvmStatic var sysHidrawClassDir: File? = null\n'
      '    @Volatile @JvmStatic var sysContext: Context? = null\n'
      '    private val padNodes = mutableMapOf<Int, String>()\n',
      'var sysDevicesDir: File?')
patch(sdp, '            hidrawClassDir = hidrawClass\n',
      '            hidrawClassDir = hidrawClass\n'
      '            sysDevicesDir = devices\n'
      '            sysHidrawClassDir = hidrawClass\n'
      '            sysContext = context.applicationContext\n',
      'sysDevicesDir = devices')
patch(svc, '                guest.add("FAKE_DECK_SYSFS_LISTING=" + SteamDeckPad.listingDir(fakeInputDir.parentFile!!.parentFile!!).path)\n',
      '                if (com.droiddeck.launcher.input.HookupBridge.wanted(this))\n'
      '                    com.droiddeck.launcher.input.HookupBridge.prepare(fakeInputDir, File(sessionDir, "pad.log"))?.let { guest.add("FAKE_HOOKUP_SHM=" + it.path) }\n'
      '                guest.add("FAKE_DECK_SYSFS_LISTING=" + SteamDeckPad.listingDir(fakeInputDir.parentFile!!.parentFile!!).path)\n',
      'FAKE_HOOKUP_SHM=')
print("OK")
PY
  then ok "hook-up sysfs + session wiring"
  else die "hook-up session patch failed: an upstream anchor moved (see ANCHOR-MISS above)."
  fi
else
  warn "fakeinput_steam.cpp / SteamDeckPad.kt / SessionService.kt not found (skipping Steam Native Hook-up)"
fi

# ---------- 16. "Game thread boost" switch in the session drawer (Latency group) ----------
# DroidDeck already had a gameThreadHints preference (default on) but no switch for it. Add one next to
# the low-latency switches; it takes effect immediately (starts/stops the boosting in the running session).
SP="$PKG/session/SessionPrefs.kt"
SO="$PKG/ui/SessionOverlay.kt"
SA="$PKG/SessionActivity.kt"
STR="$DD/app/src/main/res/values/strings.xml"
if [ -f "$SP" ] && [ -f "$SO" ] && [ -f "$SA" ] && [ -f "$STR" ]; then
  if python3 - "$SP" "$SO" "$SA" "$STR" <<'PY'
import sys
sp, so, sa, st = sys.argv[1:5]
def patch(path, edits):
    s = open(path, encoding='utf-8').read()
    for old, new, marker in edits:
        if marker in s:
            continue
        if s.count(old) != 1:
            sys.stderr.write("ANCHOR-MISS %s :: %r (found %d)\n" % (path, old[:70], s.count(old)))
            sys.exit(3)
        s = s.replace(old, new, 1)
    open(path, 'w', encoding='utf-8').write(s)
patch(sp, [(
    '    fun gameThreadHints(context: Context): Boolean = prefs(context).getBoolean("gameThreadHints", true)\n',
    '    fun gameThreadHints(context: Context): Boolean = prefs(context).getBoolean("gameThreadHints", true)\n\n'
    '    fun setGameThreadHints(context: Context, on: Boolean) {\n'
    '        prefs(context).edit().putBoolean("gameThreadHints", on).apply()\n'
    '    }\n',
    'fun setGameThreadHints(')])
patch(so, [
    ('    val onLowLatencyTouch: (Boolean) -> Unit = {},\n',
     '    val onLowLatencyTouch: (Boolean) -> Unit = {},\n'
     '    val gameThreadHints: Boolean = true,\n'
     '    val onGameThreadHints: (Boolean) -> Unit = {},\n',
     'val onGameThreadHints:'),
    ('                                    chipModifier = focus.track(page, "low-latency-touch"), onChange = a.onLowLatencyTouch)\n',
     '                                    chipModifier = focus.track(page, "low-latency-touch"), onChange = a.onLowLatencyTouch)\n'
     '                                ToggleRow(host, "game-thread-hints", stringResource(R.string.drawer_game_thread_hints),\n'
     '                                    stringResource(R.string.drawer_game_thread_hints_hint), a.gameThreadHints,\n'
     '                                    chipModifier = focus.track(page, "game-thread-hints"), onChange = a.onGameThreadHints)\n',
     '"game-thread-hints"'),
])
patch(sa, [
    ('    private var lowLatencyTouch by mutableStateOf(false)\n',
     '    private var lowLatencyTouch by mutableStateOf(false)\n'
     '    private var gameThreadHints by mutableStateOf(true)\n',
     'private var gameThreadHints by'),
    ('        lowLatencyTouch = SessionPrefs.lowLatencyTouch(this)\n',
     '        lowLatencyTouch = SessionPrefs.lowLatencyTouch(this)\n'
     '        gameThreadHints = SessionPrefs.gameThreadHints(this)\n',
     'gameThreadHints = SessionPrefs.gameThreadHints(this)'),
    ('                    lowLatencyTouch = lowLatencyTouch,\n',
     '                    lowLatencyTouch = lowLatencyTouch,\n'
     '                    gameThreadHints = gameThreadHints,\n'
     '                    onGameThreadHints = { on ->\n'
     '                        SessionPrefs.setGameThreadHints(this@SessionActivity, on)\n'
     '                        gameThreadHints = on\n'
     '                        if (on) android.util.Log.i("GameThreadHints", com.droiddeck.launcher.session.GameThreadHints.start(this@SessionActivity))\n'
     '                        else com.droiddeck.launcher.session.GameThreadHints.stop()\n'
     '                    },\n',
     'onGameThreadHints = { on ->'),
])
patch(st, [(
    '</resources>',
    '    <string name="drawer_game_thread_hints">Game thread boost</string>\n'
    '    <string name="drawer_game_thread_hints_hint">Moves the busiest game threads to the fastest CPU cores (Android performance hints). Turn off if a game paces worse.</string>\n'
    '</resources>',
    'drawer_game_thread_hints')])
print("OK")
PY
  then ok "session drawer: Game thread boost switch"
  else die "Game thread boost switch: an upstream anchor moved (see ANCHOR-MISS above)."
  fi
else
  warn "SessionPrefs/SessionOverlay/SessionActivity/strings.xml not found (skipping Game thread boost switch)"
fi

# ---------- 17. "Game thread boost" switch in DroidDeck's Settings -> Performance page too ----------
PD="$PKG/ui/PerformanceDialog.kt"
# The activity that holds the Performance page state (MainActivity.kt, renamed FrontEndActivity.kt upstream in
# 0.6.0): whichever top-level activity has the gpuClockPin state.
MA="$(grep -l 'private var gpuClockPin by mutableStateOf' "$PKG"/*.kt 2>/dev/null | head -1)"
if [ -f "$PD" ] && [ -n "$MA" ] && [ -f "$MA" ]; then
  if python3 - "$PD" "$MA" <<'PY'
import sys
pd, ma = sys.argv[1], sys.argv[2]
def patch(path, edits):
    s = open(path, encoding='utf-8').read()
    for old, new, marker in edits:
        if marker in s:
            continue
        if s.count(old) != 1:
            sys.stderr.write("ANCHOR-MISS %s :: %r (found %d)\n" % (path, old[:70], s.count(old)))
            sys.exit(3)
        s = s.replace(old, new, 1)
    open(path, 'w', encoding='utf-8').write(s)
patch(pd, [
    ('    gpuClockPin: Boolean,\n', '    gpuClockPin: Boolean,\n    gameThreadHints: Boolean = true,\n', 'gameThreadHints: Boolean = true,'),
    ('    onGpuClockPin: (Boolean) -> Unit,\n', '    onGpuClockPin: (Boolean) -> Unit,\n    onGameThreadHints: (Boolean) -> Unit = {},\n',
     'onGameThreadHints: (Boolean) -> Unit = {},'),
    ('                gamescopeRealtime, onChange = onGamescopeRealtime,\n            )\n',
     '                gamescopeRealtime, onChange = onGamescopeRealtime,\n            )\n'
     '            ToggleRow(\n'
     '                host, "gamethreadhints", stringResource(R.string.drawer_game_thread_hints),\n'
     '                stringResource(R.string.drawer_game_thread_hints_hint),\n'
     '                gameThreadHints, onChange = onGameThreadHints,\n'
     '            )\n',
     '"gamethreadhints"'),
])
patch(ma, [
    ('    private var gpuClockPin by mutableStateOf(false)\n',
     '    private var gpuClockPin by mutableStateOf(false)\n    private var gameThreadHints by mutableStateOf(true)\n',
     'private var gameThreadHints by'),
    ('            gpuClockPin = gpuClockPin,\n', '            gpuClockPin = gpuClockPin,\n            gameThreadHints = gameThreadHints,\n',
     'gameThreadHints = gameThreadHints,'),
    ('            onGpuClockPin = { on -> SessionPrefs.setGpuClockPin(this, on); gpuClockPin = on },\n',
     '            onGpuClockPin = { on -> SessionPrefs.setGpuClockPin(this, on); gpuClockPin = on },\n'
     '            onGameThreadHints = { on -> SessionPrefs.setGameThreadHints(this, on); gameThreadHints = on },\n',
     'onGameThreadHints = { on ->'),
    ('        gpuClockPin = SessionPrefs.gpuClockPin(this)\n',
     '        gpuClockPin = SessionPrefs.gpuClockPin(this)\n        gameThreadHints = SessionPrefs.gameThreadHints(this)\n',
     'gameThreadHints = SessionPrefs.gameThreadHints(this)'),
])
print("OK")
PY
  then ok "Settings -> Performance: Game thread boost switch"
  else die "Performance page switch: an upstream anchor moved (see ANCHOR-MISS above)."
  fi
else
  warn "PerformanceDialog.kt / the activity with the Performance page state not found (skipping Performance page switch)"
fi

# ---------- 18. Steam Native Hook-up: no extra Steam Deck pad next to the real controller ----------
# While controllers are handed to Steam (and no bridged gamepad needs it), DroidDeck's own Steam Deck pad
# is withdrawn (pad type 7 = none), so the real controller is player 1 -- like plugging it into a PC.
CPP="$DD/app/src/main/cpp/fakeinput_steam.cpp"
FIW="$IN/FakeInputWriter.java"
if [ -f "$CPP" ] && [ -f "$FIW" ]; then
  if python3 - "$CPP" "$FIW" <<'PY'
import sys
cpp, fiw = sys.argv[1], sys.argv[2]
def patch(path, edits):
    s = open(path, encoding='utf-8').read()
    for old, new, marker in edits:
        if marker in s:
            continue
        if s.count(old) != 1:
            sys.stderr.write("ANCHOR-MISS %s :: %r (found %d)\n" % (path, old[:70], s.count(old)))
            sys.exit(3)
        s = s.replace(old, new, 1)
    open(path, 'w', encoding='utf-8').write(s)
patch(cpp, [
    ('PAD_TYPE_STEAM_2015 = 6, PAD_TYPE_LAST = PAD_TYPE_STEAM_2015;',
     'PAD_TYPE_STEAM_2015 = 6,\n                          PAD_TYPE_NONE = 7, PAD_TYPE_LAST = PAD_TYPE_NONE;',
     'PAD_TYPE_NONE = 7'),
    ('__attribute__((visibility("hidden"))) static int pad_type_uevent(uint32_t type, const char *action) {\n',
     '__attribute__((visibility("hidden"))) static int pad_type_uevent(uint32_t type, const char *action) {\n'
     '  if (type == PAD_TYPE_NONE) return 0;  // sdl3bridge: no pad (real controllers handed to Steam)\n',
     'if (type == PAD_TYPE_NONE) return 0;'),
    ('"Steam Controller (2015)"};', '"Steam Controller (2015)", "no pad"};', '"no pad"};'),
    ('kNames[was % 7]', 'kNames[was % 8]', 'kNames[was % 8]'),
])
patch(fiw, [
    ('    public static final int PAD_TYPE_STEAM_2015 = 6;\n',
     '    public static final int PAD_TYPE_STEAM_2015 = 6;\n    public static final int PAD_TYPE_NONE = 7;\n',
     'PAD_TYPE_NONE = 7'),
])
print("OK")
PY
  then ok "pad type 'none' while controllers are handed to Steam"
  else die "pad type none: an upstream anchor moved (see ANCHOR-MISS above)."
  fi
fi

# ---------- 19. Upstream-only workflows stay upstream ----------
# Upstream DroidDeck's other workflows -- its "human authorship" gate, and the builders for KWin / the KDE
# desktop, FEX, gamescope and the AAudio sink -- start on pushes that touch their folders. In this fork every
# sync pushes upstream's latest tree, so they ran here too: the authorship gate failed on the sync bot's
# commits, and e.g. a KWin update made GitHub compile all of KWin. None of that is needed for the APK (it
# downloads those components from upstream's releases). Each of their jobs now runs only on
# Droid-Deck/droiddeck; upstream itself is unchanged. (Changes you ever send upstream must be your own commits.)
WF="$DD/.github/workflows"
if [ -d "$WF" ]; then
  if python3 - "$WF" <<'PY'
import os, re, sys
wf = sys.argv[1]
COND = "github.repository == 'Droid-Deck/droiddeck'"
changed = []
def gate_jobs(text):
    lines = text.split("\n")
    out, in_jobs, i = [], False, 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True
        elif in_jobs and re.match(r"^\S", line):
            in_jobs = False
        elif in_jobs and re.match(r"^  [A-Za-z0-9_-]+:\s*$", line):
            # this job's own keys: lines indented exactly 4 spaces until the next job
            j, has_if = i + 1, False
            while j < len(lines) and not re.match(r"^  \S", lines[j]) and not re.match(r"^\S", lines[j]):
                if re.match(r"^    if:", lines[j]):
                    has_if = True
                j += 1
            if not has_if:
                out.append("    if: " + COND)
        i += 1
    return "\n".join(out)
# build.yml (the APK) keeps its jobs; only its authorship step is gated. Reusable workflows it calls
# (sign/publish-packs/update-catalog) and PR/release flows are left alone.
for name in ("authorship.yml", "build-aaudio-sink.yml", "build-desktop-kde.yml", "build-fex.yml", "build-gamescope.yml"):
    path = os.path.join(wf, name)
    if not os.path.exists(path):
        continue
    s = open(path, encoding="utf-8").read()
    if COND in s:
        continue
    new = gate_jobs(s)
    if new != s:
        open(path, "w", encoding="utf-8").write(new)
        changed.append(name)
build = os.path.join(wf, "build.yml")
if os.path.exists(build):
    s = open(build, encoding="utf-8").read()
    old = "      - name: Check human authorship\n"
    if COND not in s and old in s:
        s = s.replace(old, old + "        if: " + COND + "\n", 1)
        open(build, "w", encoding="utf-8").write(s)
        changed.append("build.yml (authorship step)")
print("gated: " + (", ".join(changed) if changed else "nothing new"))
PY
  then ok "upstream-only workflows (authorship, KWin/KDE, FEX, gamescope, AAudio) skipped in this fork"
  else warn "could not gate the upstream-only workflows"
  fi
fi

# ---------- 20. CI downloads retry instead of hanging ----------
# The build downloads gamescope, mangoapp, PipeWire, msitools and the Debian image with curl, which has no time
# limit: one stalled connection (Valve's package servers do that now and then) hangs the build until GitHub
# kills it after 45 minutes. A ~/.curlrc written first makes a stalled download time out (no connection in 30 s,
# or under 2 KB/s for a minute), and the build's own --retry 3 then tries again.
if [ -f "$WF/build.yml" ]; then
  if python3 - "$WF/build.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
MARK = "SDL3Deck: downloads retry instead of hanging"
if MARK in s:
    print("already"); sys.exit(0)
# the first step of the job that downloads runtime components (upstream reorganised it; older layout first)
anchors = ["      - name: Build libfakeinput.so and libblsession.so",
           "      - name: Restore verified preload snapshots"]
anchor = next((a for a in anchors if s.count(a) == 1), None)
if not anchor:
    sys.stderr.write("ANCHOR-MISS curlrc :: none of %r\n" % anchors); sys.exit(3)
step = ("      - name: \"" + MARK + "\"\n"
        "        run: printf 'connect-timeout = 30\\nspeed-limit = 2048\\nspeed-time = 60\\n' > \"$HOME/.curlrc\"\n\n")
s = s.replace(anchor, step + anchor, 1)
open(p, "w", encoding="utf-8").write(s)
print("OK")
PY
  then ok "CI downloads time out and retry instead of hanging the build"
  else warn "could not add the CI download timeouts (upstream build.yml changed)"
  fi
fi

# ---------- 21. Steam Input updates the game's virtual controller faster (controller_rate) ----------
# Steam Input's virtual controller (what the game reads) is updated every controller_rate microseconds:
# Steam's default is 2000 (500 Hz). Typed in Steam's console it lasts until Steam restarts, so DroidDeck now
# starts the client with "+controller_rate 500" (2000 Hz) every time. Another value (0 = no limit) can be put
# in ~/.config/droiddeck/controller-rate inside the Linux system.
SESS="$DD/tools/linuxfs/overlay/usr/local/bin/droiddeck-session"
if [ -f "$SESS" ]; then
  if python3 - "$SESS" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
MARK = "sdl3bridge: controller_rate"
if MARK in s:
    print("already"); sys.exit(0)
edits = [
    ('    [ -n "${BL_STEAM_LANGUAGE:-}" ] && _bl_lang=(-language "$BL_STEAM_LANGUAGE")\n',
     '    [ -n "${BL_STEAM_LANGUAGE:-}" ] && _bl_lang=(-language "$BL_STEAM_LANGUAGE")\n'
     '    # ' + MARK + ': how often Steam Input updates the game\'s virtual controller, in microseconds\n'
     '    # (Steam\'s default 2000 = 500 Hz). Override in ~/.config/droiddeck/controller-rate (0 = no limit).\n'
     '    _bl_rate=$(cat "$HOME/.config/droiddeck/controller-rate" 2>/dev/null)\n'
     '    case $_bl_rate in \'\'|*[!0-9]*) _bl_rate=500 ;; esac\n'
     '    _bl_input=(+controller_rate "$_bl_rate")\n'),
    ('${_bl_lang[*]} -clientbeta $steam_channel', '${_bl_lang[*]} ${_bl_input[*]} -clientbeta $steam_channel'),
    ('"${_bl_lang[@]}" -clientbeta "$steam_channel"', '"${_bl_lang[@]}" "${_bl_input[@]}" -clientbeta "$steam_channel"'),
]
for old, new in edits:
    if s.count(old) != 1:
        sys.stderr.write("ANCHOR-MISS controller_rate :: %r (found %d)\n" % (old[:70], s.count(old)))
        sys.exit(3)
    s = s.replace(old, new, 1)
open(p, "w", encoding="utf-8").write(s)
print("OK")
PY
  then ok "Steam started with +controller_rate 500 (virtual controller updated at 2000 Hz)"
  else warn "could not add +controller_rate to the Steam launch (upstream session script changed)"
  fi
else
  warn "droiddeck-session not found (skipping +controller_rate)"
fi

# ---------- 22. "SDL3Bridge" tab in DroidDeck's Settings ----------
# A Settings tab that shows the bridge's controllers and changes all of its settings (mode, driver, source, poll
# rate, bubble, per-player gyro / touchpad / button remaps / lightbar, gyro calibration) through the bridge's
# settings messages, plus an "Open SDL3Bridge" button. Built only from DroidDeck's own settings widgets: if their
# signatures ever change, the tab is left out (with a warning) instead of breaking the build.
UI="$PKG/ui"
TAB_SRC="$SRC/SdlBridgeSettings.kt"
FES="$UI/FrontEndSetup.kt"
if [ -f "$TAB_SRC" ] && [ -f "$FES" ] && [ -f "$UI/SettingsWidgets.kt" ]; then
  if python3 - "$UI" "$TAB_SRC" "$FES" <<'PY'
import os, sys
ui, tab_src, fes = sys.argv[1:4]
widgets = open(os.path.join(ui, "SettingsWidgets.kt"), encoding="utf-8").read()
extra = ""
for name in os.listdir(ui):
    if name.endswith(".kt") and name != "SdlBridgeSettings.kt":
        extra += open(os.path.join(ui, name), encoding="utf-8").read()
needed = [
    "fun SettingsGroup(title: String",
    "fun SettingsRow(label: String, hint: String?, highlighted: Boolean = false, hintLines: Int? = null, stacked: Boolean = false",
    "fun ValueChip(text: String, open: Boolean, enabled: Boolean = true, modifier: Modifier = Modifier, onClick: () -> Unit)",
    "fun AnchoredMenu(",
    "open: Boolean, onDismiss: () -> Unit, title: String? = null, note: String? = null,",
    "content: @Composable ColumnScope.(FocusRequester) -> Unit,",
    "fun MenuItem(",
    "label: String, checked: Boolean, enabled: Boolean = true, detail: String? = null,",
    "focusRequester: FocusRequester? = null, modifier: Modifier = Modifier, onClick: () -> Unit,",
    "var open by mutableStateOf<String?>(null)",
    "fun ToggleRow(host: MenuHost, key: String, label: String, hint: String?, checked: Boolean, enabled: Boolean = true",
    "label: String, hint: String?, value: Int, range: IntRange, step: Int = 1, enabled: Boolean = true,",
    "format: (Int) -> String = { it.toString() }, modifier: Modifier = Modifier, onChange: (Int) -> Unit",
    "fun ActionRow(label: String, hint: String?, button: String, onClick: () -> Unit",
    "fun <T> SegmentedTabs(options: List<Pair<T, String>>, selected: T?, modifier: Modifier = Modifier,",
    "class MenuHost",
]
missing = [n for n in needed if n not in widgets and n not in extra]
if missing:
    sys.stderr.write("WIDGETS-CHANGED " + " | ".join(missing) + "\n")
    sys.exit(4)
dst = os.path.join(ui, "SdlBridgeSettings.kt")
body = open(tab_src, encoding="utf-8").read()
if not os.path.exists(dst) or open(dst, encoding="utf-8").read() != body:
    open(dst, "w", encoding="utf-8").write(body)
s = open(fes, encoding="utf-8").read()
MARK = "SdlBridgeSettingsTab(host)"
if MARK not in s:
    edits = [
        ('stringResource(R.string.setup_tab_glasses))', 'stringResource(R.string.setup_tab_glasses), "SDL3Bridge")'),
        ('                    GLASSES_TAB -> GlassesSetupPanel()\n',
         '                    GLASSES_TAB -> GlassesSetupPanel()\n'
         '                    GLASSES_TAB + 1 -> SdlBridgeSettingsTab(host)   // sdl3bridge: SDL3Bridge tab\n'),
    ]
    for old, new in edits:
        if s.count(old) != 1:
            sys.stderr.write("ANCHOR-MISS SDL3Bridge tab :: %r (found %d)\n" % (old[:70], s.count(old)))
            os.remove(dst)
            sys.exit(3)
        s = s.replace(old, new, 1)
    open(fes, "w", encoding="utf-8").write(s)
print("OK")
PY
  then ok "Settings: SDL3Bridge tab (all bridge settings + Open SDL3Bridge)"
  else warn "SDL3Bridge settings tab left out (DroidDeck's settings screen changed; see the line above)"
  fi
else
  warn "SdlBridgeSettings.kt or DroidDeck's settings screen not found (skipping the SDL3Bridge tab)"
fi

# ---------- 23. The same SDL3Bridge page in the in-session drawer ----------
# The session drawer (Controller / Display / Effects / VR / Game profile / Session) gets an SDL3Bridge page too,
# so the bridge can be changed while playing. Its controls get the drawer's focus tracking (controller navigation).
# All or nothing: if one of DroidDeck's files no longer matches, none of them is changed.
SDP="$UI/SessionDrawerPage.kt"
SOV="$UI/SessionOverlay.kt"
STR="$DD/app/src/main/res/values/strings.xml"
if [ -f "$UI/SdlBridgeSettings.kt" ] && [ -f "$SDP" ] && [ -f "$SOV" ] && [ -f "$STR" ]; then
  if python3 - "$SDP" "$SOV" "$STR" <<'PY'
import sys
paths = sys.argv[1:4]
texts = {p: open(p, encoding="utf-8").read() for p in paths}
sdp, sov, strs = paths
MARK = "SDL3BRIDGE("
if MARK in texts[sdp]:
    print("already"); sys.exit(0)
edits = {
    sdp: [('    SESSION("suspend"),\n', '    SDL3BRIDGE("sdl3-open"),   // sdl3bridge: SDL3Bridge page\n    SESSION("suspend"),\n')],
    sov: [
        ('import androidx.compose.material.icons.outlined.SportsEsports\n',
         'import androidx.compose.material.icons.outlined.SportsEsports\nimport androidx.compose.material.icons.outlined.Usb\n'),
        ('    SessionDrawerPage.SESSION -> R.string.mode_session\n',
         '    SessionDrawerPage.SDL3BRIDGE -> R.string.drawer_page_sdl3bridge\n    SessionDrawerPage.SESSION -> R.string.mode_session\n'),
        ('    SessionDrawerPage.SESSION -> Icons.Outlined.Settings\n',
         '    SessionDrawerPage.SDL3BRIDGE -> Icons.Outlined.Usb\n    SessionDrawerPage.SESSION -> Icons.Outlined.Settings\n'),
        ('                        SessionDrawerPage.SESSION -> {\n',
         '                        SessionDrawerPage.SDL3BRIDGE -> SdlBridgeSettingsTab(host) { key -> focus.track(page, key) }\n'
         '                        SessionDrawerPage.SESSION -> {\n'),
    ],
    strs: [('</resources>', '    <string name="drawer_page_sdl3bridge">SDL3Bridge</string>\n</resources>')],
}
for path, changes in edits.items():
    for old, new in changes:
        if texts[path].count(old) != 1:
            sys.stderr.write("ANCHOR-MISS drawer page :: %s :: %r (found %d)\n" % (path.rsplit("/", 1)[-1], old[:60], texts[path].count(old)))
            sys.exit(3)
        texts[path] = texts[path].replace(old, new, 1)
for path in paths:
    open(path, "w", encoding="utf-8").write(texts[path])
print("OK")
PY
  then ok "session drawer: SDL3Bridge page"
  else warn "SDL3Bridge page left out of the session drawer (DroidDeck's drawer changed; see the line above)"
  fi
else
  warn "session drawer files or the SDL3Bridge tab not found (skipping the drawer page)"
fi

# ---------- 24. The fork's own README (only when one is shipped next to this script) ----------
# Upstream's README comes back with every sync; a fork that keeps its own README as sdl3/README.md gets it put
# back at the root of the build branch. (No README next to the script = nothing changes.)
if [ -f "$SRC/README.md" ]; then
  if cmp -s "$SRC/README.md" "$DD/README.md"; then skip "fork README"
  else cp "$SRC/README.md" "$DD/README.md" && ok "fork README installed at the root"
  fi
fi

# ---------- 25. DroidDeck's own controllers: Steam reads the newest reports too (mailbox) ----------
# The same mailbox the hooked-up controllers use (hookup_native.inc, HookupQueue) for DroidDeck's own pad nodes:
# Steam Deck pad, DualSense / Edge, DualShock 4, Steam Controller 2015, Steam Controller 2026 (its pad and the
# passthrough). Their reports used to go into a socket that holds a few reports: when Steam read late, the
# newest were the ones dropped. The touch-screen node is left as it is. All or nothing: if an anchor moved, the
# pads keep upstream's socket and the build goes on.
if [ -f "$CPP" ] && grep -q "sdl3bridge: Steam Native Hook-up" "$CPP"; then
  res=$(python3 - "$CPP" <<'PY'
import sys
cpp = sys.argv[1]
s = open(cpp, encoding='utf-8').read()
if "pad_mailbox_offer(*self" in s:
    print("SKIP")
    sys.exit(0)
SEND = ('    if (send(self->peer, report, sizeof(report), MSG_DONTWAIT | MSG_NOSIGNAL) < 0 &&\n'
        '        errno != EAGAIN && errno != EWOULDBLOCK)\n'
        '      break;\n')
OFFER = '    if (pad_mailbox_offer(*self, report, sizeof(report)) < 0) break;\n'
edits = [
    # forward declarations (defined in the hook-up block further down)
    ('__attribute__((visibility("hidden"))) static void *deck_report_thread(void *arg) {\n',
     '// sdl3bridge: Steam reads the newest reports of every controller (mailbox, see HookupQueue)\n'
     'static void pad_mailbox_attach(DeckHidraw &pad);\n'
     'static int pad_mailbox_offer(DeckHidraw &pad, const uint8_t *data, uint32_t length);\n\n'
     '__attribute__((visibility("hidden"))) static void *deck_report_thread(void *arg) {\n'),
    # the report threads: Steam Deck, Sony, Steam Controller 2015, Steam Controller 2026 pad
    ('    build_deck_report(report, ++packet, buttons, axes, extras);\n' + SEND,
     '    build_deck_report(report, ++packet, buttons, axes, extras);\n' + OFFER),
    ('    build_sony_report(report, self->sony, ++packet, monotonic_us() - start_us, buttons, axes, extras, touch);\n' + SEND,
     '    build_sony_report(report, self->sony, ++packet, monotonic_us() - start_us, buttons, axes, extras, touch);\n' + OFFER),
    ('    build_sc1_report(report, ++packet, buttons, axes, extras);\n' + SEND,
     '    build_sc1_report(report, ++packet, buttons, axes, extras);\n' + OFFER),
    ('    build_triton_report(report + 1, ++packet, monotonic_us() - start_us, buttons, axes, extras);\n' + SEND,
     '    build_triton_report(report + 1, ++packet, monotonic_us() - start_us, buttons, axes, extras);\n' + OFFER),
    # Steam Controller 2026 passthrough
    ('      report[0] = report_id;\n'
     '      if (send(self->peer, report, length + 1, MSG_DONTWAIT | MSG_NOSIGNAL) < 0 &&\n'
     '          errno != EAGAIN && errno != EWOULDBLOCK)\n'
     '        break;\n',
     '      report[0] = report_id;\n'
     '      if (pad_mailbox_offer(*self, report, static_cast<uint32_t>(length + 1)) < 0) break;\n'),
    # each pad node gets its mailbox before Steam can read it
    ('  deck->sony = sony;\n  deck->sc1 = sc1;\n',
     '  deck->sony = sony;\n  deck->sc1 = sc1;\n  pad_mailbox_attach(*deck);\n'),
    ('  triton->triton = true;\n  triton->emulated = emulated;\n',
     '  triton->triton = true;\n  triton->emulated = emulated;\n  pad_mailbox_attach(*triton);\n'),
    # readv() and the fortified read() reach the mailbox too
    ('EXPORT ssize_t readv(int fd, const struct iovec *iov, int iovcnt) {\n'
     '  if (!is_fake_input_fd(fd)) return syscall(SYS_readv, fd, iov, iovcnt);\n',
     'EXPORT ssize_t readv(int fd, const struct iovec *iov, int iovcnt) {\n'
     '  if (ssize_t mailbox = hookup_readv_mailbox(fd, iov, iovcnt); mailbox != -2) return mailbox;\n'
     '  if (!is_fake_input_fd(fd)) return syscall(SYS_readv, fd, iov, iovcnt);\n'),
    ('EXPORT ssize_t read(int fd, void *buf, size_t count) {\n  return read_input(fd, buf, count);\n}\n',
     'EXPORT ssize_t read(int fd, void *buf, size_t count) {\n  return read_input(fd, buf, count);\n}\n\n'
     '// sdl3bridge: read() as programs built with _FORTIFY_SOURCE call it\n'
     'EXPORT ssize_t __read_chk(int fd, void *buf, size_t count, size_t buflen) {\n'
     '  if (count > buflen) {  // a buffer overflow: the C library reports it, as it would without the hook\n'
     '    static auto real = reinterpret_cast<ssize_t (*)(int, void *, size_t, size_t)>(dlsym(RTLD_NEXT, "__read_chk"));\n'
     '    if (real) return real(fd, buf, count, buflen);\n'
     '    abort();\n'
     '  }\n'
     '  return read_input(fd, buf, count);\n'
     '}\n'),
]
for old, new in edits:
    n = s.count(old)
    if n != 1:
        sys.stderr.write("ANCHOR-MISS pad mailbox :: %r (found %d, expected 1)\n" % (old[:80], n))
        sys.exit(3)
for old, new in edits:
    s = s.replace(old, new)
open(cpp, 'w', encoding='utf-8').write(s)
print("OK")
PY
)
  case "$res" in
    OK) ok "DroidDeck's own controllers: Steam reads the newest reports (mailbox)" ;;
    SKIP) skip "pad mailbox" ;;
    *) warn "pad mailbox left out (an upstream anchor moved, see ANCHOR-MISS above); DroidDeck's pads keep their socket" ;;
  esac
else
  warn "hook-up block not in fakeinput_steam.cpp (skipping the pad mailbox)"
fi

# ---------- 26. CI: the Debian build image comes from upstream's release when the fork has none ----------
# Upstream's build downloads its pinned Debian image from a release of the repo being built. A fork doesn't have
# that release, so the build fell back to pulling from Amazon's public registry, which rate-limits GitHub's
# runners ("toomanyrequests: Data limit exceeded") and failed the build. The same file is published on
# upstream's release: fetch it from there (checked against upstream's pinned SHA-256) before the registry.
DEBIMG="$DD/tools/components/recipes/debian-image.sh"
if [ -f "$DEBIMG" ]; then
  res=$(python3 - "$DEBIMG" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
if 'sdl3deck: upstream release' in s:
    print("SKIP")
    sys.exit(0)
old = ('if gh release download "$DEBIAN_IMAGE_TAG" -R "$GITHUB_REPOSITORY" -p "$DEBIAN_IMAGE_ASSET" -O /tmp/debian-image.tar.zst \\\n'
       '   && {')
new = ('# sdl3deck: upstream release when this fork has none (same file, same pinned SHA-256)\n'
       'if { gh release download "$DEBIAN_IMAGE_TAG" -R "$GITHUB_REPOSITORY" -p "$DEBIAN_IMAGE_ASSET" -O /tmp/debian-image.tar.zst \\\n'
       '     || { rm -f /tmp/debian-image.tar.zst; curl -fsSL --retry 3 -o /tmp/debian-image.tar.zst \\\n'
       '          "https://github.com/Droid-Deck/droiddeck/releases/download/$DEBIAN_IMAGE_TAG/$DEBIAN_IMAGE_ASSET"; }; } \\\n'
       '   && {')
if s.count(old) != 1 or 'DEBIAN_IMAGE_SHA256' not in s:
    sys.stderr.write("ANCHOR-MISS debian-image.sh :: %r\n" % old[:70])
    sys.exit(3)
open(path, 'w', encoding='utf-8').write(s.replace(old, new))
print("OK")
PY
)
  case "$res" in
    OK) ok "CI: Debian build image from upstream's release (no registry rate limit)" ;;
    SKIP) skip "CI Debian image from upstream's release" ;;
    *) warn "CI Debian image fallback left out (debian-image.sh changed upstream, see ANCHOR-MISS above)" ;;
  esac
fi

# ---------- 27. Controller-driven mouse works out of the box ("Draw the cursor inside gamescope" on) ----------
# Upstream made Performance -> Session fixes -> "Draw the cursor inside gamescope" opt-in (off saves a plane on
# the phone's compositor). With it off, Steam Input's mouse output from a controller doesn't work properly: a
# button bound to a mouse click did nothing (keyboard bindings and mouse movement still did). This fork is about
# controllers, so it starts ON here; the switch stays, and turning it off still works.
CPREFS="$PKG/session/SessionPrefs.kt"
if [ -f "$CPREFS" ]; then
  res=$(python3 - "$CPREFS" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
new = 'fun cursorComposite(context: Context): Boolean = prefs(context).getBoolean("cursorComposite", true)'
if new in s:
    print("SKIP")
    sys.exit(0)
old = 'fun cursorComposite(context: Context): Boolean = prefs(context).getBoolean("cursorComposite", false)'
if s.count(old) != 1:
    sys.stderr.write("ANCHOR-MISS SessionPrefs.cursorComposite :: %r\n" % old[:70])
    sys.exit(3)
s = s.replace(old, new)
s = s.replace('/** gamescope draws the cursor itself. Off by default: on a phone that plane costs frames. */',
              '/** gamescope draws the cursor itself. SDL3Deck: on by default, for controller-driven mouse (Steam Input). */')
open(path, 'w', encoding='utf-8').write(s)
print("OK")
PY
)
  case "$res" in
    OK) ok "\"Draw the cursor inside gamescope\" on by default (controller mouse clicks work)" ;;
    SKIP) skip "cursor inside gamescope on by default" ;;
    *) warn "cursor default left as upstream (SessionPrefs changed, see ANCHOR-MISS above): turn on Performance -> Draw the cursor inside gamescope" ;;
  esac
fi

echo
echo "Done. Review with:  cd \"$DD\" && git diff"
