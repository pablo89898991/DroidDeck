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

  # 4c. detach on teardown (inside onDestroy, next to padBridge?.stop())
  if grep -q "DualSenseBridge.detach(" "$SA"; then
    skip "SessionActivity detach()"
  elif grep -q "padBridge?.stop()" "$SA"; then
    sed -i '/padBridge?.stop()/a\        com.droiddeck.launcher.input.DualSenseBridge.detach()' "$SA"
    grep -q "DualSenseBridge.detach(" "$SA" && ok "SessionActivity detach()" || warn "SessionActivity detach() NOT inserted"
  else
    warn "SessionActivity: add  com.droiddeck.launcher.input.DualSenseBridge.detach()  where the session is destroyed"
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
  if grep -q "DualSenseBridge.isBridgedSlot" "$RC"; then
    skip "RumbleComponent bridge routing"
  elif grep -q "if (!enabled) return" "$RC"; then
    sed -i '/if (!enabled) return/a\        if (com.droiddeck.launcher.input.DualSenseBridge.isBridgedSlot(slot)) { com.droiddeck.launcher.input.DualSenseBridge.rumble(slot, strong shr 8, weak shr 8); return }' "$RC"
    grep -q "DualSenseBridge.isBridgedSlot" "$RC" && ok "RumbleComponent bridge routing" || warn "RumbleComponent hook NOT inserted"
  else
    warn "RumbleComponent: add a DualSenseBridge.isBridgedSlot(slot) check at the top of buzz()"
  fi
else
  warn "RumbleComponent.kt not found (skipping rumble routing)"
fi

echo
echo "Done. Review with:  cd \"$DD\" && git diff"
