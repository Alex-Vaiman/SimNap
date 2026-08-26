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
STATE_KEY="com.simnap.simulator-network.state"

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
# Rejects empty/null/non-numeric input explicitly. Passing "null" straight to
# `[ -lt ]` would emit a bash error and report a confusing failure.
assert_lt() {
  local desc=$1 value=$2 max=$3
  case "$value" in
    ''|*[!0-9]*) fail "$desc (expected a number, got '$value')"; return ;;
  esac
  if [ "$value" -lt "$max" ]; then pass "$desc ($value < $max)"; else fail "$desc ($value >= $max)"; fi
}
assert_nonzero_exit() {
  local desc=$1 code=$2
  if [ "$code" -ne 0 ]; then pass "$desc"; else fail "$desc (exit was 0)"; fi
}
# Aborts the run rather than reporting dozens of confusing assertion failures.
abort() {
  echo
  echo "[verify] ABORT: $1"
  exit 1
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
# A fixed derived-data path: locating the product by globbing DerivedData picks
# an arbitrary directory when more than one exists, which can install a build
# from an unrelated checkout.
DERIVED_DATA="$ROOT/.verify-deriveddata"
if ! xcodebuild -project "$DEMO_PROJECT" -scheme SimNapDemo \
    -destination "platform=iOS Simulator,id=$PRIMARY_UDID" \
    -derivedDataPath "$DERIVED_DATA" build \
    >/tmp/simnap-verify-demo-build.log 2>&1; then
  cat /tmp/simnap-verify-demo-build.log
  log "demo app build failed — aborting"
  exit 1
fi
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/SimNapDemo.app"
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

# Runs a request admitted while online, transitions offline once it is in
# flight, starts a new request while offline, and returns both JSON results.
run_admission_boundary_check() {
  local udid=$1 error_mode=$2
  local exec_path outfile pid waited in_flight_result new_result
  "$CLI" online --device "$udid" >/dev/null
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
  new_result=$(run_scenario "$udid" quick)
  wait "$pid" 2>/dev/null
  in_flight_result=$(grep "SIMNAP_RESULT " "$outfile" | tail -1 | sed 's/^SIMNAP_RESULT //')
  rm -f "$outfile"
  printf '%s\n%s\n' "$in_flight_result" "$new_result"
}

# Keeps one app process alive, deletes its persisted record, writes a fresh
# offline record, and returns the state change observed by that same process.
run_state_watch_after_record_reset() {
  local udid=$1
  local exec_path outfile pid waited result
  "$CLI" online --device "$udid" >/dev/null
  exec_path=$(app_exec_path "$udid")
  outfile=$(mktemp)
  SIMCTL_CHILD_SIMNAP_SCENARIO="state-watch" xcrun simctl spawn "$udid" "$exec_path" >"$outfile" 2>&1 &
  pid=$!
  waited=0
  while ! grep -q "SIMNAP_READY" "$outfile" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -gt 50 ] && break
  done
  xcrun simctl spawn "$udid" defaults delete NSGlobalDomain "$STATE_KEY" >/dev/null
  "$CLI" offline --device "$udid" --error timedOut >/dev/null
  waited=0
  while ! grep -q "SIMNAP_RESULT " "$outfile" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -gt 50 ] && break
  done
  result=$(grep "SIMNAP_RESULT " "$outfile" | tail -1 | sed 's/^SIMNAP_RESULT //')
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$outfile"
  printf '%s\n' "$result"
}

install_app "$PRIMARY_UDID"

# The installed binary — not the one just built — is what every scenario runs,
# so the vocabulary is read back out of that binary. Checking the local source
# instead would pass happily against a stale install that still answers `state`
# but knows nothing of, say, `stop-start`.
log "Checking the installed app supports every scenario this suite uses..."
REQUIRED_SCENARIOS="state state-watch quick stop stop-start headers redirect post-online post-offline start-only shared-session unintegrated network-framework delayed-watch"
CAPABILITIES=$(run_scenario "$PRIMARY_UDID" capabilities)
if [ -z "$CAPABILITIES" ]; then
  abort "the installed app emitted no SIMNAP_RESULT for 'capabilities' — it is stale or crashed on launch"
fi
for scenario in $REQUIRED_SCENARIOS; do
  if ! echo "$CAPABILITIES" | jq -e --arg s "$scenario" 'any(.scenarios[]; . == $s)' >/dev/null 2>&1; then
    abort "the installed app does not support scenario '$scenario' — rebuild and reinstall the demo app"
  fi
  # Secondary guard: catches the reported list drifting from the switch.
  if ! grep -q "case \"$scenario\":" "$ROOT/Demo/SimNapDemo/ScenarioRunner.swift"; then
    abort "ScenarioRunner reports '$scenario' but has no case for it"
  fi
done

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

xcrun simctl spawn "$PRIMARY_UDID" defaults write NSGlobalDomain "$STATE_KEY" -string "not-json-at-all" >/dev/null
"$CLI" status --device "$PRIMARY_UDID" >/tmp/simnap-verify-corrupt-status.log 2>&1
CORRUPT_STATUS_EXIT=$?
assert_nonzero_exit "status reports a corrupt record" "$CORRUPT_STATUS_EXIT"
"$CLI" online --device "$PRIMARY_UDID" >/tmp/simnap-verify-corrupt-repair.log 2>&1
CORRUPT_REPAIR_EXIT=$?
assert_eq "online repairs a corrupt record" "0" "$CORRUPT_REPAIR_EXIT"
REPAIRED_GENERATION=$("$CLI" status --device "$PRIMARY_UDID" --json | jq -r '.generation')
"$CLI" online --device "$PRIMARY_UDID" >/dev/null
IDEMPOTENT_GENERATION=$("$CLI" status --device "$PRIMARY_UDID" --json | jq -r '.generation')
assert_eq "retrying an already-applied state does not increment generation" "$REPAIRED_GENERATION" "$IDEMPOTENT_GENERATION"

R=$(run_state_watch_after_record_reset "$PRIMARY_UDID")
assert_eq "running app begins record-reset check online" "online" "$(echo "$R" | jq -r '.initialState')"
assert_eq "running app accepts generation 1 from a new record epoch" "offline:timedOut" "$(echo "$R" | jq -r '.state')"

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

R=$(run_scenario "$PRIMARY_UDID" stop)
assert_true "stop test starts from offline state" "$(echo "$R" | jq -r '.stateBeforeStop | startswith("offline")')"
assert_eq "stop reports pass-through online state" "online" "$(echo "$R" | jq -r '.stateAfterStop')"
assert_eq "request after stop reaches the network" "success" "$(echo "$R" | jq -r '.outcome')"

# stop() no longer clears the applied generation, so start() re-applying an
# unchanged record depends on the reconcile comparison staying `>=`, not `>`.
R=$(run_scenario "$PRIMARY_UDID" stop-start)
assert_true "stop/start test starts from offline state" "$(echo "$R" | jq -r '.beforeStop | startswith("offline")')"
assert_eq "stop leaves pass-through" "online" "$(echo "$R" | jq -r '.stoppedState')"
assert_eq "request while stopped reaches the network" "success" "$(echo "$R" | jq -r '.stoppedOutcome')"
assert_true "explicit start() re-applies the unchanged persisted record" "$(echo "$R" | jq -r '.restartedState | startswith("offline")')"
assert_eq "request after restart is blocked again" "failure" "$(echo "$R" | jq -r '.restartedOutcome')"
assert_eq "request after restart gets the configured error" "timedOut" "$(echo "$R" | jq -r '.restartedError')"

"$CLI" online --device "$PRIMARY_UDID" >/dev/null
R=$(run_scenario "$PRIMARY_UDID" headers)
assert_eq "custom header forwarding succeeds" "success" "$(echo "$R" | jq -r '.outcome')"
assert_true "custom header round-trips to the server" "$(echo "$R" | jq -r '.headerEchoed')"

R=$(run_scenario "$PRIMARY_UDID" redirect)
assert_eq "redirect forwarding succeeds" "success" "$(echo "$R" | jq -r '.outcome')"
assert_eq "redirect forwarding lands on final 200" "200" "$(echo "$R" | jq -r '.status')"

# A POST body is the check that would have caught proxying online traffic:
# a re-sending interception layer loses request bodies.
R=$(run_scenario "$PRIMARY_UDID" post-online)
assert_eq "POST while online succeeds" "success" "$(echo "$R" | jq -r '.outcome')"
assert_eq "POST while online gets HTTP 200" "200" "$(echo "$R" | jq -r '.status')"
assert_true "POST body reaches the server unmodified" "$(echo "$R" | jq -r '.bodyEchoed')"

"$CLI" offline --device "$PRIMARY_UDID" --error notConnectedToInternet >/dev/null
R=$(run_scenario "$PRIMARY_UDID" post-offline)
assert_eq "POST while offline is blocked" "failure" "$(echo "$R" | jq -r '.outcome')"
assert_eq "POST while offline gets the configured error" "notConnectedToInternet" "$(echo "$R" | jq -r '.error')"
assert_lt "POST while offline is rejected without a round trip" "$(echo "$R" | jq -r '.elapsedMs')" 1000

echo
log "=== C. Request admission boundary ==="

RESULTS=$(run_admission_boundary_check "$PRIMARY_UDID" timedOut)
IN_FLIGHT_RESULT=$(printf '%s\n' "$RESULTS" | sed -n '1p')
NEW_RESULT=$(printf '%s\n' "$RESULTS" | sed -n '2p')
assert_eq "request admitted online survives offline transition" "success" "$(echo "$IN_FLIGHT_RESULT" | jq -r '.outcome')"
assert_eq "new request is blocked after transition" "failure" "$(echo "$NEW_RESULT" | jq -r '.outcome')"
assert_eq "new request gets configured timedOut error" "timedOut" "$(echo "$NEW_RESULT" | jq -r '.error')"

RESULTS=$(run_admission_boundary_check "$PRIMARY_UDID" notConnectedToInternet)
IN_FLIGHT_RESULT=$(printf '%s\n' "$RESULTS" | sed -n '1p')
NEW_RESULT=$(printf '%s\n' "$RESULTS" | sed -n '2p')
assert_eq "second online-admitted request also survives" "success" "$(echo "$IN_FLIGHT_RESULT" | jq -r '.outcome')"
assert_eq "second new request is blocked" "failure" "$(echo "$NEW_RESULT" | jq -r '.outcome')"
assert_eq "new request gets configured notConnected error" "notConnectedToInternet" "$(echo "$NEW_RESULT" | jq -r '.error')"

# start() on its own must gate an ordinarily-built session, with no SimNap
# call anywhere near the networking layer, and stop() must hand Foundation
# back so the very same construction reaches the network again.
"$CLI" offline --device "$PRIMARY_UDID" --error timedOut >/dev/null
R=$(run_scenario "$PRIMARY_UDID" start-only)
assert_eq "start() alone gates a plain URLSession(configuration: .default)" "failure" "$(echo "$R" | jq -r '.afterStart')"
assert_eq "that session fails with the configured error" "timedOut" "$(echo "$R" | jq -r '.afterStartError')"
assert_eq "stop() restores Foundation for the same construction" "success" "$(echo "$R" | jq -r '.afterStop')"

echo
log "=== D. Documented boundary ==="

# URLSession.shared is built internally and never goes through the intercepted
# class methods, so it stays outside the boundary even after start().
R=$(run_scenario "$PRIMARY_UDID" shared-session)
assert_true "shared-session check runs while offline" "$(echo "$R" | jq -r '.stateAtStart | startswith("offline")')"
assert_eq "URLSession.shared is NOT gated, even after start()" "success" "$(echo "$R" | jq -r '.outcome')"

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
log "=== F. Writer lock under concurrent commands ==="

# Each command reports the record it wrote inside the lock, plus whether it
# wrote at all. Under a correct lock every writing command must own a distinct
# generation, and the record must advance by exactly one per writing command.
# Asserting against a post-hoc `status` read instead would be worthless: with
# the lock disabled entirely, eight commands lost seven updates and every such
# assertion still passed.
"$CLI" online --device "$PRIMARY_UDID" >/dev/null
BURST_GENERATION_BEFORE=$("$CLI" status --device "$PRIMARY_UDID" --json | jq -r '.generation')
BURST_DIR=$(mktemp -d)
BURST_N=8
for i in $(seq 1 "$BURST_N"); do
  if [ $((i % 2)) -eq 0 ]; then
    "$CLI" offline --device "$PRIMARY_UDID" --error timedOut --json >"$BURST_DIR/$i.json" 2>&1 &
  else
    "$CLI" offline --device "$PRIMARY_UDID" --error notConnectedToInternet --json >"$BURST_DIR/$i.json" 2>&1 &
  fi
done
wait

BURST_JSON=$(cat "$BURST_DIR"/*.json 2>/dev/null | jq -s -c 'map(select(.generation != null))' 2>/dev/null || echo '[]')
BURST_REPORTED=$(echo "$BURST_JSON" | jq -r 'length')
assert_eq "every concurrent command reported a result" "$BURST_N" "$BURST_REPORTED"

# The core assertion: a lost update means two writers computed the same
# generation, so distinct writer generations must equal the number of writers.
BURST_WRITERS=$(echo "$BURST_JSON" | jq -r 'map(select(.changed == true)) | length')
BURST_DISTINCT=$(echo "$BURST_JSON" | jq -r 'map(select(.changed == true)) | map(.generation) | unique | length')
assert_eq "no two concurrent writers were assigned the same generation" "$BURST_WRITERS" "$BURST_DISTINCT"
assert_true "at least one concurrent command actually wrote" \
  "$([ "$BURST_WRITERS" -gt 0 ] && echo true || echo false)"

BURST_GENERATION_AFTER=$("$CLI" status --device "$PRIMARY_UDID" --json 2>/dev/null | jq -r '.generation')
assert_true "record is still readable after the concurrent burst" "$([ -n "$BURST_GENERATION_AFTER" ] && echo true || echo false)"
# Exact, not a bound: every writing command must have advanced the record once.
assert_eq "generation advanced by exactly one per writing command" \
  "$BURST_WRITERS" "$((BURST_GENERATION_AFTER - BURST_GENERATION_BEFORE))"
rm -rf "$BURST_DIR"

echo
log "=== G. Menu bar app ==="

# Validates the real menu headlessly: every actionable item must have a target
# that responds to its action, and automatic enabling must stay off so the
# explicit isEnabled logic is not overridden. A liveness check alone cannot
# catch a menu item that only raises when clicked.
"$MENUBAR" --self-check >/tmp/simnap-verify-menu-selfcheck.log 2>&1
MENU_SELFCHECK_EXIT=$?
if [ "$MENU_SELFCHECK_EXIT" -eq 0 ]; then
  pass "menu self-check: every item's target handles its action"
else
  fail "menu self-check reported problems: $(tr '\n' '; ' </tmp/simnap-verify-menu-selfcheck.log)"
fi

"$MENUBAR" &
MENUBAR_PID=$!
sleep 2
if kill -0 "$MENUBAR_PID" 2>/dev/null; then
  pass "menu bar app stays alive after launch (no crash)"
else
  fail "menu bar app crashed or exited immediately"
fi

# A second copy would add an indistinguishable second status item and double
# the simctl polling load.
"$MENUBAR" >/tmp/simnap-verify-second-instance.log 2>&1
SECOND_INSTANCE_EXIT=$?
assert_nonzero_exit "a second menu bar instance refuses to start" "$SECOND_INSTANCE_EXIT"
assert_true "second instance explains why" \
  "$(grep -q "already running" /tmp/simnap-verify-second-instance.log && echo true || echo false)"

# The self-check must stay usable while a real instance holds the lock.
"$MENUBAR" --self-check >/dev/null 2>&1
assert_eq "self-check still runs alongside a live instance" "0" "$?"

kill "$MENUBAR_PID" 2>/dev/null || true
sleep 2
"$MENUBAR" &
MENUBAR_PID_2=$!
sleep 2
if kill -0 "$MENUBAR_PID_2" 2>/dev/null; then
  pass "instance lock is released when the app exits"
else
  fail "instance lock outlived the process — a new instance could not start"
fi
kill "$MENUBAR_PID_2" 2>/dev/null || true

echo
log "=== H. Application bundle ==="

# build-app.sh validates what it produced: Info.plist keys (including
# LSUIElement, without which a status-bar app takes a Dock icon), that
# CFBundleExecutable names a file that exists, the ad-hoc signature, and that
# both bundled binaries run under an empty environment the way launchd starts
# a Finder-launched app.
"$ROOT/Scripts/build-app.sh" --debug >/tmp/simnap-verify-bundle.log 2>&1
BUNDLE_EXIT=$?
if [ "$BUNDLE_EXIT" -eq 0 ]; then
  pass "app bundle assembles and passes its own validation"
else
  fail "app bundle build/validation failed: $(tail -3 /tmp/simnap-verify-bundle.log | tr '\n' ' ')"
fi

# The lock backing single-instance and per-Simulator serialization must not
# depend on TMPDIR, which differs by launch context.
LOCKS_DIR="$HOME/Library/Caches/com.simnap.simulator-network/locks"
ALT_TMPDIR=$(mktemp -d)
TMPDIR="$ALT_TMPDIR" "$CLI" online --device "$PRIMARY_UDID" >/dev/null 2>&1
assert_true "locks live outside TMPDIR so every launch context shares them" \
  "$([ -d "$LOCKS_DIR" ] && [ -z "$(ls -A "$ALT_TMPDIR" 2>/dev/null)" ] && echo true || echo false)"
rm -rf "$ALT_TMPDIR"

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
