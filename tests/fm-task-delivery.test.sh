#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
# The project directory is a real git repo with a real origin, because a push-mode
# spawn now re-reads that origin to confirm the brief's recorded landing place.
LAND_FIXTURE=fixture-owner/fixture-repo
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  git -C "$projects/proj" init -q
  git -C "$projects/proj" remote add origin "https://github.com/$LAND_FIXTURE.git"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

# A push mode records its verified landing place on the same contract line; a
# local-only brief has no push and records none. Pass <land> to override it.
write_brief() {  # <home> <id> [<recorded-mode>] [<recorded-land>]
  local home=$1 id=$2 mode=${3:-} land=${4:-}
  mkdir -p "$home/data/$id"
  if [ -z "$land" ]; then
    case "$mode" in
      no-mistakes|direct-PR) land=$LAND_FIXTURE ;;
    esac
  fi
  [ "$land" != none ] || land=
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    if [ -n "$mode" ]; then
      printf 'Delivery contract: mode=%s' "$mode"
      [ -z "$land" ] || printf ' land=%s' "$land"
      printf '\n'
    fi
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The brief's landing place is a pre-answered fact, so the spawn re-reads the clone
# it is about to hand the worker instead of trusting the record. A missing value, or
# one the repository already contradicts, must stop before any endpoint exists: that
# is the intake stop replacing the mid-run one, where a finished worker parked to ask
# where to push because the recorded target was not the one it could push to.
test_push_mode_spawn_verifies_the_recorded_landing_place() {
  local rec home proj fakebin out status mode
  rec=$(make_home landing)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  for mode in no-mistakes direct-PR; do
    write_brief "$home" "landing-missing-$mode" "$mode" none
    out=$(run_spawn "$home" "$fakebin" "landing-missing-$mode" "$proj" claude --mode "$mode" --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$mode: a brief with no landing place should exit non-zero"
    assert_contains "$out" "records no landing place for landing-missing-$mode" \
      "$mode: refusal did not name the missing landing place"
    assert_contains "$out" "re-scaffold it with bin/fm-brief.sh --land <owner/repo>" \
      "$mode: refusal did not say how to fix it"
    assert_absent "$home/state/landing-missing-$mode.meta" "$mode: refused spawn wrote task metadata"

    write_brief "$home" "landing-wrong-$mode" "$mode" other-owner/other-repo
    out=$(run_spawn "$home" "$fakebin" "landing-wrong-$mode" "$proj" claude --mode "$mode" --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$mode: a landing place the clone contradicts should exit non-zero"
    assert_contains "$out" "landing mismatch for landing-wrong-$mode" \
      "$mode: refusal did not name the task"
    assert_contains "$out" "the brief says land=other-owner/other-repo" \
      "$mode: refusal did not show the recorded landing place"
    assert_contains "$out" "is $LAND_FIXTURE" "$mode: refusal did not show the repository's own origin"
    assert_absent "$home/state/landing-wrong-$mode.meta" "$mode: refused spawn wrote task metadata"

    # The agreeing case clears the check and only fails later, at the refusing tmux.
    write_brief "$home" "landing-ok-$mode" "$mode"
    out=$(run_spawn "$home" "$fakebin" "landing-ok-$mode" "$proj" claude --mode "$mode" --yolo off)
    assert_not_contains "$out" "landing mismatch" "$mode: an agreeing landing place was reported as a mismatch"
    assert_not_contains "$out" "records no landing place" "$mode: an agreeing landing place was reported as missing"
  done

  # A brief with no delivery contract line at all predates both fields, and already
  # warns on the mode check, so it is not additionally refused for a field its
  # generator never wrote.
  write_brief "$home" landing-legacy
  out=$(run_spawn "$home" "$fakebin" landing-legacy "$proj" claude --mode no-mistakes --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief stopped warning about its missing contract"
  assert_not_contains "$out" "records no landing place" "a legacy brief was refused a field its generator never wrote"

  # local-only never pushes, so it carries and is asked for no landing place.
  write_brief "$home" landing-local-only local-only
  out=$(run_spawn "$home" "$fakebin" landing-local-only "$proj" claude --mode local-only --yolo off)
  assert_not_contains "$out" "records no landing place" "a local-only spawn demanded a landing place it never uses"
  assert_not_contains "$out" "landing mismatch" "a local-only spawn checked a landing place it does not carry"
  pass "fm-spawn: a push-mode spawn confirms the brief's landing place against the clone's own origin"
}

# Comparison is against the repository, not the URL spelling, so an equivalent
# remote must not read as a contradiction while a different repository still does.
test_landing_comparison_survives_equivalent_remote_spellings() {
  local rec home proj fakebin out url
  rec=$(make_home landing-forms)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" landing-forms-c1 no-mistakes
  for url in "git@github.com:$LAND_FIXTURE.git" "https://github.com/$LAND_FIXTURE" \
             "ssh://git@github.com/$LAND_FIXTURE.git" "https://github.com/Fixture-Owner/Fixture-Repo.git"; do
    git -C "$proj" remote set-url origin "$url"
    out=$(run_spawn "$home" "$fakebin" landing-forms-c1 "$proj" claude --mode no-mistakes --yolo off)
    assert_not_contains "$out" "landing mismatch" "origin spelled '$url' was read as a different repository"
  done

  git -C "$proj" remote set-url origin "git@github.com:other-owner/other-repo.git"
  out=$(run_spawn "$home" "$fakebin" landing-forms-c1 "$proj" claude --mode no-mistakes --yolo off)
  assert_contains "$out" "landing mismatch" "a genuinely different repository was accepted"

  # An origin that names no owner/repo disproves nothing, so it warns rather than
  # refusing: an absent remote, and a local mirror in either spelling git accepts.
  for url in "$TMP_ROOT/local-mirror.git" "file://$TMP_ROOT/local-mirror.git"; do
    git -C "$proj" remote set-url origin "$url"
    out=$(run_spawn "$home" "$fakebin" landing-forms-c1 "$proj" claude --mode no-mistakes --yolo off)
    assert_not_contains "$out" "landing mismatch" "a local mirror spelled '$url' was reported as a contradiction"
    assert_contains "$out" "names no owner/repo to compare" "a local mirror spelled '$url' was not reported at all"
  done

  git -C "$proj" remote remove origin
  out=$(run_spawn "$home" "$fakebin" landing-forms-c1 "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "landing mismatch" "an absent origin was reported as a contradiction"
  assert_contains "$out" "names no owner/repo to compare" "an absent origin was not reported at all"
  git -C "$proj" remote add origin "https://github.com/$LAND_FIXTURE.git"
  pass "fm-spawn: equivalent remote spellings agree, a different repository refuses, an unreadable origin warns"
}

# The fork workflow that motivated the landing pre-answer fetches from the upstream
# and pushes to the fork, so the landing place must be verified against where a push
# actually goes. Verifying the fetch URL there would confirm a landing place no push
# ever reaches, which is the confidently wrong pre-answer this check exists to stop.
test_landing_is_verified_against_the_push_url() {
  local rec home proj fakebin out status
  rec=$(make_home landing-pushurl)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  git -C "$proj" remote set-url origin "https://github.com/upstream-owner/upstream-repo.git"
  git -C "$proj" remote set-url --push origin "https://github.com/$LAND_FIXTURE.git"

  write_brief "$home" landing-pushurl-f1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" landing-pushurl-f1 "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "landing mismatch" "the repository the clone actually pushes to was read as a contradiction"

  write_brief "$home" landing-pushurl-f2 no-mistakes upstream-owner/upstream-repo
  out=$(run_spawn "$home" "$fakebin" landing-pushurl-f2 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a landing place naming the fetch URL's repository should exit non-zero"
  assert_contains "$out" "landing mismatch for landing-pushurl-f2" "the fetch-only repository was accepted as a landing place"
  assert_contains "$out" "is $LAND_FIXTURE" "the refusal did not name the repository the clone pushes to"
  assert_absent "$home/state/landing-pushurl-f2.meta" "refused spawn wrote task metadata"

  # With no pushurl set, --push falls back to the fetch URL, so the common case is
  # unchanged and a clone that never joined a fork workflow still verifies.
  git -C "$proj" remote set-url --delete --push origin "https://github.com/$LAND_FIXTURE.git"
  git -C "$proj" remote set-url origin "https://github.com/$LAND_FIXTURE.git"
  out=$(run_spawn "$home" "$fakebin" landing-pushurl-f1 "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "landing mismatch" "a clone with no pushurl stopped verifying against its fetch URL"
  pass "fm-spawn: the landing place is verified against where the clone pushes, not where it fetches"
}

# An unfilled placeholder means the intake this brief depends on never finished, so
# the worker would be reading a template rather than instructions. {TASK} is on both
# the ship and scout scaffolds; the scope slots are ship-only.
test_spawn_refuses_a_brief_that_is_still_a_template() {
  local rec home proj fakebin out status placeholder n=0
  rec=$(make_home placeholders)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  for placeholder in '{TASK}' '{SCOPE_MUST_CHANGE}' '{SCOPE_MUST_NOT_TOUCH}'; do
    n=$((n + 1))
    write_brief "$home" "placeholder-d$n" no-mistakes
    printf 'Must change: %s\n' "$placeholder" >> "$home/data/placeholder-d$n/brief.md"
    out=$(run_spawn "$home" "$fakebin" "placeholder-d$n" "$proj" claude --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$placeholder: a brief still carrying it should exit non-zero"
    assert_contains "$out" "still carries unfilled placeholders ($placeholder)" \
      "$placeholder: refusal did not name the placeholder that is still unfilled"
    assert_contains "$out" "a worker cannot be launched against a template" \
      "$placeholder: refusal did not explain why a template cannot dispatch"
    assert_absent "$home/state/placeholder-d$n.meta" "$placeholder: refused spawn wrote task metadata"
  done

  # Every unfilled slot is named at once, so one relaunch settles them all.
  write_brief "$home" placeholder-all local-only
  printf 'Must change: {SCOPE_MUST_CHANGE}\nMust not touch: {SCOPE_MUST_NOT_TOUCH}\n' \
    >> "$home/data/placeholder-all/brief.md"
  out=$(run_spawn "$home" "$fakebin" placeholder-all "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "{SCOPE_MUST_CHANGE} {SCOPE_MUST_NOT_TOUCH}" \
    "a brief with two unfilled slots did not name both"

  # A filled brief clears the check and only fails later, at the refusing tmux.
  write_brief "$home" placeholder-filled no-mistakes
  out=$(run_spawn "$home" "$fakebin" placeholder-filled "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "unfilled placeholders" "a filled brief was refused as a template"

  # The scout scaffold emits the same {TASK} slot, so a scout brief that is still a
  # template cannot dispatch either. It carries no scope slots to check.
  write_brief "$home" placeholder-scout
  printf 'Investigate {TASK}.\n' >> "$home/data/placeholder-scout/brief.md"
  out=$(run_spawn "$home" "$fakebin" placeholder-scout "$proj" claude --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout brief still carrying {TASK} should exit non-zero"
  assert_contains "$out" "still carries unfilled placeholders ({TASK})" \
    "scout refusal did not name the placeholder that is still unfilled"
  assert_contains "$out" "a worker cannot be launched against a template" \
    "scout refusal did not explain why a template cannot dispatch"
  assert_absent "$home/state/placeholder-scout.meta" "refused scout spawn wrote task metadata"

  # A filled scout brief clears the check and only fails later, at the refusing tmux.
  write_brief "$home" placeholder-scout-filled
  out=$(run_spawn "$home" "$fakebin" placeholder-scout-filled "$proj" claude --scout)
  assert_not_contains "$out" "unfilled placeholders" "a filled scout brief was refused as a template"
  pass "fm-spawn: a ship or scout brief still carrying its scaffold placeholders cannot dispatch"
}

# The cases above build their briefs by hand, which cannot see what a real scaffold
# actually contains. Every brief scaffolded without --herdr-lab carries a fixed
# hard-safety paragraph that names `{TASK}` in prose, and firstmate is explicitly
# told not to hand-edit it, so a placeholder check reading the whole file refuses
# briefs whose slots are all correctly filled and blocks the default dispatch path
# entirely. This round-trips the real scaffold so that defect cannot come back.
test_a_filled_real_scaffold_dispatches() {
  local rec home proj fakebin brief out kind
  rec=$(make_home real-scaffold)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  for kind in ship scout; do
    if [ "$kind" = ship ]; then
      FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
        "$ROOT/bin/fm-brief.sh" "real-$kind" app --mode no-mistakes --land "$LAND_FIXTURE" >/dev/null 2>&1 \
        || fail "$kind: the real scaffold did not generate"
    else
      FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
        "$ROOT/bin/fm-brief.sh" "real-$kind" app --scout >/dev/null 2>&1 \
        || fail "$kind: the real scaffold did not generate"
    fi
    brief="$home/data/real-$kind/brief.md"

    # Assert the prose mention is really there, so this case cannot go vacuous if
    # that paragraph is ever reworded away.
    # shellcheck disable=SC2016  # single quotes are deliberate: this literal prose must not expand.
    grep -F 'replaces `{TASK}` later' "$brief" >/dev/null \
      || fail "$kind: the scaffold no longer carries the prose mention this case exists to cover"

    # Fill every slot exactly as firstmate does at intake, leaving the prose alone.
    sed -e 's/^{TASK}$/Do the real work./' \
        -e 's/^Must change: {SCOPE_MUST_CHANGE}$/Must change: bin\/foo.sh/' \
        -e 's/^Must not touch: {SCOPE_MUST_NOT_TOUCH}$/Must not touch: everything else/' \
        "$brief" > "$brief.filled"
    mv "$brief.filled" "$brief"

    if [ "$kind" = ship ]; then
      out=$(run_spawn "$home" "$fakebin" "real-$kind" "$proj" claude --mode no-mistakes --yolo off)
    else
      out=$(run_spawn "$home" "$fakebin" "real-$kind" "$proj" claude --scout)
    fi
    assert_not_contains "$out" "unfilled placeholders" \
      "$kind: a fully filled real scaffold was refused as a template"
  done
  pass "fm-spawn: a real scaffold with every slot filled dispatches despite the safety paragraph naming {TASK}"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing approval posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided approval posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_push_mode_spawn_verifies_the_recorded_landing_place
test_landing_comparison_survives_equivalent_remote_spellings
test_landing_is_verified_against_the_push_url
test_spawn_refuses_a_brief_that_is_still_a_template
test_a_filled_real_scaffold_dispatches
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_project_mode_maps_the_conditional_policy
echo "# all fm-task-delivery tests passed"
