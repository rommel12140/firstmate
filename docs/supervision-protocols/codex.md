Mode: Codex Stop-owned event notification.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Finish the turn when current work is handled.
   The tracked Stop hook invokes `bin/fm-codex-stop.sh`, which verifies its home-bound watcher and uses native `codex queue` to notify this exact primary thread when durable work arrives.
3. Ordinary notification: drain and handle the queued work, acknowledge it after handling, then finish the turn again.
   Native input queued during a busy turn remains pending until Codex can handle it.
4. Do not run recurring foreground checkpoints or start a background watcher tool.
   The Stop adapter owns watcher continuity and sources `__FM_X_MODE_ENV__` when present.
5. A notification or watcher failure is recoverable work: inspect `state/.codex-notify-failure` and `state/.codex-notify.log`, repair the reported path, then let the next Stop retry retained work.
   The existing turn-end guard and configured alarm remain active when the adapter cannot verify supervision.

This path requires a supported local Codex TUI with native `queue` access and a verified primary process owner.
It does not use Claude's `asyncRewake` field or asynchronous hook output to start idle turns.
[`watcher-continuity.md`](../watcher-continuity.md#codex-stop-notification) owns supported limits and recovery behavior.
