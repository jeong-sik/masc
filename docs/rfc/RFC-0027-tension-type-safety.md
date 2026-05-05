# RFC 0027 — Tension Type Safety and Configurable Severity

- Status: Draft
- Author: Vincent (vincent.dev@kidsnote.com)
- Date: 2026-05-05
- Related RFCs:
  - RFC-0026 (Work-Conserving Keeper Admission) — orthogonal
- Modules affected:
  - `lib/meta_cognition_types.ml` / `.mli` — type definitions
  - `lib/meta_cognition_rules.ml` / `.mli` — rule definitions
  - `lib/meta_cognition_parse.ml` / `.mli` — JSON parsing
  - `lib/meta_cognition_interpret.ml` / `.mli` — salience interpretation
  - `lib/meta_cognition_snapshot.ml` — snapshot assembly
  - `lib/meta_cognition.ml` / `.mli` — public API
  - `lib/tool_board.ml` — board tool surface
  - `lib/dashboard_tla_specs.ml` — TLA+ specs

## 0. TL;DR

The tension subsystem uses `string option` for `severity` and `kind` fields
in `tension_summary` and `tension_rule`. The operator-escalation decision
compares `tension.severity = Some "high"` — a magic string with no
compile-time guarantee. This RFC replaces all stringly-typed tension fields
with proper OCaml variants, makes the escalation threshold configurable,
and adds recurrence tracking with typed persistence.

## 1. Problem Statement

### 1.1 Stringly-typed severity

Current code (`meta_cognition_interpret.ml:75`):

```ocaml
| Operator_tension,
  match summary.top_tension with
  | Some tension -> tension.needs_operator || tension.severity = Some "high"
  | None -> false
```

If the LLM produces `severity = "High"` (capital H) or `severity = "critical"`,
the escalation silently fails. There is no compile-time check that the
string values are valid.

### 1.2 Stringly-typed kind

`tension_rule.kind` is `"policy_gap" | "boredom" | "blocker"` — but as a
plain string. Adding a new kind requires coordinated manual edits across
multiple files with no exhaustiveness checking.

### 1.3 No configurable threshold

The escalation threshold is hardwired to `severity = Some "high"`. Operators
cannot tune this per-deployment without a code change. A deployment that
wants `medium` tensions to trigger operator intervention has no mechanism.

### 1.4 No typed persistence

Tension recurrence (`recurrence_count`) is parsed from JSON summaries
produced by the LLM. The count is not tracked in persistent storage —
it resets when the board context window rolls over. This makes
recurrence-based escalation unreliable.

## 2. Proposed Changes

### 2.1 Variant types for severity and kind

In `meta_cognition_types.ml`:

```ocaml
type tension_severity =
  | Low
  | Medium
  | High
  | Critical
[@@deriving show, eq, ord]

type tension_kind =
  | Policy_gap
  | Boredom
  | Blocker
  | Custom of string  (* forward-compatible for operator-defined kinds *)
[@@deriving show, eq]
```

### 2.2 Updated `tension_summary` and `tension_rule`

```ocaml
type tension_summary = {
  id : string option;
  topic : string option;
  kind : tension_kind option;        (* was: string option *)
  severity : tension_severity option; (* was: string option *)
  recurrence_count : int option;
  needs_operator : bool;
  evidence_refs : string list;
}

type tension_rule = {
  id : string;
  topic : string;
  kind : tension_kind;               (* was: string *)
  matches : source -> bool;
}
```

### 2.3 Configurable escalation threshold

In `Env_config_keeper` (or `Keeper_config`):

```ocaml
(* Minimum severity that triggers Operator_tension salience.
   Env: MASC_TENSION_OPERATOR_SEVERITY_THRESHOLD. Default: High.
   Accepted values: low, medium, high, critical. *)
let operator_severity_threshold : tension_severity =
  match Env_config_core.resolve "MASC_TENSION_OPERATOR_SEVERITY_THRESHOLD" with
  | Some "low"      -> Low
  | Some "medium"   -> Medium
  | Some "critical" -> Critical
  | _               -> High  (* default *)
```

Updated interpretation logic:

```ocaml
| Operator_tension,
  match summary.top_tension with
  | Some tension ->
      tension.needs_operator
      || (match tension.severity with
          | Some sev -> sev >= operator_severity_threshold
          | None -> false)
  | None -> false
```

### 2.4 Severity parsing from LLM JSON

In `meta_cognition_parse.ml`, add robust parsing:

```ocaml
let parse_severity = function
  | `String s ->
      (match String.lowercase_ascii (String.trim s) with
       | "low"      -> Some Low
       | "medium"   -> Some Medium
       | "high"     -> Some High
       | "critical" -> Some Critical
       | _ ->
           Log.Misc.warn "tension_parse: unknown severity %S, defaulting to Low" s;
           Some Low)
  | _ -> None

let parse_kind = function
  | `String s ->
      (match String.lowercase_ascii (String.trim s) with
       | "policy_gap" -> Some Policy_gap
       | "boredom"    -> Some Boredom
       | "blocker"    -> Some Blocker
       | other        -> Some (Custom other))
  | _ -> None
```

### 2.5 Recurrence persistence (Phase 2)

Phase 1 (this RFC): type safety only. No storage changes.

Phase 2 (future): persist tension events to `dated_jsonl` so recurrence
counts survive context window rollover. This requires a new
`tension_event` type and a log-rotation policy, which should be its own
RFC because it introduces a new IO path in the meta-cognition loop.

## 3. Migration Plan

### Phase 1: Type definitions + parsing

1. Add `tension_severity` and `tension_kind` variants to `meta_cognition_types.ml`
2. Update `tension_summary` and `tension_rule` field types
3. Update `meta_cognition_rules.ml` — replace string literals with variant constructors
4. Update `meta_cognition_parse.ml` — add `parse_severity`/`parse_kind`
5. Update `meta_cognition_interpret.ml` — replace string comparison with variant comparison
6. Update JSON serialization (to_json functions) to emit lowercase strings
7. Update all `.mli` files

### Phase 2: Configurable threshold

1. Add `MASC_TENSION_OPERATOR_SEVERITY_THRESHOLD` env var to `Env_config_keeper`
2. Wire into `meta_cognition_interpret.ml` via parameter or config read
3. Default to `High` (preserving current behavior)

### Phase 3: Recurrence persistence (future, separate RFC)

- New `tension_event` log in `dated_jsonl/`
- `recurrence_count` computed from persistent log, not just LLM output
- Dashboard surface for tension history

## 4. Invariants

**I1 (severity ordering)**: `Low < Medium < High < Critical`. The `ord`
deriving ensures `>=` comparison works correctly.

**I2 (forward-compatible kind)**: Unknown LLM-produced kinds map to
`Custom string`, never to a default variant. Dashboard/logs display the
raw string.

**I3 (threshold default stability)**: When the env var is unset or
invalid, the threshold falls back to `High` — identical to the current
hardcoded `= Some "high"` behavior.

**I4 (JSON round-trip)**: `parse_severity (severity_to_json sev) = Some sev`
for all four variants. Unknown strings parse to `Custom` (kind) or
default to `Low` with a warning (severity).

## 5. Affected Callers

| Caller | Change |
|--------|--------|
| `meta_cognition_rules.ml` | `kind = "policy_gap"` → `kind = Policy_gap` |
| `meta_cognition_interpret.ml:75` | `severity = Some "high"` → `severity >= threshold` |
| `meta_cognition_parse.ml` | Add variant parsers |
| `meta_cognition_snapshot.ml` | Update summary assembly |
| `tool_board.ml` | Update JSON construction for board posts |
| `dashboard_tla_specs.ml` | Update TLA+ spec constants |
| `masc_grpc_server.ml` | Update gRPC response mapping |
| `tool_schemas/tool_schemas_agent.ml` | Update schema descriptions |
| `prompt_registry.ml` | Update prompt templates referencing tension kinds |
| `anti_rationalization.ml` | Update rationalization detection |
| `keeper_meta_store.ml` | Update meta persistence |
| `keeper_types_profile.ml` | Update profile tension fields |
| `keeper_turn_fsm.mli` | Update FSM event types |
| `server_routes_http_pages.mli` | Update dashboard routes |
| `server_dashboard_http_core.ml` | Update dashboard rendering |
| `server_dashboard_http_link_preview.ml` | Update link preview |
| `server_dashboard_http_namespace_truth_support.ml` | Update truth support |

## 6. Scope Boundaries

**In scope (Phase 1)**:
- Type definitions
- Parsing/serialization
- Interpretation logic
- Configurable threshold

**Out of scope**:
- Recurrence persistence (Phase 2, separate RFC)
- New tension rules or severity levels
- Dashboard UI changes
- TLA+ spec changes (update constants only)

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| LLM produces unexpected severity string | Medium | Low (parse → Low + warn) | Robust parser with fallback |
| JSON round-trip breakage | Low | High (dashboard/gRPC desync) | Property test `parse ∘ to_json = id` |
| Caller migration misses a file | Medium | Medium (compile error) | `dune build` catches all |
| Threshold env var typo | Low | Low (fallback to High) | Documented accepted values |

## 8. Testing

1. **Unit tests**: `parse_severity` covers all 4 variants + 3 invalid inputs
2. **Property test**: `parse_severity (severity_to_json s) = Some s` for all variants
3. **Interpretation test**: `Operator_tension` triggers at threshold but not below
4. **Integration test**: Full summary JSON → parse → interpret → correct salience
5. **Regression test**: Existing tension fixtures produce identical salience with new types
