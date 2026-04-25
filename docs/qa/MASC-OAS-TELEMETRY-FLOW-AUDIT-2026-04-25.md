# MASC/OAS Telemetry Flow Audit

Date: 2026-04-25 KST

## Scope

This audit covers the MASC-owned keeper telemetry repair between OAS tool execution and dashboard surfaces. OAS remains the generic agent/run/tool/proof substrate; MASC owns keeper/task/goal/sandbox/approval/runtime-radius semantics.

## Before Snapshot

The handoff snapshot from 2026-04-24T16:16:28Z showed the pipeline was partially flowing:

| Source | State |
| --- | --- |
| `oas_event` | fresh |
| `agent_event` | fresh |
| `keeper_metric` | fresh |
| `tool_call_io` | fresh |
| `tool_metric` | stale by about 34 min |
| `tool_usage` | stale by about 4.2 h |

Primary mismatch: keeper/OAS tool calls reached `.masc/tool_calls`, but the trajectory-backed `/tool-stats` lane could miss the same executions, so `/tool-calls` and `/tool-stats` disagreed.

## Implementation Result

| Surface / Store | Producer | Durable Store | Result |
| --- | --- | --- | --- |
| `/api/v1/keepers/:name/tool-calls` | `keeper_hooks_oas.post_tool_use`, `mcp_server_eio_call_tool.runtime_mcp` | `.masc/tool_calls/YYYY-MM/DD.jsonl` | Full I/O rows now include `runtime_contract` and `action_radius`. |
| `/api/v1/keepers/:name/tool-stats` | `keeper_hooks_oas.post_tool_use`, `mcp_server_eio_call_tool.runtime_mcp` | `.masc/trajectories/<keeper>/<trace>.jsonl` | Post-tool-use and runtime-MCP keeper tool traces now record trajectory `Tool_call` rows. |
| `/api/v1/dashboard/execution-trust` | `keeper_agent_run.execution_receipt` | `.masc/keepers/<keeper>/execution-receipts` | Execution receipts now include `runtime_contract` and `action_radius`. |
| `/api/v1/dashboard/telemetry/summary` | `Telemetry_unified.summary_json` | all unified telemetry stores | Each source now reports `health`, `freshness_slo_s`, `producer`, `durable_store`, `dashboard_surface`, and `stale_reason`; trajectory rows and execution receipts are first-class sources. |
| `.masc/telemetry-coverage-gaps` | trajectory/receipt failure reporters | `.masc/telemetry-coverage-gaps/YYYY-MM/DD.jsonl` | Trajectory append and receipt append failures are durable coverage gaps. |

## Runtime Contract

Keeper tool-call logs, trajectory tool-call rows, execution receipts, and unified projections now use the same canonical nested fields where the producing lane has enough context:

- `runtime_contract`: keeper/agent identity, trace/session/generation/turn, task/goal ids, sandbox/network/shared-memory/approval context, tool surface counts and required/missing tools, provider/model/cascade profile.
- `action_radius`: tool/action key, target kind/path, sandbox target, observed path-like inputs, success, duration, and error.

Existing top-level fields remain in place for backwards-compatible dashboard readers.

## Gate Decoding

Trajectory readers now parse the persisted `gate` object. Legacy rows without a readable gate remain readable as `Pass`, and `/tool-stats` reports `gate_decode.parsed_gate_count` and `gate_decode.legacy_default_count` so operators can see how much of the window is using legacy defaults.

## OAS Boundary Audit

No OAS patch was made. The audit found generic correlation already present at the OAS boundary:

| Area | Evidence | Finding |
| --- | --- | --- |
| EventBus envelope | `lib/event_bus.mli` | `correlation_id`, `run_id`, and `caused_by` are generic envelope fields. |
| Tool events | `lib/agent/agent_tools.ml` | `ToolCalled` and `ToolCompleted` propagate `correlation_id`, `run_id`, and completion `caused_by`. |
| Event forwarding | `lib/event_forward.ml` | forwarded payloads preserve `correlation_id`, `run_id`, and `caused_by`. |
| Raw trace | `lib/raw_trace.ml` | raw trace remains generic with `worker_run_id` and `session_id`; no MASC-specific fields were added. |
| Runtime evidence | `lib/runtime_server_worker.ml`, `lib/runtime_server.ml` | participant success/failure events carry `raw_trace_run_id` through runtime evidence. |

`Runtime_server_types.emit_event` publishes session-level runtime events with `correlation_id=session_id`; that path does not currently expose a per-participant `run_id`, so no MASC runtime fields were added there.

## Known Provider Gaps

Provider usage gaps remain data-source limitations, not MASC coverage failures. For example, providers/CLIs that do not report token usage should continue to be classified as `provider_unavailable` rather than a broken MASC telemetry lane.

## Verification

Focused MASC build:

```sh
scripts/dune-local.sh build test/test_trajectory.exe test/test_keeper_tool_call_log.exe test/test_dashboard_keeper_routes.exe test/test_dashboard_execution.exe test/test_telemetry_unified.exe test/test_telemetry_eio_coverage.exe
```

Result: passed.

Focused binaries:

```sh
_build/default/test/test_trajectory.exe
_build/default/test/test_keeper_tool_call_log.exe
env MASC_BASE_PATH=/tmp/masc-test-dashboard-keeper-routes _build/default/test/test_dashboard_keeper_routes.exe
env MASC_BASE_PATH=/tmp/masc-test-dashboard-execution _build/default/test/test_dashboard_execution.exe
_build/default/test/test_telemetry_unified.exe
_build/default/test/test_telemetry_eio_coverage.exe
```

Result: all passed. The two dashboard binaries require an explicit `/tmp` `MASC_BASE_PATH` because their startup guard rejects the home workspace as a test base path.

Dashboard checks:

```sh
pnpm --dir dashboard exec vitest run --no-file-parallelism --maxWorkers=1 src/components/keeper-tool-telemetry.test.ts src/components/telemetry-unified.test.ts src/api/dashboard.test.ts
pnpm --dir dashboard typecheck
pnpm --dir dashboard test -- keeper-tool-telemetry.test.ts telemetry-unified.test.ts api/dashboard.test.ts
```

Result: targeted telemetry/API tests passed, typecheck passed, and the package-script invocation completed the full dashboard suite successfully (241 files, 4045 tests). The full-suite command emitted repeated `--localstorage-file` warnings and one transient `ECONNREFUSED localhost:3000` log line from an optional browser/server probe, but the suite still exited 0.

Runtime acceptance with a fresh live keeper turn was not executed in this worktree. The code path is covered by focused tests and the next live acceptance check should confirm:

- `/api/v1/dashboard/telemetry/summary` shows fresh `keeper_metric`, `tool_call_io`, and `oas_event`.
- `/tool-stats` and `/tool-calls` agree on recent keeper tool executions.
- A sample execution receipt and trajectory row both include `runtime_contract` and `action_radius`.

Additional runtime-MCP delta found during 2026-04-25 re-verification: the live server had `sangsu` `/tool-calls` rows with `lane=runtime_mcp`, `runtime_contract`, and `action_radius`, while `/tool-stats` was empty for the same keeper because that direct runtime-MCP trace path bypassed `keeper_hooks_oas`. This report now includes the follow-up fix: `mcp_server_eio_call_tool.runtime_mcp` appends the matching trajectory row and reports append failures to `.masc/telemetry-coverage-gaps`.

Additional root-cause pass after PR review found three read-side leaks:

- Runtime-MCP trajectory rows used the ambient `Env_config_core.cluster_name` instead of the already configured keeper tool-call store root. Runtime-MCP now derives the trajectory root from `Keeper_tool_call_log.configured_masc_root`, keeping `/tool-calls` and `/tool-stats` in the same cluster namespace.
- Runtime-MCP read-before-append failures on existing trajectory files could abort the trajectory lane without a coverage gap. The read is now protected, records `runtime_mcp_trajectory_read_failed`, and still attempts the append with a conservative round value.
- Unified telemetry and the dashboard frontend did not treat `trajectory_tool_call` and `execution_receipt` as first-class sources. `/telemetry/summary`, source filters, previews, `/tool-stats`, and `/tool-calls` now preserve and render the same freshness/source metadata.

## External Currentness Evidence

- [근거] OpenTelemetry Generative AI semantic conventions are still marked `Development`; do not rename emitted fields to the latest experimental `gen_ai.*` names without a dedicated compatibility decision. Source: https://opentelemetry.io/docs/specs/semconv/gen-ai/ checked 2026-04-25 KST, confidence High.
- [근거] The MCP specification URL currently redirects to `2025-11-25`; `/mcp`, sessions, roots, headers, and security behavior should be checked against that current spec before protocol naming changes. Source: https://modelcontextprotocol.io/specification checked 2026-04-25 KST, confidence High.
