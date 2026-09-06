#!/usr/bin/env bash
# Codex Stop-owned event notification for persistent local CLI primaries.
#
# Usage: fm-codex-stop.sh [--run <owner-pid> <owner-identity> <thread-uuid>]
# Stop input is the native hook JSON on stdin. The synchronous hook launches a
# detached, home-singleton adapter and verifies its watcher before returning.
# Codex permits successful hooks to leave helpers running. The adapter is bound
# to the lock owner's process identity and the hook's exact thread UUID; it
# retires its own watcher when that owner exits, is replaced, or enters AFK.
# It uses fm-watch-arm for watcher lifecycle and codex queue for notification.
# No terminal input, native thread resume, wake drain, or acknowledgement occurs
# here. Busy-turn input stays in Codex's native queue. Durable Firstmate rows
# survive notification, interruption, and process restart until handled + acked.
# Each accepted notification suppresses duplicates for the same durable queue
# snapshot. A later Stop retries remaining work, including interrupted handling.
# A failed queue call is retried twice with a bounded command timeout; exhaustion
# retains the rows and records a recoverable failure using configured alerts.
# This is a Codex-specific transport, not a second event classifier.
#
# Requires Codex with `queue` support (live-verified on 0.153.4). A remote/shared
# app-server primary has no unique TUI process owner and is refused by this
# adapter; its existing guard remains the fallback. No daemon is reconfigured.
# Test bounds: FM_CODEX_NOTIFY_START_TICKS (default 150, 0.1s),
# FM_CODEX_NOTIFY_POLL (default 1s), FM_CODEX_NOTIFY_TIMEOUT (default 15s).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-alert-lib.sh
. "$SCRIPT_DIR/fm-alert-lib.sh"

LOCK="$STATE/.codex-notify.lock"
START_LOCK="$STATE/.codex-notify-start.lock"
RECORD="$STATE/.codex-notify-owner"
READY="$STATE/.codex-notify-ready"
SENT="$STATE/.codex-notify-sent"
FAILURE="$STATE/.codex-notify-failure"
GRACE=${FM_GUARD_GRACE:-300}
POLL=${FM_CODEX_NOTIFY_POLL:-1}
TIMEOUT=${FM_CODEX_NOTIFY_TIMEOUT:-15}
START_TICKS=${FM_CODEX_NOTIFY_START_TICKS:-150}
case "$POLL" in ''|*[!0-9]*|0) POLL=1 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=15 ;; esac
case "$START_TICKS" in ''|*[!0-9]*|0) START_TICKS=150 ;; esac

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
owner_valid() {
  [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$OWNER" ] || return 1
  fm_harness_pid_alive "$OWNER" || return 1
  [ "$(fm_pid_identity "$OWNER" 2>/dev/null)" = "$OWNER_ID" ]
}
adapter_valid() {
  local pid identity
  [ "$(sed -n '2p' "$RECORD" 2>/dev/null)" = "$OWNER" ] || return 1
  [ "$(sed -n '3p' "$RECORD" 2>/dev/null)" = "$THREAD" ] || return 1
  [ "$(sed -n '4p' "$RECORD" 2>/dev/null)" = "$OWNER_ID" ] || return 1
  pid=$(sed -n '1p' "$RECORD" 2>/dev/null)
  [ "$pid" = "$(cat "$LOCK/pid" 2>/dev/null)" ] || return 1
  identity=$(sed -n '5p' "$RECORD" 2>/dev/null)
  [ -n "$identity" ] && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ] || return 1
  owner_valid
}
adapter_healthy() {
  adapter_valid && [ ! -e "$FAILURE" ] && [ "$(fm_path_age "$READY")" -lt "$GRACE" ] \
    && fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"
}
record_failure() {
  local message=$1
  owner_valid || return 0
  log "$message"
  if [ ! -e "$FAILURE" ]; then
    printf '%s\n' "$message" > "$FAILURE" || return 1
    fm_wake_append check codex-notify-failure 'check: codex-notify-failure' || return 1
    FM_ALERT_TITLE='firstmate: Codex notification failed' \
      wedge_alarm_notify "$message; pending work is retained. See $FAILURE" "$FAILURE"
  fi
}

if [ "${1:-}" != --run ]; then
  [ "$#" -eq 0 ] || { echo 'usage: fm-codex-stop.sh' >&2; exit 2; }
  PAYLOAD=$(cat)
  fallback() {
    local rc
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    # Keep the existing one-block-per-turn bound for a missing transport even
    # when another watcher happens to be healthy.
    if [ "$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" != true ]; then
      echo 'Codex event notification is unavailable. Inspect state/.codex-notify-failure and .codex-notify.log; repair the Stop adapter before relying on idle supervision.' >&2
      return 2
    fi
    return 0
  }
  if [ -e "$STATE/.afk" ] || ! fm_supervision_needed "$STATE" "$GRACE"; then
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh"
    exit $?
  fi
  THREAD=$(printf '%s' "$PAYLOAD" | jq -er '.session_id | select(test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))' 2>/dev/null) || { fallback; exit $?; }
  fm_session_lock_owned_by_self "$STATE" || { fallback; exit $?; }
  OWNER=$(cat "$STATE/.lock")
  OWNER_ID=$(fm_pid_identity "$OWNER") || { fallback; exit $?; }
  case "$(ps -o args= -p "$OWNER" 2>/dev/null)" in
    *' app-server'*)
      echo 'Codex event notification requires a local TUI process owner; shared app-server ancestry is unsupported.' >&2
      fallback
      exit $?
      ;;
  esac
  if ! fm_run_timed "$TIMEOUT" codex queue --help >/dev/null 2>&1; then
    echo 'Codex queue is unavailable; this integration requires the native queue command (verified on 0.153.4).' >&2
    fallback
    exit $?
  fi
  if ! fm_lock_try_acquire "$START_LOCK"; then
    adapter_healthy && exit 0
    fallback
    exit $?
  fi
  trap 'fm_lock_release "$START_LOCK"' EXIT
  # A new Stop means the model has had an opportunity to handle an accepted
  # callback. Unacknowledged rows now need another notification after an
  # interrupted/incomplete handling turn, never implicit consumption.
  rm -f "$SENT"
  if ! adapter_valid; then
    # Only the hook launches a detached helper; the model never shells &.
    nohup "$SCRIPT_DIR/fm-codex-stop.sh" --run "$OWNER" "$OWNER_ID" "$THREAD" \
      </dev/null >>"$STATE/.codex-notify.log" 2>&1 &
  fi
  tick=0
  while [ "$tick" -lt "$START_TICKS" ]; do
    adapter_healthy && exit 0
    # An existing failure is the reason this Stop is retrying. Wait for the
    # new attempt, rather than rejecting its stale marker before it can run.
    if [ -e "$FAILURE" ] && [ -e "$SENT" ]; then break; fi
    sleep 0.1
    tick=$((tick + 1))
  done
  [ ! -f "$FAILURE" ] || cat "$FAILURE" >&2
  fallback
  exit $?
fi

[ "$#" -eq 4 ] || exit 2
OWNER=$2 OWNER_ID=$3 THREAD=$4
# This initial check happens before the launching hook returns. Thereafter the
# kernel identity and home lock, not reparented ancestry, bind the helper.
fm_session_lock_owned_by_self "$STATE" && owner_valid || exit 1
fm_lock_try_acquire "$LOCK" || exit 0
RUN_PID=$$
ARM_PID=
PREDECESSOR=
OUT="$STATE/.codex-notify-output.$$"
# An owned asynchronous job crosses exec before its argv identity settles.
# Bash owns this job until wait; its running job table avoids both that race
# and signalling a reused PID after the child has exited.
arm_running() {
  [ -n "$ARM_PID" ] && jobs -pr | grep -qx "$ARM_PID"
}
# shellcheck disable=SC2329 # Trap callback.
cleanup() {
  trap - EXIT TERM INT
  if arm_running; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  wedge_alarm_stop_active_notifier
  if [ "$(sed -n '1p' "$RECORD" 2>/dev/null)" = "$RUN_PID" ]; then
    rm -f "$RECORD" "$READY" "$SENT"
  fi
  rm -f "$OUT"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
printf '%s\n' "$RUN_PID" "$OWNER" "$THREAD" "$OWNER_ID" "$(fm_pid_identity "$RUN_PID")" > "$RECORD.tmp.$$" \
  && mv "$RECORD.tmp.$$" "$RECORD" || exit 1
rm -f "$READY" "$SENT"
# The configured Relay cadence remains the same as the other watcher owners.
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=/dev/null
[ ! -f "$CONFIG/x-mode.env" ] || . "$CONFIG/x-mode.env"

notify_pending() {
  local signature prior attempt message rc
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  signature=$(cksum < "$FM_WAKE_QUEUE") || return 1
  prior=$(cat "$SENT" 2>/dev/null || true)
  [ "$signature" != "$prior" ] || return 0
  fm_operational_input_encode watcher \
    'A durable Firstmate supervision event needs handling. Run bin/fm-wake-drain.sh, handle the emitted work, then run its exact WAKE_ACK_REQUIRED acknowledgement. The Codex Stop adapter owns watcher continuity; do not run a checkpoint or background watcher tool.' message || return 1
  attempt=0
  while [ "$attempt" -lt 2 ]; do
    owner_valid && [ ! -e "$STATE/.afk" ] || return 0
    attempt=$((attempt + 1))
    fm_run_timed "$TIMEOUT" codex queue --thread "$THREAD" --message "$message" >> "$OUT" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
        rm -f "$FAILURE"
      fi
      printf '%s\n' "$signature" > "$SENT"
      return 0
    fi
  done
  record_failure "Codex queue delivery failed (exit $rc); repair native queue access and let the next Stop retry."
  # Prevent a failure episode from becoming a command or model retry loop.
  cksum < "$FM_WAKE_QUEUE" > "$SENT" 2>/dev/null || true
  return 1
}

while owner_valid && [ ! -e "$STATE/.afk" ] && fm_supervision_needed "$STATE" "$GRACE"; do
  FM_WATCH_PREDECESSOR_ARM_PID="$PREDECESSOR" \
    FM_CODEX_NOTIFY_PID="$RUN_PID" FM_CODEX_NOTIFY_IDENTITY="$(fm_pid_identity "$RUN_PID")" \
    "$SCRIPT_DIR/fm-watch-arm.sh" > "$OUT" 2>&1 &
  ARM_PID=$!
  while arm_running; do
    owner_valid && [ ! -e "$STATE/.afk" ] || exit 0
    if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
      touch "$READY"
      # A verified watcher closes a watcher-failure episode. Transport failures
      # remain open until their retained notification succeeds.
      if [ -f "$FAILURE" ] && grep -q '^Codex watcher closed' "$FAILURE"; then
        rm -f "$FAILURE"
      fi
    fi
    notify_pending || true
    sleep "$POLL"
  done
  wait "$ARM_PID"
  arm_rc=$?
  PREDECESSOR=$ARM_PID
  log "watcher arm pid=$ARM_PID exited $arm_rc"
  cat "$OUT" >&2
  ARM_PID=
  owner_valid && [ ! -e "$STATE/.afk" ] || exit 0
  if grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT"; then
    notify_pending || true
  elif ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    record_failure 'Codex watcher closed without a verified successor or actionable event; inspect .codex-notify.log and retry from the next Stop.'
    notify_pending || true
  fi
  sleep "$POLL"
done
