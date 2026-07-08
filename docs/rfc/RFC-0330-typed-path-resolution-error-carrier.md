# RFC-0330: Typed path-resolution error carrier (retire the classify_error string round-trip)

**Status**: Draft
**Date**: 2026-07-08
**Builds on**: [RFC-0042](./RFC-0042-keeper-terminal-code-closed-sum.md) (closed-sum, no-string-classifier lineage), [RFC-0088](./RFC-0088-counter-as-fix-result-propagation.md) (Result propagation), [RFC-0005](./RFC-0005-typed-capability-substrate.md) (typed capability substrate)
**Related**: PR #23588 (adds the typed matchers this RFC wires), [RFC-0329](./RFC-0329-keeper-execute-governance-payload-aware-and-typed-exemption.md) (Execute *governance* risk — a different classifier; see §10)
**Tracking**: task-1854

## 1. Summary

PR #23588 added two pure ADT matchers to `lib/keeper_failure_circuit_breaker_types/`:

- `classify_typed_path_check : Keeper_path_check_error.t -> error_class`
- `classify_typed_path_rejection : Keeper_path_rejection.keeper_path_rejection -> error_class`

They are correct and exhaustively tested, but they have **no honest production caller**. Every runtime path that produces a path error stringifies the typed value at its birth site, and the only consumer of `error_class` (`actionable_path_error`, and the failure circuit breaker) re-derives a variant from that string via `classify_error` — a string→variant round-trip. So the matchers today are reachable only through the string wrappers `classify_path_check_prefix` / `classify_path_rejection_prefix` (which call `parse_prefix` first) and through tests.

This RFC records why "give the typed matchers a real caller" is a single, shared-infrastructure change (not two separable slices), specifies the typed carrier that removes the string round-trip, and proves the migration is behavior-preserving at the `error_class` level.

It does **not** propose merging that code inside #23588. #23588 stays a prep + test-coverage PR (it adds no string classifier); this RFC is the follow-up that wires the matchers.

## 2. Evidence (the error is stringified at birth)

Two independent typed path-error contracts both collapse to a string before any `error_class` consumer sees them.

### 2.1 Shell-path (`Keeper_path_check_error.t`)

- `Keeper_path_check_error.t` is constructed and stringified in the **same expression**: `exec_policy.ml:631` `validate_shell_ir_paths` returns `(unit, string) result` (`exec_policy.mli:68`); the error side is built by `to_message` at `exec_policy.ml:642` / `:649`.
- Downstream carries only `Path_reject of string` (`keeper_tool_execute_shell_ir.ml:81`), populated at `:276` `| Error e -> Error (Path_reject e)`.
- `classify_typed_path_check`'s output would only ever land in the circuit-breaker `classify_error` call over the serialized `raw_output` string. Feeding it typed requires a typed classification (or typed failure) on `executed_tool_result` populated at every tool producer — i.e. the circuit-breaker record boundary.

### 2.2 Read-path (`Keeper_path_rejection.keeper_path_rejection`)

- The `Keeper_alerting_path` resolvers keep the rejection typed: `(string, keeper_path_rejection) result` (`keeper_alerting_path.mli:100`, `:158`). `Keeper_alerting_path` is `include Keeper_path_rejection` (`keeper_alerting_path.ml:3`), so this is the exact type `classify_typed_path_rejection` accepts.
- The typed value is flattened to a string at the `Keeper_tool_shared_runtime` wrappers: `user_message_error` (`keeper_tool_shared_runtime.ml:561`, `Error (rejection_to_user_message rej)`), and `:702` / `:725` `| Error rej -> Error (rejection_to_user_message rej)`.
- The single `error_class` consumer on this path is `actionable_path_error` (`keeper_tool_shared_runtime.ml:96`), which re-parses at `:103` `let cls = Keeper_failure_circuit_breaker.classify_error error in`. Its only caller is `path_error` (`keeper_workspace_read_ops.ml:77`) via `Read_target_error e -> path_error e` (`:153`).

## 3. Why this is one RFC, not two salvageable slices

An earlier plan estimated the read-path rejection wiring as a "medium, 5-file" salvage separable from the shell-path work. A consumer census refutes the separability: the read-path resolvers are shared infrastructure.

`resolve_keeper_read_path` / `resolve_projected_read_path` / `resolve_projected_keeper_read_path` / `resolve_tool_read_path` are consumed by, at minimum:

- `keeper_tool_execute_path.ml:18` / `:138` / `:144` / `:165`
- `keeper_tool_filesystem_runtime.ml:94` (`let* cwd = resolve_keeper_read_path …` — a `result` bind that propagates the error type), `:166`, `:174`
- `keeper_tool_registered_runtime.ml:38`
- `keeper_deterministic_evidence_probe.ml:50`
- `keeper_workspace_read_ops.ml:70`
- tests: `test_keeper_visible_path_projection.ml:138` / `:154`, `test_keeper_tool_search_files_containment.ml:503` / `:600`

Changing the resolver **error type** from `string` to a typed carrier propagates through every one of these, including the monadic `let*` sites. That is the same shared-boundary change reached from the read side that the shell side reaches from `executed_tool_result` — one coherent typed-error migration, so it is one RFC.

## 4. Design invariants (no hidden hardcoding)

1. **No new string/substring classifier.** This RFC removes a string round-trip; it adds none. `error_class` is derived from the typed carrier by a total match, never by `contains_substring` / prefix probing on the message.
2. **Classification is derived, not stored-in-parallel.** The carrier holds the typed error (or an explicitly opaque string); `message_of` and `classification_of` are total pure functions of it. There is no `{ message; classification }` pair that can drift.
3. **Opaque is explicit and gated.** Error sources with no ADT (containment `check_read_target : (unit, string) result`, the `"rg executable not found; Grep requires rg"` literal) map to a named `Opaque of string` whose classification is `Other` — and only after §6 verifies today's `classify_error` already yields `Other` for them. Absence-of-ADT is `Other`; it is never silently reparsed.
4. **Closed-sum, exhaustive.** The carrier is a closed variant; adding a producer forces a compile-time arm. No `_ ->` catch-all.
5. **No hardcoded keeper/command lists**, no magic thresholds. The change is purely in the type of the error channel.

## 5. Decision

### 5.1 Read-path carrier

Introduce a closed sum for the read-path error channel:

```ocaml
type read_path_error =
  | Rejected of Keeper_path_rejection.keeper_path_rejection
  | Opaque of string

let message_of = function
  | Rejected rej -> Keeper_path_rejection.rejection_to_user_message rej
  | Opaque s -> s

let classification_of = function
  | Rejected rej -> Keeper_failure_circuit_breaker_types.classify_typed_path_rejection rej
  | Opaque _ -> Keeper_failure_circuit_breaker_types.Other
```

Thread `read_path_error` through the resolver surface (§3 list). `user_message_error` and the `:702` / `:725` flatten sites return `Rejected rej` instead of `rejection_to_user_message rej`. `actionable_path_error` takes the carrier and uses `classification_of` — deleting the `classify_error` reparse at `:103` — while still emitting `message_of` for the `"error"` JSON field. Non-ADT sources (containment, rg literal) wrap `Opaque`.

### 5.2 Shell-path

Carry `Keeper_path_check_error.t` instead of stringifying at `exec_policy.ml:642` / `:649`: widen `Path_reject of string` (`keeper_tool_execute_shell_ir.ml:81`) to carry the typed check error (or a `read_path_error`-shaped carrier), and populate the typed classification on `executed_tool_result` so the circuit breaker records from the typed value rather than `classify_error` over `raw_output`. This is the larger half and lands after 5.1.

### 5.3 End state

`classify_error`'s string entry point remains only for genuinely unstructured inputs (shell exit text). Once 5.1 + 5.2 land, the path-error branches of `classify_error` (prefix + JSON + substring ladders) are dead for the resolver/exec channels and can be removed, closing the round-trip entirely.

## 6. Behavior-preservation proof (read-path)

The migration is a refactor, not a behavior change: for every `keeper_path_rejection` variant, the typed classification equals today's string round-trip classification at the `error_class` level. `parse_rejection_prefix (rejection_to_user_message rej)` may collapse distinct variants (e.g. `Absolute_path_rejected` → `Outside_project_root`), but both collapse targets share the same `error_class`.

| variant | `classify_typed_path_rejection` | round-trip via `parse_rejection_prefix` | same class |
|---|---|---|---|
| `Not_found_relative` | `Path_not_found` | `Not_found_relative` → `Path_not_found` | yes |
| `Absolute_path_rejected` | `Path_not_allowed` | `Outside_project_root` → `Path_not_allowed` | yes |
| `Outside_project_root` | `Path_not_allowed` | `Outside_project_root` → `Path_not_allowed` | yes |
| `Outside_sandbox` | `Path_not_allowed` | `Outside_sandbox` → `Path_not_allowed` | yes |
| `Task_state_file_path_blocked` | `Path_not_allowed` | `Task_state_file_path_blocked` → `Path_not_allowed` | yes |
| `Path_required` | `Other` | `Path_required` → `Other` | yes |
| `Allowed_paths_normalized_empty` | `Other` | `Allowed_paths_normalized_empty` → `Other` | yes |
| `Ambiguous_relative_read_path` | `Other` | `Ambiguous_relative_read_path` → `Other` | yes |

The `Opaque` arms must be checked individually against the current classifier before assigning `Other` (regression gate): the containment message from `check_read_target` and the `"rg executable not found; Grep requires rg"` literal each carry no path prefix, are not JSON, and contain neither `"No such file or directory"` nor `"exit"`+`"code"`, so `classify_error` returns `Other` today — matching `Opaque _ -> Other`. Any future `Opaque` source must re-run this check.

## 7. Migration / staging

1. **PR #23588 (landed as prep):** typed matchers + exhaustive tests. No wiring, no overclaim.
2. **PR A (read-path):** §5.1 carrier + resolver threading + §3 consumer adaptations + `classify_typed_path_rejection` becomes a real caller; delete the `:103` reparse. Regression-gate §6 `Opaque` arms.
3. **PR B (shell-path):** §5.2 typed `Path_reject` + `executed_tool_result` typed classification; `classify_typed_path_check` becomes a real caller.
4. **PR C (cleanup):** remove the now-dead path branches of `classify_error` (§5.3).

## 8. Verification

- **Build:** from-scratch `DUNE_CACHE=disabled dune build --root .` at each PR (incremental cache masks cross-module `.cmi`/`.cmx` breaks — cf. #23720/#23729 false-green).
- **Tests:** `test/test_circuit_breaker.ml`, `test/test_keeper_failure_circuit_breaker_types.ml` (the typed matchers), `test_keeper_visible_path_projection.ml`, `test_keeper_tool_search_files_containment.ml`, keeper read-op path-rejection tests.
- **New test:** a typed `Not_found_relative` / `Outside_sandbox` rejection routes to the correct actionable hint **without** the string reparse (assert `classification_of` is called, not `classify_error`).
- **Regression:** §6 table encoded as a property test over all `keeper_path_rejection` variants: `classify_typed_path_rejection rej = classify_error (rejection_to_user_message rej)`.

## 9. Non-goals

- Changing failure-counting *policy* in the circuit breaker (only the input type: typed value instead of a re-parsed string).
- The `Agent_sdk.Error.sdk_error` classifier (`keeper_error_classify.ml:73`) — a separate channel.
- Retiring `classify_error` entirely in the same PR as the wiring (staged; §5.3 is PR C).

## 10. Relationship to RFC-0329

RFC-0329 types the **Execute governance risk** classifier (Shell IR `R0/R1/R2` risk on the write/exec authorization path). This RFC types the **failure/error classifier** (`error_class` on the read/diagnostic path feeding actionable hints and the failure circuit breaker). Different subsystems, different sum types; they share only the "a typed variant exists but the runtime round-trips through a string" shape. Kept separate so neither blocks the other.
