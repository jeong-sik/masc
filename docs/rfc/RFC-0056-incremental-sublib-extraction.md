# RFC-0056 — Incremental Sub-Library Extraction from Flat masc_mcp Library

Status: Draft · Phase 0 PoC included
Author: jeong-sik (with Claude Opus 4.7)
Date: 2026-05-09
Supersedes: —
Related: existing `lib/cdal_runtime/dune` (template), prior PR #14166 (prometheus split, closed by user as cosmetic)

## 1. Problem

`lib/dune` declares one library:

```
(include_subdirs unqualified)
(library (name masc_mcp) ...)
```

This single stanza absorbs every `.ml` file under `lib/` — except sub-folders that have their own `dune` — into one library namespace. Effects measured on `main` 2026-05-09:

| Measurement | Value |
|---|---|
| `.ml` files under `lib/` | 961 |
| Sub-libraries with own `dune` | 42 |
| `.ml` files in flat `masc_mcp` namespace | ~880 |
| `lib/keeper/` (largest single domain in flat ns) | 208 files |
| Flat-ns `.ml` with external fan-in == 0 | 39 |
| Flat-ns `.ml` with external fan-in == 1 (≥ 200 LoC) | 30 |

Two structural consequences:

1. **dune does not enforce dependency direction inside the flat namespace.** Two flat modules can reference each other freely; the `masc_mcp` library accepts the cycle because both are members. OCaml's strongest static guarantee (acyclic library DAG) is disabled for ~880 modules.

2. **Domain prefixes are aspirational, not load-bearing.** Audit of the `cdal_*` prefix (2026-05-09):

   | Location | Files | Status |
   |---|---|---|
   | `lib/cdal/` (no `dune`, absorbed by parent) | 2 (`adversarial_eval`, `labeling`) | flat |
   | `lib/` root (also absorbed) | 6 (`cdal_eval_v1`, `cdal_friction_projection`, `cdal_judge`, `cdal_loader`, `cdal_types`, `cdal_verdict_gate`) | flat |
   | `lib/cdal_runtime/` (own `dune`) | 8 (audit, autonomy_*, ...) | wrapped sub-library |

   The same prefix is split across three locations because the parent's `(include_subdirs unqualified)` makes "where I drop the file" cosmetic — compilation is identical. Naming intent diverges from compilation reality.

This is not a per-domain problem. It is a partition problem.

## 2. Non-goals

- **Not a godfile-split RFC.** PR #14166 (prometheus.ml 2,756 LoC split into N files via `include` re-export, closed by user) demonstrated that LoC redistribution inside the same library namespace changes nothing the compiler enforces. This RFC is the opposite axis: **add boundary between libraries**, not move text within a library.
- **Not a multi-sprint plan.** Memory-recorded analysis "keeper sub-library extraction" (2026-05-01) showed `lib/keeper/` has 189 ↔ 118 bidirectional references with the rest of `lib/`, requiring a multi-PR campaign. This RFC defines the **gate** that any future extraction must pass — it is not the keeper extraction itself.

## 3. Proposal

### 3.1 Extraction gate (apply to every future sub-library extraction)

A directory `lib/<X>/` may be promoted to a wrapped sub-library if and only if all five gates pass on the proposed final file set:

| Gate | Definition | Verification |
|---|---|---|
| **G1: No cycle** | The candidate's outbound module references resolve to (a) sub-libraries declared in its `dune` `(libraries ...)`, (b) the proposed sub-library's own modules, or (c) modules that the new sub-library declares as dependencies. No reference goes back into `masc_mcp` flat namespace. | `python3 scripts/audit-sublib-cycle.py lib/<X>` (to be added) |
| **G2: No `.mli` change** | Public interfaces of moved modules remain byte-identical. Phase 0 may not narrow or widen any signature. | `git diff --stat lib/**/<X>*.mli == 0` |
| **G3: No caller rename** | Callers of moved modules continue to write `Foo` (not `Bar.Foo`). Achieved via `(wrapped false)` on the new library. | `git diff lib/ test/ bin/` shows no `open` / module-prefix changes outside the moved files |
| **G4: Build green on `@check`** | `dune build @check` succeeds locally and on CI Fundamental. | CI status |
| **G5: Caller delta budget** | Number of files outside the candidate directory that change is bounded. The only allowed caller change in Phase 0 is **redundant-qualifier removal of moved modules** — when a caller previously wrote `Masc_mcp.X` it must rewrite to `X`, because `X` no longer lives inside the wrapped `masc_mcp` library. Anything beyond `s/Masc_mcp\.<Module>/<Module>/g` (signature changes, `open` additions, semantic accommodations) violates G5 and means the candidate is not a leaf. Phase 1+ may state larger budgets per-PR with explicit justification. | `git diff` outside `lib/<X>/` shows only the qualifier-removal pattern |

Failure of any gate → reject. No "WORKAROUND:" override path; reject means the candidate is not yet a leaf.

### 3.2 Reject conditions (anti-patterns this RFC forbids)

- **Cosmetic split** — moving N% of a flat-ns file into `lib/foo/file_part2.ml` while remaining in flat ns. (PR #14166 pattern.)
- **Wrapping rename** — making the library wrapped (modules become `Foo.Bar`) without an explicit Phase ≥ 2 RFC. Phase 0/1 stay `(wrapped false)`.
- **Cycle laundering** — moving a module into the new sub-library "for now" while leaving its cyclic references unresolved. If A in the new lib references B in flat ns and B references A back, neither moves.

### 3.3 Phase 0 PoC: `lib/cdal/` Phase 1A evaluator skeleton

Concrete extraction to validate the gate. Smallest scope that exercises G1–G5 non-trivially.

**Scope (3 modules):**

| Module | Current location | New location | LoC | Outbound deps |
|---|---|---|---|---|
| `Cdal_types` | `lib/cdal_types.ml(i)` | `lib/cdal/cdal_types.ml(i)` | 260 + 92 | 0 |
| `Adversarial_eval` | `lib/cdal/adversarial_eval.ml(i)` | unchanged path | 358 + ? | `lib/exec`, `lib/core` |
| `Labeling` | `lib/cdal/labeling.ml(i)` | unchanged path | 178 + ? | `Cdal_types` only |

**Out of Phase 0 scope (have flat-ns cycle risk, deferred to Phase 1):**

| Module | Cycle source | Resolution path |
|---|---|---|
| `Cdal_judge` | references `Cdal_types` (resolved if 1A moves) — verify in Phase 1 | re-test gate after 1A |
| `Cdal_eval_v1` | calls `Cdal_judge`, `Cdal_loader` | follows judge + loader |
| `Cdal_loader` | calls `Proof_artifact_reader` (flat-ns thin wrapper of `cdal_runtime`) | move `Proof_artifact_reader` with loader, OR call `cdal_runtime` directly |
| `Cdal_verdict_gate` | references `Attribution`, `Bounded` (flat-ns) | `Bounded` is *not* CDAL-domain ("Bounded Autonomy" generic); refactor verdict_gate to drop `Bounded` dep, OR leave verdict_gate in flat ns |
| `Cdal_friction_projection` | references `Session`, `Violation_record`, `Proof_artifact_reader` | `Session` is *not* CDAL-domain (rate limiting); same trade-off |

This deferred set is not a TODO — it is the explicit Phase 1 ask, with the gate predicting which moves are clean and which need refactor first.

**dune (new file `lib/cdal/dune`):**

```
; RFC-0056 Phase 0 — extract CDAL Phase 1A evaluator from flat masc_mcp.
; Mirrors lib/cdal_runtime/dune: (include_subdirs no) opts out of the
; parent's (include_subdirs unqualified), letting this directory compile
; as its own library. (wrapped false) keeps module names unqualified so
; existing callers do not rewrite imports — this is Phase 0 budget G3/G5.
;
; Future Phase 1 will move cdal_judge / cdal_eval_v1 / cdal_loader once
; their root-namespace cycles (Proof_artifact_reader, Attribution, Bounded,
; Session, Violation_record) are resolved per RFC-0056 §3.3.
(include_subdirs no)

(library
 (name masc_mcp_cdal)
 (public_name masc_mcp.cdal)
 (wrapped false)
 (libraries
  yojson
  masc_core))
```

`masc_core` is `wrapped false` and exposes `String_util` / `Json_util` at top level — the only non-stdlib symbols `Adversarial_eval` references. `Labeling` and `Cdal_types` use only `Yojson` plus the new sub-library's own types.

**`lib/dune` change:**

Add `masc_mcp.cdal` to the existing `(libraries ...)` list.

**`test/deps/dune` change:**

Add `(re_export masc_mcp.cdal)` mirroring the existing `(re_export masc_mcp.cdal_runtime)` line — so test modules referencing `Cdal_types`, `Adversarial_eval`, `Labeling` keep resolving.

**Caller delta after PoC build:** 9 files (1 in `bin/`, 8 in `test/`), each a single-line `s/Masc_mcp\.Cdal_types/Cdal_types/g` or `s/Masc_mcp\.Labeling/Labeling/g` — the qualifier-removal pattern G5 explicitly permits. The 11 callers that already wrote unprefixed `Cdal_types` / `Adversarial_eval` / `Labeling` (the unwrapped-import style) needed no change. `tool_deep_review.ml` (`Adversarial_eval` consumer) was unchanged. `lib/dune` adds one library to its deps; `test/deps/dune` adds one `re_export`; `bin/dune` adds the new sub-library to `cdal_label`'s deps so its qualifier removal still resolves.

### 3.4 Phase 1+ (out of this RFC's scope)

After Phase 0 passes the gate on `main`, future RFCs propose extractions in priority order based on a fan-in/fan-out audit run against `main`. The audit script (G1 verification) is the durable artifact — it lets each future PR self-check before requesting review.

## 4. Validation

| Check | Expected | PoC actual |
|---|---|---|
| `dune build @check` | green | green (after qualifier-removal in 9 callers) |
| `dune runtest` for `test/test_cdal_*` | unchanged pass count | TBD on CI |
| Number of dune files modified outside `lib/cdal/` | 3 (`lib/dune`, `bin/dune`, `test/deps/dune`) | 3 |
| Number of `.ml` / `.mli` semantic changes (non-rename) | 0 | 0 |
| Number of `Masc_mcp\.<Moved>` qualifier removals | 9 (allowed by G5) | 9 (8 tests + 1 bin) |
| Number of `open` additions in callers | 0 | 0 |

Failure of any of these → Phase 0 rejected, RFC body amended with the actual cycle and re-submitted.

## 4.1 What the gate caught (PoC findings)

Two findings the gate surfaced that audit-only analysis missed:

1. **`Masc_mcp.Cdal_types` access pattern (9 callers).** Pre-PoC fan-in measurement counted unprefixed references only. The wrapped-library access pattern `Masc_mcp.<Module>` is invisible to a `\b<Module>\b` grep. The `dune build` failure forced their enumeration: `bin/cdal_label.ml` plus `test/test_{labeling, cdal_types, cdal_eval_v1, cdal_friction_projection, cdal_judge, cdal_verdict_gate, operator_control_actions}.ml`. **Lesson for future extraction audits**: grep both bare and `Masc_mcp.` patterns.

2. **`String_util` ambiguity in `lib/`.** Two files exist (`lib/exec/string_util.ml` inside wrapped `masc_exec`, `lib/core/string_util.ml` inside wrapped-false `masc_core`). The latter wins for unprefixed callers. PoC dependency declaration only needed `masc_core`, not `masc_exec`. **Lesson**: when a moved module references a top-level identifier, the dep is the wrapped-false sub-library that exports it, not every sub-library that contains a same-named file.

These findings update the audit script (G1 verification) requirements: future extractions must include both grep patterns and a dune-name disambiguation pass before the `dune` file is written.

## 5. Risks

- **`lib/exec` / `lib/core` not yet exposing required public_names.** If their `dune` doesn't have a usable `(public_name ...)`, the new sub-library cannot list them as deps without touching their dune. Verified against `main`: both have `public_name` and are already used as deps by `cdal_runtime`. Risk → low.
- **`(wrapped false)` namespace pollution.** Every module name in the sub-library becomes a top-level identifier visible to anyone depending on `masc_mcp.cdal`. CDAL prefix already discriminates these names; collision risk near zero. Phase 2 may revisit by switching to wrapped + adding caller rewrites.
- **Cycle discovered post-merge.** Mitigated by `dune build @check` which fails fast on dependency cycles before merge.

## 6. Decision

Phase 0 PoC is included in this PR. RFC merges with Phase 0; Phase 1 RFC is a follow-up authored after Phase 0 lands on `main`.
