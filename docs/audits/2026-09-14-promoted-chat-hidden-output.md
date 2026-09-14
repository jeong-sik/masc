# Promoted chat hid output while the Keeper kept working

## Observed incident

The operator sent `얼마나 했삼?` to `msx-retro-mania` at
2026-09-14 15:24:59 KST. Operation
`tui-01a09e97-1ed6-7000-bbd5-48e000b0b44d` was admitted at
1789367099.099418 and started at 1789367099.102223: about 3 ms of queue wait.
The running server reported embedded build `c9505f8228bfe5144db0633ea713c65956cd5969`.

Its durable chat event journal contains 266 public `text_delta` events.
The first public delta is sequence 57 at 1789367105.811106, about 6.7 seconds
after admission. The run trace contains the matching public statement that it
will check the current state, followed by an unloaded-machine observation,
Board lookups, a detailed progress answer, and further game-recovery tools.
The operation was interrupted at 1789367668.561282. Public output existed
while execution was ongoing; it was not waiting for the queue to empty.

The operator screenshot instead showed the promoted USER tail labelled
`sent · the running turn answers it` and a running-operation footer, without
the live answer. No hidden reasoning content is needed to establish the defect.

Evidence sources on the operator workspace (not copied into the repository):

- `keepers/msx-retro-mania/chat-operations.sqlite3`, exact operation above.
- `keeper_chat_events/msx-retro-mania/<operation>.jsonl`, public event types,
  timestamps and sequence numbers.
- `keepers/msx-retro-mania/raw-traces/turn-1789367099809-3279-000001.jsonl`,
  public assistant text and tool-execution records.

## Cause and correction

The TUI accepted live text into its transcript, but `render_keeper_message`
excluded the entire live block whenever `promoted_inflight_for_keeper` returned
a request. `compute_chat_rows_for` also removed that request's history rows.
Only a separate USER tail survived. Promotion changes how an input is admitted;
it must not decide whether the corresponding output can be shown.

Promoted requests now use the ordinary user/history/live timeline. The special
USER tail and both blanket suppression conditions are removed. Execution,
queue admission, model choice and completion authority are unchanged.

The renderer regression feeds public text before and after a tool while the
operation is still running. It also covers success, failure, cancellation and
overlapping journal replay, checking that the USER and both public text spans
appear once. Source parsing is not a behavioral test; CI must run the renderer
suite before this correction is considered verified.

## Separate incident after restart

The replacement server on port 61952 reported build
`f5bd87c812f64eea9cb63fd8d7cedab1bea77cf9`. A second input remained queued.
Its log reports chat-store unavailability and later repeats
`begin operation transaction: rc=IOERR detail=disk I/O error` through the Owner
metadata commit path. This is a separate execution-admission failure; showing
live output does not repair storage. The underlying filesystem/SQLite I/O cause
has not been established. No restart, queue deletion or live database mutation
was performed during this diagnosis.
