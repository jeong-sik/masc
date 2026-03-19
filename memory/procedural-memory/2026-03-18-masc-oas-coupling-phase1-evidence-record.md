# MASC ↔ OAS Coupling Analysis Phase 1 — Evidence Record

**Date**: 2026-03-18  
**Author**: Claude Code  
**Scope**: OAS v0.50.0, MASC v2.110.0  
**Verification**: Complete file enumeration + API surface mapping (9 MASC files, 100% read coverage)  
**Confidence**: High (code-based, not inferred)

---

## Evidence Summary

### What Was Discovered

MASC (Multi-Agent Streaming Coordination) depends on OCaml Agent SDK (OAS) v0.50.0 at **two distinct layers**:

1. **Core Execution Layer** (local_agent_eio_container.ml, spawn_eio.ml):
   - MASC wraps `Oas.Agent.t` in custom container for checkpoint persistence, metadata tracking, and evidence audit
   - MASC routes provider config via cascading logic (Provider_adapter → Llm_client → Oas.Provider.config)
   - Checkpoint serialization uses `Oas.Checkpoint.of_string/to_string` (implicit coupling)
   - Tool schemas converted via `Oas.Mcp.mcp_tool_to_sdk_tool` (delegation pattern)

2. **Trace & Evidence Integration Layer** (tool_team_session_step_exec.ml, tool_team_session_step_types.ml):
   - MASC retrieves OAS trace data via injected functions: `oas_worker_evidence_payload`, `oas_trace_capability_to_string`, `oas_worker_status_to_json`, `raw_trace_run_ref_to_json`
   - MASC merges OAS-produced trace metadata with MASC-tracked worker snapshots
   - Raw trace references (`Oas.Raw_trace.run_ref`) persisted in worker metadata
   - Evidence audit trails persist via `Oas.Direct_evidence.persist`

### What Does NOT Exist (Gaps)

OAS lacks **consumer-facing utilities** for:
- Checkpoint restoration from serialized format (MASC works around with direct deserialization)
- Trace data serialization to JSON (MASC injects custom converters)
- Provider resolution from model_spec (MASC duplicates logic via Provider_adapter)
- Worker metadata enrichment (MASC manually merges evidence fields)
- Execution scope → guardrail mapping (MASC couples team_session_types to guardrail config)

### Why This Matters for OAS Issue #144 (lwt→eio)

The identified gaps are **independent of async runtime** (lwt vs eio). They represent architectural abstraction layers that exist in MASC because OAS doesn't expose them. Converting lwt→eio will require:

1. Ensuring **all async boundaries** in OAS remain consistent (Eio.t return types)
2. Exposing **checkpoint and trace utilities** as Eio-based functions to remove MASC's workarounds
3. Verifying **provider resolution pipeline** works correctly with new async model

**Risk**: If OAS leaves checkpoint/trace/provider resolution unexposed, lwt→eio conversion will still require MASC to maintain custom adapters. Unify them now.

---

## Verification Method

**Source**: File-by-file analysis of MASC OCaml codebase
**Files Analyzed** (9 total):
1. `lib/local_agent_eio_runners.ml` (651 lines)
2. `lib/tool_team_session_support.ml` (728 lines)
3. `lib/tool_team_session_handlers.ml` (800 lines)
4. `lib/tool_team_session_step.mli` (291 lines)
5. `lib/local_agent_eio_container.ml` (613 lines) ← Core execution layer
6. `lib/local_agent_eio_types.ml` (693 lines) ← Metadata carrier
7. `lib/spawn_eio.ml` (400+ lines) ← Provider routing + spawn lifecycle
8. `lib/tool_team_session_step_exec.ml` (450+ lines) ← Evidence integration
9. `lib/tool_team_session_step_types.ml` (149 lines) ← Dependency injection

**Methodology**:
- Grep for `Oas\.` module references across codebase (returned 9 files)
- Read each file completely to understand usage patterns
- Mapped OAS types to usage: `Oas.Provider.config` (9 files), `Oas.Agent.t` (5 files), `Oas.Sessions.worker_run` (4 files), etc.
- Extracted dependency injection interfaces (step_deps record, 41 fields)
- Documented checkpoint persistence pattern (lines 322/332)
- Traced evidence payload flow (lines 231–273)

**Reproducibility**: Run in masc-mcp worktree:
```bash
rg 'Oas\.' lib/ --no-heading --line-number
# Returns 9 files with Oas module references
```

Then inspect each file using `mcp__serena__read_file` to extract:
1. Type usage (type constructors, pattern matches)
2. Function calls (Provider_adapter cascade, Direct_evidence.persist, etc.)
3. Dependency injection signatures (step_deps, oas_worker_evidence_payload, etc.)

---

## Uncertainty & Limitations

| Uncertainty | Mitigation | Confidence |
|-------------|-----------|------------|
| OAS v0.50.0 API stability | OAS versions stable per dune-project. API surface unlikely to change mid-version. | High |
| MASC usage patterns completeness | Grep for `Oas\.` returned 9 files. Manual inspection confirmed no false negatives. | High |
| Gap severity assessment | Based on code inspection, not runtime testing. Gaps are **architectural** not **functional** (MASC works). | Medium (architecture-level, not failure-level) |
| Provider cascade necessity | Current logic supports Llama + custom providers. Unknown if OAS v0.51+ will expose provider resolution. | Medium (external dependency) |
| Trace serialization patterns | Injected functions may be work-in-progress. Unclear if OAS plans to expose these publicly. | Medium |

**Applicability Scope**: 
- Findings apply to **MASC v2.110.0 + OAS v0.50.0** specifically
- Upgrades to OAS v0.51+ may close some gaps
- Patterns may differ if MASC consumer (e.g., Figma MCP) uses different orchestration

---

## Recommendations (By Priority)

### Immediate (Blocks OAS #144)
1. **Expose checkpoint restoration** as public OAS API
   ```ocaml
   val Oas.Checkpoint.of_yojson : Yojson.Safe.t → (t, string) result
   val Oas.Checkpoint.to_yojson : t -> Yojson.Safe.t
   ```

2. **Expose trace serialization utilities**
   ```ocaml
   val Oas.Sessions.trace_capability_to_yojson : trace_capability → Yojson.Safe.t
   val Oas.Sessions.worker_status_to_yojson : worker_status → Yojson.Safe.t
   val Oas.Raw_trace.run_ref_to_yojson : run_ref → Yojson.Safe.t
   ```

3. **Expose provider resolution**
   ```ocaml
   val Oas.Provider.resolve : model_id:string → (config, string) result
   ```

### Follow-Up (Nice-to-Have)
4. Checkpoint lifecycle manager (error recovery + gc)
5. Worker metadata enrichment builder
6. Execution scope → guardrail mapper

---

## Related Issues & PRs

- **OAS Issue #144**: lwt→eio conversion (main context)
- **MASC PR #1410** (Draft): Evidence payload integration (depends on OAS utilities)
- **OAS Consumer Gap**: Unknown (does Figma MCP or other consumers face same gaps?)

---

## Next Steps

1. **OAS Team**: Review gaps 1–3 above for inclusion in v0.51 release
2. **MASC Team**: Once OAS exposes utilities, refactor local_agent_eio_container.ml and tool_team_session_step_exec.ml to use OAS functions instead of custom adapters
3. **Cross-Project**: Audit other OAS consumers (Figma MCP, etc.) to validate gap severity

