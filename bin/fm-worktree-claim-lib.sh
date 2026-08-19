# shellcheck shell=bash
# Shared "who already claims this worktree" scan.
# Usage: . bin/fm-worktree-claim-lib.sh   (requires fm_meta_get from fm-backend.sh)
#
# Treehouse hands out worktrees from a shared pool, and a pool slot frees when
# its lease is released - including when a task's harness session merely dies
# overnight. The task's own durable record still names that worktree, so a later
# `treehouse get` can hand the very same copy to a second task. Observed live on
# 18-19 August 2026: two tasks recorded the same worktree=, one picked up an
# instruction meant for the other and opened a PR from the shared copy, a steer
# sent to the first sat unsubmitted, and cleanup of either would have run
# `treehouse return --force` over the other's work.
#
# The claim is the durable record, not the process: bin/fm-teardown.sh removes
# state/<id>.meta as the last step of cleanup, so a meta file that still exists
# is a task that still holds whatever it names. That makes the scan cheap,
# restart-proof, and independent of whether the holder's endpoint is alive - the
# incident happened precisely because the holder's session was dead.
#
# Scope: this home's own state directory. Each firstmate home records only its
# own direct reports, so a cross-home collision is a different problem with a
# different owner (docs/architecture.md).
#
# The pool lease remains the primary mutual exclusion between two live spawns.
# This scan is the backstop for the case the lease cannot cover: a slot the pool
# has already released while a task's durable record still names it.

# fm_worktree_claim_canonical: the physically-resolved path of <path>, falling
# back to the literal string when it cannot be resolved. Callers compare these,
# never raw input, so a symlinked prefix (macOS's /tmp -> /private/tmp, a
# symlinked pool root) cannot hide a collision - the same `pwd -P` comparison
# bin/fm-spawn.sh's validate_spawn_worktree already relies on. The fallback
# keeps a collision visible once the directory is gone, where the two records
# can only be compared as text.
fm_worktree_claim_canonical() {  # <path>
  local path=$1 real
  [ -n "$path" ] || return 1
  if real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# fm_worktree_claim_holders: every OTHER live task in <state-dir> whose durable
# record already claims <worktree-path> (compared as resolved real paths) or,
# when non-empty, <orca-worktree-id> (compared literally - an Orca worktree id
# is an opaque handle, not a path).
#
# Prints one "<task-id> <field>[,<field>]" line per holding task, returning 0
# when at least one was printed and 1 when nothing else claims it. An Orca task
# normally matches on both fields at once, so the fields of one holder are
# merged into that holder's single line rather than naming it twice.
fm_worktree_claim_holders() {  # <state-dir> <self-task-id> <worktree-path> [<orca-worktree-id>]
  local state=$1 self=$2 wt=$3 orca=${4:-}
  local meta holder fields wt_real holder_wt holder_orca found=1
  [ -d "$state" ] || return 1
  [ -n "$wt" ] || [ -n "$orca" ] || return 1
  wt_real=
  [ -z "$wt" ] || wt_real=$(fm_worktree_claim_canonical "$wt")
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    if [ -L "$meta" ]; then
      continue
    fi
    holder=${meta##*/}
    holder=${holder%.meta}
    if [ "$holder" = "$self" ]; then
      continue
    fi
    fields=
    if [ -n "$wt_real" ]; then
      holder_wt=$(fm_meta_get "$meta" worktree)
      if [ -n "$holder_wt" ] \
         && [ "$(fm_worktree_claim_canonical "$holder_wt")" = "$wt_real" ]; then
        fields=worktree
      fi
    fi
    if [ -n "$orca" ]; then
      holder_orca=$(fm_meta_get "$meta" orca_worktree_id)
      if [ -n "$holder_orca" ] && [ "$holder_orca" = "$orca" ]; then
        if [ -z "$fields" ]; then
          fields=orca_worktree_id
        else
          fields="$fields,orca_worktree_id"
        fi
      fi
    fi
    if [ -n "$fields" ]; then
      printf '%s %s\n' "$holder" "$fields"
      found=0
    fi
  done
  return "$found"
}

# fm_worktree_claim_describe: the holder lines from fm_worktree_claim_holders
# rendered as one clause for a refusal message, e.g.
# "task-a (worktree), task-b (worktree,orca_worktree_id)".
fm_worktree_claim_describe() {  # <holder-lines>
  local lines=$1 id fields out=
  while read -r id fields; do
    [ -n "$id" ] || continue
    if [ -z "$out" ]; then
      out="$id ($fields)"
    else
      out="$out, $id ($fields)"
    fi
  done <<EOFHOLDERS
$lines
EOFHOLDERS
  printf '%s\n' "$out"
}
