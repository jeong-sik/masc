---
status: runbook
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_exec_masc.ml
  - lib/cascade/
  - lib/mcp_server.ml
---

# OAS Boundary Health Check - 2026-03-31

Scope: `masc-mcp` to OAS boundary health snapshot on commit `aade21ba7402baede95e565c503d3e38a923558b`

## Verdict

Initial boundary health is `healthy with known structural gaps`.

- Boundary build and targeted tests passed.
- Live OpenAPI export passed when run with local port binding enabled.
- No unsafe boundary-pattern hits were found in the checked OAS-facing modules.
- Known risks remain the same as the current audit: team-session bridge fidelity and the narrow boolean `resource_check`.

## Evidence

### Static checks

- `dune build --root .`
  - Result: pass
  - [evidence] source: local command; checked: 2026-03-31; confidence: High

- `scripts/check-oas-pin.sh`
  - Result: pass with drift warning
  - Warning: pinned `61e5314630c3db7b6415b937e83f4beac27897ee`, upstream `main` `0fea023a7c8a40e5a55eefd6c6c53894641d9c96`
  - [evidence] source: local command + upstream git ref check; checked: 2026-03-31; confidence: High

- `bash scripts/health_snapshot.sh --skip-build --json-out .health/health-snapshot.json`
  - Result: completed
  - Note: repo-wide snapshot still reports `Anti-fake: suspect=16 fake=55` and `.ml` line-cap `manual=159`
  - Interpretation: this is a repository health concern, not a boundary-specific failure
  - [evidence] source: local command; checked: 2026-03-31; confidence: High

### Boundary tests

- `_build/default/test/test_oas_integration.exe`
  - Result: pass, 8 tests
  - [evidence] source: local test binary; checked: 2026-03-31; confidence: High

- `_build/default/test/test_oas_adapters.exe`
  - Result: pass, 9 tests
  - [evidence] source: local test binary; checked: 2026-03-31; confidence: High

- `_build/default/test/test_oas_worker.exe`
  - Result: pass, 34 tests
  - Focus: cascade config, SSE bridge, OAS checkpoint continuity, keeper handoff rollover
  - [evidence] source: local test binary; checked: 2026-03-31; confidence: High

- `_build/default/test/test_team_session_oas_bridge.exe`
  - Result: pass, 32 tests
  - Focus: role projection, cascade resolution, supported-tool filtering, `resource_check` presence, telemetry `trace_ref`
  - [evidence] source: local test binary; checked: 2026-03-31; confidence: High

- `_build/default/test/test_tool_local_runtime_verify.exe`
  - Result: pass, 5 tests
  - Focus: provider health, runtime blockers, contract mismatch handling
  - [evidence] source: local test binary; checked: 2026-03-31; confidence: High

- `_build/default/test/test_local_runtime_pool.exe`
  - Result: pass, 9 tests
  - Focus: runtime env parsing, slot acquisition, measured ceiling recording
  - [evidence] source: local test binary; checked: 2026-03-31; confidence: High

- `_build/default/test/test_dashboard_harness_health.exe`
  - Result: pass, 6 tests
  - Focus: persisted runtime-signal surfacing and stale-signal handling
  - [evidence] source: local test binary; checked: 2026-03-31; confidence: High

- `_build/default/test/test_openapi_api_e2e.exe`
  - Result: pass, 1 test
  - Note: sandbox execution skipped because local port bind was unavailable; rerun with local port binding enabled succeeded
  - [evidence] source: local e2e test; checked: 2026-03-31; confidence: High

### Boundary module hygiene

Checked modules:

- `lib/oas_worker.ml`
- `lib/worker_oas.ml`
- `lib/memory_oas_bridge.ml`
- `lib/context_compact_oas.ml`
- `lib/verifier_oas.ml`
- `lib/keeper/keeper_hooks_oas.ml`
- `lib/keeper/keeper_tools_oas.ml`
- `lib/team_session/team_session_oas_bridge.ml`

Command:

- `rg -n "failwith|Option\\.get|Obj\\.magic|List\\.hd|List\\.tl" lib/oas_*.ml lib/*oas*.ml lib/team_session/team_session_oas_bridge.ml lib/keeper/*oas*.ml -g '!_build'`
  - Result: no matches
  - [evidence] source: local command; checked: 2026-03-31; confidence: High

## Current Risks

These remain aligned with the existing audit and boundary contract docs, not new regressions found in this check.

1. `team_session` bridge fidelity is still incomplete.
2. `resource_check` is still a narrow boolean gate rather than a richer runtime-health probe.
3. Several OAS-facing files remain large enough that future boundary drift is likely to hide in file-size complexity.

## Next Actions

1. Replace the current boolean `resource_check` path with a structured runtime-health probe.
2. Keep reducing fidelity loss in `team_session_oas_bridge` projection and telemetry export.
3. Break down the largest OAS-facing files before the next migration step adds more bridge logic.
