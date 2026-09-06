#!/usr/bin/env bash
# Opt-in real Codex TUI guard. Uses only a named Herdr lab through its guarded
# helper, preserves evidence, and never changes a live primary's configuration.
# FM_CODEX_NOTIFY_LIVE_E2E=1 FM_CODEX_NOTIFY_LIVE_DIR=<private-evidence-dir>
#   bin/fm-test-run.sh tests/fm-codex-stop-live-e2e.test.sh
# Requires installed Codex/Herdr and authentication. The lab uses the real Stop,
# arm, watcher, queue, drain and acknowledgement. Only startup and task inputs are
# isolated fixtures. Native hooks are explicitly trusted for this lab invocation.
# Like the existing Codex continuity guard, this uses unsandboxed test tools:
# macOS workspace-write denies ps, which prevents the existing lock/ack owners
# from observing their kernel ancestry. This does not change product permissions.
set -u
if [ "${FM_CODEX_NOTIFY_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_CODEX_NOTIFY_LIVE_E2E=1 for the real Codex Stop notification guard'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_VERSION=$(codex --version) || exit 1
LAB=${FM_CODEX_NOTIFY_LIVE_DIR:?set an isolated private evidence directory}
[ ! -e "$LAB" ] || { echo 'refusing to overwrite an existing lab' >&2; exit 1; }
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-codex-async-rewake) || exit 1
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || exit 1
mkdir -p "$LAB/project/state" "$LAB/project/config" "$LAB/project/.codex"
PROJECT="$LAB/project"
# Preserve the original verdict and make a default-session tripwire failure a
# hard test failure, even if every assertion before teardown passed.
cleanup_lab() {
  local rc=$1 teardown_rc
  trap - EXIT
  touch "$PROJECT/state/release"
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" > "$LAB/teardown.txt" 2>&1
  teardown_rc=$?
  printf 'exit=%s\n' "$teardown_rc" >> "$LAB/teardown.txt"
  [ "$teardown_rc" -eq 0 ] || { cat "$LAB/teardown.txt" >&2; exit "$teardown_rc"; }
  exit "$rc"
}
trap 'cleanup_lab "$?"' EXIT
# Exercise the same provisioning/EXIT cleanup boundary without any model call.
# The requested exit code proves cleanup preserves both success and failure.
if [ -n "${FM_CODEX_NOTIFY_LIVE_CLEANUP_ONLY:-}" ]; then
  exit "$FM_CODEX_NOTIFY_LIVE_CLEANUP_ONLY"
fi
printf '%s\n' "$HERDR_LAB_SESSION" > "$LAB/session"
printf '%s\n' "$CODEX_VERSION" > "$LAB/version"
git init -q "$PROJECT"
cp -R "$ROOT/bin" "$PROJECT/bin"
printf 'This is an isolated Codex notification lab. Follow the test prompt.\n' > "$PROJECT/AGENTS.md"
printf 'project=fixture\n' > "$PROJECT/state/task.meta"
# No network/bootstrap work is needed to test Stop. Keep the actual Stop and
# PreToolUse registrations; a recorder observes native payloads independently.
jq '.hooks.UserPromptSubmit = [{hooks:[{type:"command",command:"jq -c . >> \"$FM_HOME/state/submit-payloads.jsonl\""}]}] | del(.hooks.SessionStart) | .hooks.Stop[0].hooks |= ([{"type":"command","command":"jq -c . >> \"$FM_HOME/state/stop-payloads.jsonl\""}] + .)' "$ROOT/.codex/hooks.json" > "$PROJECT/.codex/hooks.json"
cat > "$PROJECT/hold.sh" <<'HOLD'
#!/bin/bash
touch "$FM_HOME/state/handling-blocked"
while [ ! -e "$FM_HOME/state/release" ]; do sleep 0.2; done
HOLD
chmod +x "$PROJECT/hold.sh"
cat > "$LAB/launch.sh" <<'LAUNCH'
#!/bin/bash
cd "$(dirname "$0")/project" || exit 1
export FM_HOME="$PWD" FM_ROOT_OVERRIDE="$PWD" FM_STATE_OVERRIDE="$PWD/state" FM_CONFIG_OVERRIDE="$PWD/config"
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999
# Alerts are observable local files; no OS notification or shared Herdr API.
export FM_WEDGE_ALARM_EXEC="$PWD/alert.sh" FM_WEDGE_ALARM_CHANNEL=osascript
exec codex --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --no-alt-screen -c 'model_reasoning_effort="low"' 'Isolated bounded primary notification test. First run only bin/fm-lock.sh. Reply INITIAL_IDLE and stop. Do not run session start, checkpoint, background tasks, or any agent. When a Firstmate watcher notification arrives, run bin/fm-wake-drain.sh and read all output. On the FIRST callback only, next run ./hold.sh as a foreground tool call before acknowledging. This deliberately pauses handling for a cancellation test. On subsequent turns handle the printed completion and needs-attention fixture events by recording their exact status text in state/handled.txt, then execute the exact WAKE_ACK_REQUIRED command from the drain. Reply HANDLED_IDLE and stop. These are isolated fixture events with no external action to perform.'
LAUNCH
cat > "$PROJECT/alert.sh" <<'ALERT'
#!/bin/bash
printf '%s\n' "$*" >> "$FM_HOME/state/alerts"
ALERT
chmod +x "$LAB/launch.sh" "$PROJECT/alert.sh"
snapshot() {
  jq -s -f "$ROOT/tests/codex-stop-observer.jq" "$PROJECT/state/stop-payloads.jsonl" "$PROJECT/state/submit-payloads.jsonl"
}
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
fail() { echo "not ok - $CODEX_VERSION: $* (evidence $LAB)" >&2; exit 1; }
wait_file() {
  local n=0
  while [ ! -s "$1" ] && [ "$n" -lt 180 ]; do sleep 1; n=$((n+1)); done
  [ -s "$1" ] || fail "missing $1"
}
lab workspace create --cwd "$PROJECT" --label codex-notify-lab --no-focus > "$LAB/workspace.txt" || exit 1
lab pane run w1:p1 "$LAB/launch.sh" > "$LAB/run.txt" || exit 1
# Trust remains a native project boundary even when hook trust is explicitly
# scoped to this test. Match its actual prompt before sending its Enter key.
sleep 3
lab pane read w1:p1 --source recent --lines 60 --format text > "$LAB/start.txt"
if grep -q 'Do you trust the contents of this directory' "$LAB/start.txt"; then
  lab pane send-keys w1:p1 Enter >/dev/null || exit 1
fi
wait_file "$PROJECT/state/.codex-notify-owner"
wait_file "$PROJECT/state/stop-payloads.jsonl"
wait_file "$PROJECT/state/submit-payloads.jsonl"
sleep 3
snapshot > "$LAB/idle-before.json" || fail 'invalid initial observer stream'
jq -e '.submitted == .stopped and (.stopped | length) == 1' "$LAB/idle-before.json" >/dev/null || fail 'initial native start and Stop do not match'
date -u +%FT%TZ > "$LAB/idle-start.txt"
sleep 12
snapshot > "$LAB/idle-after.json" || fail 'invalid quiet observer stream'
date -u +%FT%TZ > "$LAB/idle-end.txt"
cmp -s "$LAB/idle-before.json" "$LAB/idle-after.json" || fail 'idle waiting produced another model Stop'
[ -e "$PROJECT/state/.codex-notify-ready" ] || fail 'Stop did not verify readiness'
lab pane read w1:p1 --source recent --lines 100 --format text > "$LAB/idle-pane.txt"
printf 'done: isolated completion\n' >> "$PROJECT/state/task.status"
n=0
while [ ! -e "$PROJECT/state/handling-blocked" ] && [ "$n" -lt 180 ]; do sleep 1; n=$((n+1)); done
[ -e "$PROJECT/state/handling-blocked" ] || fail 'completion did not wake the idle primary'
cp "$PROJECT/state/.wake-queue" "$LAB/interrupted-queue"
printf 'needs-decision: [key=fixture-attention] isolated needs-attention\n' >> "$PROJECT/state/task.status"
n=0
while ! grep -F 'needs-attention' "$PROJECT/state/.codex-notify.log" >/dev/null 2>&1 && [ "$n" -lt 15 ]; do
  # The real watcher must scan the second status while model handling is busy.
  if [ "$(grep -c 'signal:' "$PROJECT/state/.watch-deliveries.log")" -ge 2 ]; then break; fi
  sleep 1; n=$((n+1))
done
[ "$(grep -c 'signal:' "$PROJECT/state/.watch-deliveries.log")" -ge 2 ] || fail 'watcher did not deliver attention while the primary was busy'
lab pane read w1:p1 --source recent --lines 120 --format text > "$LAB/busy-pane.txt"
INTERRUPTED_TURN=$(jq -sr 'last.turn_id' "$PROJECT/state/submit-payloads.jsonl")
printf '%s\n' "$INTERRUPTED_TURN" > "$LAB/interrupted-turn"
lab pane send-keys w1:p1 Escape >/dev/null || exit 1
sleep 3
grep -F 'signal:' "$PROJECT/state/.wake-queue" >/dev/null || fail 'interruption discarded durable events'
touch "$PROJECT/state/release"
lab pane send-text w1:p1 'The isolated cancellation probe is complete. Handle both fixture statuses using the original instructions, skip hold.sh, and acknowledge the exact drain generation. Reply HANDLED_IDLE and stop.' >/dev/null || exit 1
sleep 1
lab pane send-keys w1:p1 Enter >/dev/null || exit 1
wait_file "$PROJECT/state/handled.txt"
n=0
while [ -s "$PROJECT/state/.wake-queue" ] && [ "$n" -lt 120 ]; do sleep 1; n=$((n+1)); done
[ ! -s "$PROJECT/state/.wake-queue" ] || fail 'handling did not acknowledge the durable queue'
grep -F 'isolated completion' "$PROJECT/state/handled.txt" >/dev/null || fail 'completion not handled'
grep -F 'isolated needs-attention' "$PROJECT/state/handled.txt" >/dev/null || fail 'attention not handled'
n=0
# The manual recovery turn can handle rows before the already accepted busy
# callback is dispatched. That queued callback is required delivery, not an
# idle timer. Wait for both handling turns before measuring settled idle.
while [ "$(snapshot | jq '.handled | length')" -lt 2 ] && [ "$n" -lt 120 ]; do sleep 1; n=$((n+1)); done
[ "$(snapshot | jq '.handled | length')" = 2 ] || fail 'user recovery and queued busy notification did not both reach Stop'
sleep 3
lab pane read w1:p1 --source recent --lines 200 --format text > "$LAB/handled-pane.txt"
snapshot > "$LAB/final-before.json" || fail 'invalid final observer stream'
jq -e --arg interrupted "$INTERRUPTED_TURN" \
  '(.stopped | length) == 3 and (.submitted | length) == 4 and
   ((.submitted - .stopped) == [$interrupted])' "$LAB/final-before.json" >/dev/null \
  || fail 'final observer does not account for every native started turn'
date -u +%FT%TZ > "$LAB/final-idle-start.txt"
sleep 12
snapshot > "$LAB/final-after.json" || fail 'invalid final quiet stream'
date -u +%FT%TZ > "$LAB/final-idle-end.txt"
cmp -s "$LAB/final-before.json" "$LAB/final-after.json" || fail 'handled idle state started another turn'
lab pane send-text w1:p1 /quit >/dev/null || exit 1
sleep 1
lab pane send-keys w1:p1 Enter >/dev/null || exit 1
n=0
while [ -e "$PROJECT/state/.codex-notify.lock" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n+1)); done
[ ! -e "$PROJECT/state/.codex-notify.lock" ] || fail 'adapter survived TUI exit'
printf 'ok - %s real TUI idle, completion, busy cancellation, attention, ack, and exit (%s)\n' "$CODEX_VERSION" "$LAB"
