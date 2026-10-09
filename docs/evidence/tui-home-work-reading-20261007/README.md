# Dashboard and Work reading surfaces

Stack parent: #41712.

Dashboard decisions and continuation destinations now precede passive context.
Opening notices and decision receipts reserve their rows before the decision
window is sized. The shared window calculation also guides selection scrolling. Candle summary rows and compact
status are alternatives, rather than repeated readings.

Work uses compact wrapped Goal/Backlog summaries at every width. Removing the
wide summary cards does not remove counts, retained Goal history, selected
details or baseline/current snapshot provenance. Dashboard, Work and Task titles
omit the decorative wall clock; connection identity remains.

## Verification scope

| Changed path | Direct consumer | Evidence |
| --- | --- | --- |
| `render_overview` row order | Home selection/window, notices, summaries and composer budget | Source review; manual check in a rebuilt TUI pending |
| `render_planning_list` compact summaries and title | Goal list height, selection, filter and connection badge | Planning title boundary follows its connection badge; manual check at wide and narrow widths pending |
| `task_detail_pane` title | Task detail body/scroll geometry | Source review; manual check pending |

The stack is type-checked with `dune build --root . @check`; the PR comments
name the run and the head it covered. `source-checks.json` records the parser
check and SHA-256 of `bin/masc_tui_render.ml`, `bin/masc_tui_home.ml` and
`bin/masc_tui_home.mli` in this layer's tree. Behavior suites were not run. Tests do
not pin screen wording, widths or row order (`docs/constitution.xml` execution
protocol), so layout is checked by hand.

Earlier independent review predates the notice-budget repair and does not
certify its final diff. Current-head review evidence is recorded in the PR.
Remaining surfaces and actual render validation stay open in the
[consistency ledger](../../design/tui/CONSISTENCY-PROGRESS.md).
