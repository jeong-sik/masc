# Inspect Skills in Tools

Open System → Tools and choose the effective Keeper with `[` / `]`. The
**호출 범위** section groups Normal Skills (instructions) and Composition Skills
(executable plans). `J` / `K` selects a Skill; the same exact reference is used
by editing, evidence lookup and the pinned source/package/revision details.

A Normal Skill supplies instruction text or a resource. The model chooses its
later tools; no declared execution graph or execution-time average is implied.

A Composition Skill shows its execution mode, required input schema, selected
output fields and each output's producer node and JSON pointer. An empty export
list returns the complete execution result. Its batch tree describes the
validated declaration, including data and ordering dependencies.

Press `Ctrl-O` outside the async-request section to preview that declared graph
through the existing asynchronous Mermaid → Pele renderer. Node identifiers are
local to the diagram; original names are escaped labels. A terminal without
image support or a missing `masc-pele` helper reports the reason, while the text
batch/dependency view remains available. Diagram acquisition captures geometry
and palette, has no terminal effects in its worker, and rejects results after
selection, workspace, Keeper or view changes.

The selected Skill's **SKILL PERFORMANCE** card appears above the catalog, so
its measurements are visible without scrolling past every Skill. Press `f`
outside the async-request section to select the next Composition and load its
exact-revision measurements. This returns to **호출 범위** and the top of the
pane. `Enter` reloads the selected revision. The same actions work with normal
terminal keys; no image helper is required for the charts.

The card compares completed and failed mean executor duration on one shared
zero-based axis and shows completed/failed/deferred counts as distribution bars.
Missing samples remain unobserved, while observed zero durations remain 0ms.
These are aggregate comparisons, not a time-series or latency percentile chart.
Normal Skills have an explanation instead of a fabricated duration chart.

Press `Enter` to load evidence for the selected **exact content revision**.
The observation shows the latest original activation/composition and every
retained settlement's actual input, result disposition, measured duration,
output, output byte count, truncation and execution origin. A retained completion
is not presented as a new dispatch. Async request progress remains under
**비동기 작업**, which keeps physical request and logical run observations separate.

The average reports completed and failed **stored executor result durations**
separately, each with its sample count. Deferred records are counted separately.
There is one sample per original run ID, within the exact-reference retained
partition across all Keepers. This is not lifetime coverage or asynchronous end-to-end queue,
dependency-wait, continuation or model latency. Missing means remain unknown.
Evidence loading and coverage gaps remain visible and do not change execution
or replay permission. The lookup shares one partition scan between latest
selection and statistics; it adds no HTTP request to Tools startup.

Source review, a successful native build, installation and a visible operator
screen are separate verification stages. This guide describes the source
interaction and does not establish installation.
