# Board child completion across parent interruption

Source baseline: `f8ffe1bfcbb77877f233bf3018b5339dbb9634db` (#43710).

## As-Is / To-Be / Before and After

| Aspect | Baseline | This layer |
| --- | --- | --- |
| Posts received while hearths still pending | No component observation until pair returns | Posts receipt and pending hearth reader observable independently |
| Parent fails or is cancelled before pair return | Parent result only; no returned component receipts | Already observed child results and clocks remain |
| Child starts / terminal observations per requested Board pair | 0 / 0 | 2 / 2 when both readers start and terminate |
| Known received posts and no terminal hearth observation at refresh end | Parent interrupted, no component evidence | Parent interrupted; posts received, hearth unfinished |
| Caught child cancellation | Not independently recorded | interrupted; distinct from unfinished |
| Child throws | Parent failed | Child failed with exception provenance, parent retains its own verdict |
| Progress delivery | Bounded mailbox insertion can suspend | Refresh-owned atomic inbox append without Eio wait |
| New HTTP / screen rows | Existing requests and rows | 0 / 0 added |

This is a source-derived observation comparison, not measured speedup or runtime
proof. The existing `Masc_tui_loader.read_pair` still uses `Eio.Fiber.pair` when
an Eio switch exists and synchronous calls otherwise. Parallelism and network work
are not added here. The Board wrapper reports directly around the real posts and
hearth readers, returns the same values and rethrows exceptions/cancellation.

## Ownership and settlement

The immutable ledger owns each component under its typed parent. Start must follow
parent start; completion must follow component start. Duplicate starts/completions,
unknown parents and post-terminal events cannot replace observed results. Ending
a parent or refresh marks only still-pending started children unfinished. Already
received, failed or cancelled child evidence is preserved. Logical-reader counts
are independent: a parent interrupted after posts succeeds remains interrupted,
not received or partial. Full returned Board success/partial/failure uses the same
availability matrix as the baseline.

All progress events, not just Board children, first enter an atomic list owned by
that refresh. UI drain reverses each captured batch to restore publication order.
Publication has no bounded mailbox insertion or cancellation checkpoint. Terminal
application drains before closing the ledger. Cold initial identity application
drains before preserving/rebinding the probe ledger; later callbacks carry the
acknowledged authority. Each successor allocates a fresh inbox. Old producers never
receive it; ticket and authority rejection still apply after collection. Retired
inboxes are session memory, not durable journals or restart recovery. There is no
new timer, action cap, retry, pool policy or configuration knob.

Dataset mailbox, workspace identity admission, Board source order, requests and
publication guards retain their separate contracts. Component receipt does not
publish posts/hearths, settle source ownership, authorize actions, finish a Task
or prove useful Keeper work. Existing Ask/Keeper early delivery is not changed.

## Timing and visibility

Only Board has independently instrumented child starts/ends here. Runtime and
Keeper/Candle components are still co-observed without individual clocks. Board
`elapsed_ms` is the monotonic interval between its observed boundaries, including
existing HTTP/decode/worker scheduling. For unfinished children the end is the
parent/refresh closure boundary, not physical worker termination. No duration is
inferred for an unstarted child and no overlapping child durations are summed.
The header identifies received/failed/cancelled/unfinished components while a
parent has not returned; it can name the pending child rather than just Board.
Returned successful reads add no persistent extra child notice. Paint, first
usable input, actual operation latency and production distributions are unmeasured.

## Evidence and remaining scope

Three feature/protocol scenarios are authored, unexecuted: a child receipt through
UI inbox drain and parent interruption without dataset authority; the four Board
availability combinations plus exception/cancellation evidence; and retired inbox,
old ticket and workspace withdrawal rejection. They inspect requested/retained
state and JSON metadata, not screen wording/layout/order or PTY output. Parsing
and diff metadata checks are recorded separately at publication; neither is typing,
scenario execution, independent approval, merge, installation or runtime proof.

The full objective remains preparation/discovery attribution and reuse, cold-start
input/readability/observability, Ask answer to original Task/useful work,
resource-owned ordinary/nested/dynamic/effectful Composition, held-job/shared
backend batches and matched Before/After retaining failed/cancelled/interrupted/
unfinished samples. This layer provides better evidence; no whole-goal completion
or measured loading improvement is claimed.
