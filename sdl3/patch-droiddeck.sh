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
    sed -i '/padBridge?.stop()/a\        com.droi