---
rfc: "0326"
title: "Typed keeper failure classification — eliminate the path-error substring/prefix classifier"
status: Draft
created: 2026-07-09
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0089", "0142", "0174", "0208"]
implementation_prs: []
---

# RFC-0326: Typed keeper failure classification

- **Status**: Draft
- **Number**: `0326` provisional (RFC numbers are claimed at Draft time; maintainer may reassign at merge — see RFC-0042 header). `0325` is taken by #23686.
- **Decision driver**: operator (2026-07-09) — "조언이 LLM이 아니면 문제 / 문자열로 분류하는 건 안 됨. 서브스트링이냐? 이게 뭔 하드코딩이야 / **substring 분류 걷어내자**."
- **Related**: RFC-0042 (closed sum for terminal code), RFC-0089 (string-classifier→typed-variant), RFC-0142 (runtime_error_classify decomp — *different* classifier, JSON extraction), RFC-0174 (dashboard substring→typed), RFC-0208 (typed-domain-classification).
- **Drives**: The keeper failure circuit breaker classifies path errors by re-parsing **strings**. Errors that are born as typed values (`Keeper_path_check_error.t`, `keeper_path_rejection`) are serialized to strings at the producer and re-parsed downstream; genuinely unstructured errors are matched by raw `contains_substring`. Keep errors typed end-to-end so the string/substring classifier can be **deleted**, not decorated.

## 1. Problem (audited at head `82783ff` / origin/main)

`Keeper_failure_circuit_breaker` maps a failure to an `error_class`
(`Path_not_found | Path_not_allowed | Cwd_not_directory | Shell_exit_nonzero | Other`).
`error_class` drives two things:

1. **Circuit breaker trip** (deterministic control): "N consecutive failures of the same class → trip + cooling window" (`keeper_failure_circuit_breaker.ml` header, `consecutive_class : error_class`).
2. **Actionable advice** (`keeper_tool_shared_runtime.actionable_path_action_for_class`): canned strings keyed on the class, e.g. `"Provide a path. Your playground root is " ^ playground`.

The production classification path is **string/substring**, in three layers:

### 1a. Self-inflicted typed → string → typed round-trip (structured errors)

The producer holds the typed value and immediately serializes it:

```
(* lib/exec_policy/exec_policy.ml:640 *)
Error (Keeper_path_check_error.(to_message
         (Path_outside_whitelist { path = value; for_keeper_command = true })))
```

`lib/keeper/keeper_tool_execute_path.ml:7,26` is worse — it *hand-formats* the prefix string (`Printf.sprintf "cwd_not_directory: %s ..."`) instead of using the variant at all.

Downstream, `Keeper_failure_circuit_breaker_types.classify_path_check_prefix`
(`.ml:37`) calls `Keeper_path_check_error.parse_prefix` — `starts_with_ci ~prefix:"path blocked:" | "cwd_not_directory:" | ...` — to reconstruct the **same typed value** that was just destroyed, then classifies it. `parse_rejection_prefix` mirrors this for `keeper_path_rejection`.

So the type exists at both ends; only the middle is a string. `to_message`/`parse_prefix` is a hand-rolled, lossy serialization channel where a typed value should have flowed.

### 1b. Raw substring fallback (unstructured errors)

```
(* lib/keeper_failure_circuit_breaker_types/keeper_failure_circuit_breaker_types.ml:95,99 *)
if String_util.contains_substring error "No such file or directory" then Path_not_found
...
if contains "No such file or directory" then Path_not_found
else if contains "exit" && contains "code" then Shell_exit_nonzero
else Other
```

This is CLAUDE.md workaround-signature #2 (string/substring classifier) — the compiler cannot catch a new failure mode; a new `contains "..."` line is added by hand.

### 1c. #23588 (task-1854) added typed matchers but they are vacuous

`classify_typed_path_check` / `classify_typed_path_rejection` exist and are exhaustive, but whole-tree `git grep` at `82783ff` shows **zero production callers**: only the two definitions, two prefix-delegation arms (which still `parse_prefix` a string first), and three `test/` call sites. The real production callers (`record_failure`/`record_observed_failure ~error_msg:string`, `actionable_path_error ~error:string`) hold **strings**. The string round-trip is not eliminated; #23588 is groundwork only.

## 2. Boundary: deterministic control vs LLM advice

Per MANIFEST (경계 구분):

- **Trip decision is deterministic control** and legitimately needs a stable "same failure class" key. It must NOT get that key by substring-sniffing. The failure's *type* is its class — thread the typed value; delete the string classifier.
- **Advice is non-deterministic** and should be produced by the LLM keeper reasoning over the typed failure, not a hardcoded `class → canned string` map. (Full advice-→-LLM redesign is a **follow-up**, §6; this RFC keeps the canned map but makes it typed-driven so it can be retired later.)

## 3. Decision

Keep keeper path failures typed from producer to consumer. Delete the
string/substring classifier once no production path depends on it.

### Part A — structured path errors (kills `parse_prefix` / `parse_rejection_prefix`)

1. Producers return typed errors, not `to_message`'d or hand-formatted strings:
   - `exec_policy` path checks return `(unit, Keeper_path_check_error.t) result` (or a shared typed error) instead of `Error (to_message …)`.
   - `keeper_tool_execute_path` stops hand-formatting `"cwd_not_directory: …"`; it constructs `Cwd_not_directory { … }`.
2. `resolve_tool_read_path` returns `(_, <typed error>) result` instead of `(_, string) result`.
3. `keeper_workspace_read_ops` passes the typed error to `actionable_path_error`; `actionable_path_error` (and the circuit breaker record path) take the typed value and call `classify_typed_path_check` / `classify_typed_path_rejection` directly (#23588's matchers — finally used).
4. Delete `to_message`-for-classification usage, `parse_prefix`, `parse_rejection_prefix`, and the `classify_path_*_prefix` / string `classify_error` path once (2) and (3) leave them with no production caller. (Keep `to_message` only if still needed for operator-facing display — that is a rendering concern, not classification.)

### Part B — unstructured shell/OS errors (kills the `contains_substring` fallback)

1. Type the failure at the **exec boundary** where the shell/OS error is produced (exit code, `Sys_error "... No such file or directory"`), into a typed variant (e.g. reuse `Not_found_relative` / a `Shell_exit` variant), once.
2. Delete the `contains "No such file or directory"` / `contains "exit" && "code"` branches in `classify_error`.

## 4. Phase-0 measurement gate (REQUIRED before Part B deletion)

Lesson from `RFC-eliminate-substring-destructive-classifier` §3: the hypothesis
"substring is redundant with typed, just delete it" was **falsified by
measurement** — there, the substring layer blocked a *wider* set. We do not
repeat that mistake.

Before deleting §3 Part B branches, **instrument** `classify_error`'s
substring fallback in production (count + sample which error strings reach it,
and from which producer) for a bounded window. Confirm every reaching string
has a typed origin that Part B's boundary typing covers. If a class of strings
has no typed origin, Part B must add that typing (or the RFC is amended), not
delete the branch and silently collapse to `Other` (which would change trip
counting).

Part A has no such risk: the typed value provably exists at the producer
(§1a), so threading it is coverage-neutral by construction.

## 5. Slices (implementation order)

| Slice | Scope | Gate |
|-------|-------|------|
| S0 | #23588 (typed matchers, exhaustive, equivalence tests) — already open, reframed as groundwork | body corrected 2026-07-09 |
| S1 | Part A: thread typed structured errors producer→consumer; delete `parse_prefix`/`parse_rejection_prefix`/string prefix path | exhaustive typed match compiles; equivalence tests green; no `parse_prefix` caller remains |
| S2 | Part B: type unstructured shell/OS errors at exec boundary; delete substring fallback | **Phase-0 measurement (§4) first**; trip-class coverage unchanged for measured inputs |
| S3 (follow-up, separate RFC) | advice → LLM: retire `actionable_path_action_for_class` canned map in favor of surfacing the typed failure to the keeper | out of scope here |

Each slice: worktree, own tests, Draft PR, `pr-rfc-check` citing this RFC.

## 6. Non-goals

- `runtime_error_classify.ml` (RFC-0142) — a different classifier (JSON field extraction). Untouched.
- The shell **destructive-op** substring classifier (`eval_gate.ml`, `RFC-eliminate-substring-destructive-classifier`) — different domain; that RFC found its substring layer load-bearing. Untouched.
- The advice-→-LLM redesign (S3) — flagged, deferred to its own RFC.

## 7. Verification

- After S1: `git grep parse_prefix\|parse_rejection_prefix\|classify_path_check_prefix` returns **zero non-test, non-deleted** hits; classification goes through `classify_typed_*` on typed inputs only.
- Exhaustive `match` on both ADTs (no `_ ->`) so a new failure variant is a compile-time obligation (RFC-0042 discipline).
- #23588's equivalence tests remain green through S1 (typed and any retained string entry agree) and are extended to the new typed call sites.
- After S2: substring fallback removed; Phase-0 measurement shows no coverage regression for observed production inputs.

## 8. Trade-offs

- **Cost**: S1 is a multi-module signature change (exec_policy → keeper_tool_execute_path → keeper_workspace_read_ops → keeper_tool_shared_runtime → circuit breaker). Higher churn than leaving the round-trip.
- **Benefit**: deletes a string/substring classifier (a recurring hand-add anti-pattern) on the deterministic control path; new failure modes become compile-time obligations; #23588's typed matchers stop being dead surface.
- **Residual**: unstructured external errors (S2) still require one typed parse at the boundary — string handling is not eliminated, only *confined to one boundary* and made total, instead of sprinkled as substring guesses in the classifier.
