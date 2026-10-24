# Live Agent journal writer removal — 2026-10-25

Source base: `98a1508e6ecbda1d38d33aa7d0eb7f366b420ddf`.
This bounded layer removes the live alternate Agent journal writer and its
configuration/save/auto-dump/bridge APIs. It does not close #27890.

## Scope and preserved behavior

Agent options and Builder no longer accept a second journal. Pipeline and Tool
execution no longer append flat lifecycle/provider/checkpoint/tool rows through
an independent writer or compute a name/input idempotency key. The unused
writer/bridge and their dedicated tests are deleted, without a compatibility
adapter. The callback used for optional end-of-run metrics remains available.

The existing typed `Agent.execution_store` path is preserved: an exact Tool
attempt is committed before entering the external effect, settled results replay,
and an admitted effect without a settlement remains unknown. Provider snapshots,
recursive attempt ownership, sink ordering and scope recovery logic are unchanged.
Existing Pipeline durability, Tool execution, telemetry/checkpoint and lane-writer
fixtures remain registered; assertions specifically about the deleted writer and
its callbacks are removed. The source census found no production consumer of the
removed API outside agent_core. Similarly named Keeper/config journals are
independent authorities and remain intact.

The public read boundary is `Agent.open_execution_projection`, not a public
Store/WAL/reducer/transaction writer. The dashboard lifecycle renderer's stale
module-name comment is corrected; no dashboard behavior is changed in this layer.

## Actual validation

Changed OCaml source/interfaces parse and `git diff --check` passes. See
[source-checks.txt](source-checks.txt) for the exact changed-file checks and hashes.
No local Dune build, runtime execution or CI PASS is claimed at this entry.
Independent adversarial source review found no P0-P2 regression in this bounded
removal, while explicitly confirming the original issue remains incomplete.

Requested behavior scope will be only:
`packages/agent_core/test/test_pipeline`,
`packages/agent_core/test/test_tool_execution`,
`packages/agent_core/test/test_telemetry_pipeline`,
`packages/agent_core/test/test_execution_lane_writer`.
This is not a full regression, MASC server build, installation or live-provider
check. Existing unchanged fixtures are not a newly observed passing result.

## Original issue acceptance still open

- Agent runs without an execution store remain transient and have no durable
  occurrence/recovery authority. This layer does not make storage mandatory.
- Native Event_bus observations still publish directly with their own identities;
  Raw_trace still has direct observational callbacks. Complete adapters must read
  committed canonical event IDs/cursors and preserve projection failure/replay
  semantics. The current observations do not prove this requirement.
- Caller-owned checkpoint sinks remain conversation snapshot boundaries; removing
  a flat checkpoint marker does not atomically unify their commits with execution
  facts or establish canonical checkpoint projection.
- A terminal recovery disposition `Retire` is permission to discard a recovery
  locator, not an explicit finite-scope journal-retention decision. Retention
  ownership/acceptance must be established separately without arbitrary runtime
  count, time, token or cost limits.

Current API/catalog documentation now states these boundaries instead of
presenting observations as proven read-only post-commit projections. #27890
remains open for the full contract and its actual execution evidence.

## Observed focused execution

[Run 40114881637](https://github.com/jeong-sik/masc/actions/runs/40114881637)
at `a7a7dbc396f5bcc55df3d957bc380f1c1d90a203` completed **SUCCESS**. Actual
suite summaries: Pipeline **68**, Tool execution **28**, execution lane writer
**22**, telemetry/checkpoint integration **9** cases, **127 total**. See
[the retained execution summary](focused-execution.txt). This is the selected
core behavior scope, including its existing recovery/settlement/sink fixtures,
not a full regression, MASC server build, installed runtime or live provider.
This evidence update changes documentation only; code/test inputs remain the
executed source. The original issue's post-commit projection, checkpoint and
retention acceptance gaps listed above remain open despite this focused PASS.
