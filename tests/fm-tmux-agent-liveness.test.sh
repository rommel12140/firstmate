#!/usr/bin/env bash
# tests/fm-tmux-agent-liveness.test.sh - portable regression for the tmux
# agent-liveness classifier and the cheap tmux presence primitive
# (bin/backends/tmux.sh).
#
# It runs REAL processes in a REAL tmux server on a private socket (`-L`), and
# needs no harness and no credentials, so it runs everywhere CI runs tmux. The
# live per-harness counterpart is tests/fm-harness-liveness-drift-live-e2e.test.sh.
#
# The defect it exists for: a harness that rewrites its own process title made
# `#{pane_current_command}` report a version string, the classifier could not
# attribute the pane, and supervision lost the agent. The version-string case
# below carries the proof that the verdict never depends on a single name
# surface: it drives the two sources apart on purpose and asserts that
# divergence, so it cannot go quietly vacuous. tmux and `ps -o comm=` read
# different name surfaces, and which one a given construction blinds differs
# between macOS and Linux, so every case asserts only the platform-independent
# property that the verdict itself is correct.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-liveness-$$"
# A second private server exists only to hold a real attached client on
# SOCKET; see the presence-primitive section at the end of this file.
CLIENT_SOCKET="fm-liveness-client-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness.XXXXXX")
SESSION=liveness

cleanup_all() {
  "$REAL_TMUX" -L "$CLIENT_SOCKET" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so bin/backends/tmux.sh's bare `tmux` calls reach the
# private socket and never touch the host's real sessions.
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/bin/claude" "$LAB/bin/decoy" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# Stand-in "harness" binaries. These are SYMLINKS to a real long-running system
# binary, never copies: a copied platform binary fails code-signing validation
# and is killed on macOS arm64. The symlink name is what the kernel records as
# the executable identity, which is exactly the signal under test.
ln -s "$SLEEP_BIN" "$LAB/bin/claude-link"
ln -s "$SLEEP_BIN" "$LAB/bin/pi"
ln -s "$SLEEP_BIN" "$LAB/bin/notaharness"

# A launcher whose own process identity is a bare shell, running the harness as
# a child in the same foreground process group - the shape the real Pi Launcher
# path takes, and the one where trusting a single name source can produce a
# false `dead`.
cat > "$LAB/bin/agent-launcher" <<SH
#!/bin/sh
"$LAB/bin/pi" 900 &
wait
SH
chmod +x "$LAB/bin/agent-launcher"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n idle -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Run the pane's process DIRECTLY as the window command rather than typing into
# a shell, so no case depends on interactive shell readiness.
new_window() {  # <name> <cmd...>
  local name=$1
  shift
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$name" -c "$LAB/wt" -- "$@" \
    || fail "could not create window $name"
}

wait_for_state() {  # <target> <expected> [tries]
  local target=$1 expected=$2 tries=${3:-100} got i=0
  while [ "$i" -lt "$tries" ]; do
    got=$(fm_backend_agent_state tmux "$target")
    [ "$got" = "$expected" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  printf 'last verdict for %s was %s (expected %s); title=%s comms=[%s]\n' \
    "$target" "${got:-<none>}" "$expected" \
    "$(fm_backend_tmux_current_command "$target")" \
    "$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')" >&2
  return 1
}

# Does the tmux current-command source, on its own, name a verified harness?
title_classifies_agent() {  # <target>
  local name
  name=$(fm_backend_tmux_current_command "$1" 2>/dev/null)
  [ "$(fm_backend_tmux_classify_process_name "$name")" = agent ]
}

# Does the foreground-process-group identity, including argv[0], name one?
comms_classify_agent() {  # <target>
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(fm_backend_tmux_classify_process_name "$name")" = agent ] && return 0
  done <<EOF
$(fm_backend_tmux_foreground_comms "$1")
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(fm_backend_tmux_classify_process_name '' "$name")" = agent ] && return 0
  done <<EOF
$(fm_backend_tmux_foreground_argv0s "$1")
EOF
  return 1
}

# The core anti-brittleness assertion: the two name sources must genuinely
# DISAGREE for this case, so a verdict of alive proves the surviving source
# carried it. Without this the divergence cases could silently go vacuous.
assert_sources_disagree() {  # <target> <label>
  local t=0 c=0
  title_classifies_agent "$1" && t=1
  comms_classify_agent "$1" && c=1
  [ $((t + c)) -eq 1 ] || fail \
    "$2: the two name sources were expected to disagree, but title=$t comms=$c (title='$(fm_backend_tmux_current_command "$1")' comms='$(fm_backend_tmux_foreground_comms "$1" | tr '\n' ' ')')"
}

# --- a harness-named foreground process -------------------------------------
# Invoking the symlink by its harness name proves the ordinary positive path
# with a real process. macOS exposes different names for the symlink through
# tmux and ps, while Linux can expose the symlink name through both, so the
# version-string case below owns the cross-platform divergence assertion.

new_window agent "$LAB/bin/claude-link" 900
wait_for_state "$SESSION:agent" alive \
  || fail "a running harness-named foreground process must classify alive"
pass "tmux liveness: a harness-named foreground process classifies alive"

# --- a version name blinds one source ---------------------------------------
# Giving a genuine harness-named executable the version-string argv[0] that
# Claude Code 2.1.220 reports drives the two sources apart on both supported
# platforms and proves the surviving source carries the verdict. This needs a
# real executable file rather than a symlink, because macOS takes the title
# from the resolved target's name, so it is skipped where no C compiler exists.

CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
if [ -n "$CC_BIN" ] &&
  printf '%s\n' '#include <unistd.h>' 'int main(void){for(;;)sleep(60);return 0;}' > "$LAB/spin.c" &&
  "$CC_BIN" -o "$LAB/bin/claude/2.1.220" "$LAB/spin.c" 2>/dev/null &&
  "$CC_BIN" -o "$LAB/bin/decoy/2.1.220" "$LAB/spin.c" 2>/dev/null; then
  new_window titled "$LAB/bin/claude/2.1.220"
  wait_for_state "$SESSION:titled" alive \
    || fail "a version-named executable under a harness install path must classify alive"
  assert_sources_disagree "$SESSION:titled" "version-string process name"
  pass "tmux liveness: a version-named executable under a harness install path classifies alive"

  new_window path-decoy "$LAB/bin/decoy/2.1.220"
  wait_for_state "$SESSION:path-decoy" ambiguous \
    || fail "a version-named executable without a whole harness path component must stay ambiguous"
  pass "tmux liveness: a version-named executable under a decoy path stays ambiguous"
else
  echo "skip: no C compiler, so the version-string process-name case cannot build its executable"
fi

# --- neither source names a harness: no invented agent ----------------------

new_window unknown bash -c "exec -a 2.1.220 '$LAB/bin/notaharness' 900"
wait_for_state "$SESSION:unknown" ambiguous \
  || fail "a foreground process no name source attributes must stay ambiguous"
pass "tmux liveness: a process neither name source attributes stays ambiguous rather than inventing an agent"

# --- a launcher whose own identity reads as a bare shell --------------------
# The single-source classifier would read this pane as an idle shell and call
# it dead - the one verdict that can start a duplicate agent on a live worktree.

new_window launcher "$LAB/bin/agent-launcher"
wait_for_state "$SESSION:launcher" alive \
  || fail "a launcher running a harness child must classify alive, never dead"
comms_classify_agent "$SESSION:launcher" \
  || fail "the launcher's harness child must be visible in the foreground process group"
pass "tmux liveness: a launcher whose own identity reads as a bare shell classifies alive from its harness child"

# --- an idle shell is still confidently dead --------------------------------

wait_for_state "$SESSION:idle" dead \
  || fail "an idle shell pane must classify dead"
pass "tmux liveness: an idle shell pane classifies dead"

# --- a harness-named BACKGROUND process must not fake an agent --------------
# Scoping to the foreground process group is what prevents this false alive; a
# descendant walk of the pane would report this pane as running an agent.
# `set -m` gives the background job its own process group, which is what an
# interactive shell does for a job an exited agent left behind.

new_window background bash -c "set -m; '$LAB/bin/claude-link' 900 & printf '%s\n' \"\$!\" > '$LAB/bg.pid'; exec /bin/sh"
bg_pid=
for _ in $(seq 1 100); do
  [ -s "$LAB/bg.pid" ] && bg_pid=$(cat "$LAB/bg.pid") && break
  sleep 0.1
done
[ -n "$bg_pid" ] || fail "the background harness-named process never started"
kill -0 "$bg_pid" 2>/dev/null \
  || fail "the background harness-named process is not running, so this case would prove nothing"
wait_for_state "$SESSION:background" dead \
  || fail "a pane whose only harness-named process is backgrounded must classify dead"
kill -0 "$bg_pid" 2>/dev/null \
  || fail "the background harness-named process died during the check, so this case proves nothing"
pass "tmux liveness: a harness-named background process in an idle pane still classifies dead"

# --- an absent window never inherits tmux's active-window fallback ----------
# tmux answers a display-message for an absent target from the CLIENT's active
# window instead of failing, so both raw name reads can describe a completely
# different pane. The classifier's window-membership check is what contains
# that, and this case proves the composed verdict does not inherit it.

fm_backend_tmux_foreground_comms "$SESSION:no-such-window" >/dev/null \
  || fail "the foreground-comms read must stay best-effort for an absent window"
[ "$(fm_backend_agent_state tmux "$SESSION:no-such-window")" = missing ] \
  || fail "an absent window in a readable session must classify missing, not whatever the fallback pane runs"
pass "tmux liveness: an absent window classifies missing rather than inheriting tmux's active-window fallback"

# --- the cheap presence primitive, with a REAL CLIENT ATTACHED --------------
# fm_backend_target_exists is the shared alive/dead read behind the
# session-start fleet digest and the recovery digests, and it is the entry
# condition for stuck-worker recovery. Built on a bare `display-message -t`
# exit code it answered `alive` for every target, including a window that
# existed nowhere, so the digest could never report a dead endpoint.
#
# An attached client is the condition that gives that fallback something to
# answer from, so the cases below only prove anything while one is attached.
# The client comes from a SECOND private tmux server, which needs no pty
# helper and keeps this as portable as the rest of the file.

cat > "$LAB/attach.sh" <<SH
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCKET" attach -t "$SESSION"
SH
chmod +x "$LAB/attach.sh"
"$REAL_TMUX" -L "$CLIENT_SOCKET" new-session -d -s attach -x 80 -y 24 "$LAB/attach.sh" \
  || fail "could not start the client-holding tmux server"

attached_client=
for _ in $(seq 1 100); do
  attached_client=$("$REAL_TMUX" -L "$SOCKET" list-clients -F '#{client_tty}' 2>/dev/null | head -1)
  [ -n "$attached_client" ] && break
  sleep 0.1
done
[ -n "$attached_client" ] \
  || fail "no client ever attached, so the presence cases would prove nothing about the fallback"

# The anti-vacuous assertion: the raw probe the primitive used to be must still
# succeed here AND describe a different, existing window. Without this, a tmux
# release that started failing the absent target would turn every case below
# into a silent pass that no longer covers the defect.
raw_readback=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:no-such-window" \
  '#{session_name}:#{window_name}' 2>/dev/null) \
  || fail "display-message failed for an absent target, so the active-window fallback is not live in this tmux"
[ "$raw_readback" != "$SESSION:no-such-window" ] && [ -n "${raw_readback#*:}" ] \
  || fail "display-message did not fall back to another window (read back '$raw_readback'), so these cases would prove nothing"
pass "tmux presence: the display-message active-window fallback is live with a client attached (absent target read back as '$raw_readback')"

fm_backend_target_exists tmux "$SESSION:no-such-window" \
  && fail "an absent window must NOT read as present while a client is attached"
pass "tmux presence: an absent window reads absent with a client attached"

fm_backend_target_exists tmux "no-such-session:no-such-window" \
  && fail "a window in a session that does not exist must not read as present"
pass "tmux presence: a window in a nonexistent session reads absent"

fm_backend_target_exists tmux "$SESSION:idle" \
  || fail "a live window must still read as present"
pass "tmux presence: a live window reads present"

fm_backend_target_exists tmux "idle" \
  || fail "the legacy bare window-name form must still resolve a live window"
fm_backend_target_exists tmux "no-such-window" \
  && fail "the legacy bare window-name form must not read an absent window as present"
pass "tmux presence: the legacy bare window-name form resolves present and absent correctly"

# The id and index target forms firstmate itself uses: the away-mode daemon
# takes its supervisor pane from $TMUX_PANE (a `%pane-id`) and otherwise falls
# back to the `firstmate:0` session:index default. A presence rule that only
# understood session:name would report both of those absent.
live_pane=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:idle" '#{pane_id}')
live_window=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:idle" '#{window_id}')
live_index=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:idle" '#{window_index}')
[ -n "$live_pane" ] && [ -n "$live_window" ] && [ -n "$live_index" ] \
  || fail "could not read the live window's own ids, so the id-form cases would prove nothing"

fm_backend_target_exists tmux "$live_pane" \
  || fail "a live pane id ($live_pane) must read present"
fm_backend_target_exists tmux "$live_window" \
  || fail "a live window id ($live_window) must read present"
fm_backend_target_exists tmux "$SESSION:$live_index" \
  || fail "a live session:index target must read present"
pass "tmux presence: live pane-id, window-id, and session:index targets read present"

fm_backend_target_exists tmux "%99999" \
  && fail "an absent pane id must read absent, not inherit the client's own pane"
fm_backend_target_exists tmux "@99999" \
  && fail "an absent window id must read absent"
fm_backend_target_exists tmux "no-such-session:0" \
  && fail "a session:index target in a nonexistent session must read absent"
pass "tmux presence: absent pane-id, window-id, and session:index targets read absent"

# The pane-qualified `session:window.pane` forms, which the two presence entry
# points answer DIFFERENTLY on purpose. firstmate never records one, so the
# recorded-endpoint primitive must reject it; docs/configuration.md documents
# FM_SUPERVISOR_TARGET as an unrestricted tmux target, so the supervisor variant
# must accept it rather than let fm-supervise-daemon.sh hard-exit at startup.
new_window presence-pane "$SLEEP_BIN" 900
"$REAL_TMUX" -L "$SOCKET" split-window -d -t "$SESSION:presence-pane" -c "$LAB/wt" -- "$SLEEP_BIN" 900 \
  || fail "could not split the pane-qualified presence window"
pane_index=$("$REAL_TMUX" -L "$SOCKET" list-panes -t "$SESSION:presence-pane" -F '#{pane_index}' | tail -1)
pane_window_index=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:presence-pane" '#{window_index}')
pane_window_name=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:presence-pane" '#{window_name}')
[ -n "$pane_index" ] && [ "$pane_index" != 0 ] && [ -n "$pane_window_index" ] \
  || fail "the split pane never appeared, so the pane-qualified cases would prove nothing"
[ "$pane_window_name" = presence-pane ] \
  || fail "the split window is named '$pane_window_name', so the session-less cases below would target the wrong window"

# The same anti-vacuous guard the cases above carry: tmux must still answer an
# absent pane-qualified target from some OTHER pane, or these assertions stop
# covering the fallback they exist for.
raw_pane_readback=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:presence-pane.99" \
  '#{session_name}:#{window_name}.#{pane_index}' 2>/dev/null) \
  || fail "display-message failed for an absent pane-qualified target, so the fallback is not live in this tmux"
[ "$raw_pane_readback" != "$SESSION:presence-pane.99" ] \
  || fail "display-message did not fall back for an absent pane (read back '$raw_pane_readback')"

fm_backend_supervisor_target_exists tmux "$SESSION:presence-pane.$pane_index" \
  || fail "a live session:name.pane supervisor target must read present"
fm_backend_supervisor_target_exists tmux "$SESSION:$pane_window_index.$pane_index" \
  || fail "a live session:index.pane supervisor target must read present"
pass "tmux presence: live pane-qualified supervisor targets read present"

fm_backend_supervisor_target_exists tmux "$SESSION:presence-pane.99" \
  && fail "an absent pane in a live window must read absent, not inherit the window's live pane"
fm_backend_supervisor_target_exists tmux "$SESSION:no-such-window.0" \
  && fail "a pane-qualified supervisor target naming an absent window must read absent"
fm_backend_supervisor_target_exists tmux "no-such-session:0.0" \
  && fail "a pane-qualified supervisor target in a nonexistent session must read absent"
pass "tmux presence: absent pane-qualified supervisor targets read absent"

# The SESSION-LESS pane-qualified forms, `name.pane` and `index.pane`. tmux
# accepts a bare `main.1` as a target-pane, and the strict primitive carries the
# session-less bare `#{window_index}` and `#{window_name}` candidates, so the
# supervisor variant must carry their pane-qualified counterparts or a live
# operator-typed `main.1` reads absent and fm-supervise-daemon.sh hard-exits.
raw_bare_pane_readback=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$pane_window_name.99" \
  '#{window_name}.#{pane_index}' 2>/dev/null) \
  || fail "display-message failed for an absent session-less pane-qualified target, so the fallback is not live in this tmux"
[ "$raw_bare_pane_readback" != "$pane_window_name.99" ] \
  || fail "display-message did not fall back for an absent session-less pane (read back '$raw_bare_pane_readback')"

fm_backend_supervisor_target_exists tmux "$pane_window_name.$pane_index" \
  || fail "a live session-less name.pane supervisor target must read present"
fm_backend_supervisor_target_exists tmux "$pane_window_index.$pane_index" \
  || fail "a live session-less index.pane supervisor target must read present"
pass "tmux presence: live session-less pane-qualified supervisor targets read present"

fm_backend_supervisor_target_exists tmux "$pane_window_name.99" \
  && fail "an absent pane in a live window must read absent through the session-less form too"
fm_backend_supervisor_target_exists tmux "no-such-window.0" \
  && fail "a session-less pane-qualified target naming an absent window must read absent"
pass "tmux presence: absent session-less pane-qualified supervisor targets read absent"

# The supervisor variant must not leak into the recorded-endpoint primitive. The
# strict read judges the same live pane-qualified targets absent, because for a
# RECORDED endpoint `sess:A.B` can only mean the window named `A.B`.
fm_backend_target_exists tmux "$SESSION:presence-pane.$pane_index" \
  && fail "the recorded-endpoint read must not accept a pane-qualified target"
fm_backend_target_exists tmux "$SESSION:$pane_window_index.$pane_index" \
  && fail "the recorded-endpoint read must not accept a session:index.pane target"
fm_backend_target_exists tmux "$pane_window_name.$pane_index" \
  && fail "the recorded-endpoint read must not accept a session-less name.pane target"
fm_backend_target_exists tmux "$pane_window_index.$pane_index" \
  && fail "the recorded-endpoint read must not accept a session-less index.pane target"
pass "tmux presence: the recorded-endpoint read rejects pane-qualified targets the supervisor read accepts"

# The false alive that pane-qualified matching re-opens for recorded endpoints.
# firstmate task ids permit `.` (see bin/fm-backend.sh's charset), so a recorded
# window may legitimately be NAMED fm-dot.0 - and tmux splits a target at its
# LAST dot, resolving that exact string to the DIFFERENT live window fm-dot,
# pane 0. Nothing here is named fm-dot.0, so a present verdict is a dead
# endpoint reading as alive.
new_window fm-dot "$SLEEP_BIN" 900
dot_pane_readback=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:fm-dot.0" \
  '#{session_name}:#{window_name}.#{pane_index}' 2>/dev/null) \
  || fail "display-message failed for the dotted-name target, so the false-alive case is not live in this tmux"
[ "$dot_pane_readback" = "$SESSION:fm-dot.0" ] \
  || fail "tmux did not resolve '$SESSION:fm-dot.0' pane-wise (read back '$dot_pane_readback'), so this case would prove nothing"
"$REAL_TMUX" -L "$SOCKET" list-windows -a -F '#{session_name}:#{window_name}' \
  | LC_ALL=C grep -Fqx -- "$SESSION:fm-dot.0" \
  && fail "a window really is named fm-dot.0, so this case would assert the wrong thing"

fm_backend_target_exists tmux "$SESSION:fm-dot.0" \
  && fail "a recorded dotted-name endpoint that is gone must read absent, not inherit window fm-dot pane 0"
fm_backend_target_exists tmux "$SESSION:fm-dot" \
  || fail "the live window the dotted target resolves to is not present, so the case above would prove nothing"
pass "tmux presence: a gone dotted-name recorded endpoint reads absent even though tmux resolves it pane-wise"

# A ghost target that is a strict prefix of a live window name. tmux target
# selectors match by pattern and substring, so a selector-based probe reports
# this absent task as present.
new_window fm-presence-abc "$SLEEP_BIN" 900
fm_backend_target_exists tmux "$SESSION:fm-presence-abc" \
  || fail "the substring-bait window is not present, so the prefix case would prove nothing"
fm_backend_target_exists tmux "$SESSION:fm-presence-ab" \
  && fail "a ghost target that is a prefix of a live window name must read absent, not match by substring"
pass "tmux presence: a ghost target that is a prefix of a live window name reads absent"

# A live window whose name is digit-shaped. tmux reads such a name as an index
# through a target selector, so the `=name` exact-match form reports this LIVE
# window absent - a false absence, the direction that can relaunch onto live
# work.
new_window 9.9.221 "$SLEEP_BIN" 900
fm_backend_target_exists tmux "$SESSION:9.9.221" \
  || fail "a live window with a digit-shaped name must read present, not be lost to selector index parsing"
fm_backend_target_exists tmux "$SESSION:9.9.999" \
  && fail "an absent digit-shaped window name must still read absent"
pass "tmux presence: a live window with a digit-shaped name reads present and its ghost sibling reads absent"

cleanup_all
trap - EXIT
