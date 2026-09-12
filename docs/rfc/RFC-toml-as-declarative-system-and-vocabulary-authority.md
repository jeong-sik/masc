# RFC — TOML as Declarative System and Wire Vocabulary Authority

- **Status**: Draft
- **Authors**: Antigravity Assistant & Jeong-sik
- **Created**: 2026-09-12
- **Related Issues**: #35289, #35032, #35039, #33166, #34405, #34379, #8462

---

## §1 Problem

Recent production investigations and triage cycles revealed widespread architecture debt where system capabilities, exact-output lane policies, wire vocabularies, timeouts, and tool definitions are hardcoded in OCaml source code, scattered across environment variables, or scraped using brittle regexes in frontend CI tests:

1. **Hardcoded Engine Capabilities & Silent Misconfiguration (#35289, PR #35300):**
   In `lib/runtime/runtime.ml:2950`, first-run auto-configuration (`Runtime.set_first_run_runtime`) indiscriminately assigned CLI runtimes to all four exact lanes (`librarian_exact`, `hitl_auto_judge`, `board_attention_exact`, `verifier_exact`) because the list of exact lanes was hardcoded in OCaml. While librarian, hitl, and board_attention have `Keeper_lane_cli_oneshot` runners, `verifier_exact` has no CLI runner. At boot, `server_runtime_bootstrap.ml:184` saw non-empty `cli_slots` and was silenced, causing a silent green boot; at completion authority time, task verification crashed when attempting to invoke the CLI client as an LLM evaluator.

```ocaml
(* lib/runtime/runtime.ml:2950 before fix *)
let set_first_run_runtime ~runtime_id ~is_cli_client () =
  (* ... *)
  List.iter (fun lane ->
    if is_cli_client then
      Runtime_toml.set_lane_slots lane ~slots:[] ~cli_slots:[ runtime_id ]
    else
      Runtime_toml.set_lane_slots lane ~slots:[ runtime_id ] ~cli_slots:[]
  ) all_exact_lanes  (* verifier_exact received cli_slots! *)
```

2. **Cross-Language Source Scraping in Frontend CI (#35032):**
   The frontend CI test runner `scripts/ci/list-dashboard-backend-coupled-tests.py` runs 6 coupled test suites that read raw OCaml backend source code files using Node `fs.readFileSync` and regular expressions:
   - `dashboard/src/components/keeper-turns-glow-parity.test.ts:25` parses `bin/masc_tui_answering.ml:18` with regex `/let finish_glow_ttl_seconds = ([0-9.]+)/`.
   - `dashboard/src/lib/turn-outcome-parity.test.ts:15` parses `lib/keeper/keeper_turn_outcome.ml:27` to extract `to_label` patterns.
   - `dashboard/src/lib/keeper-attention-labels.ts:42` and `dashboard/src/lib/keeper-attention-labels.test.ts:18` scrape `lib/keeper/keeper_status_bridge.ml:45`.
   - `dashboard/src/components/keeper-lifecycle-timeline.test.ts:22` scrapes `lib/keeper/keeper_lifecycle_transitions.ml:34`.
   - `dashboard/src/sse-event-type-parity.test.ts:46` scrapes 17 separate OCaml source files across `lib/**/*.ml` to verify 22 SSE event strings.

   This regex source scraping violates build boundary hygiene, couples the frontend build to OCaml backend implementation details, and breaks when backend pattern matching or formatting is refactored.

3. **Environment Knob Sprawl & Probe Budget Fragmentation (#35039):**
   Over 24 operational timeouts and probe budgets (`MASC_*_TIMEOUT`, `MASC_PROBE_*_SEC`, `MASC_KEEPER_AUTONOMOUS_STEP_TIMEOUT`) are scattered across arbitrary environment variables without typed validation or discovery. Operators cannot configure or audit system timeouts in one place, violating `<forbidden id="env_var_sprawl">` and the constitutional mandate `<bar>모든 설정을 직접 할 수 있고 TOML 이 올바르게 반영된다.</bar>`.

4. **Permissive Parser Defaults & Typo Invisibility (#33166, #34405):**
   Configuration parsers across `runtime.toml`, `keepers/*.toml`, and tool definitions silently ignore unrecognized keys. Operators making typos (e.g. `cl_slots` instead of `cli_slots`) observe silent default fallbacks rather than immediate parse errors.

---

## §2 Target Architecture

This RFC establishes **declarative schemas and TOML configurations as the single source of truth (SSOT)** for engine lane capabilities, cross-language wire vocabularies, operational timeouts, and tool catalogs.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Checked-in System Schema SSOT                         │
│   - config/schema/exact_output_lanes.toml   (lane engine capabilities)      │
│   - config/schema/wire_vocabularies.toml    (SSE events, outcomes, labels)  │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
                ┌──────────────────────┴──────────────────────┐
                ▼                                             ▼
     [ OCaml Code Generation ]                     [ TS Code Generation ]
     - lib/exact_output_lane_catalog.gen.ml        - dashboard/src/api/wire-vocabularies.gen.ts
     - lib/wire_vocabularies.gen.ml                (Types checked into git;
     (Closed sum variants, 0 regexes)               0 OCaml dependency for vitest)
                ▲                                             ▲
                │ validates at boot / CLI                     │
┌───────────────┴─────────────────────────────────────────────┴───────────────┐
│              Operator Configuration: <base-path>/.masc/config/runtime.toml  │
│   - [runtime.exact_output_lanes.<id>] (slots = [...], cli_slots = [...])     │
│   - [runtime.timeouts]                (step, keeper_turn, sse_keepalive)    │
│   - [runtime.probes]                  (health_interval, budget_ms)          │
│   - [runtime.limits]                  (max_backlog_items, max_tokens)       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Pillar 1: Exact-Output Lane Policy & Engine Capabilities

1. **System Invariants vs Operator Configuration:**
   - **System Invariant (Schema):** Whether an exact lane supports CLI runners (`supports_cli`) or is mandatory (`mandatory`) is an engine property dictated by available runners (e.g. `Keeper_lane_cli_oneshot` vs `Anti_rationalization`). It is **not** an operator knob.
   - **Operator Configuration (`runtime.toml`):** Operators configure **slot assignments** (`slots = [...]`, `cli_slots = [...]`).
   - Declaring fake toggles like `supports_cli = true` on `verifier_exact` in `runtime.toml` would create a `<forbidden id="facade">` since the engine cannot execute CLI slots for completion verification.

2. **Checked-in Lane Schema (`config/schema/exact_output_lanes.toml`):**
```toml
# config/schema/exact_output_lanes.toml
[lanes.verifier_exact]
description = "Task completion authority evaluator"
supports_cli = false
mandatory = false

[lanes.librarian_exact]
description = "Repository search and contextual briefing"
supports_cli = true
mandatory = false

[lanes.hitl_auto_judge]
description = "Human-in-the-loop auto adjudication"
supports_cli = true
mandatory = false

[lanes.board_attention_exact]
description = "Board attention evaluation and triaging"
supports_cli = true
mandatory = false
```

3. **Closed Sum Variant Dispatch (`<inv id="closed_sum_over_string">`):**
   - OCaml runtime maintains closed sum types for dispatch:
     ```ocaml
     type exact_lane = Librarian | Hitl_auto_judge | Board_attention | Verifier
     ```
   - Generated module `Exact_output_lane_catalog.gen.ml` binds each variant to its declared schema properties.
   - First-run wizard `Runtime.set_first_run_runtime` queries `Exact_output_lane_catalog.supports_cli lane` directly from the schema catalog, solving the chicken-and-egg defect of #35289 before `runtime.toml` is written.

4. **Fail-Closed Slot Validation in `runtime.toml`:**
   In `<base-path>/.masc/config/runtime.toml`:
```toml
[runtime.exact_output_lanes.verifier_exact]
slots = ["openai.gpt"]

[runtime.exact_output_lanes.librarian_exact]
slots = []
cli_slots = ["codex.codex"]
```
   If an operator configures `cli_slots` for a lane where `supports_cli = false` (such as `verifier_exact`), the TOML parser immediately fails closed:
   `Fatal error: exact lane 'verifier_exact' does not support cli_slots`.

### 2.2 Pillar 2: Elimination of OCaml Regex Scraping via `wire_vocabularies.toml`

1. **Shared Wire Vocabulary SSOT (`config/schema/wire_vocabularies.toml`):**
   All cross-boundary wire strings and shared constants are declared in a centralized schema:
```toml
[vocabularies.turn_outcomes]
description = "Canonical keeper turn outcome labels emitted on the wire"
source_ref = "lib/keeper/keeper_turn_outcome.ml"
values = [
  "visible_reply",
  "continuation_checkpoint",
  "external_effect_completed",
  "external_effect_pending",
  "no_visible_reply"
]

[vocabularies.keeper_attention_reasons]
description = "Reasons a keeper enters an attention-required state"
source_ref = "dashboard/src/lib/keeper-attention-labels.ts"
values = [
  "approval_pending",
  "paused",
  "runtime_attempts_exhausted",
  "provider_runtime_error",
  "fiber_unresolved",
  "runtime_blocked",
  "approval_queue_unavailable",
  "runtime_trust_snapshot_unavailable",
  "runtime_exhausted",
  "preflight_config_error",
  "degraded_retry",
  "transient_runtime_retry",
  "internal_error",
  "cancelled",
  "transcript_corruption",
  "provider_attempt_effect_fenced",
  "tool_correction_lost",
  "terminal_effect_failed",
  "unmapped_runtime_state"
]

[constants.tui]
finish_glow_ttl_seconds = 60.0

[vocabularies.sse_events]
description = "SSE event types routed by exact match"
backend_emitted = [
  "approval:audit",
  "approval:pending",
  "approval:resolved",
  "approval:summary_updated",
  "execution_snapshot",
  "runtime_param_changed",
  "keeper_chat_appended",
  "keeper_waiting_inventory_changed",
  "keeper_composite_changed",
  "keeper_heartbeat",
  "keeper_turn_complete",
  "agent_core_telemetry_sample",
  "operator_digest",
  "operator_snapshot",
  "post_created",
  "project_snapshot",
  "transport_health_snapshot",
  "fusion_run_status",
  "workspace_message_delivery_changed"
]
fe_only = [
  "heartbeat",
  "system_connected",
  "stream_reconnect_scheduled"
]
```

2. **Frontend & Backend Decoupling (No Local Dune Requirement):**
   - Code generation is executed via `python3 scripts/sync-wire-vocabularies.py`:
     - Emits `dashboard/src/api/schemas/wire-vocabularies.gen.ts`.
     - Emits `lib/wire_vocabularies.gen.ml`.
   - Generated files are committed to version control.
   - Frontend CI and local developers run `vitest` in `dashboard/` with **zero dependency on OCaml or Dune**.
   - A CI hygiene lint (`scripts/ci/check-wire-vocabulary-drift.sh`) ensures that checked-in generated files never drift from `config/schema/wire_vocabularies.toml`.
   - Regex-based source reading (`fs.readFileSync`) is completely removed from all 6 frontend parity tests.

### 2.3 Pillar 3: Unification of Environment Knob Sprawl into `runtime.toml`

1. **Declarative Section in `<base-path>/.masc/config/runtime.toml`:**
   Collapse arbitrary environment knobs into structured TOML sections:
```toml
[runtime.timeouts]
step_seconds = 300
keeper_turn_seconds = 600
completion_authority_seconds = 180
http_client_connect_seconds = 10
http_client_total_seconds = 60
sse_keepalive_seconds = 15
process_cleanup_seconds = 30

[runtime.probes]
health_interval_seconds = 5
probe_budget_seconds = 3
liveness_stale_threshold_seconds = 30

[runtime.limits]
max_turn_retries = 3
max_concurrent_keepers = 16
max_backlog_tasks = 1000
```

2. **Strict Non-Permissive Parsing (`<forbidden id="legacy_residue">`, `<inv id="strict_parse_no_default">`):**
   - No backward-compatibility fallback ladders.
   - Missing required keys fail closed at boot.
   - For non-OCaml harness or external CLI scripts that require timeouts, a lightweight accessor script (`scripts/runtime-config.py --get runtime.timeouts.step_seconds`) or environment injection during process launch is used, eliminating loose ad-hoc environment variable reads.

### 2.4 Pillar 4: Tool & Keeper Catalog Declarations

1. **Declarative Tool Catalog (`config/tools/*.toml`):**
   All system and extension tools are declared via standalone TOML files with explicit parameter schemas, effect domains, and timeout policies.
2. **Strict Typo Protection (#33166):**
   All TOML loaders must check keys against an exhaustive allowed set. Unknown keys immediately raise descriptive errors:
   `Unknown configuration key 'cl_slots' under [runtime.exact_output_lanes.verifier_exact]. Did you mean 'cli_slots'?`

---

## §3 Phased Implementation Plan

### Phase 1: Shared Wire Vocabulary SSOT & Elimination of Frontend Regex Scraping
- Create `config/schema/wire_vocabularies.toml` with `turn_outcomes`, `keeper_attention_reasons`, `tui.finish_glow_ttl_seconds`, and `sse_events`.
- Author `scripts/sync-wire-vocabularies.py` to generate `dashboard/src/api/schemas/wire-vocabularies.gen.ts` and `lib/wire_vocabularies.gen.ml`.
- Add drift check `scripts/ci/check-wire-vocabulary-drift.sh` to CI.
- Migrate the 6 frontend test suites to consume the generated TypeScript module.
- Delete regex-scraping code from `scripts/ci/list-dashboard-backend-coupled-tests.py`.

### Phase 2: Exact-Output Lane Policy & Setup Wizard Wiring
- Create `config/schema/exact_output_lanes.toml` declaring engine capabilities (`supports_cli`, `description`, `mandatory`).
- Generate / wire `Exact_output_lane_catalog.gen.ml`.
- Update `Runtime.set_first_run_runtime` to inspect `Exact_output_lane_catalog.supports_cli` instead of hardcoding lane assignments.
- Enforce strict validation in `Runtime_toml`: reject `cli_slots` on lanes that declare `supports_cli = false`.
- Add unit and integration tests verifying parse failure upon invalid slot configuration.

### Phase 3: Consolidation of Timeouts and Limits into `runtime.toml`
- Define `[runtime.timeouts]`, `[runtime.probes]`, and `[runtime.limits]` schema.
- Implement strict TOML parser in `lib/config/runtime_config_timeouts.ml`.
- Update OCaml runtime systems to consume structured timeouts from `Runtime.timeouts ()`.
- Provide `scripts/runtime-config.py` for Python and bash harness scripts to read resolved TOML values.
- Deprecate and remove legacy `MASC_*_TIMEOUT` environment variables.

### Phase 4: Unified Tool Catalog & Typo Protection
- Extend strict unknown-key validation across all TOML loaders in `lib/config/` and `packages/agent_core/`.
- Validate dynamic table keys against declared schemas.
- Add typo distance calculation (Levenshtein distance) in error diagnostics.

---

## §4 Non-Goals & Invariants

1. **No Stringly-Typed Dispatch in Engine (`<inv id="closed_sum_over_string">`):**
   OCaml engine execution must remain dispatching on closed sum variants (`type exact_lane`, `type turn_outcome`). The engine will not perform dynamic string dispatch at runtime.
2. **No Pseudo-Configuration Facades (`<forbidden id="facade">`):**
   Engine invariants (such as `supports_cli = false` for verification authority) will not be exposed as user-editable toggles in `runtime.toml`.
3. **No Legacy Residue or Fallback Ladders (`<forbidden id="legacy_residue">`):**
   MASC is an unreleased system; `<base-path>/.masc` will be re-seeded cleanly. No legacy fallbacks, default masking, or backward-compatibility migrations will be introduced.
4. **No Local Dune Requirement for Frontend Tests (`<build_and_ci>`):**
   Generated TypeScript schemas are checked into git so frontend testing remains completely independent of the OCaml toolchain.
