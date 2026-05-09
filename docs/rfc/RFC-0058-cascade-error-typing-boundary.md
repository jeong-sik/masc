# RFC-0057: Cascade Error Typing Boundary

**Status**: Draft  
**Author**: Agent (Claude Opus 4.7)  
**Date**: 2026-05-09  
**Related**: RFC-0041 (hierarchical cascade config), RFC-0042 (Provider_error.t typed contract), PR #14383 (filter_healthy strict-only), PR #14382 (cascade_routes exhaustive match), CLAUDE.md software-development.md §"AI 코드 생성 안티패턴" #2  

---

## 1. Problem Statement

`lib/cascade/cascade_attempt_fsm.ml` contains **13** calls to `String_util.contains_substring_ci` across **4** classification functions, backed by **2** hardcoded indicator string lists, scattered across **~15** call sites in `lib/cascade/`, `lib/keeper/`, and `lib/cascade/cascade_transport.ml`.

### 1.1 The String Classifier Surface

| Function | Lines | String match count | Callers |
|----------|-------|-------------------|---------|
| `retry_message_looks_like_not_found` | 10--13 | 3 | `cascade_attempt_fsm.ml:48,59,203` |
| `retry_message_looks_like_model_access_denied` | 15--19 | 4 | `cascade_attempt_fsm.ml:48` |
| `message_looks_like_cli_wrapped_hard_quota` | 282--286 | 1 (via `List.exists` over `cli_wrapped_hard_quota_indicators`: 7 strings) | `cascade_attempt_fsm.ml:425`, `keeper_error_classify.ml:161` |
| `message_looks_like_cli_wrapped_max_turns` | 301--305 | 1 (via `List.exists` over `cli_wrapped_max_turns_indicators`: 5 strings) | `cascade_attempt_fsm.ml:628,648,656`, `keeper_turn_driver.ml:335,340,345,359` |
| `exit_code_of_message` | 307--320 | 1 (regex) | `cascade_transport.ml:1103,1157,1175,1188,1216` |
| Moonshot auth hint | 141,174 | 2 | `cascade_attempt_fsm.ml:141,174` |

Total: **13** `contains_substring_ci` calls + **2** `List.exists` over literal string lists = **15** string-matching decision points in a single 665-LoC module.

### 1.2 Why This Is an Anti-Pattern

CLAUDE.md `software-development.md` §"AI 코드 생성 안티패턴" #2 (String/Substring 분류기 보강):

> typed variant이 가능한 자리에 string match를 추가하거나 잠금. 컴파일러가 reader 누락을 못 잡음. 새 prefix가 자유롭게 추가됨.

The current flow loses type information at the protocol boundary:

```
Provider/CLI transport emits error
    → [Llm_provider.Retry.InvalidRequest { message : string }]
        → cascade_attempt_fsm receives the unstructured string
            → String_util.contains_substring_ci message "not found"
                → Reconstructs NotFound from a 400 body text
```

`Llm_provider.Retry` already has separate variants for `NotFound`, `RateLimited`, `ContextOverflow`, `AuthError`, `ServerError`, `NetworkError`, `Timeout`, `Overloaded`. But `InvalidRequest` is a catch-all bucket that every provider dumps unrelated errors into. The cascade then tries to recover the lost semantics through substring matching.

### 1.3 Operational Impact

- **Silent misclassification**: A new provider error message that does not match any indicator string is classified as a generic 400, losing the ability to trigger the correct cascade action (retry vs advance vs terminate).
- **Maintenance burden**: Every new provider (e.g. Kimi, ZAI GLM) requires a sweep of all indicator lists to map its error phrasing. There is no exhaustive compiler check.
- **TLA+ spec drift**: The `KeeperCascadeRouting.tla` spec models `provider_outcome` as a closed variant (`Call_ok | Call_err | Accept_rejected | Slot_full`), but the actual `Call_err` payload is an `http_error` that is partially reconstructed from strings. The spec's `classify_failure` invariant cannot prove anything about substring matching.

### 1.4 Existing Typed Surface (Underutilized)

`lib/core/provider_error.mli` already defines a typed `provider_error` variant:

```ocaml
type provider_error =
  | RateLimit of { retry_after : float option; provider : string }
  | CapacityExhausted of { scope : capacity_scope; affected : string list }
  | AuthError of { provider : string }
  | ServerError of { code : int; transient : bool }
  | InvalidRequest of { provider : string; reason : string }
```

The mli header states:

> "This module is additive: callers can emit it beside existing string error labels while later sweeps remove stringly-typed decisions."

This RFC is the sweep.

---

## 2. Root Cause Analysis

### 2.1 Protocol Boundary at Write

The CLI subprocess provider adapter (`lib/cascade/cascade_transport.ml`, `lib/llm_provider` via opam pin) parses CLI exit codes and stderr lines, then converts them into `Llm_provider.Retry` variants. The conversion is lossy:

| CLI reality | Current mapping | Lost information |
|-------------|----------------|------------------|
| Exit code 127 + "command not found" | `InvalidRequest { message }` | `NotFound` semantic |
| Exit code 137 + "Killed" (OOM) | `InvalidRequest { message }` | `ResourceExhausted` semantic |
| Exit code 1 + "max_execution_time_s exceeded" | `InvalidRequest { message }` | `Timeout` semantic |
| "401 Unauthorized" from API proxy | `AuthError { message }` | OK — typed, but cascade reclassifies it |
| "404 model not found" from API | `NotFound { message }` | OK — typed |
| "429 rate limit" from API | `RateLimited { message }` | OK — typed |

The CLI adapter is the **protocol boundary at write**. It should emit typed variants for every recoverable semantic, not compress them into `InvalidRequest`.

### 2.2 Cascade Reconstruction at Read

`cascade_attempt_fsm` receives the typed `Llm_provider.Retry` variant (good) but then:

1. For `InvalidRequest`, applies string matching to re-derive the original semantic (bad)
2. For `NotFound` / `RateLimited` / etc., passes through correctly (good)

The string matching is a **read-side repair** of a **write-side omission**.

CLAUDE.md §"Symptom 억제 패턴 — Repair / Sanitize":

> "UTF-8 repair", "JSON normalize on read" → Protocol boundary enforce (validate at write, reject on read)

---

## 3. Design

### 3.1 Invariant

> Adding a new error semantic to any provider adapter must be a **compile-time forced update** across all three layers: provider adapter (write), cascade FSM (read), and TLA+ spec (model).

### 3.2 Phase Plan

| Phase | Scope | Files | Est. LoC | Gate |
|-------|-------|-------|----------|------|
| **0** | RFC (this doc) + `Provider_error.t` variant extension | `lib/core/provider_error.{ml,mli}` | ~30 | Merge this RFC |
| **1** | Extend `Llm_provider.Retry` variant with CLI-specific constructors | External: `llm_provider` opam pin | ~80 | PR to `llm_provider` repo, pin bump |
| **2** | Rewire `cascade_attempt_fsm` to use typed variants, remove all string classifiers | `lib/cascade/cascade_attempt_fsm.{ml,mli}`, `lib/keeper/keeper_turn_driver.ml`, `lib/keeper/keeper_error_classify.ml`, `lib/cascade/cascade_transport.ml` | ~200 | All 13 `contains_substring_ci` calls removed; `dune build` + `tsc --noEmit` + `dune test` |
| **3** | Extend TLA+ `KeeperCascadeRouting` spec to cover new error variants | `specs/keeper-state-machine/KeeperCascadeRouting.tla` | ~50 | TLC clean pass + buggy violation |
| **4** | Extend `cascade_health_filter` to route typed errors to correct health lane | `lib/cascade/cascade_health_filter.ml` | ~40 | Existing `classify_failure` becomes exhaustive match |

### 3.3 Phase 0: `Provider_error.t` Extension (This PR)

Add the following variants to `lib/core/provider_error.mli`:

```ocaml
type provider_error =
  | ... (* existing *)
  | CliWrappedHardQuota of {
      provider : string;
      detail : string;
    }
  | CliWrappedMaxTurns of {
      provider : string;
      detail : string;
    }
  | CliWrappedResumableSession of {
      provider : string;
      detail : string;
      exit_code : int option;
    }
  | PermissionDenied of {
      provider : string;
      resource : string option;
    }
  | ModelNotFound of {
      provider : string;
      model_name : string;
    }
```

These are **additive**: existing code that pattern-matches on `provider_error` will get a non-exhaustive match warning, which `-warn-error +8` turns into a hard error. Every consumer is forced to handle the new variant at compile time.

### 3.4 Phase 1: `Llm_provider.Retry` Extension (External PR)

Extend the opam-pinned `llm_provider` library's `Retry` module:

```ocaml
type api_error =
  | ... (* existing: InvalidRequest, NotFound, RateLimited, etc. *)
  | CliWrapped of {
      kind : cli_error_kind;
      message : string;
      exit_code : int option;
    }

and cli_error_kind =
  | Hard_quota
  | Max_turns
  | Resumable_session
  | Unknown_cli_error
```

The CLI adapter (`cascade_transport.ml` or `llm_provider` CLI layer) maps exit codes + stderr lines to `CliWrapped` at the protocol boundary. No string matching in cascade.

### 3.5 Phase 2: Cascade Rewire (Main PR)

Replace the `sdk_error_to_cascade_outcome` function:

```ocaml
(* BEFORE — string classification *)
match err with
| Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message }) ->
    if retry_message_looks_like_not_found message then
      ... (* reconstruct NotFound from string *)
    else if retry_message_looks_like_model_access_denied message then
      ... (* reconstruct PermissionDenied from string *)
    else ...

(* AFTER — typed variant dispatch *)
match err with
| Agent_sdk.Error.Api (Llm_provider.Retry.CliWrapped { kind = Hard_quota; message; _ }) ->
    Some (Cascade_fsm.Call_err (ProviderFailure { kind = Hard_quota; message }))
| Agent_sdk.Error.Api (Llm_provider.Retry.CliWrapped { kind = Max_turns; message; _ }) ->
    Some (Cascade_fsm.Call_err (ProviderFailure { kind = Max_turns; message }))
| Agent_sdk.Error.Api (Llm_provider.Retry.NotFound { message }) ->
    Some (Cascade_fsm.Call_err (HttpError { code = 404; body = message }))
| ... (* all existing typed variants pass through *)
```

### 3.6 Phase 3: TLA+ Spec Extension

Add `CliWrapped` and its sub-kinds to the `KeeperCascadeRouting` spec's `http_error` type:

```tla
HttpError ==
    [ kind : {"http"}, code : 100..599 ]
    \cup [ kind : {"network"}, message : STRING ]
    \cup [ kind : {"cli_wrapped"}, sub_kind : {"hard_quota", "max_turns", "resumable_session"}, message : STRING ]
```

Update `classify_failure` and `should_cascade_to_next` to handle the new `cli_wrapped` kind.

### 3.7 Phase 4: Health Filter Rewire

`cascade_health_filter.ml`'s `classify_failure` currently matches on `Llm_provider.Http_client.http_error`. After Phase 2, it receives a typed `Provider_error.t` directly, making the match exhaustive and eliminating the need for string classification at the health layer too.

---

## 4. Verification Plan

### 4.1 Compile-Time Invariant

After Phase 0 merge, `dune build` must fail with non-exhaustive match errors on all existing `provider_error` consumers. The fix is to add the new constructors to each match, ensuring no silent omission.

### 4.2 Test Invariant

After Phase 2, `dune test` must include a new test file `test_cascade_attempt_fsm_typed.ml` that:

1. Constructs every `CliWrapped` sub-kind
2. Asserts `sdk_error_to_cascade_outcome` returns the expected `provider_outcome`
3. Asserts no `String_util.contains_substring_ci` is called (via mocking or static analysis)

### 4.3 TLA+ Invariant

After Phase 3, TLC must:
- Clean config: no errors, all invariants hold
- Buggy config (with `CliWrapped` incorrectly mapped to `InvalidRequest`): invariant violated in ≤ 5 steps

---

## 5. Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `llm_provider` opam pin bump breaks other consumers | Medium | Phase 1 PR to `llm_provider` includes backward-compatible `InvalidRequest` fallback; old code continues to work |
| CLI adapter cannot reliably map exit codes to `CliWrapped` sub-kinds | Medium | `Unknown_cli_error` sub-kind catches unrecognized cases; no worse than current `InvalidRequest` catch-all |
| TLA+ spec divergence from OCaml implementation | Low | Phase 3 includes mutation testing (buggy cfg must violate invariant) |
| Compilation failure in dashboard or other non-cascade consumers | Low | Phase 0 additive only; `Provider_error` is not used by dashboard |

---

## 6. References

- `lib/cascade/cascade_attempt_fsm.ml` — 13 `String_util.contains_substring_ci` calls
- `lib/core/provider_error.mli` — existing typed contract (underutilized)
- `lib/cascade/cascade_fsm.mli` — `provider_outcome` variant
- `specs/keeper-state-machine/KeeperCascadeRouting.tla` — TLA+ spec to extend
- CLAUDE.md `software-development.md` §"AI 코드 생성 안티패턴" #2 (String/Substring 분류기 보강)
- CLAUDE.md `software-development.md` §"Symptom 억제 패턴 — Repair / Sanitize"
- PR #14382 (cascade_routes exhaustive match) — same anti-pattern family, different module
- PR #14383 (filter_healthy strict-only) — same "fail-open → fail-closed" philosophy
