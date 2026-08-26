#!/usr/bin/env bash
# End-to-end verification for SimNap: builds every target for real and drives
# real `simctl` processes and a real booted Simulator — no mocks. Each check
# either passes or fails against actual observed behavior.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT/Host"
DEMO_PROJECT="$ROOT/Demo/SimNapDemo.xcodeproj"
BUNDLE_ID="com.simnap.demo"
SECOND_SIM_NAME="SimNap Verify Secondary"

PASS=0
FAIL=0
declare -a FAILURES=()

log()  { echo "[verify] $*"; }
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); echo "  FAIL  $1"; }

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then pass "$desc"; else fail "$desc (expected '$expected', got '$actual')"; fi
}
assert_true() {
  local desc=$1 cond=$2
  if [ "$cond" = "true" ]; then pass "$desc"; else fail "$desc (got '$cond')"; fi
}
assert_lt() {
  local desc=$1 value=$2 max=$3
  if [ "$value" -lt "$max" ]; then pass "$desc ($value < $max)"; else fail "$desc ($value >= $max)"; fi
}
assert_nonzero_exit() {
  local desc=$1 code=$2
  if [ "$code" -ne 0 ]; then pass "$desc"; else fail "$desc (exit was 0)"; fi
}

# ---------------------------------------------------------------------------
# Build everything for real.
# ---------------------------------------------------------------------------
log "Building root package (SimulatorNetworkCore)..."
if ! (cd "$ROOT" && swift build) >/tmp/simnap-verify-root-build.log 2>&1; then
  cat /tmp/simnap-verify-root-build.log
  log "root package build failed — aborting"
  exit 1
fi

log "Building Host package (CLI + menu bar)..."
if ! (cd "$HOST_DIR" && swift build) >/tmp/simnap-verify-host-build.log 2>&1; then
  cat /tmp/simnap-verify-host-build.log
  log "host package build failed — aborting"
  exit 1
fi
CLI="$HOST_DIR/.build/debug/simulator-network"
MENUBAR="$HOST_DIR/.build/debug/simulator-network-menubar"

log "Booting/selecting primary Simulator..."
PRIMARY_UDID=$(xcrun simctl list devices booted -j | jq -r '.devices | to_entries[] | .value[] | select(.state=="Booted") | .udid' | head -1)
if [ -z "$PRIMARY_UDID" ]; then
  log "No booted Simulator found — boot one first (e.g. via Xcode or \`xcrun simctl boot <udid>\`)"
  exit 1
fi
log "Primary Simulator: $PRIMARY_UDID"

log "Building demo app..."
if ! xcodebuild -project "$DEMO_PROJECT" -scheme SimNapDemo \
    -destination "platform=iOS Simulator,id=$PRIMARY_UDID" build \
    >/tmp/simnap-verify-demo-build.log 2>&1; then
  cat /tmp/simnap-verify-demo-build.log
  log "demo app build failed — aborting"
  exit 1
fi
DERIVED_DATA_APP=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname "SimNapDemo-*" -print -quit)
APP_PATH="$DERIVED_DATA_APP/Build/Products/Debug-iphonesimulator/SimNapDemo.app"
if [ ! -d "$APP_PATH" ]; then
  log "Could not locate built .app at $APP_PATH — aborting"
  exit 1
fi

install_app() {
  xcrun simctl install "$1" "$APP_PATH"
}

app_exec_path() {
  xcrun simctl get_app_container "$1" "$BUNDLE_ID" 2>/dev/null | awk '{print $0 "/SimNapDemo"}'
}

# Runs one scenario as a brand-new process (equivalent to a cold launch) and
# prints only the JSON payload of its SIMNAP_RESULT line.
run_scenario() {
  local udid=$1 scenario=$2
  local exec_path
  exec_path=$(app_exec_path "$udid")
  SIMCTL_CHILD_SIMNAP_SCENARIO="$scenario" xcrun simctl spawn "$udid" "$exec_path" 2>/dev/null \
    | grep "SIMNAP_RESULT " | tail -1 | sed 's/^SIMNAP_RESULT //'
}

# Runs the delayed-watch scenario, triggers an offline transition on the CLI
# the instant the request is confirmed in flight, and returns the JSON result.
run_delayed_watch_and_interrupt() {
  local udid=$1 error_mode=$2
  local exec_path outfile pid waited
  exec_path=$(app_exec_path "$udid")
  outfile=$(mktemp)
  SIMCTL_CHILD_SIMNAP_SCENARIO="delayed-watch" xcrun simctl spawn "$udid" "$exec_path" >"$outfile" 2>&1 &
  pid=$!
  waited=0
  while ! grep -q "SIMNAP_READY" "$outfile" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -gt 50 ] && break
  done
  "$CLI" offline --device "$udid" --error "$error_mode" >/dev/null
  wait "$pid" 2>/dev/null
  grep "SIMNAP_RESULT " "$outfile" | tail -1 | sed 's/^SIMNAP_RESULT //'
  rm -f "$outfile"
}

install_app "$PRIMARY_UDID"

echo
log "=== A. CLI / Host Core ==="

DEVICES_OUT=$("$CLI" devices --json)
assert_true "devices lists the primary UDID" "$(echo "$DEVICES_OUT" | jq -r --arg u "$PRIMARY_UDID" 'any(.[]; .udid == $u) | tostring')"

"$CLI" offline --device "$PRIMARY_UDID" --error timedOut >/dev/null
G1=$("$CLI" status --device "$PRIMARY_UDID" --json | jq -r '.generation')
"$CLI" online --device "$PRIMARY_UDID" >/dev/null
G2=$("$CLI" status --device "$PRIMARY_UDID" --json | jq -r '.generation')
"$CLI" offline --device "$PRIMARY_UDID" --error notConnectedToInternet >/dev/null
G3=$("$CLI" status --device "$PRIMARY_UDID" --json | jq -r '.generation')
if [ "$G1" -lt "$G2" ] && [ "$G2" -lt "$G3" ]; then
  pass "generation strictly increases across offline/online/offline ($G1 < $G2 < $G3)"
else
  fail "generation strictly increases across offline/online/offline (got $G1, $G2, $G3)"
fi

STATUS_JSON=$("$CLI" status --device "$PRIMARY_UDID" --json)
assert_eq "status --json reflects last write (state)" "offline" "$(echo "$STATUS_JSON" | jq -r '.state')"
assert_eq "status --json reflects last write (error)" "notConnectedToInternet" "$(echo "$STATUS_JSON" | jq -r '.error')"

"$CLI" status --device "DEADBEEF-NOT-REAL" >/tmp/simnap-verify-bad-udid.log 2>&1
BAD_UDID_EXIT=$?
assert_nonzero_exit "bad UDID exits nonzero" "$BAD_UDID_EXIT"
assert_true "bad UDID message is actionable" "$(grep -q "not booted" /tmp/simnap-verify-bad-udid.log && echo true || echo false)"

echo
log "=== B. Cold-launch guarantee, gating, forwarding ==="

"$CLI" online --device "$PRIMARY_UDID" >/dev/null
R=$(run_scenario "$PRIMARY_UDID" quick)
assert_eq "quick request succeeds while online" "success" "$(echo "$R" | jq -r '.outcome')"
assert_eq "quick request gets HTTP 200" "200" "$(echo "$R" | jq -r '.status')"

"$CLI" offline --device "$PRIMARY_UDID" --error notConnectedToInternet >/dev/null
R=$(run_scenario "$PRIMARY_UDID" quick)
assert_eq "cold process, offline(notConnectedToInternet): request fails" "failure" "$(echo "$R" | jq -r '.outcome')"
assert_eq "cold process, offline(notConnectedToInternet): correct error" "notConnectedToInternet" "$(echo "$R" | jq -r '.error')"
assert_lt "cold process, offline: rejected before any real round trip" "$(echo "$R" | jq -r '.elapsedMs')" 1000

"$CLI" offline --device "$PRIMARY_UDID" --error timedOut >/dev/null
R=$(run_scenario "$PRIMARY_UDID" quick)
assert_eq "cold process, offline(timedOut): correct error" "timedOut" "$(echo "$R" | jq -r '.error')"
assert_lt "cold process, offline(timedOut): rejected fast" "$(echo "$R" | jq -r '.elapsedMs')" 1000

"$CLI" online --device "$PRIMARY_UDID" >/dev/null
R=$(run_scenario "$PRIMARY_UDID" headers)
assert_eq "custom header forwarding succeeds" "success" "$(echo "$R" | jq -r '.outcome')"
assert_true "custom header round-trips to the server" "$(echo "$R" | jq -r '.headerEchoed')"

R=$(run_scenario "$PRIMARY_UDID" redirect)
assert_eq "redirect forwarding succeeds" "success" "$(echo "$R" | jq -r '.outcome')"
assert_eq "redirect forwarding lands on final 200" "200" "$(echo "$R" | jq -r '.status')"

echo
log "=== C. Exactly-once in-flight cancellation ==="

R=$(run_delayed_watch_and_interrupt "$PRIMARY_UDID" timedOut)
assert_eq "in-flight request cancelled on offline transition" "failure" "$(echo "$R" | jq -r '.outcome')"
assert_eq "cancellation delivers the configured error (timedOut)" "timedOut" "$(echo "$R" | jq -r '.error')"
assert_lt "cancellation happens well before natural completion" "$(echo "$R" | jq -r '.elapsedMs')" 5500

"$CLI" online --device "$PRIMARY_UDID" >/dev/null
R=$(run_delayed_watch_and_interrupt "$PRIMARY_UDID" notConnectedToInternet)
assert_eq "cancellation delivers the configured error (notConnectedToInternet)" "notConnectedToInternet" "$(echo "$R" | jq -r '.error')"
assert_lt "second cancellation also happens well before completion" "$(echo "$R" | jq -r '.elapsedMs')" 5500

echo
log "=== D. Documented boundary ==="

"$CLI" offline --device "$PRIMARY_UDID" --error timedOut >/dev/null
R=$(run_scenario "$PRIMARY_UDID" unintegrated)
assert_true "package considers itself offline during this check" "$(echo "$R" | jq -r '.stateAtStart | startswith("offline")')"
assert_eq "unintegrated URLSession is NOT gated (succeeds while offline)" "success" "$(echo "$R" | jq -r '.outcome')"

R=$(run_scenario "$PRIMARY_UDID" network-framework)
assert_eq "raw Network.framework traffic is NOT gated (succeeds while offline)" "success" "$(echo "$R" | jq -r '.outcome')"

"$CLI" online --device "$PRIMARY_UDID" >/dev/null

echo
log "=== E. Simulator isolation ==="

SECOND_UDID=$(xcrun simctl list devices -j | jq -r --arg n "$SECOND_SIM_NAME" '.devices | to_entries[] | .value[] | select(.name==$n) | .udid' | head -1)
if [ -z "$SECOND_UDID" ]; then
  RUNTIME=$(xcrun simctl list runtimes -j | jq -r '.runtimes | map(select(.isAvailable)) | .[0].identifier')
  SECOND_UDID=$(xcrun simctl create "$SECOND_SIM_NAME" "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" "$RUNTIME")
fi
xcrun simctl boot "$SECOND_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SECOND_UDID" -b >/dev/null 2>&1
install_app "$SECOND_UDID"

"$CLI" offline --device "$PRIMARY_UDID" --error timedOut >/dev/null
"$CLI" online --device "$SECOND_UDID" >/dev/null

R1=$(run_scenario "$PRIMARY_UDID" state)
R2=$(run_scenario "$SECOND_UDID" state)
assert_eq "primary Simulator independently offline" "offline:timedOut" "$(echo "$R1" | jq -r '.state')"
assert_eq "secondary Simulator independently online" "online" "$(echo "$R2" | jq -r '.state')"

"$CLI" online --device "$PRIMARY_UDID" >/dev/null

echo
log "=== F. Menu bar app smoke test ==="

"$MENUBAR" &
MENUBAR_PID=$!
sleep 2
if kill -0 "$MENUBAR_PID" 2>/dev/null; then
  pass "menu bar app stays alive after launch (no crash)"
else
  fail "menu bar app crashed or exited immediately"
fi
kill "$MENUBAR_PID" 2>/dev/null || true

echo
log "=== Cleanup ==="
xcrun simctl shutdown "$SECOND_UDID" >/dev/null 2>&1 || true
xcrun simctl delete "$SECOND_UDID" >/dev/null 2>&1 || true
log "Deleted temporary Simulator '$SECOND_SIM_NAME'"

echo
echo "============================================================"
echo " $PASS passed, $FAIL failed"
echo "============================================================"
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
