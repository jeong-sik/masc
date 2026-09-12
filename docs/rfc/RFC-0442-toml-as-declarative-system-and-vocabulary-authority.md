---
rfc: "0442"
title: "TOML as Declarative System and Wire Vocabulary Authority"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: yousleepwhen
related: ["0004", "0032", "0141", "0335", "0361"]
---

# RFC-0442 — TOML as Declarative System and Wire Vocabulary Authority

- **Status:** Draft
- **Authors:** Vincent (yousleepwhen)
- **Created:** 2026-09-12
- **Related:** RFC-0004 (OCaml & TypeScript wire contract parity), RFC-0032 (env-knob unification), RFC-0141 (TOML field resolution typed variant), RFC-0335 (TOML single settings source), RFC-0361 (verification authority observation)
- **Issues Addressed:** #35289 (`verifier_exact` slot leakage and synthesis rollback), #35032 (dashboard backend-coupled regex scraping), #35039 (hardcoded probe budgets), #34405 (quadruplicate tool descriptions), #34379 (tool catalog ordering), #33166 (silent acceptance of unknown TOML keys)

---

## 0. Executive Summary

MASC's constitution establishes two fundamental tenets:
1. `<bar>모든 설정을 직접 할 수 있고 TOML 이 올바르게 반영된다.</bar>`
2. `<forbidden id="env_var_sprawl">환경변수를 또 만들기 전에, 이미 있는 환경변수인지, TOML로 쓰면 안 되는지 먼저 묻습니다.</forbidden>`

Despite these constitutional rules, critical runtime behaviors, cross-language vocabularies, operational timeouts, and tool catalogs have drifted into **OCaml source-code hardcoding** and **environmental knob sprawl**.

The recent defect cluster exposed the severe brittleness of this architecture:
- In **#35289**, exact-output lane policies were hardcoded in OCaml, causing first-run setup to write illegal empty tables (`slots = []`, `cli_slots = []`) that crashed TOML validation on boot.
- In **PR check CI**, frontend tests in `dashboard/` (`scripts/ci/list-dashboard-backend-coupled-tests.py`) were discovered to be **reading raw OCaml `.ml` files via `fs.readFileSync` and matching tokens with regular expressions**. Refactoring a single OCaml variable to an expression broke dashboard CI immediately.
- In **#35039**, remote microVM health probes reused a local 5-second git timeout because probe budgets are hardcoded in code rather than configured in TOML.
- In **#34405** and **#34379**, tool descriptions and orderings are duplicated across four disconnected code and test locations.

**This RFC decrees that all system capabilities, lane policies, wire vocabularies, and operational tuning parameters must be declared in TOML (or structured schema files derived from TOML/JSON), completely eliminating source-regex scraping and environmental sprawl.**

---

## 1. The Core Architectural Problems

### 1.1 Lane Policy Concealed in Code (#35289)
Exact-output lanes (`librarian_exact`, `hitl_auto_judge`, `board_attention_exact`, `verifier_exact`) are represented as table keys in `runtime.toml`, but their execution capabilities are buried in OCaml pattern matches:
- Whether a lane supports a CLI oneshot runner (`supports_cli_tail`) was only known to OCaml functions.
- `set_first_run_runtime` iterated over a hardcoded string list in code, fabricating empty tables for non-CLI lanes and aborting startup.
- Operators cannot inspect or alter lane policies without recompiling the OCaml binary.

### 1.2 Fragile Cross-Language Regex Coupling (#35032)
Six dashboard test suites enforce parity between TypeScript and OCaml:
1. `src/api/standalone-lanes-parity.test.ts` (reads `runtime.ml` and `exact_lane_run_registry.ml`)
2. `src/components/keeper-lifecycle-timeline.test.ts` (reads `keeper_lifecycle_events.ml`)
3. `src/components/keeper-turns-glow-parity.test.ts` (reads `masc_tui_answering.ml`)
4. `src/lib/keeper-attention-labels.drift.test.ts` (reads 4 OCaml modules)
5. `src/sse-event-type-parity.test.ts` (reads 17 OCaml modules)
6. `src/turn-outcome-parity.test.ts` (reads `keeper_turn_outcome.ml`)

Every one of these tests uses naive regexes (`/let verifier_exact_lane_id = "([^"]+)"/`, `matchAll(/->\s*"([^"]+)"/g)`) against backend implementation text. They do not parse ASTs; they parse formatting. This is the antithesis of a robust typed boundary.

### 1.3 Environmental Knob Sprawl & Magic Numbers
- Over 24 distinct `MASC_*_TIMEOUT` environment variables are policed by `scripts/lint/timeout-env-ceiling.sh`.
- Timeouts, retry bounds, probe intervals, and queue capacities are declared as code constants or ad-hoc environment lookups rather than declared in `runtime.toml`.
- Operators cannot discover or adjust timeouts in a single, documented configuration file.

### 1.4 Tool and Keeper Catalog Fragmentation
- Tool metadata and descriptions are declared in OCaml descriptors, golden files, test stanzas, and documentation separately.
- Parser permissiveness (#33166) silently ignores unknown keys in `[models.<id>]` and `[providers.<id>]`, masking typos and invalid configurations.

---

## 2. Target Architecture

```
                       ┌──────────────────────────────────────┐
                       │           config/schema/             │
                       │     wire_vocabularies.toml           │
                       │  (SSE events, lane IDs, outcomes)    │
                       └──────────────────┬───────────────────┘
                                          │
                         ┌────────────────┴────────────────┐
                         ▼                                 ▼
              [ OCaml Codegen / Build ]         [ TS Codegen / Build ]
              - Sse_event_types.ml              - sse-event-types.ts
              - Exact_lane_catalog.ml           - dashboard-lanes.ts
              (100% typed, 0 regexes)           (100% typed, 0 regexes)
                                          ▲
                                          │ validates
                       ┌──────────────────┴───────────────────┐
                       │      <base-path>/.masc/config/       │
                       │           runtime.toml               │
                       │  - [runtime.exact_output_lanes.*]    │
                       │  - [runtime.timeouts]                │
                       │  - [runtime.probes]                  │
                       │  - [runtime.limits]                  │
                       └──────────────────────────────────────┘
```

### 2.1 Declarative Lane Specification in `runtime.toml`
Lane declarations in `runtime.toml` must explicitly declare their policies:
```toml
[runtime.exact_output_lanes.verifier_exact]
description = "Task completion authority evaluator"
supports_cli = false
mandatory = false
slots = ["openai.gpt"]

[runtime.exact_output_lanes.librarian_exact]
description = "Repository search and contextual briefing"
supports_cli = true
mandatory = false
slots = []
cli_slots = ["codex.codex"]
```
- The OCaml runtime derives lane capabilities from the loaded TOML declaration, not hardcoded sum variants.
- Setup wizards inspect `supports_cli` from the schema before attempting to assign CLI runtimes.
- Empty lanes (`slots = [] && cli_slots = []`) are rejected universally by the TOML parser schema validator.

### 2.2 Wire Vocabularies as Shared TOML/JSON Schemas
All cross-language wire vocabularies are extracted into a shared declarative schema directory: `config/schema/wire_vocabularies.toml`.

```toml
[vocabularies.standalone_lanes]
description = "Known standalone exact-output and background execution lanes"
values = [
  "librarian_exact",
  "hitl_auto_judge",
  "board_attention_exact",
  "verifier_exact"
]

[vocabularies.turn_outcomes]
description = "Terminal turn outcome classifications"
values = [
  "completed",
  "failed",
  "cancelled",
  "blocked_on_input"
]

[vocabularies.keeper_attention_reasons]
description = "Attention triggers for keeper dispatch"
values = [
  "turn_complete",
  "user_mention",
  "system_alert",
  "review_requested"
]
```
- **Elimination of Regex Tests:** `dashboard/src/api/standalone-lanes-parity.test.ts` and its sibling tests no longer read `.ml` files. They read `config/schema/wire_vocabularies.toml` directly (or generated TypeScript enums).
- **OCaml Integration:** A Dune rule or generator emits typed closed sums from `wire_vocabularies.toml`, ensuring compile-time exhaustiveness.

### 2.3 Operational Knobs, Timeouts, and Probes in `runtime.toml`
All operational knobs policed by `timeout-env-ceiling.sh` move into structured TOML sections in `runtime.toml`:

```toml
[runtime.timeouts]
task_verification_seconds = 180
http_idle_seconds = 600
microvm_probe_seconds = 30
turn_yield_seconds = 15

[runtime.probes]
reachability_interval_seconds = 60
native_auth_probe_enabled = false

[runtime.limits]
max_concurrent_turns = 8
max_verification_evidence_bytes = 10485760
```
- `Sys.getenv_opt "MASC_*_TIMEOUT"` lookups are eliminated across `lib/`.
- All timeout readers read from the active loaded `Runtime.t` / `Runtime_config.t` snapshot.

### 2.4 Strict Schema Validation & Rejection of Unknown Keys
To fulfill #33166:
- Every table under `[runtime]`, `[models]`, `[providers]`, and `[tools]` strictly rejects unknown keys.
- Typo protection is armed uniformly across all tables with descriptive diagnostic messages pointing to valid alternatives.

---

## 3. Phased Implementation Roadmap

### Phase 1: Lane Policies & Attributes in TOML (Immediate, Resolves #35289)
1. Add `supports_cli` and `mandatory` boolean fields to `Runtime_schema.exact_output_lane_decl`.
2. Update `lib/runtime/runtime_toml.ml` to parse and validate lane policy fields with sensible defaults for backward compatibility.
3. Update `set_first_run_runtime` to inspect the lane declaration schema rather than relying on hardcoded OCaml sum variants.
4. Eliminate empty-table synthesis across all first-run setup flows.

### Phase 2: Decoupled Dashboard Wire Vocabularies (Resolves #35032 & Parity Regexes)
1. Create `config/schema/wire_vocabularies.toml` containing standalone lanes, turn outcomes, attention reasons, and SSE event types.
2. Update `scripts/ci/list-dashboard-backend-coupled-tests.py` to retire OCaml regex scanning.
3. Update all 6 dashboard parity tests to validate against `config/schema/wire_vocabularies.toml` using `Otoml` / `@iarna/toml` or generated JSON.
4. Introduce code generation for OCaml closed variants and TypeScript types from the single vocabulary TOML.

### Phase 3: Timeout & Probe Configuration Unification (Resolves Knob Sprawl & #35039)
1. Define `[runtime.timeouts]` and `[runtime.probes]` tables in `lib/runtime/runtime_toml.ml`.
2. Migrate all 24 `MASC_*_TIMEOUT` call sites in `lib/` to read through `Runtime.timeouts`.
3. Update `scripts/lint/timeout-env-ceiling.sh` to enforce that no new environment variables are added and decrement the ceiling as variables are purged.

### Phase 4: Tool Catalog SSOT & Strict TOML Validation (Resolves #34405, #34379, #33166)
1. Enforce strict unknown-key rejection across `[models.*]` and `[providers.*]` in `runtime_toml.ml`.
2. Unify tool ordering and descriptions to load directly from `config/tools/*.toml`.
3. Validate workspace boundary paths in `masc_lane_attach` (#35295) against declared TOML manifests.

---

## 4. Invariants & Constitutional Compliance

1. **`<bar>모든 설정을 직접 할 수 있고 TOML 이 올바르게 반영된다.</bar>`**:
   Eliminates unconfigurable magic numbers and code-hidden lane policies. The operator can configure every operational parameter in `runtime.toml`.
2. **`<forbidden id="env_var_sprawl">`**:
   Stops the proliferation of environment variables. Moving 24 timeout variables into `[runtime.timeouts]` directly aligns with this rule.
3. **`<forbidden id="facade">`**:
   Eliminates tests that falsely claim to verify contract parity by parsing code comments or variable string assignments with regexes.
4. **`<inv id="closed_sum_over_string">`**:
   Types in OCaml remain strictly closed sums; they are generated or backed by validated TOML schema entries rather than arbitrary ad-hoc string comparisons.

---

## 5. Verification & Safety Story

- **Backward Compatibility:** Existing `runtime.toml` files without explicit `[runtime.timeouts]` or lane attribute fields continue to parse with safe defaults.
- **Strict Linting:** `run-lint-suite.sh` verifies that no frontend test invokes `readFileSync` on OCaml `.ml` files once Phase 2 lands.
- **Atomic Reload:** `runtime.toml` updates continue to use `Fs_compat.save_file_atomic_strict_staged` and transactional registry replacement.
