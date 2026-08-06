#!/usr/bin/env bash
# Behavior tests for the safety-surface check.
#
# Every case runs against fixtures rather than the repository's own AGENTS.md:
# the check's job is to fail when a manifest sentence leaves the surface, and
# that failure can only be exercised on a surface the test is free to mutate.
# CI runs bin/fm-safety-surface-check.sh against the real AGENTS.md separately.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-safety-surface-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-safety-surface)

FIRST_SENTENCE="Never merge a red PR."
SECOND_SENTENCE="Never force teardown without explicit discard authority."

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected', got a pass"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

write_surface() {
  # $1 = destination, $2 = "full" or the sentence to leave out.
  local dest=$1
  local omit=$2
  : > "$dest"
  {
    printf '%s\n' '# Fixture surface'
    printf '%s\n' ''
    [ "$omit" = "$FIRST_SENTENCE" ] || printf '%s\n' "$FIRST_SENTENCE"
    [ "$omit" = "$SECOND_SENTENCE" ] || printf '%s\n' "   $SECOND_SENTENCE"
  } >> "$dest"
}

write_manifest() {
  # $1 = destination, $2 = one of: full, no-rules, empty-sentences, blank-sentence.
  local dest=$1
  local mode=$2
  case "$mode" in
    full)
      cat > "$dest" <<JSON
{
  "version": 1,
  "surface": "SURFACE.md",
  "rules": [
    {
      "id": "never-merge-red",
      "rule": "Never merge a red PR",
      "section": "fixture",
      "sentences": ["$FIRST_SENTENCE"]
    },
    {
      "id": "never-force-teardown",
      "rule": "Never force teardown without discard authority",
      "section": "fixture",
      "sentences": ["$SECOND_SENTENCE"]
    }
  ]
}
JSON
      ;;
    no-rules)
      cat > "$dest" <<'JSON'
{
  "version": 1,
  "surface": "SURFACE.md",
  "rules": []
}
JSON
      ;;
    empty-sentences)
      cat > "$dest" <<'JSON'
{
  "version": 1,
  "surface": "SURFACE.md",
  "rules": [
    {"id": "never-merge-red", "rule": "Never merge a red PR", "section": "fixture", "sentences": []}
  ]
}
JSON
      ;;
    blank-sentence)
      cat > "$dest" <<'JSON'
{
  "version": 1,
  "surface": "SURFACE.md",
  "rules": [
    {"id": "never-merge-red", "rule": "Never merge a red PR", "section": "fixture", "sentences": ["   "]}
  ]
}
JSON
      ;;
    *)
      fail "unknown manifest mode: $mode"
      ;;
  esac
}

new_fixture() {
  # $1 = fixture name. Echoes its root; caller writes the surface and manifest.
  local repo="$TMP_ROOT/$1"
  mkdir -p "$repo"
  printf '%s\n' "$repo"
}

test_complete_surface_passes() {
  local repo
  repo=$(new_fixture pass)
  write_surface "$repo/SURFACE.md" full
  write_manifest "$repo/manifest.json" full
  local out
  out=$("$CHECK" --root "$repo" --manifest manifest.json) \
    || fail "check rejected a surface carrying every manifest sentence"
  assert_contains "$out" "ok rules=2 sentences=2" \
    "check did not report how much it actually verified"
  assert_contains "$out" "surface=SURFACE.md" \
    "check did not report which surface it read"
  pass "a surface carrying every manifest sentence passes, reporting the counts it proved"
}

test_missing_sentence_fails_and_names_it() {
  local repo
  repo=$(new_fixture missing-one)
  write_manifest "$repo/manifest.json" full

  write_surface "$repo/SURFACE.md" "$FIRST_SENTENCE"
  run_expect_failure "$FIRST_SENTENCE" "$CHECK" --root "$repo" --manifest manifest.json
  run_expect_failure "rule never-merge-red" "$CHECK" --root "$repo" --manifest manifest.json

  # The second sentence is indented in the fixture, proving the check matches
  # the sentence itself rather than a whole line, and still catches its removal.
  write_surface "$repo/SURFACE.md" "$SECOND_SENTENCE"
  run_expect_failure "$SECOND_SENTENCE" "$CHECK" --root "$repo" --manifest manifest.json
  run_expect_failure "rule never-force-teardown" "$CHECK" --root "$repo" --manifest manifest.json
  pass "removing any single manifest sentence fails the check and names that sentence"
}

test_reworded_sentence_fails() {
  local repo
  repo=$(new_fixture reworded)
  write_manifest "$repo/manifest.json" full
  write_surface "$repo/SURFACE.md" "$FIRST_SENTENCE"
  printf '%s\n' 'Never merge a red pull request.' >> "$repo/SURFACE.md"
  run_expect_failure "$FIRST_SENTENCE" "$CHECK" --root "$repo" --manifest manifest.json
  pass "a reworded safety sentence fails: the guarantee is the exact wording"
}

test_empty_and_missing_manifest_refuse() {
  local repo
  repo=$(new_fixture vacuous)
  write_surface "$repo/SURFACE.md" full

  write_manifest "$repo/manifest.json" no-rules
  run_expect_failure "lists no safety rules" "$CHECK" --root "$repo" --manifest manifest.json

  write_manifest "$repo/manifest.json" empty-sentences
  run_expect_failure "lists no sentences" "$CHECK" --root "$repo" --manifest manifest.json

  write_manifest "$repo/manifest.json" blank-sentence
  run_expect_failure "has an empty sentence" "$CHECK" --root "$repo" --manifest manifest.json

  run_expect_failure "manifest is missing" "$CHECK" --root "$repo" --manifest absent.json

  printf '%s\n' 'not json' > "$repo/broken.json"
  run_expect_failure "manifest is unreadable" "$CHECK" --root "$repo" --manifest broken.json
  pass "an empty, vacuous, missing, or unreadable manifest refuses instead of passing"
}

test_missing_surface_refuses() {
  local repo
  repo=$(new_fixture no-surface)
  write_manifest "$repo/manifest.json" full
  run_expect_failure "safety surface is missing" "$CHECK" --root "$repo" --manifest manifest.json

  : > "$repo/SURFACE.md"
  run_expect_failure "safety surface is empty" "$CHECK" --root "$repo" --manifest manifest.json
  pass "a missing or empty safety surface refuses instead of passing"
}

test_complete_surface_passes
test_missing_sentence_fails_and_names_it
test_reworded_sentence_fails
test_empty_and_missing_manifest_refuse
test_missing_surface_refuses
