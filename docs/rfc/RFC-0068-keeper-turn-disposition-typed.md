# RFC-0068 — Typed `Keeper_turn_disposition` (operator-facing closed sum)

> **Renumber note (2026-05-12)**: Originally filed as RFC-0047 on 2026-05-08,
> conflicting with `RFC-0047-oas-adapter-decomposition.md` (Implemented
> #14314). Renumbered to RFC-0068 to resolve the collision, mirroring the
> RFC-0057 → RFC-0067 renumber pattern (#14672).

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-05-08
- **Related**:
  - RFC-0042 (closed sum for runtime terminal code, MERGED)
  - RFC-0042 PR-3 (deferred — see §6 below)
- **Drives**: separate the runtime-termination layer (RFC-0042) from the
  operator-facing disposition layer that `Keeper_turn_terminal.t` actually
  carries today, so that `severity / summary / next_action` become
  exhaustive matches on a closed sum instead of string-substring
  classifiers.

## 1. Problem — RFC-0042 PR-3 cannot land cleanly

RFC-0042 PR-3 was supposed to swap `Keeper_turn_terminal.t.code` from
`string` to `Keeper_turn_terminal_code.t`. Diagnosis from PR-2.5 close-out
(2026-05-08) shows the swap is structurally wrong: the two types are at
**different abstraction layers** and their wire-code sets are nearly
disjoint.

### 1.1 Layer mismatch — concrete inventory

`Keeper_turn_terminal_code.t` (RFC-0042 PR-1 + PR-2.5) — **runtime layer**:

```
Healthy / Stale_turn_timeout_idle | _in_turn | _noop /
Stale_termination_storm / Stale_fleet_batch / Oas_timeout_budget /
Heartbeat_failures / Turn_failures /
Provider_runtime_error of string / Tool_required_unsatisfied of string /
Ambiguous_partial_commit_* / Fiber_unresolved /
Exception_unhandled of string / Sdk_error of string
```

Sources: `Keeper_registry.failure_reason`, `Agent_sdk.Error.sdk_error`.
Concern: *what terminated the turn at the runtime / SDK boundary?*

`Keeper_turn_terminal.t.code` (string today) — **application layer**:

```
"success" / "external_cancel" / "turn_wall_clock_timeout" /
"oas_timeout_budget" / "gh_repo_context_missing_worktree" /
"required_tool_use_no_tool_call" / "required_tool_use_unsatisfied" /
"post_commit_ambiguous" / "provider_error" / "unknown_error" /
"api_error_*" (substring) / "completion_contract_violation:..." (substring)
```

Sources: `severity_of_code`, `summary_of_code`, `next_action_of_code`,
`normalize_code` in `lib/keeper/keeper_turn_terminal.ml`.
Concern: *what should the operator see / do?*

Only `Oas_timeout_budget` overlaps as a literal. Everything else is
distinct.

### 1.2 Why the existing `Keeper_turn_terminal_code.t` cannot absorb this

If we tried to merge — i.e., add `Success`, `External_cancel`,
`Turn_wall_clock_timeout`, `Gh_repo_context_missing_worktree`,
`Required_tool_use_no_tool_call`, `Required_tool_use_unsatisfied`,
`Post_commit_ambiguous`, `Provider_error`, `Unknown_error` to `t` — we
would conflate two domains:

- Runtime cause (what the SDK/registry reported)
- Operator outcome (what the dashboard chip says)

A single `Keeper_registry.Stale_turn_timeout (In_turn_hung _)` would
need *two* values: its runtime classification (`Stale_turn_timeout_in_turn`)
and its operator disposition (`Turn_wall_clock_timeout`). The single-type
approach forces every reader to know about every arm of every layer.

The substring matchers in `severity_of_code`
(`String.starts_with ~prefix:"api_error_"`) document this: they are
already silently doing layer-2 (disposition) classification on top of
layer-1 (runtime) wire strings. RFC-0042 PR-3 alone cannot remove them.

## 2. Goals & non-goals

### Goals

| # | Goal |
|---|------|
| G1 | `severity / summary / next_action` become exhaustive `match` on a closed sum, no substring matching. |
| G2 | Adding a new operator disposition is a compile error in every consumer. |
| G3 | Layer separation: runtime termination (`Keeper_turn_terminal_code.t`) and operator disposition (`Keeper_turn_disposition.t`) are two distinct types. Promotion is explicit (`Provider_error of Keeper_turn_terminal_code.t`). |
| G4 | Wire format on the receipt JSON `code` field is byte-for-byte preserved during PR-1 and PR-2; PR-3 is the only step that can change it (and only by *adding* fields, not removing). |
| G5 | RFC-0042 PR-3 (the field-swap step) is replaced by RFC-0068 PR-2/PR-3 (the disposition migration). The runtime type stays narrow. |

### Non-goals

| # | Non-goal |
|---|---------|
| NG1 | Removing `Keeper_turn_terminal_code.t` or merging it into `Keeper_turn_disposition.t`. The two layers stay distinct. |
| NG2 | Removing `Keeper_turn_terminal.t` itself; we only retype its `code` field over PR-2/PR-3. |
| NG3 | Solving `lib/prometheus.ml` godfile (orthogonal). |
| NG4 | Per-variant breakdown of `Provider_error` (e.g., `Provider_error_rate_limited`). The runtime layer carries the parametrised wire under `Sdk_error of string`; operator disposition does not need that granularity yet. |

## 3. Design

### 3.1 New module — `Keeper_turn_disposition`

```ocaml
(* lib/keeper/keeper_turn_disposition.mli *)

type t =
  | Success
      (** Turn completed normally. Severity Ok. *)
  | External_cancel
      (** Turn cancelled before completion (operator stop, switch_keeper, etc.). *)
  | Turn_wall_clock_timeout
      (** Turn exceeded its wall-clock budget. *)
  | Oas_timeout_budget
      (** OAS turn-budget cooldown / cap rejection. *)
  | Gh_repo_context_missing_worktree
      (** GitHub command blocked because the active task has no linked
          worktree. *)
  | Required_tool_use_no_tool_call
      (** Required-tool-use contract: model returned no tool call. *)
  | Required_tool_use_unsatisfied
      (** Required-tool-use contract: tool call did not satisfy the
          contract. *)
  | Post_commit_ambiguous
      (** Provider failed after a mutating tool may have committed side
          effects. Reconcile_partial_commit. *)
  | Provider_error of Keeper_turn_terminal_code.t
      (** Runtime-layer termination promoted to operator-facing
          disposition. Wraps the typed runtime cause for diagnostics
          (Prometheus / dashboard / bin/masc-trace). [to_wire] uses the
          inner code's wire. *)
  | Unknown of { raw_error : string }
      (** Last-resort escape hatch for un-classified producer paths.
          [raw_error] is the original message; [to_wire] returns
          ["unknown_error"] when [raw_error] is empty, else [raw_error]
          verbatim (matches the legacy [of_legacy_error_text "" → "unknown_error"]
          behaviour). PR-3 lint blocks reuse of identical [raw_error]
          payloads at >= 2 sites — those must be promoted to a
          constructor. *)

type severity = Ok | Warn | Bad | Unknown_bad

val severity : t -> severity
val summary : t -> string
val next_action : t -> string option

val to_wire : t -> string
val of_wire : string -> t
(** Best-effort deserialiser. Unknown wire strings produce
    [Unknown { raw_error = wire }]. Layer-1 wire strings (e.g.,
    "stale_turn_timeout", "api_error_overloaded") deserialise via
    [Keeper_turn_terminal_code.of_wire] then through
    [of_termination_code]. *)

val of_termination_code : Keeper_turn_terminal_code.t -> t
(** Canonical projection from runtime layer to operator layer.

    - [Healthy]                    → [Success]
    - [Stale_turn_timeout_*]       → [Turn_wall_clock_timeout]
    - [Oas_timeout_budget]         → [Oas_timeout_budget]
    - [Heartbeat_failures]         → [Provider_error _]
    - [Turn_failures]              → [Provider_error _]
    - [Provider_runtime_error _]   → [Provider_error _]
    - [Tool_required_unsatisfied _] → [Required_tool_use_unsatisfied]
    - [Ambiguous_partial_commit_*] → [Post_commit_ambiguous]
    - [Stale_termination_storm]    → [Provider_error _]
    - [Stale_fleet_batch]          → [Provider_error _]
    - [Fiber_unresolved]           → [Provider_error _]
    - [Exception_unhandled _]      → [Provider_error _]
    - [Sdk_error _]                → [Provider_error _]

    Note: a runtime cause may map to a *non-Provider_error* operator
    disposition when the runtime classification fully determines the
    operator action (e.g., [Tool_required_unsatisfied → Required_tool_use_unsatisfied]).
    Otherwise we wrap with [Provider_error] so the runtime cause is
    preserved for diagnostics. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
```

### 3.2 Why `Provider_error of Keeper_turn_terminal_code.t` (not `of string`)

The runtime cause is already a closed sum. Wrapping it as the payload
of `Provider_error` keeps the type discipline at both layers without
re-flattening to string. Dashboards and `bin/masc-trace` get the same
wire bytes (`to_wire (Provider_error code) = to_wire code`); operator
classification (`severity = Bad`, `next_action = inspect_latest_error`)
is exhaustive on the constructor itself.

### 3.3 Why `Unknown of { raw_error }` exists

Three legacy paths in `lib/keeper/keeper_turn_terminal.ml::of_legacy_error_text`
reach `make ~source:"legacy_error_text" "unknown_error"` when none of
the substring heuristics match. Until those producer paths are
themselves typed (a separate refactor), `Unknown` carries the raw
error so dashboards can still surface it.

PR-3 lints:

```sh
# scripts/lint/no-free-unknown-disposition.sh
# Fail CI if Keeper_turn_disposition.Unknown { raw_error = "X" } is
# constructed with the same X at >= 2 sites; X must be promoted.
```

### 3.4 Field shape on `Keeper_turn_terminal.t` after migration

```ocaml
(* PR-2 — additive, non-breaking *)
type t =
  { code : string                              (* legacy, kept for wire compat *)
  ; disposition : Keeper_turn_disposition.t    (* NEW, populated by typed producers *)
  ; source : string
  ; severity : severity                        (* derived from disposition when present, else fallback *)
  ; summary : string
  ; next_action : string option
  }

(* PR-3 — remove [code] *)
type t =
  { disposition : Keeper_turn_disposition.t
  ; source : string
  }
(* severity / summary / next_action become exhaustive matches on
   disposition, no field needed in the record. *)
```

`to_json` in PR-2 emits both `code` (legacy wire) and `disposition`
(new structured field). PR-3 keeps the `code` JSON field
(`= Keeper_turn_disposition.to_wire t.disposition`) for downstream
compat; it's just no longer in the OCaml record.

## 4. Migration plan (3 PRs)

| PR | Title | Files | Compile? | Wire stable? | Behaviour change? |
|----|-------|-------|----------|--------------|-------------------|
| **PR-1** | introduce `Keeper_turn_disposition` (inert) | `lib/keeper/keeper_turn_disposition.{ml,mli}` + `lib/keeper/dune` (no — single-lib) + 1 test | ✅ | yes (no callers) | none |
| **PR-2** | add `disposition` field + populate from typed producers | `keeper_turn_terminal.{ml,mli}` + ~6-8 producer sites | ✅ | yes | severity/summary/next_action prefer typed disposition; legacy fallback retained |
| **PR-3** | remove `code: string`; readers exhaustive on disposition; lint guard for `Unknown` reuse | `keeper_turn_terminal.{ml,mli}` + ~10-12 file sweep | ✅ | yes (JSON keeps `code` string field via `to_wire`) | substring matchers deleted |

**Total**: ~15-20 files, ~600-800 LOC. Each step ships independently;
mid-sequence revert is safe.

### 4.1 Test plan

- **PR-1**: round-trip (`of_wire (to_wire t) = t` for canonical
  variants); byte-compat oracle vs current
  `keeper_turn_terminal.severity_of_code / summary_of_code /
  next_action_of_code` for every legacy code. The test imports the
  current substring-based functions and asserts they produce the same
  severity/summary/next_action as the new typed `severity / summary /
  next_action` for each disposition.
- **PR-2**: golden-file test that
  `Keeper_turn_terminal.to_json` JSON output is byte-identical for a
  fixture set of (typed_producer, legacy_producer) pairs.
- **PR-3**: invariant test — no `String.starts_with ~prefix` on the
  `code`/`disposition` wire in `lib/keeper/keeper_turn_terminal.ml`
  (mechanically verifiable via grep at CI time).

## 5. Trade-offs

### 5.1 Why two types instead of one

A single big closed sum (~30 constructors covering both layers) was
tempting. Rejected because:
- Every reader of either layer would have to match on every arm of the
  other layer.
- Promotion (`Sdk_error → Provider_error`) becomes implicit and
  ambiguous: which arm is "the cause" vs "the disposition"?
- The runtime layer (RFC-0042) already shipped narrow; widening it now
  contradicts §3.1 of RFC-0042 ("intentionally flat").

Two types with explicit `Provider_error of Keeper_turn_terminal_code.t`
keeps each layer's reader exhaustive *for its concern*.

### 5.2 Cost of `Unknown { raw_error }`

Same trade-off as RFC-0044 `Other of string` and RFC-0042 PR-2.5
`Sdk_error of string`. Documented in the .mli, lint-guarded at PR-3,
removable when the producer side (`of_legacy_error_text`) is itself
typed.

### 5.3 Interaction with RFC-0042 PR-3 (deferred)

RFC-0042 PR-3 ("`Keeper_turn_terminal.t.code: string → t`") is **not
landing as written**. RFC-0068 supersedes that step. RFC-0042 stays
correct for the runtime layer (PR-1 + PR-2 + PR-2.5 already merged);
PR-3 / PR-4 of RFC-0042 are repurposed:

- RFC-0042 PR-3 → RFC-0068 PR-2 (add disposition field to
  `Keeper_turn_terminal.t`)
- RFC-0042 PR-4 (reader migration) → RFC-0068 PR-3

Both RFC-0042 docs (#14181 still open) and this RFC need the same
maintainer review for that handoff to be authoritative.

### 5.4 What this RFC explicitly does not do

- Does not retype `Keeper_turn_terminal_code.t` (still owned by RFC-0042).
- Does not change the wire format on the receipt JSON `code` field.
- Does not re-litigate the substring matchers in `lib/keeper/keeper_unified_metrics.ml`
  or `lib/keeper/keeper_runtime_trust_snapshot.ml`. Those are
  consumers; PR-3 sweeps them.

## 6. Decision

This RFC is filed as Draft. PR-1 (`Keeper_turn_disposition`
introduction, inert) can land independently of approval here — it is
a new file with no callers and costs nothing to revert. PR-2 / PR-3
require:

1. Confirmation that the layer separation in §3 is the canonical
   shape (vs. a single-type expansion of `Keeper_turn_terminal_code.t`).
2. Confirmation that RFC-0042 PR-3/PR-4 are superseded by RFC-0068
   PR-2/PR-3 (so RFC-0042 closes after PR-2.5 + RFC-0042 docs merge).
3. Maintainer approval of the disposition variant set in §3.1
   (the inventory was lifted from current
   `lib/keeper/keeper_turn_terminal.ml` consumers; new dispositions
   require same-PR additions).

## 7. References

- `lib/keeper/keeper_turn_terminal.{ml,mli}` — current
  application-layer surface.
- `lib/keeper/keeper_turn_terminal_code.{ml,mli}` — RFC-0042 runtime
  layer.
- `lib/keeper/keeper_agent_error.{ml,mli}` — RFC-0042 PR-2.5 SDK
  bridge.
- `instructions/software-development.md §워크어라운드 거부 기준` — the
  string-substring classifier anti-pattern this RFC closes.
