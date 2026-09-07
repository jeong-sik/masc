# TUI outcomes and observation semantics

The previous Metrics screen counted every owner row as mid-turn, called
unpaused keepers running, and calculated task health from an active-only list.
Its 24-hour activity chart used a 60-second, latest-per-keeper transition glow
cache. None of those is a measure of completed work.

## Visible contract

- **Work & Outcomes:** creation, Done and cancellation timestamps in the last
  24 hours of the retained task snapshot; current open states, verification
  backlog, snapshot age and oldest open registration. This is not an event
  ledger: removed tasks and earlier states of reopened tasks are not recovered.
- **Current owner turns:** only owner-reported running rows, with idle and
  unavailable counted separately. `turn` age starts at the reported turn start.
  Failed observations do not keep presenting old rows as current execution.
- **Recent:** locally observed activity, not another current-execution table.
  `evt` is time since local receipt. `seen` counts observed tool rows in an
  open record; `total` is a confirmed completed-turn tool count. Missing totals
  are unknown. An open record without a running owner is `open/gap`.
- Unobserved GC/scheduler metrics and empty scheduler sample windows remain
  explicitly unknown. Ordinary and source facts are named separately. An empty
  YOLO list does not establish a universal approval policy.

The task summary is an immutable projection computed once when the durable
backlog refreshes. Rendering does not read files or parse task timestamps.
The recent-event cache remains for the existing transient activity glow; it
is no longer plotted as historical production.

## Validation

Focused tests cover window boundaries, creation versus completion timestamps,
verification versus completion, cancellation, invalid/future timestamps,
active-list independence, observation failures, missing telemetry, Recent
receipt/count semantics, and narrow pane navigation/line budgets.

Source review was performed independently. Local Dune builds were not run.
CI results and binary/UI observations will be recorded after they exist.
