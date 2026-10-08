# Dashboard and Work reading surfaces

Stack base: `b3dc00b0b2f57fab8f1b801fbdfea5bdf9ae7e6d` (#41712, including
its subsequently added footer fixture dependency).

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
| `render_overview` row order | Home selection/window, notices, summaries and composer budget | Independent source review; focused Home layout/receipt/Candle PTY runs pending |
| `render_planning_list` compact summaries and title | Goal list height, selection, filter and connection badge | Planning title boundary follows its connection badge; registered Studio PTY expects compact summaries at wide and narrow widths; PTY run pending |
| `task_detail_pane` title | Task detail body/scroll geometry | Source review; executable rendering pending |

Changed OCaml source is checked with `ocamlc -stop-after parsing`, Python with
`ast.parse`, and whitespace with `git diff --check`. `source-checks.json` records
file hashes and actual results. The recorded syntax checks were rerun after
correcting crowded-window notice priority, including the updated receipt fixture.
Syntax checks are not type checking or runtime
evidence. No application build, CI dispatch, PTY run or installed binary change
was performed for this slice.

Earlier independent review predates subsequent notice-budget and PTY fixture
repairs and does not certify their final diff. Current-head review evidence is
recorded separately in the PR. Remaining surfaces and actual
render validation stay open in the [consistency ledger](../../design/tui/CONSISTENCY-PROGRESS.md).
