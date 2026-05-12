# Keeper Runtime Truth Unification Goal

Date: 2026-05-12
Status: not product-ready; latest live liveness fails fast with a structured no-tool-capable-provider terminal
Parent audit: `docs/audit/2026-05-12-keeper-oas-agent-runtime-flow-comparison.md`

## Current Implementation Slice

Implemented in this branch:

- `Keeper_runtime_manifest` schema, JSON codec, path helper, and append helper.
- Manifest append failures now record `Telemetry_coverage_gap` rows instead of
  disappearing into warn logs only.
- JSONL destination convention:
  `.masc/keepers/<keeper>/runtime-manifests/<trace_id>.jsonl`.
- Runtime hooks for:
  `turn_started`, `phase_gate_decided`, `cascade_routed`,
  `pre_dispatch_blocked`, `tool_surface_selected`,
  `provider_lane_resolved`, `provider_attempt_started`,
  `provider_attempt_finished`, `context_injected`, `context_compacted`,
  `event_bus_correlated`, `memory_injected`, `memory_flushed`,
  `checkpoint_loaded`, `checkpoint_saved`, `receipt_appended`, and
  `turn_finished`.
- Provider-lane manifest decisions now record requested tools, required tools,
  materialized tools, missing required tools, resolved lane, effective inline
  tool count, and runtime MCP policy presence.
- Required-tool turns now fail before provider dispatch if the resolved provider
  lane cannot materialize the required tools.
- Successful provider turns now persist structured keeper state snapshots to:
  - `<session_dir>/state-snapshots/turn-000001.json`
  - `<session_dir>/state-snapshot.latest.json`
- Context manifest rows record prompt/context/history digests and link the
  structured state snapshot sidecars after the provider run.
- `Keeper_cascade_engine` now encodes the keeper cascade boundary as a typed
  value: MASC owns named-cascade provider iteration and hands OAS a
  single-provider agent run per attempt.
- Runtime manifest decision rows now include `cascade_engine`,
  `oas_dispatch_mode`, and `oas_internal_cascade_allowed`.
- A focused guard still checks that the keeper hot path does not call OAS
  `Complete_cascade`, but the primary invariant is now typed and runtime
  visible.
- Keeper manifest/FSM turn ids now use the next keeper turn id
  (`total_turns + 1`) consistently across pre-dispatch, provider-attempt, and
  post-provider manifest rows. OAS SDK turn count remains separate as
  `oas_turn_count`.
- `masc-trace <base-path> <keeper> <turn_id>` now also reads
  `runtime-manifests` rows and prints them beside receipt/FSM/tool-call
  evidence. It also prints a `turn identity` summary that separates keeper
  turn id, max OAS SDK turn count, provider attempt counts, checkpoint rows,
  receipt rows, terminal rows, Event_bus correlation id, and compaction
  start/complete counters. It also prints memory injection/flush row counts.
- `GET /api/v1/keepers/<name>/runtime-trace?trace_id=<trace>&turn_id=<n>`
  now returns manifest rows, matching receipt rows, and linked artifact
  presence for dashboard/operator use. The response includes `turn_identity`
  with manifest keeper turn ids, receipt turn counts, max OAS turn count, and
  provider/checkpoint/receipt/Event_bus counters. It also includes an
  `event_bus` summary with correlation ids, run ids, and compaction counts.
  It also includes a `memory` summary with injection/flush counts and flushed
  episode/procedure counts.
- Keeper detail now fetches the runtime-trace endpoint and renders compact
  FsmHub evidence chips for trace health, keeper/OAS turn identity,
  Event_bus/compaction counters, and memory injection/flush counts.
- `/runtime-trace` now includes a `provider_attempts` summary with start/finish
  counts, terminal provider kind/model/status/error/exception, and compact
  attempt rows. Keeper detail renders that terminal provider chip directly in
  FsmHub so operator-visible failure evidence no longer requires opening raw
  manifest JSON.
- `scripts/keeper-runtime-truth-gate.sh` now provides a read-only live proof
  gate for an existing keeper turn. It checks manifest events, provider-lane
  boundary fields, Event_bus summary fields, memory-injection fields, linked
  receipt/checkpoint/tool-call artifacts, and can also verify the
  `/runtime-trace` API when `--server-url` is provided. The
  `--self-test` mode builds a temporary fixture so the gate itself is locally
  testable without mutating live runtime state. Its self-test now covers both
  a successful provider turn with a checkpoint and a timeout/error provider
  turn where the OAS context rolls back without `checkpoint_saved`; the latter
  is accepted only when `turn_finished.status = error` and provider
  start/finish counts are terminal.
- Focused test binary: `test/test_keeper_runtime_manifest.ml` with 15 tests,
  including:
  - a producer fixture that calls the pre-dispatch terminal path and verifies
    manifest JSONL rows plus the linked receipt path;
  - a successful provider/OAS-run fixture that calls `keeper_tool_search`
    through a local OpenAI-compatible mock and verifies the manifest,
    checkpoint, state sidecar, tool-call log, and receipt chain together.
  - a provider-lane matrix regression that covers inline-only,
    runtime-MCP-only, mixed, no-tool, and runtime-MCP-connect-only surfaces.
  - a checkpoint-load fixture proving `state-snapshot.latest.json` hydrates
    replay metadata before raw `[STATE]` text re-derivation.
  - a read-only runtime trace API fixture proving manifest rows and matching
    execution receipt rows are joined through the operator endpoint JSON.
  - a typed cascade-engine boundary fixture proving keeper runtime dispatch
    uses `single_provider_agent_run` and disables OAS-internal cascade fallback.
- `test/test_memory_hooks.ml` now covers runtime manifest rows from the
  hook-first memory path: `memory_injected` and `memory_flushed`.
- Direct model-string keeper runs now use direct-call defaults for
  strategy/concurrency knobs when no active cascade catalog exists. Named
  cascades still fail closed on catalog resolution errors.
- `test/test_keeper_unified.ml` no longer depends on the deleted
  `config/cascade.json` fixture; it now copies `config/cascade.toml` for its
  temp config root. Its livelock priming uses the same next-turn id convention
  as the runtime.
- Declarative cascade validation now accepts 5-layer `tier.*` and
  `tier-group.*` profiles from the declarative snapshot, instead of requiring
  legacy `<profile>_models` materialization for every route target.
- `routes.*.target` values are preserved while the live catalog is not yet
  validated, instead of collapsing to a legacy alias that may not exist in the
  declarative `cascade.toml`.
- Degraded retry now distinguishes phase aliases (`local_only`,
  `local_recovery`) from concrete fallback profiles with the same historical
  names. Generic fail-open follows the configured phase-recovery route; concrete
  `local_recovery` is used only when explicitly hinted.
- Required-tool degraded retries prepend the default route when catalog-owned
  rotation is present, so filtering recovery/control lanes does not leave a
  required-tool turn with no valid same-turn recovery path.
- `masc_keeper_up` now accepts and validates a public `cascade_name` argument,
  matching the legacy-model removal error text and schema. Invalid or
  system-only cascades fail before keeper creation.
- `save_private_text_file` now uses `Fun.protect` for channel cleanup inside
  blocking/systhread auth I/O, avoiding an Eio cancellation-context effect
  outside a fiber while still guaranteeing `close_out_noerr`.
- `scripts/harness/workload/keeper_continuity_validation.sh` was updated for
  the current MCP and keeper contracts:
  - bearer token is loaded from the isolated base path before tool calls;
  - MCP `initialize` is performed and `Mcp-Session-Id` is reused;
  - removed `models`, `presence_keepalive`, and `require_existing` args are no
    longer sent;
  - `masc_keeper_msg` queued responses are not treated as turn completion;
  - liveness waits for `meta.total_turns` to advance;
  - continuity waits for both `meta.total_turns` and continuity state to
    advance;
  - liveness/continuity timeout summaries read the runtime manifest for the
    expected turn and include terminal status, terminal reason, provider
    status, and provider error when the turn failed after queueing;
  - phase logging survives helper failures and empty snapshot paths.
- Provider attempts now close their manifest chain on all locally observable
  terminal paths. Normal `Ok`/`Error` provider returns emit
  `provider_attempt_finished` inside the provider-attempt scope. If the outer
  keeper/OAS bridge timeout interrupts the attempt before `run_named` can
  unwind normally, `Keeper_agent_run` repairs the last unmatched
  `provider_attempt_started` row with a terminal
  `provider_attempt_finished` row carrying `status = timeout`,
  `exception_kind = outer_oas_timeout`, and the bridge error text.
- Attempt-liveness tick fibers now have an explicit stop signal. A provider
  can return a terminal API error before the liveness FSM sees a terminal
  stream event; the attempt owner now wakes the tick fiber before leaving the
  attempt switch so the original provider error is not masked as a 120s outer
  timeout.
- `no_tool_capable_provider` now remains a structured terminal reason instead
  of collapsing to `internal_error`. The runtime manifest also records a
  `pre_dispatch_blocked` row with the configured labels, required tool names,
  provider rejections, and MASC/OAS cascade-boundary fields.
- OAS pin is bumped to `v0.193.8` /
  `7885ff316cfd64a3ed7d7550186b64141214b801`, with `dune-project`,
  `masc_mcp.opam`, docs, and `scripts/oas-api-surface.json` regenerated from
  that pinned OAS checkout.

Latest verification:

- `git fetch origin main`
- `git fetch origin main` in `../oas`
- `./scripts/check-oas-pin.sh`
- `opam list --installed agent_sdk` -> `agent_sdk 0.193.8`
- `scripts/dune-local.sh build test/test_cascade_attempt_liveness_observer.exe test/test_ci_hardening_source.exe test/test_keeper_runtime_manifest.exe test/test_keeper_terminal_reason.exe test/test_keeper_sdk_error_typed_bridge.exe test/test_keeper_unified.exe bin/main_eio.exe`
- `./_build/default/test/test_cascade_attempt_liveness_observer.exe` (11 tests; tick-fiber pending-stop regression now completes in 0.003s)
- `./_build/default/test/test_ci_hardening_source.exe test source_guard 37`
- `./_build/default/test/test_keeper_runtime_manifest.exe` (18 tests)
- `./_build/default/test/test_keeper_terminal_reason.exe` (34 tests)
- `./_build/default/test/test_keeper_sdk_error_typed_bridge.exe` (2 tests)
- `./_build/default/test/test_keeper_unified.exe` (359 tests)
- `scripts/keeper-runtime-truth-gate.sh --self-test` (success fixture plus
  timeout/error fixture)
- `env RUN_ID=keeper-runtime-truth-live-20260512-codex5 RUN_DIR=/private/tmp/keeper-runtime-truth-live-20260512-codex5 KEEP_ARTIFACTS=1 TARGET_PHASES=bootstrap,liveness MAX_TURNS=1 TURN_TIMEOUT_SEC=120 HEALTH_TIMEOUT_SEC=45 HEARTBEAT_WAIT_SEC=20 PRESSURE_BYTES=1000 MASC_CONFIG_DIR=/Users/dancer/me/.masc/config scripts/harness_keeper_continuity_validation.sh`
  (expected FAIL before tick-stop fix: provider API error was masked as outer timeout)
- `env RUN_ID=keeper-runtime-truth-live-20260513-codex8 RUN_DIR=/private/tmp/keeper-runtime-truth-live-20260513-codex8 KEEP_ARTIFACTS=1 TARGET_PHASES=bootstrap,liveness MAX_TURNS=1 TURN_TIMEOUT_SEC=120 HEALTH_TIMEOUT_SEC=45 HEARTBEAT_WAIT_SEC=20 PRESSURE_BYTES=1000 MASC_CONFIG_DIR=/Users/dancer/me/.masc/config scripts/harness_keeper_continuity_validation.sh`
  (expected FAIL after tick-stop fix: GLM insufficient-balance error propagates in 0.74s; keeper turn then fails on no tool-capable provider)
- `env RUN_ID=keeper-runtime-truth-live-20260513-codex9 RUN_DIR=/private/tmp/keeper-runtime-truth-live-20260513-codex9 KEEP_ARTIFACTS=1 TARGET_PHASES=bootstrap,liveness MAX_TURNS=1 TURN_TIMEOUT_SEC=30 HEALTH_TIMEOUT_SEC=30 HEARTBEAT_WAIT_SEC=10 PRESSURE_BYTES=1000 MASC_CONFIG_DIR=/Users/dancer/me/.masc/config scripts/harness_keeper_continuity_validation.sh`
  (expected FAIL: terminal reason is now `no_tool_capable_provider` and manifest includes `pre_dispatch_blocked`)
- `scripts/keeper-runtime-truth-gate.sh --base-path /var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T//keeper-continuity.keeper-runtime-truth-live-20260512-codex5.2OnAhW --keeper continuity-keeper-runtime-truth-live-20260512-codex5 --trace-id trace-1778579781467-00000 --turn-id 1 --mode provider`
- `git diff --check`

Latest-main live evidence:

- Current branch was rebased onto `origin/main` at
  `429cf1c47cc1f69c8ba55f88491017cde53117c5`
  (`HEAD` merge-base with `origin/main` is
  `429cf1c47cc1f69c8ba55f88491017cde53117c5`).
- Current OAS pin matches fetched OAS `origin/main` at
  `7885ff316cfd64a3ed7d7550186b64141214b801` (`v0.193.8`).
- Bootstrap-only isolated run:
  `/private/tmp/keeper-runtime-truth-live-20260512-bootstrap9`
  classified `PASS`; phase log shows active keepalive and room presence.
- The active config root used in the live run was
  `/Users/dancer/me/.masc/config`, whose active catalog default was
  `coding_plan`. The harness no longer hardcodes `big_three`.
- Latest post-fix live-like liveness rerun:
  `/private/tmp/keeper-runtime-truth-live-20260512-codex5`
  classified `FAIL`; bootstrap passed, liveness still timed out after the
  queued keeper message.
- The codex5 phase summary is now operator-actionable:
  `turn_status=error terminal_reason=api_error_timeout provider_status=timeout
  provider_error=Timeout: Timeout after 120.0s (budget=120s)`.
- The codex5 manifest includes the previously missing terminal row:
  `provider_attempt_finished` with `status = timeout`,
  `provider_kind = glm`, `model_id = glm-5.1`, and
  `exception_kind = outer_oas_timeout`.
- `scripts/keeper-runtime-truth-gate.sh` passes against the codex5 failed
  live-like turn. It accepts absent `checkpoint_saved` and absent
  `event_bus_correlated` only because `turn_finished.status = error`, treating
  that as an OAS rollback/pre-correlation terminal-failure path rather than a
  healthy success path.
- Post tick-stop live run:
  `/private/tmp/keeper-runtime-truth-live-20260513-codex8` still classified
  `FAIL`, but the GLM insufficient-balance provider error propagated after
  `0.738s` instead of being masked as a 120s outer timeout.
- Latest live run:
  `/private/tmp/keeper-runtime-truth-live-20260513-codex9` classified `FAIL`;
  phase summary reports `turn_status=error
  terminal_reason=no_tool_capable_provider`.
- The codex9 manifest includes `pre_dispatch_blocked` with
  `reason = no_tool_capable_provider`, `configured_labels = ["glm:glm-5.1"]`,
  `require_tool_support = true`, and `original_candidate_count = 1`.
- The codex9 receipt and `turn_finished` rows both carry
  `terminal_reason_code = no_tool_capable_provider`.

## Goal

Make every keeper turn explainable from one evidence chain:

```
keeper stimulus
-> phase gate
-> cascade route
-> provider attempts
-> tool surface and provider lane
-> OAS SDK turns
-> context/memory/compaction decisions
-> checkpoint
-> execution receipt
```

The product-level target is not "more logs". The target is that an operator,
dashboard, CLI, or reviewer can answer why a turn succeeded, skipped, failed,
or retried without reconstructing the story from unrelated files.

## Product Health Assessment

Current state is improved and closer to product-grade, but the latest-main
live run is still a hard stop for a product-ready claim. The immediate
hardening slice is healthy enough to ship as an observability/reliability
improvement, because it now exposes timeout and pre-dispatch capability
failures precisely and the gate can validate failed turn chains. The keeper
runtime as a whole is not healthy enough to call fully product-ready until live
provider turns finish reliably or the active keeper route includes a concrete
tool-capable provider.

Healthy parts:

- Keeper pre-dispatch skips/errors are receipt-backed.
- Tool selection has explicit policy gates, required-tool checks, and
  reported/observed/canonical reconciliation.
- MASC owns cascade routing and provider attempt observations.
- OAS owns the generic single-agent loop, tool execution loop, context reducer,
  memory primitive, checkpoint primitive, and compaction machinery.
- Boundary documentation already states that OAS must stay generic while MASC
  owns world/task/board/governance semantics.
- The current declarative cascade route target (`tier-group.big_three`) is now
  accepted by the active catalog validator and broad keeper lifecycle tests.
- The latest live-like run no longer hides queued `masc_keeper_msg` responses
  as successful turns; the harness waits for actual turn state.

Fragile parts:

- A single human concept, "turn", is split across MASC keeper turn,
  MASC cascade attempt, and OAS SDK turn counters.
- Tool surface selection happens before the final provider lane is known.
  The current branch now detects impossible required-tool lanes before provider
  dispatch and has a successful provider/OAS fixture proving manifest rows and
  receipts line up in one actual turn. The remaining gap is provider-lane
  E2E breadth, not the pure lane contract or the existence of the causal
  chain.
- The keeper hot path uses MASC cascade, while OAS also has a generic
  `Complete_cascade`; both are valid but must not be mixed accidentally. This
  branch now adds a typed `Keeper_cascade_engine` boundary, records the dispatch
  mode in runtime manifests, and keeps a source guard as a secondary alarm.
- Runtime context is split across MASC `working_context`, OAS checkpoint,
  raw `[STATE]` text, memory hooks, memory bank, and receipts.
- Structured state snapshot sidecars now reduce dependence on raw `[STATE]`;
  OAS checkpoint load hydrates replay metadata from
  `state-snapshot.latest.json` when the checkpoint lacks structured metadata.
  Remaining work is broader live evidence and dashboard/API read surfaces.
- Compaction evidence is now represented in two places: the pre-dispatch
  checkpoint/compaction decision row and a final `event_bus_correlated` row
  that carries the OAS Event_bus correlation id, run id, overflow hint, and
  proactive/emergency compaction counters for the keeper turn. Hook-first
  memory injection and after-turn flush are now joined through
  `memory_injected` and `memory_flushed` rows. Remaining context risk is
  broader live evidence and deeper quality metrics for what memory/compaction
  preserved or dropped.
- Cascade alias semantics are now encoded in tests, but the long-term shape
  should still remove module-init route constants in favor of explicit dynamic
  route resolution or literal phase sentinels. The current slice closes the
  observed failures, not the whole historical naming ambiguity.
- Production-like config no longer masks the observed GLM provider error as a
  120-second outer timeout, but the active keeper route still does not
  complete a keeper turn under production-like config. The latest failure is
  now earlier and more precise: `no_tool_capable_provider` because the active
  route has `glm:glm-5.1` while the turn requires materialized keeper tool
  support.
- Live config drift is real: the current config root exposes `coding_plan` as
  the only active catalog profile, while older scripts assumed `big_three`.
  The harness now avoids that hardcoded default, but operator docs/config still
  need cleanup.
- Local Docker is not reachable on this host, so declarative docker keepers in
  the active config repeatedly fail sandbox preflight during live runs. This is
  not the direct cause of the test keeper's local-profile liveness failure, but
  it adds production noise and should be separated from provider-runtime
  failures in operator surfaces.

### Product Readiness Gate

Verdict as of this slice: do not promote as fully product-healthy yet.

It is acceptable to ship behind an operator-facing experimental gate if the
goal is observability hardening. It is not yet acceptable as a final product
runtime guarantee because the strongest live-like evidence on latest main now
fails at route capability: the keeper message queues, but the active
`tier-group.coding_plan` route has no tool-capable provider for the keeper's
materialized internal tool surface.

Highest-risk gaps:

1. Route capability gap: latest live run
   `/private/tmp/keeper-runtime-truth-live-20260513-codex9` fails with
   `no_tool_capable_provider`. The manifest now records
   `pre_dispatch_blocked`, and the receipt/turn terminal reason stays
   structured. Still open: configure `tier-group.coding_plan` with a concrete
   tool-capable provider for keeper-internal tools, or route these keeper turns
   to a provider lane that can materialize runtime MCP/inline tools.
2. Real-turn evidence gap: closed for focused fixture coverage. The successful
   provider/OAS fixture proves the manifest, checkpoint, state sidecar,
   tool-call log, and receipt chain together. Remaining risk is live
   long-running keeper evidence under production-like config.
3. Turn identity gap: the immediate off-by-one hazard between pre-dispatch and
   provider paths is fixed in this branch, and `masc-trace` plus
   `/runtime-trace` now expose a `turn_identity` summary. Keeper detail now
   renders that summary as compact evidence chips. Remaining risk is
   drill-down depth and live long-running evidence, not backend/API visibility.
4. Tool contract gap: pure lane-matrix coverage now exists for inline-only,
   runtime-MCP-only, mixed, no-tool, and runtime-MCP-connect-only surfaces.
   Remaining risk is E2E provider-kind coverage for concrete transports.
5. Context ownership gap: checkpoint load now uses the latest state sidecar
   before raw `[STATE]` re-derivation when structured checkpoint metadata is
   absent. Hook-first memory injection/flush now has manifest rows. Remaining
   risk is broader live keeper evidence, non-checkpoint operator surfaces, and
   preservation-quality metrics.
6. Operator surface gap: `masc-trace`,
   `/api/v1/keepers/:name/runtime-trace` now expose manifest rows and linked
   receipt artifacts, Event_bus correlation, compaction counters, and
   memory-injection/flush summaries. The API also exposes provider-attempt
   terminal status/error/model directly, and
   `scripts/keeper-runtime-truth-gate.sh` can validate the chain from an
   existing live turn. The keeper detail FsmHub now has compact evidence
   chips for that endpoint, including provider terminal status. Remaining
   risk is collecting/publishing live long-running keeper evidence under
   production-like config and improving drill-down beyond the compact summary.
7. Cascade plane gap: the keeper/OAS cascade-plane invariant is now typed and
   visible in manifests. Remaining risk is that future non-keeper entry points
   may need the same explicit engine classification if they reuse parts of the
   driver.
8. Cascade naming gap: `test/test_keeper_unified.exe` is now green under
   `config/cascade.toml`, but the codebase still carries historical
   `default`/`local_only`/`local_recovery` aliases beside declarative
   `tier.*` and `tier-group.*` profiles. This should be simplified before
   treating route semantics as final.

## Done Criteria

This goal is complete only when all of the following are true:

1. Each keeper turn has a durable runtime decision manifest.
2. The manifest links keeper turn id, trace id, generation, OAS SDK turn count,
   cascade name, provider attempt count, checkpoint ids, and receipt path/id.
3. The manifest records phase-gate, cascade-route, provider-attempt,
   tool-surface, provider-lane, context-injection, compaction, checkpoint, and
   receipt decisions, plus the OAS Event_bus correlation/run ids and memory
   injection/flush decisions observed for the turn.
4. Required-tool decisions prove whether the tool was available inline,
   through runtime MCP, or unavailable for the actual provider lane.
5. Keeper hot path has a documented/tested invariant: MASC cascade owns keeper
   provider iteration; OAS `Complete_cascade` is not silently used there.
6. Context/checkpoint ownership has a documented migration path and at least one
   code slice reducing MASC `working_context` dependence or moving continuity
   to structured sidecars.
7. There is an operator surface, even if minimal CLI first, that can read one
   turn and print the evidence chain.
8. Focused tests or verifiers cover the manifest producer and at least one
   pre-dispatch path plus one successful OAS-run path.

## Completion Audit (2026-05-12)

Objective restated: produce a code-level and flowchart-level audit of Keeper,
tools, provider/model/cascade, external agent turn loops, and
compaction/memory/context behavior; then merge the most important improvement
into the product so runtime readiness can be judged from evidence.

Prompt-to-artifact checklist:

1. Keeper lifecycle: covered by
   `docs/audit/2026-05-12-keeper-oas-agent-runtime-flow-comparison.md` section
   1 and runtime-manifest rows for `turn_started`, `phase_gate_decided`,
   `cascade_routed`, `pre_dispatch_blocked`, provider attempts, receipts, and
   terminal turn events.
2. Tool search/use flow: covered by audit section 2 and manifest/test coverage
   for `tool_surface_selected`, `provider_lane_resolved`, required-tool lane
   mismatches, and inline/runtime-MCP/no-tool matrices.
3. Provider/model/cascade flow: covered by audit section 3, the typed
   `Keeper_cascade_engine` boundary, manifest fields
   `cascade_engine`, `oas_dispatch_mode`, and
   `oas_internal_cascade_allowed`, plus route/cascade regression tests.
4. External Agent SDK comparison: covered by the audit's Claude Agent SDK,
   Google ADK, OpenAI Agents SDK, OpenClaw, and Hermes sections using the
   checked primary-source links recorded in the audit.
5. Compaction/memory/context insertion/removal: covered by audit section 5,
   manifest rows for `context_injected`, `context_compacted`,
   `event_bus_correlated`, `memory_injected`, and `memory_flushed`, and
   focused memory/context tests.
6. Product readiness judgment: this branch is shippable as a gated
   observability/reliability improvement. It is not yet a final product
   runtime guarantee because the latest-main live-like run failed with a
   structured route-capability error:
   `no_tool_capable_provider` for `tier-group.coding_plan` with
   `glm:glm-5.1`.

Completion status: not complete as a full product-readiness goal. The immediate
observability slice is useful and verified locally, and the first P0 follow-up
is now proven on live-like failed turns: provider timeout/error terminals are
normalized, no-tool-capable pre-dispatch failures stay structured, and both
are represented in the manifest/receipt chain. Still open: make the active
provider route complete with a tool-capable provider under production-like
config.

## Non-Goals

- Do not replace `Keeper_execution_receipt`; the manifest links and explains it.
- Do not move MASC world/task/governance concepts into OAS.
- Do not migrate to OAS `Complete_cascade` as part of the MVP.
- Do not build adaptive cascade ranking before the manifest proves current
  decisions.
- Do not rewrite compaction. First make compaction decisions observable as one
  stream.

## Plan Overview

| Priority | Slice | Outcome |
|---|---|---|
| P0 | Runtime decision manifest MVP | One keeper turn produces one causality spine. |
| P1 | Provider-lane/tool-surface contract | Required tools are checked against actual provider lane. |
| P1 | Cascade plane invariant | Keeper path cannot accidentally switch to OAS cascade semantics. |
| P1 | Context/checkpoint SSOT cleanup | OAS checkpoint moves closer to runtime transcript SSOT. |
| P2 | Compaction/memory event unification | Add/remove/inject decisions are visible in one stream. |
| P2 | Product/operator upgrades | CLI/dashboard/replay/eval use the manifest. |

## P0: Runtime Decision Manifest MVP

### Purpose

Create a low-risk append-only artifact that links existing evidence instead of
replacing it.

### Proposed Artifact

Path:

```
$MASC_ROOT/keepers/<keeper>/runtime-manifests/<trace_id>.jsonl
```

One JSONL row per decision event. The final row for a turn is terminal and
contains links to the receipt/checkpoint/tool log.

Suggested module:

- `lib/keeper/keeper_runtime_manifest.ml`
- `lib/keeper/keeper_runtime_manifest.mli`

Suggested event kinds:

- `turn_started`
- `phase_gate_decided`
- `cascade_routed`
- `pre_dispatch_blocked`
- `tool_surface_selected`
- `provider_lane_resolved`
- `provider_attempt_started`
- `provider_attempt_finished`
- `context_injected`
- `context_compacted`
- `checkpoint_loaded`
- `checkpoint_saved`
- `receipt_appended`
- `turn_finished`

Minimal fields:

```json
{
  "schema_version": 1,
  "ts": "2026-05-12T00:00:00Z",
  "keeper_name": "pm",
  "agent_name": "keeper-pm",
  "trace_id": "...",
  "generation": 12,
  "keeper_turn_id": 42,
  "oas_turn_count": 3,
  "event": "tool_surface_selected",
  "cascade_name": "tier_medium",
  "provider_kind": "codex_cli",
  "model_id": "auto",
  "status": "ok",
  "decision": {},
  "links": {
    "receipt_path": "...",
    "checkpoint_path": "...",
    "tool_call_log_path": "..."
  }
}
```

### Implementation Order

1. Add manifest types and JSON encoding.
2. Add append helper with failure-is-observable behavior:
   - manifest append failure should increment a metric and add a coverage gap;
   - it should not initially fail the keeper turn unless the terminal receipt
     succeeds but manifest terminal row fails after P0 hardening decision.
3. Emit `turn_started` / `phase_gate_decided` / `pre_dispatch_blocked` from
   `keeper_unified_turn.ml` near existing pre-dispatch receipt sites.
4. Emit `checkpoint_loaded` from `Keeper_run_context.prepare_run_context`.
5. Emit initial `tool_surface_selected` from
   `Keeper_run_tools.prepare_agent_setup`.
6. Emit per-OAS-turn `tool_surface_selected` from the `BeforeTurnParams` hook.
7. Emit `provider_attempt_started/finished` around
   `Keeper_turn_driver_try_provider.run_try_provider`.
8. Emit `provider_lane_resolved` immediately after
   `Cascade_runner.resolve_tool_lane_for_oas_tools`.
9. Emit `checkpoint_saved` and `receipt_appended` from `Keeper_agent_run`.
10. Add a minimal CLI/read helper or dashboard endpoint that prints the chain by
    `keeper + trace_id` or `keeper + keeper_turn_id`.

### Focused Tests

Start with pure/fixture tests:

- JSON round-trip for manifest event encoding.
- Append JSONL creates valid rows and preserves order.
- Pre-dispatch blocked fixture emits terminal manifest row.
- Successful run fixture links receipt/checkpoint/tool surface fields.

Suggested focused command after implementation:

```
scripts/dune-local.sh build test/test_keeper_runtime_manifest.exe
```

If the test binary does not exist yet, add it in the same P0 slice.

## P1: Provider-Lane / Tool-Surface Contract

### Problem

The keeper hook selects visible tools and `tool_choice` before the actual
provider lane is resolved. A provider can later choose inline tools, runtime
MCP, or a reduced/no-tool lane.

### Required Product Behavior

For every tool-required turn, the product must show:

- requested tool names,
- allowed visible tool names,
- selected `tool_choice`,
- provider kind/model,
- resolved lane: `inline`, `runtime_mcp`, `public_mcp`, `none`, or mixed,
- materialized required tools,
- missing required tools after lane resolution,
- whether the contract was satisfied by an actual tool call.

### Implementation Order

1. Extend manifest `provider_lane_resolved`.
2. Extend `Keeper_execution_receipt.tool_surface` or add linked manifest-only
   fields first to avoid receipt churn.
3. In `run_try_provider`, compare required tools against effective tools after
   `resolve_tool_lane_for_oas_tools`.
4. If required tools cannot materialize, return a typed error before calling
   provider.
5. Add one regression test for required tool + provider without tool support.

## P1: Cascade Plane Invariant

### Problem

MASC and OAS both have cascade concepts. Keeper runtime must not silently drift
from MASC cascade semantics into OAS `Complete_cascade`.

### Implementation Order

1. Add a typed `Keeper_cascade_engine` value near
   `Keeper_turn_driver.run_named`.
2. Record the engine id and OAS dispatch mode in runtime-manifest decision
   rows.
3. Add a test/grep guard that keeper hot path does not call
   `Llm_provider.Complete_cascade.complete_cascade`.
4. Document migration requirements if this invariant is ever intentionally
   changed:
   - health tracker,
   - admission queue,
   - fallback observation,
   - receipt fields,
   - dashboard semantics,
   - tool/provider lane semantics.

## P1: Context / Checkpoint SSOT Cleanup

### Problem

Runtime transcript truth is split:

- MASC `working_context`,
- OAS `Agent.state.messages`,
- OAS checkpoint,
- raw `[STATE]` text,
- MASC memory bank,
- receipt/checkpoint sidecars.

### Near-Term Direction

Do not rewrite all context logic at once. First reduce ambiguity:

1. Manifest records context source hashes:
   - base system prompt,
   - dynamic context,
   - memory context,
   - temporal context,
   - history message count/hash,
   - checkpoint before/after ids.
2. Store structured state snapshot sidecar as the durable continuity payload.
3. Treat raw `[STATE]` as a display/compatibility input, not the only durable
   continuity source.
4. Pick one small code path where MASC no longer re-derives state from raw text
   if the structured sidecar exists.

## P2: Compaction / Memory Event Unification

### Problem

Compaction and memory decisions are real, but currently spread across:

- pre-dispatch checkpoint hygiene,
- OAS proactive compaction,
- OAS emergency compaction,
- memory hook injection,
- memory hook flush,
- post-run checkpoint patching,
- deterministic memory bank writes.

### Product Behavior

The operator should be able to answer:

- What was injected?
- What was summarized?
- What was dropped?
- What was relocated?
- What was reloaded from memory?
- What checkpoint contains the surviving context?

### Implementation Order

1. Add manifest events for current compaction/memory points without changing
   behavior. Current branch covers pre-dispatch compaction decisions and
   OAS Event_bus compaction/overflow summaries.
2. Add memory hook injection/flush summaries to the same causal stream.
   Current branch records `memory_injected` and `memory_flushed`.
3. Add a compaction summary view keyed by `trace_id`.
4. Add quality metrics later:
   - before/after tokens,
   - required marker/state preserved,
   - tool-result pair preserved,
   - next-turn continuity success.

## P2: Product Upgrades After P0/P1

Only after the manifest exists:

- CLI replay: `masc trace-runtime <keeper> <turn_id|trace_id>`.
- Dashboard turn inspector: phase/cascade/tool/context/checkpoint/receipt tabs.
- Offline eval for tool selection quality.
- Compaction quality benchmark.
- Adaptive cascade ranking using observed latency/cost/health, not static theory.

## First Concrete PR Sequence

1. `docs(goal): record keeper runtime truth unification plan`
   - this document and parent audit only.
2. `feat(keeper): add runtime manifest schema and JSONL append`
   - pure module, tests, no behavior change.
3. `feat(keeper): emit manifest for pre-dispatch and receipt paths`
   - phase gate/cascade blocked/success terminal links.
4. `feat(keeper): record provider lane and tool surface in manifest`
   - no new fail-loud yet; observe first.
5. `fix(keeper): fail required-tool turns when provider lane cannot materialize`
   - behavior change after observation proves shape.
6. `feat(keeper): type and expose the keeper/OAS cascade boundary`
   - invariant hardening plus manifest-visible dispatch mode.
7. `feat(keeper): context/compaction decision events`
   - unify context evidence.

## Completion Audit Checklist

Before marking this goal complete, verify real evidence for each row:

| Requirement | Evidence needed |
|---|---|
| Goal recorded | This file exists in repo and is linked from the parent audit or follow-up PR. |
| Manifest schema implemented | `keeper_runtime_manifest.mli/ml` and tests exist. |
| Manifest rows emitted | Fixture/live run contains JSONL rows for start, phase, cascade, tool, provider, checkpoint, receipt, finish. |
| Provider lane captured | Manifest row proves requested vs materialized required tools. |
| Required-tool impossible lane fails | Focused regression test fails before fix and passes after fix. |
| Cascade invariant guarded | `Keeper_cascade_engine` fixture and secondary source guard prove keeper hot path uses MASC provider iteration plus OAS single-provider dispatch. |
| Context/checkpoint SSOT improved | At least one code path uses structured sidecar/checkpoint truth instead of raw `[STATE]` only. |
| Operator surface exists | CLI, endpoint, and read-only gate can print/validate the evidence chain and turn identity from one id. |
| Verification commands run | Focused `scripts/dune-local.sh build ...` commands or CI checks are attached to the PR. |
