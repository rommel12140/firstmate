#!/usr/bin/env bash
# No-provider observer controls, including optional retrospective native replay.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-observer)
OBS="$ROOT/tests/codex-stop-observer.jq"
snapshot() { jq -s -f "$OBS" "$@"; }
record() {
  jq -cn --arg turn "$1" --arg message "$2" \
    '{session_id:"fixture",turn_id:$turn,hook_event_name:"Stop",last_assistant_message:$message}'
}
record initial INITIAL_IDLE > "$TMP_ROOT/initial"
record recovery HANDLED_IDLE > "$TMP_ROOT/recovery"
record delayed HANDLED_IDLE > "$TMP_ROOT/delayed"
cat "$TMP_ROOT/initial" "$TMP_ROOT/recovery" > "$TMP_ROOT/before-delayed"
cat "$TMP_ROOT/before-delayed" "$TMP_ROOT/delayed" > "$TMP_ROOT/complete"
tr -d '\n' < "$TMP_ROOT/complete" > "$TMP_ROOT/concatenated"
snapshot "$TMP_ROOT/complete" > "$TMP_ROOT/expected"
snapshot "$TMP_ROOT/concatenated" > "$TMP_ROOT/actual"
cmp -s "$TMP_ROOT/expected" "$TMP_ROOT/actual" || fail 'concatenated JSON changed the observer verdict'
[ "$(jq '.handled | length' "$TMP_ROOT/actual")" = 2 ] || fail 'distinct completed turns miscounted'
pass 'concatenated JSON and JSONL count the same two distinct handling turns'
snapshot "$TMP_ROOT/complete" "$TMP_ROOT/recovery" > "$TMP_ROOT/duplicate"
cmp -s "$TMP_ROOT/expected" "$TMP_ROOT/duplicate" || fail 'duplicate delivery invented a turn'
pass 'duplicate native records do not inflate completion or quiet counts'
snapshot "$TMP_ROOT/before-delayed" > "$TMP_ROOT/pending"
[ "$(jq '.handled | length' "$TMP_ROOT/pending")" = 1 ] || fail 'delayed callback was prematurely complete'
! cmp -s "$TMP_ROOT/pending" "$TMP_ROOT/expected" || fail 'delayed callback did not change observation'
pass 'already queued delayed callback must finish before the quiet baseline'
record new-idle HANDLED_IDLE > "$TMP_ROOT/new-idle"
snapshot "$TMP_ROOT/complete" "$TMP_ROOT/new-idle" > "$TMP_ROOT/new-stop"
! cmp -s "$TMP_ROOT/expected" "$TMP_ROOT/new-stop" || fail 'new post-drain idle callback passed quiet assertion'
printf '%s\n' '{"session_id":"fixture","turn_id":"new-start","hook_event_name":"UserPromptSubmit","prompt":"unexpected idle callback"}' > "$TMP_ROOT/new-start"
snapshot "$TMP_ROOT/complete" "$TMP_ROOT/new-start" > "$TMP_ROOT/new-started"
! cmp -s "$TMP_ROOT/expected" "$TMP_ROOT/new-started" || fail 'new unfinished idle callback passed quiet assertion'
pass 'intentional new post-drain callback fails quiet at start and at Stop'
record recovery DIFFERENT > "$TMP_ROOT/conflict"
if snapshot "$TMP_ROOT/complete" "$TMP_ROOT/conflict" > /dev/null 2>&1; then fail 'conflicting duplicate was accepted'; fi
printf '%s\n' '{"session_id":"fixture","hook_event_name":"Stop"}' > "$TMP_ROOT/invalid"
if snapshot "$TMP_ROOT/invalid" > /dev/null 2>&1; then fail 'missing turn identity was accepted'; fi
pass 'conflicting duplicates and missing turn IDs fail closed'
if [ -n "${FM_CODEX_OBSERVER_REPLAY:-}" ]; then
  snapshot "$FM_CODEX_OBSERVER_REPLAY" > "$TMP_ROOT/replayed"
  [ "$(jq '.handled | length' "$TMP_ROOT/replayed")" = 2 ] || fail 'retrospective native replay did not contain two distinct completed handling turns'
  snapshot "$FM_CODEX_OBSERVER_REPLAY" "$FM_CODEX_OBSERVER_REPLAY" > "$TMP_ROOT/replayed-twice"
  cmp -s "$TMP_ROOT/replayed" "$TMP_ROOT/replayed-twice" || fail 'native replay duplicates changed verdict'
  pass 'RETROSPECTIVE native stream replay has two distinct handling turns; this is not a passing live run'
fi
