# Keeper workbench: baseline and design options

The existing Keeper roster provides many operational facts, but the available
width and the scope of each observation determine what an operator can use.
This proposal follows the existing [TUI layout language](../design/tui/LAYOUT-LANGUAGE.md).
The [interactive comparison](2026-10-28-keeper-workbench-preview.html) uses
synthetic rows and browser layout; it is a design aid, not an executable TUI.

## Observed baseline

The [baseline record](../evidence/research/2026-10-28-keeper-workbench/README.md)
describes the source and capture boundary. At 190 × 52 the separate installed
TUI's roster contained many ellipses. At 120 × 32 and 80 × 24 only a page of
the fleet was visible. The wide frame devoted about ten cells to DETAIL beside
the Activity pane. An ellipsis is a marker, not a measurement of the bytes
omitted. A later Schedules observation explicitly limited its page to the
first 20. These are different, changing snapshots; workspace-specific counts
remain in the local working record instead of this shared document.

The installed executable at that observation predates the proposed stack; the
measurements are not proof that a proposed change is visible. The roster's
column allocator also reserves more runtime width when any Keeper is failing.
The source of the proposed compact layout gives that width back to work detail;
the detailed layout keeps runtime when it fits.

## Three possible starting points

| Direction | What it helps | Cost |
| --- | --- | --- |
| Integrated roster and selection | Scan state, select a Keeper, then see its observed task and next actions in context. | Fleet-wide scheduling and relationship exploration still need dedicated views. |
| Schedule first | Compare upcoming and due work across Keepers. | Current projection exposes a bounded first page, so a complete agenda needs a paging contract. |
| Relationship first | Follow recorded requests and outcomes between actors. | A fleet graph needs identified edges and their state; queued sender records alone do not prove a complete graph. |

The operator selected **integrated roster and selection** as the first
implementation direction on 2026-10-28. This selects the starting point; it
does not approve every detail of the final design. The other two directions
remain reachable views rather than being represented as complete by the first
increment.

## Interaction and presentation

- Keep the roster as the navigation anchor. Sort and layout choices survive
  restart, and a data refresh or change of sort preserves the selected Keeper
  by identity. Within grouped view, each group retains the selected sort.
- Groups communicate attention, active work, waits and inactive states. A
  failing or blocked item remains visible even if its colour cannot be seen.
  Existing theme tokens and short, consistently defined glyphs carry the same
  meaning without colour; avoid treating emoji width as a portable cell size.
- On a wide terminal retain the existing Activity pane and its Recent/Changes
  tabs. Show the selected Keeper's observed task, a waiting-schedule example,
  a delegate-result observation and direct actions before Activity content.
  Protect both content and keyboard focus when the available height changes.
  On a narrow terminal preserve the existing roster-to-detail transition,
  selected identity and scroll position instead of assuming a side pane.
- `J` goes to the selected Keeper's scoped schedule reading. Its source
  returns up to 200 requests; the fleet page returns up to 20. A waiting
  inventory item is an observation, not the Keeper's entire schedule count,
  nor proof that the item shown is the next due.
- `K` shows incoming queued requests only where a recorded Keeper sender
  identifies an edge. It reads one page; a queued delegate-result mark is not
  a list of active delegations. Unread, failed, partial, retained and
  workspace-mismatched readings must not be presented as empty or fresh.
- Filters, a full paginated fleet agenda, navigation among actual relationship
  edges and per-Keeper task/delegate drill-down are follow-up design and
  implementation work. Any complete graph requires typed node/edge identity,
  state, direction, coverage and freshness, rather than inferring edges from
  similar display names.

The [Grafana node graph contract](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/node-graph/)
is a useful precedent for explicitly identified sources and targets;
[OpenTelemetry's trace model](https://opentelemetry.io/docs/specs/otel/trace/api/)
distinguishes parent-child relationships from other causal links. Neither
implies MASC already records all edges. [K9s command and filtering
navigation](https://k9scli.io/topics/commands/) offers a precedent for a
keyboard-first resource list without replacing each resource's detail view.

## Implementation and verification boundaries

The proposed stacked source changes add roster layouts and persisted sort,
selected-Keeper schedules, a bounded queued-peer view, and a compact selected
context in the Activity pane. They do not implement a full fleet agenda or
complete delegate graph. The reference preview also illustrates future
directions that are not implemented by this increment.

Before calling the design visually verified, build a candidate for an exact
source head, observe it at the same terminal sizes and record the source,
binary, workspace, data and viewport. Compare the actual UI to this baseline;
do not substitute a browser mockup, source review or a private fixture for a
native runtime observation. No production installation or deployment is
implied by that verification.
