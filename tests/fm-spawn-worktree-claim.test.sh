#!/usr/bin/env bash
# Regression test for bin/fm-spawn.sh's refusal to launch a task into a worktree
# another live task already records (bin/fm-worktree-claim-lib.sh).
#
# A treehouse pool slot frees when its lease is released, which includes a task
# whose harness session merely died. Observed live on 18-19 August 2026: a
# scout's `treehouse get` was handed the exact copy a still-live bench task
# recorded, the scout picked up an instruction meant for the bench task and
# opened a PR from the shared copy, and cleanup of either task would have run
# `treehouse return --force` over the other's work.
#
# validate_spawn_worktree only proves the resolved copy is a real worktree that
# is not the primary checkout, so it accepted the collision. These cases drive
# the spawn end to end with a fake tmux and a recording fake treehouse and
# assert: a claimed worktree refuses, hands the copy back with a NON-forced
# `treehouse return`, and records no task metadata; an unclaimed one still
# launches; and a symlinked prefix cannot hide the collision.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-claim)

# A fake tmux whose pane_current_path always answers FM_FAKE_PANE_PATH (the
# worktree treehouse get "moved" the pane into), plus a treehouse that appends
# every invocation to FM_FAKE_TREEHOUSE_LOG so the test can prove whether the
# copy was handed back, and with which flags.
make_claim_fakebin() {  # <case-dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# Build a home with a project, one real worktree standing in for the pooled copy
# the pane lands in, and a brief for <id>. Echoes a pipe-joined record.
make_claim_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  log="$case_dir/treehouse.log"
  fakebin=$(make_claim_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  : > "$log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$log"
}

read_claim_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR TREEHOUSE_LOG <<REC
$1
REC
}

# Record another live task that already holds <worktree>. The meta file IS the
# claim: fm-teardown.sh removes it as the last step of cleanup.
claim_worktree_for() {  # <task-id> <worktree>
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=firstmate:fm-$1" \
    "endpoint_task_id=$1" \
    "worktree=$2" \
    "project=$PROJ_DIR" \
    "kind=ship" \
    "mode=no-mistakes"
}

run_claim_spawn() {  # <task-id> [pane-path]
  local id=$1 pane=${2:-$WT_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

test_claimed_worktree_refuses_and_is_returned() {
  local rec id holder out status
  id=claim-refused-k1
  holder=claim-holder-k2
  rec=$(make_claim_case claim-refused "$id")
  read_claim_record "$rec"
  claim_worktree_for "$holder" "$WT_DIR"

  set +e
  out=$(run_claim_spawn "$id")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "spawn succeeded into a worktree $holder already holds"
  assert_contains "$out" "$holder" "the refusal did not name the task holding the worktree"
  assert_contains "$out" "$WT_DIR" "the refusal did not name the shared worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn still recorded task metadata for the shared worktree"
  assert_grep "return $WT_DIR" "$TREEHOUSE_LOG" \
    "the refused spawn did not hand the worktree back to the pool"
  assert_no_grep "return --force" "$TREEHOUSE_LOG" \
    "the refused spawn used a forced return over another task's copy"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$holder.meta" \
    "the refusal disturbed the holding task's own record"
  pass "a spawn into a worktree another live task records refuses and returns the copy"
}

test_unclaimed_worktree_still_launches() {
  local rec id out
  id=claim-clear-k3
  rec=$(make_claim_case claim-clear "$id")
  read_claim_record "$rec"

  out=$(run_claim_spawn "$id") || fail "spawn failed on an unclaimed worktree: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success on an unclaimed worktree"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the unclaimed worktree"
  pass "a spawn into a worktree no other task records still launches"
}

test_retired_holder_frees_the_worktree() {
  local rec id holder out
  id=claim-retired-k4
  holder=claim-gone-k5
  rec=$(make_claim_case claim-retired "$id")
  read_claim_record "$rec"
  claim_worktree_for "$holder" "$WT_DIR"
  # Cleanup of the holding task removes its record, which releases the claim.
  rm -f "$HOME_DIR/state/$holder.meta"

  out=$(run_claim_spawn "$id") || fail "spawn failed after the holding task was cleaned up: $out"
  assert_contains "$out" "spawned $id" "spawn did not launch once the holder's record was gone"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the released worktree"
  pass "a worktree is free again once the holding task's record is gone"
}

test_symlinked_prefix_cannot_hide_the_claim() {
  local rec id holder out status link
  id=claim-symlink-k6
  holder=claim-symlink-holder-k7
  rec=$(make_claim_case claim-symlink "$id")
  read_claim_record "$rec"
  # The holder recorded the same copy through a symlinked prefix. A raw string
  # comparison would call these two different worktrees; a real-path one does not.
  link="$TMP_ROOT/claim-symlink/wt-link"
  ln -s "$WT_DIR" "$link"
  claim_worktree_for "$holder" "$link"

  set +e
  out=$(run_claim_spawn "$id")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "a symlinked prefix hid the collision from the spawn"
  assert_contains "$out" "$holder" "the refusal did not name the task holding the symlinked copy"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn still recorded task metadata for the symlinked shared worktree"
  pass "a symlinked prefix in the holder's record does not hide the collision"
}

test_claimed_worktree_refuses_and_is_returned
test_unclaimed_worktree_still_launches
test_retired_holder_frees_the_worktree
test_symlinked_prefix_cannot_hide_the_claim

echo "# all fm-spawn-worktree-claim tests passed"
