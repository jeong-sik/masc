# Slack REST collection checkpoints

The optional `server_slack_poll_lane` collector fills `Slack_lane`'s existing
bounded recent-message ring from bound channels. It is independent of the
Browser-based Slack TUI and does not send Slack messages.

Slack history is newest-first. Advancing `oldest` after a partial fetch excludes
all older, unfetched pages. The collector instead fixes `oldest` and an upper
time boundary for each window, and moves `latest` backwards to the final message
timestamp after each successful page. Four pages per channel per cycle remains
the fairness boundary. Reaching it saves progress for the next scheduled cycle.

The checkpoint at `<base-path>/.gate/runtime/slack/poll-cursor.json` stores a
closed state for each channel:

- `idle`: committed high-water timestamp.
- `scanning`: original oldest/upper bounds, next latest boundary, newest observed
  timestamp, and the complete staged message set in chronological order.
- `ready`: completed staged messages awaiting publication and the prospective
  high-water timestamp; the previously committed oldest remains explicit.

Each successful page is atomically checkpointed before another fetch. A complete
window becomes `ready` on disk before its messages enter the ring. Only after
publication does the checkpoint become `idle` at the newest observed timestamp.
Using an observed timestamp also leaves messages exactly at the original upper
boundary eligible for the next window. A channel first seen starts at now;
existing unreadable or invalid checkpoints stop collection instead of resetting.

Fetch failures hold the current channel and allow other channels to proceed.
Checkpoint write failures stop the cycle: the next tick rereads disk before any
further transition. A `ready` checkpoint survives a failed publication or final
high-water write and replays on restart. Ring insertion deduplicates timestamps.
Strict atomic replacement provides process-restart recovery; this is not a claim
of hardware power-loss persistence.

Staged pages are retained until completion and publication. Once published, the
ring keeps only its configured recent-message capacity. This is collection
continuity, not a durable Slack archive or a promise that all historical messages
remain visible. Existing human-message and mention filters still apply.

The current staging implementation keeps the entire unfinished window in memory
and in the JSON checkpoint, without a separate message-count or byte cap. Every
page rewrites the checkpoint, including staged windows for other channels, so
large backlogs increase memory use, disk space, and write cost. The four-page
cycle limit bounds requests per channel per cycle; it does not bound cumulative
staging size. Disk write failures stop collection for replay, but this mechanism
does not establish a memory ceiling or archival capacity guarantee.

Protocol source checked 2026-09-07: [Slack conversations.history pagination by
time](https://docs.slack.dev/reference/methods/conversations.history/#pagination-by-time).
Slack documents exclusive timestamp boundaries and setting the final message's
`ts` as the next `latest`; opaque cursors are not persisted between poll cycles.

Behavior tests cover more than one cycle of pages, restart serialization, new
messages outside an unfinished window, fetch failures, checkpoint failures before
and after publication, missing continuation boundaries, and corrupted storage.
Compilation and the registered test suite must be verified by CI; local builds
are excluded by the repository execution protocol.
