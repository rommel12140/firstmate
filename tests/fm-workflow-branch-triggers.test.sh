#!/usr/bin/env bash
# Behavior tests for the branch filters on this repo's two pull-request workflows.
#
# The filters are the whole mechanism behind batch landings: small tasks land on
# an open batch/YYYY-MM-DD branch through ordinary pull requests, the full
# validation pipeline runs once on the batch head, and one signed pull request
# takes the batch to main. That only works while CI's test suite covers pull
# requests aimed at batch/**, and while the signature gate stays main-only, which
# is what exempts batch landings from it with no rule change.
#
# Those two filters therefore have to diverge, and the divergence is easy to
# "fix" into consistency by mistake in either direction: widening the signature
# gate would demand a signed body on every small batch pull request, and
# narrowing CI back to main would leave those merges with no mechanical checking
# at all between batches. Both cases are silent - nothing fails until a real
# pull request behaves wrongly - so the decision is pinned here instead.
#
# The assertions are decisions, not file contents: each case asks whether a pull
# request against a given base branch would run that workflow, resolved through
# GitHub's own branch-filter glob semantics (`*` stops at `/`, `**` does not).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
SIGNATURE_WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
TMP_ROOT=$(fm_test_tmproot fm-workflow-branch-triggers)
RESOLVER="$TMP_ROOT/resolve-trigger.py"

# Reads one workflow's `on.<event>.branches` filter and answers whether a base
# branch is covered. It refuses a missing event or a missing branches filter
# rather than reporting "no match", so a restructured trigger fails the case it
# was meant to prove instead of passing vacuously.
cat > "$RESOLVER" <<'PY'
import re
import sys

workflow, event, base_ref = sys.argv[1], sys.argv[2], sys.argv[3]

with open(workflow, encoding="utf-8") as handle:
    lines = [line.rstrip("\n") for line in handle]


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_filler(line):
    """Blank lines and comments carry no structure, so they set no indent."""
    return not line.strip() or line.lstrip(" ").startswith("#")


def child_indent(body):
    """The indent a block's own entries share, or None when it has none."""
    indents = [indent_of(line) for line in body if not is_filler(line)]
    return min(indents) if indents else None


def block(lines, key, at_indent):
    """Lines under `key:` at `at_indent`, up to the next sibling or dedent."""
    for index, line in enumerate(lines):
        if is_filler(line):
            continue
        if indent_of(line) != at_indent:
            continue
        stripped = line.strip()
        if stripped == f"{key}:" or stripped.startswith(f"{key}: "):
            body = []
            pending = []
            for following in lines[index + 1:]:
                if is_filler(following):
                    pending.append(following)
                    continue
                following_indent = indent_of(following)
                if following_indent < at_indent:
                    break
                # A block sequence may sit at its own key's indent, so only a
                # non-item line at that indent is the next sibling key.
                if following_indent == at_indent and not following.strip().startswith("- "):
                    break
                body.extend(pending)
                pending = []
                body.append(following)
            return stripped, body
    return None, None


def unquote(token):
    token = token.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in ("'", '"'):
        return token[1:-1]
    return token


def branch_filter(lines, at_indent):
    header, body = block(lines, "branches", at_indent)
    if header is None:
        return None
    inline = header[len("branches:"):].strip()
    if inline.startswith("[") and inline.endswith("]"):
        inner = inline[1:-1].strip()
        return [unquote(item) for item in inner.split(",")] if inner else []
    if inline:
        return [unquote(inline)]
    entries = []
    for line in body:
        stripped = line.strip()
        if stripped.startswith("- "):
            entries.append(unquote(stripped[2:]))
    return entries


def matches(pattern, ref):
    """GitHub branch-filter globbing: * stops at /, ** does not."""
    regex = ""
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*":
            if pattern[index + 1:index + 2] == "*":
                regex += ".*"
                index += 2
                continue
            regex += "[^/]*"
            index += 1
            continue
        if char == "?":
            regex += "[^/]"
            index += 1
            continue
        regex += re.escape(char)
        index += 1
    return re.fullmatch(regex, ref) is not None


_, on_body = block(lines, "on", 0)
if on_body is None:
    sys.exit(f"{workflow}: no top-level 'on:' trigger block")

event_indent = child_indent(on_body)
if event_indent is None:
    sys.exit(f"{workflow}: 'on:' declares no triggers")

_, event_body = block(on_body, event, event_indent)
if event_body is None:
    sys.exit(f"{workflow}: 'on:' has no '{event}:' trigger")

filter_indent = child_indent(event_body)
patterns = branch_filter(event_body, filter_indent) if filter_indent is not None else None
if not patterns:
    sys.exit(f"{workflow}: '{event}:' declares no branch filter")

print("trigger" if any(matches(p, base_ref) for p in patterns) else "skip")
PY

resolve() {
  # $1 = workflow path, $2 = event, $3 = base branch. Prints trigger|skip.
  python3 "$RESOLVER" "$1" "$2" "$3"
}

assert_decision() {
  # $1 = workflow, $2 = event, $3 = base branch, $4 = expected, $5 = why
  local actual
  actual=$(resolve "$1" "$2" "$3") || fail "could not resolve $2 on $(basename "$1") for base '$3'"
  [ "$actual" = "$4" ] || fail "$5 (base '$3' resolved to '$actual', expected '$4')"
}

# The test suite has to reach pull requests aimed at a batch branch, because the
# full validation run happens once per batch rather than once per task.
test_ci_covers_main_and_batch_pull_requests() {
  assert_decision "$CI_WORKFLOW" pull_request main trigger \
    "CI stopped covering pull requests to main"
  assert_decision "$CI_WORKFLOW" pull_request batch/2026-08-07 trigger \
    "CI stopped covering pull requests to a batch branch, leaving small merges unchecked"
  assert_decision "$CI_WORKFLOW" pull_request batch/2026-08-07/retry trigger \
    "CI's batch pattern stopped crossing a slash, so a nested batch branch loses coverage"
  assert_decision "$CI_WORKFLOW" pull_request feature/some-work skip \
    "CI widened beyond main and batch branches"
  pass "ci.yml: pull requests to main and to batch branches both run the suite"
}

# Only main is a merge target where the whole batch, validated once, arrives.
# Widening this would put a signature requirement on every small batch landing,
# which is exactly the per-task pipeline cost the batch flow removes.
test_signature_gate_stays_main_only() {
  assert_decision "$SIGNATURE_WORKFLOW" pull_request main trigger \
    "the signature gate stopped covering pull requests to main"
  assert_decision "$SIGNATURE_WORKFLOW" pull_request batch/2026-08-07 skip \
    "the signature gate widened to batch branches, so batch landings are no longer exempt"
  assert_decision "$SIGNATURE_WORKFLOW" pull_request feature/some-work skip \
    "the signature gate widened beyond main"
  pass "no-mistakes-required.yml: the signature gate covers main only, exempting batch landings"
}

# Only the pull-request filter was widened. Pushes to a batch branch are covered
# by that branch's own pull requests, so a push trigger there would duplicate the
# same runs on every merge into the batch.
test_ci_push_trigger_stays_main_only() {
  assert_decision "$CI_WORKFLOW" push main trigger \
    "CI stopped running on pushes to main"
  assert_decision "$CI_WORKFLOW" push batch/2026-08-07 skip \
    "CI's push trigger widened to batch branches, duplicating every batch pull-request run"
  pass "ci.yml: the push trigger stayed on main"
}

test_ci_covers_main_and_batch_pull_requests
test_signature_gate_stays_main_only
test_ci_push_trigger_stays_main_only
