#!/usr/bin/env bash
# Portable executable-interface tests for Codex event notification ownership.
# Real processes exercise lock identity and lifecycle; only vendor queue I/O and
# worker event production are fixtures. The opt-in Codex suite proves the vendor.
# shellcheck disable=SC2016
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-stop)
LAB="$TMP_ROOT/home"
mkdir -p "$LAB/state" "$LAB/config" "$TMP_ROOT/harness" "$TMP_ROOT/commands"
git init -q "$LAB"
: > "$LAB/AGENTS.md"
cp -R "$ROOT/bin" "$LAB/bin"
ln -s /bin/bash "$TMP_ROOT/harness/codex"
printf 'project=fixture\n' > "$LAB/state/task.meta"
cat > "$TMP_ROOT/commands/codex" <<'SH'
#!/bin/bash
[ "$1 ${2:-}" != 'queue --help' ] || exit 0
printf '%s\n' "$*" >> "$FM_HOME/queue-calls"
[ ! -e "$FM_HOME/fail-queue" ] || exit 7
exit 0
SH
cat > "$TMP_ROOT/commands/alert" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FM_HOME/alerts"
SH
cat > "$LAB/bin/fm-watch.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/fm-wake-lib.sh"
fm_lock_try_acquire "$STATE/.watch.lock" || exit 0
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$0" > "$STATE/.watch.lock/watcher-path"
printf '%s\n' "$(fm_pid_identity "$$")" > "$STATE/.watch.lock/pid-identity"
trap 'fm_lock_release "$STATE/.watch.lock"; exit 0' TERM INT
while :; do touch "$STATE/.last-watcher-beat"; sleep 0.2; done
SH
cat > "$LAB/controller" <<'SH'
#!/bin/bash
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
while [ ! -e "$FM_HOME/quit" ]; do
  if [ -e "$FM_HOME/invoke" ]; then
    rm "$FM_HOME/invoke"
    printf '%s\n' '{"session_id":"11111111-1111-4111-8111-111111111111","stop_hook_active":false}' | "$FM_HOME/bin/fm-codex-stop.sh" > "$FM_HOME/stop.out" 2>&1
    printf '%s\n' "$?" > "$FM_HOME/stop.rc"
  fi
  sleep 0.1
done
SH
chmod +x "$TMP_ROOT/commands/"* "$LAB/bin/fm-watch.sh"
export FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state"
export FM_WEDGE_ALARM_EXEC="$TMP_ROOT/commands/alert" FM_WEDGE_ALARM_CHANNEL=osascript
export PATH="$TMP_ROOT/commands:$PATH"
OWNER=
cleanup_test() {
  touch "$LAB/quit"
  [ -z "$OWNER" ] || wait "$OWNER" 2>/dev/null || true
}
trap cleanup_test EXIT
wait_file() {
  local file=$1 n=0
  while [ ! -e "$file" ] && [ "$n" -lt 400 ]; do sleep 0.1; n=$((n+1)); done
  [ -e "$file" ] || fail "timed out waiting for $file: $(cat "$LAB/stop.out" "$LAB/state/.codex-notify.log" 2>/dev/null)"
}
wait_count() {
  local file=$1 expected=$2 n=0 count
  while [ "$n" -lt 400 ]; do
    count=0
    [ ! -f "$file" ] || count=$(wc -l < "$file" | tr -d ' ')
    [ "${count:-0}" -ge "$expected" ] && return 0
    sleep 0.1
    n=$((n+1))
  done
  fail "timed out waiting for $expected lines in $file"
}
invoke_stop() {
  rm -f "$LAB/stop.rc"
  touch "$LAB/invoke"
  wait_file "$LAB/stop.rc"
}
append_wake() {
  FM_HOME="$LAB" bash -c '. "$FM_HOME/bin/fm-wake-lib.sh"; fm_wake_append check "$1" "check: $1"' _ "$1"
}
# A live shell PID is not a primary, even when it occupies the home lock.
printf '%s\n' "$$" > "$LAB/state/.lock"
printf '%s\n' '{"session_id":"11111111-1111-4111-8111-111111111111"}' | "$LAB/bin/fm-codex-stop.sh" > "$LAB/refusal.out" 2>&1
[ ! -e "$LAB/state/.codex-notify.lock" ] || fail 'bare shell acquired notification ownership'
[ ! -e "$LAB/queue-calls" ] || fail 'bare shell received a notification'
pass 'bare shell cannot claim primary notification ownership'
rm "$LAB/state/.lock"
"$TMP_ROOT/harness/codex" "$LAB/controller" &
OWNER=$!
invoke_stop
[ "$(cat "$LAB/stop.rc")" = 0 ] || fail "initial Stop failed: $(cat "$LAB/stop.out")"
wait_file "$LAB/state/.codex-notify-ready"
RUN_PID=$(cat "$LAB/state/.codex-notify.lock/pid")
sleep 2
[ ! -e "$LAB/queue-calls" ] || fail 'quiet waiting queued a model turn'
pass 'Codex adapter waits without a quiet notification'
invoke_stop
[ "$(cat "$LAB/state/.codex-notify.lock/pid")" = "$RUN_PID" ] || fail 'second Stop replaced a live singleton'
pass 'repeated Stop retains the same home singleton'
append_wake completion
wait_count "$LAB/queue-calls" 1
cp "$LAB/state/.wake-queue" "$LAB/retained"
sleep 2
[ "$(wc -l < "$LAB/queue-calls" | tr -d ' ')" = 1 ] || fail 'unchanged pending event produced duplicate notifications'
cmp -s "$LAB/retained" "$LAB/state/.wake-queue" || fail 'delivery consumed a durable event'
grep -F -- '--thread 11111111-1111-4111-8111-111111111111' "$LAB/queue-calls" >/dev/null || fail 'wrong primary thread'
pass 'completion notification targets the bound thread and retains unacknowledged work'
invoke_stop
wait_count "$LAB/queue-calls" 2
cmp -s "$LAB/retained" "$LAB/state/.wake-queue" || fail 'interrupted handling lost work'
pass 'later Stop retries interrupted handling without consuming its event'
touch "$LAB/fail-queue"
append_wake needs-attention
wait_count "$LAB/queue-calls" 4
wait_file "$LAB/alerts"
wait_file "$LAB/state/.codex-notify-failure"
sleep 2
[ "$(wc -l < "$LAB/queue-calls" | tr -d ' ')" = 4 ] || fail 'exhausted delivery entered an unbounded retry loop'
grep -F needs-attention "$LAB/state/.wake-queue" >/dev/null || fail 'failed notification lost attention event'
pass 'queue failure is bounded, actively reported, and durable'
rm "$LAB/fail-queue"
invoke_stop
wait_count "$LAB/queue-calls" 5
[ "$(cat "$LAB/stop.rc")" = 0 ] || fail 'repaired Stop did not verify the successful retry'
[ ! -e "$LAB/state/.codex-notify-failure" ] || fail 'successful recovery left the failure episode open'
pass 'next Stop retries a repaired native notification path'
# Abrupt owner death must not strand its arm/watch child. Durable records are
# intentionally left for the next native Stop to recover.
WATCH_PID=$(cat "$LAB/state/.watch.lock/pid")
kill -KILL "$RUN_PID"
n=0
while kill -0 "$WATCH_PID" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
! kill -0 "$WATCH_PID" 2>/dev/null || fail 'killed adapter stranded its watcher'
invoke_stop
[ "$(cat "$LAB/stop.rc")" = 0 ] || fail 'Stop did not recover a killed adapter'
NEW_PID=$(cat "$LAB/state/.codex-notify.lock/pid")
[ "$NEW_PID" != "$RUN_PID" ] || fail 'Stop reused a killed adapter'
wait_count "$LAB/queue-calls" 6
pass 'hard cancellation retires the child and next Stop recovers retained events'
RUN_PID=$NEW_PID
touch "$LAB/quit"
wait "$OWNER"
OWNER=
n=0
while [ -e "$LAB/state/.codex-notify.lock" ] && [ "$n" -lt 400 ]; do sleep 0.1; n=$((n+1)); done
[ ! -e "$LAB/state/.codex-notify.lock" ] || fail 'adapter survived its primary process'
[ ! -e "$LAB/state/.watch.lock" ] || fail 'adapter left its watcher after primary exit'
grep -F completion "$LAB/state/.wake-queue" >/dev/null || fail 'primary exit discarded queued work'
pass 'dead primary retires its watcher and preserves pending events'

# Keep the actual watcher in this case: a passive fixture cannot expose repeated
# rearm-resurface closes which starve the next status while handling is busy.
LAB="$TMP_ROOT/real-home"
mkdir -p "$LAB/state" "$LAB/config"
git init -q "$LAB"
: > "$LAB/AGENTS.md"
cp -R "$ROOT/bin" "$LAB/bin"
cp "$TMP_ROOT/home/controller" "$LAB/controller"
printf 'project=fixture\n' > "$LAB/state/task.meta"
export FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state"
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999
"$TMP_ROOT/harness/codex" "$LAB/controller" &
OWNER=$!
invoke_stop
[ "$(cat "$LAB/stop.rc")" = 0 ] || fail 'real watcher did not become ready'
printf 'done: isolated completion\n' >> "$LAB/state/task.status"
wait_count "$LAB/queue-calls" 1
printf 'needs-decision: [key=fixture] isolated attention\n' >> "$LAB/state/task.status"
wait_count "$LAB/queue-calls" 2
n=0
while [ "$(grep -c 'signal:' "$LAB/state/.watch-deliveries.log" 2>/dev/null)" -lt 2 ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
[ "$(grep -c 'signal:' "$LAB/state/.watch-deliveries.log")" = 2 ] || fail 'successor did not scan the attention status'
sleep 3
WATCH_PID=$(cat "$LAB/state/.watch.lock/pid")
CALLS=$(wc -l < "$LAB/queue-calls")
sleep 4
[ "$(cat "$LAB/state/.watch.lock/pid")" = "$WATCH_PID" ] || fail 'unchanged pending work churned watcher cycles'
[ "$(wc -l < "$LAB/queue-calls")" = "$CALLS" ] || fail 'unchanged pending work churned notifications'
[ -s "$LAB/state/.wake-queue" ] || fail 'real watcher notification consumed pending events'
pass 'real handling successor scans new attention and parks without recovery churn'
touch "$LAB/quit"
wait "$OWNER"
OWNER=
n=0
while [ -e "$LAB/state/.codex-notify.lock" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
[ ! -e "$LAB/state/.watch.lock" ] || fail 'real watcher survived primary exit'
pass 'real watcher retires after primary exit'

LAB="$TMP_ROOT/missing-watcher-home"
mkdir -p "$LAB/state" "$LAB/config"
git init -q "$LAB"
: > "$LAB/AGENTS.md"
cp -R "$ROOT/bin" "$LAB/bin"
cp "$TMP_ROOT/home/controller" "$LAB/controller"
printf 'project=fixture\n' > "$LAB/state/task.meta"
printf '#!/bin/bash\necho "fixture watcher startup failure" >&2\nexit 7\n' > "$LAB/bin/fm-watch.sh"
export FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state"
"$TMP_ROOT/harness/codex" "$LAB/controller" &
OWNER=$!
invoke_stop
[ "$(cat "$LAB/stop.rc")" != 0 ] || fail 'missing watcher allowed a quiet Stop'
wait_file "$LAB/state/.codex-notify-failure"
wait_file "$LAB/alerts"
grep -F 'codex-notify-failure' "$LAB/state/.wake-queue" >/dev/null || fail 'missing watcher failure was not durable'
grep -F 'fixture watcher startup failure' "$LAB/state/.codex-notify.log" >/dev/null || fail 'child failure evidence was discarded'
pass 'missing watcher retains child evidence, durable recovery, and active alarm'
touch "$LAB/quit"
wait "$OWNER"
OWNER=
