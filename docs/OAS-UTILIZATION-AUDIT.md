# MASC-MCP OAS Utilization Audit

Date: 2026-04-09
<!-- BEGIN GENERATED: oas-pin-audit-header -->
OAS Pin Snapshot: dependency floor `0.139.0`, runtime pin `main@190743039992308b5c606c230c399dbbabc6574f`, declared base version `v0.139.0`
<!-- END GENERATED: oas-pin-audit-header -->
Snapshot: `main` audit aligned to the current upstream `agent_sdk.opam`; drift is checked against upstream `refs/heads/main`, not GitHub releases

Latest boundary check: [docs/qa/OAS-BOUNDARY-HEALTHCHECK-2026-03-31.md](docs/qa/OAS-BOUNDARY-HEALTHCHECK-2026-03-31.md)

## Current Read

OAS adoption in `masc-mcp` is now structurally real, but still incomplete.
The main remaining problems are no longer “missing migration” at large. They are:

1. incomplete bridge fidelity,
2. a few remaining duplicated runtime paths,
3. stale docs that still describe already-removed or already-migrated systems.
4. a small number of boundary ownership leaks where MASC still reconstructs OAS-owned config or layout details locally.

## Pin Policy

<!-- BEGIN GENERATED: oas-pin-audit-policy -->
`masc-mcp` keeps the runtime pin ratcheted against upstream `main`, while the dependency floor tracks the pinned SDK declaration in `agent_sdk.opam`. Generated snapshot: runtime pin `main@190743039992308b5c606c230c399dbbabc6574f`, declared base version `v0.139.0`, dependency floor `0.139.0`.
<!-- END GENERATED: oas-pin-audit-policy -->

## Status by Area

| Area | Status | Evidence |
|------|--------|----------|
| Single-agent runtime | Strong | `oas_worker`, keeper turn path, verifier, governance/dashboard provider runs, keeper rollover, router/judge flows use `Agent.run` through OAS wrappers |
| Context reduction | Real | `context_compact_oas.ml` delegates directly to OAS `Context_reducer` |
| Event bus / SSE | Real | `oas_events.ml` publishes `masc:*` events and `oas_sse_bridge.ml` relays them to SSE |
| Memory bridge | Partial but real | `memory_oas_bridge.ml` now seeds long-term, procedural, and episodic memory; Working/Scratchpad remain runtime-only |
| Team session swarm | Partial but real | `team_session_swarm_runner.ml` runs through OAS Swarm and now receives a real supported-tool dispatch bundle |
| Runtime dedupe | Improving | dashboard single-run and initial local worker run now reuse shared OAS execution helpers |
| Provider ownership | Improving | keeper state now treats OAS-owned provider allowlists in legacy TOML/meta as compatibility-only input and keeps active selection at `cascade_name` |

## Boundary Audit Snapshot

| Surface | Classification | Evidence |
|---------|----------------|----------|
| `oas_worker*.ml`, `worker_oas.ml`, `verifier_oas.ml` | Correct | MASC consumes runtime/build/hook contracts without adding MASC concepts to OAS APIs |
| `context_compact_oas.ml` | Acceptable but lossy | compaction is OAS-native, but importance scoring still keys on MASC marker text |
| `memory_oas_bridge.ml` | Acceptable but lossy | correct consumer-side adapter, but seeding/flushing is still imperative |
| `team_session_oas_bridge.ml` | Acceptable but lossy | OAS Swarm runs the workers, but projection/runtime-health fidelity is incomplete |
| keeper continuity path | Boundary violation | keeper still owns `working_context` and raw-text continuity markers |

## What Changed In This Pass

- `memory_oas_bridge` is no longer lying about episodic support.
  - `seed_episodes` now loads recent institution episodes from `institution_episodes.jsonl`
  - `flush_episodes` now writes new OAS episodes back without duplicating already-persisted IDs
  - `create_memory_full` now honors `episode_limit`
- `team_session` no longer launches OAS Swarm with `masc_tools=[]` and `no dispatch`.
  - start/recovery paths now pass a real supported local-worker tool subset
  - bridge dispatch auto-injects worker identity fields where needed
  - heartbeat/tool dispatch can now work in background swarm workers
- runtime duplication was reduced.
  - dashboard provider single-run now uses `Oas_worker.run_model`
  - initial local worker execution now uses `Worker_oas.run_worker_via_oas`
- path/layout ownership is narrower.
  - `cdal_loader` now resolves proof-store contract paths through `proof_artifact_reader`
  - team-session evidence readers now reuse the shared `oas-runtime` session-root helper
- keeper meta compatibility is narrower.
  - persisted legacy tool-policy fields are scrubbed into canonical `tool_access`
  - direct keeper meta parsing now rejects legacy compatibility keys instead of silently carrying them forward
- this work also exposed and fixed a real pre-existing bug:
  - `Institution_eio.load_recent_episodes_jsonl` ignored `limit` when the log was larger than the requested window

## Remaining Gaps

### 1. Team-session bridge is still lossy

The bridge still throws away part of MASC session semantics:

- `planned_worker` metadata is only partially projected into swarm entries
- per-agent telemetry now includes `trace_ref`, usage, and turn_count, so downstream proof views can link back to raw OAS runs
- convergence now uses a single-pass success-ratio callback, but not a richer multi-iteration swarm policy
- `resource_check` now guards on room initialization only; it is not yet a broader runtime-health probe
- budget now derives wall-clock time from `duration_seconds`, but there is still no richer token/cost policy

This means the runner is now tool-capable, but not yet fidelity-complete.

### 2. Keeper runtime still owns duplicated state

The public OAS worker surface no longer exposes the MASC-specific `working_context`
name and instead treats extra checkpoint JSON as a neutral checkpoint sidecar.
That helps the boundary at the worker API edge, but the keeper runtime still owns
its own `working_context` wrapper and serialized continuity path.

### 3. Resume path is only partially consolidated

Direct OAS build/run sites now remain primarily in:

- `oas_worker.ml`
- `worker_oas.ml`
- `local/worker_container_runners.ml` resume/continue path

The resume path now shares the same checkpoint/evidence/completion-log cleanup helper as the initial run path, but it still constructs resume-specific config locally before delegating into the shared execution tail.

### 4. Message marker leakage remains real

Keeper continuity still depends on raw message conventions like `[STATE]`,
goal markers, and memory-summary markers. That is workable, but it is still
boundary leakage because OAS-facing runtime/compaction paths can observe MASC
domain semantics through plain text instead of structured metadata.

### 5. Memory bridge scope is now honest, but not universal

The episodic source of truth is `Institution_eio` JSONL.
That is enough for current keeper/governance/handoff usage, but it does not mean every historical MASC memory source has been unified into OAS memory.

### 6. Some older docs are still stale by implication

The worst offenders were fixed in this pass, but any document still prioritizing:

- legacy ecosystem-loop migration
- “Event_bus bridge planned”
- “team_session is still pre-OAS”

should be treated as outdated until refreshed.

## Recommended Priorities

1. Finish keeper runtime state ownership migration so OAS owns runtime context/checkpoint semantics more directly.
2. Reduce marker/text leakage in keeper continuity and compaction-related paths.
3. Finish team-session bridge fidelity: trace refs, richer runtime-health checks, and less-lossy worker/session projection.
4. Move memory bridge lifecycle toward more reusable hook/callback seams where the abstraction stays generic.
5. Keep docs synced to code after each OAS migration step; documentation drift is currently more dangerous than the remaining missing code.
