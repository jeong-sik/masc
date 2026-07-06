---
rfc: "0132"
title: "Redaction SSOT — `runtime` boundary-label private type"
status: Implemented
created: 2026-05-19
updated: 2026-05-21
author: agent-llm-a-cron-loop (vincent)
supersedes: []
superseded_by: null
related: ["0085", "0088", "0089", "0126", "0131"]
implementation_prs: [16531, 16536, 16537]
---

## Implementation summary (2026-05-21)

All three §4 phases shipped:

| Phase | PR | Scope | Merged |
|-------|-----|------|--------|
| PR-1 | #16531 | `lib/types_boundary/boundary_redaction.{ml,mli}` SSOT module introduction (< 100 LoC, no caller change) | 2026-05-19 |
| PR-2 | #16536 | Codemod across ~23 sites — Group A inline literals + Group B local constants → `Boundary_redaction.to_string` | 2026-05-19 |
| PR-3 | #16537 | `scripts/lint/no-runtime-literal-outside-boundary-redaction.sh` + Fundamental Check workflow job — compile-time inline-literal rejection | 2026-05-19 |

§5 acceptance conditions all hold:

- ✅ Compiler-enforced SSOT — new emit sites without `Boundary_redaction`
  fail the lint at CI time (PR-3 wired into
  `.github/workflows/fundamental-check.yml` as
  `no-runtime-literal-outside-boundary-redaction`).
- ✅ 23-site changeset landed under PR-2 without invoking the optional
  PR-2a/2b split.
- ✅ Misclassification risk addressed in PR-2 body per-site table
  (reviewed at merge time).

### Related RFC

- **RFC-0089** (String Classifier to Typed Variant, Implemented):
  same parse-don't-validate discipline applied to a different
  string surface (substring matcher vs literal-as-label).
- **RFC-0126** (Silent fallback discipline, Active): the lint stack
  pattern that PR-3 followed.
- **RFC-0131** (Shell Command Gate facade, Active): adjacent typed-
  surface RFC from the same audit week.

---

# RFC-0132 — Redaction SSOT for `"runtime"` boundary label

Status: Draft
Author: Agent-LLM-A (cron loop) on behalf of vincent
Date: 2026-05-19

Plan SSOT cross-reference:
- `knowledge/research/2026-05-19-reverse-engineering-design-map-gap-tracking.md` Gap 2
- Bundle research artifact PR #16480 §RFC B candidate

Memory cross-reference:
- `memory/feedback_runtime_lens_boundary_carve_out.md` (2026-05-13~14, PRs #15040 / #15070 / #15089) — establishes the *external surface redact `"runtime"` / internal observability real provider* boundary as a runtime invariant.

Workaround Rejection Bar cross-reference (`instructions/software-development.md` §AI 코드 생성 안티패턴):
- Pattern **1. 하드코딩 산포 (Scattered Hardcoded Defaults)** — exact match.

Related RFCs:
- RFC-0089 (string classifier → typed variant — general policy)
- RFC-0126 (silent fallback discipline — workaround rejection bar)
- RFC-0088 (Counter-as-Fix umbrella; redaction is a *typed-surface* root fix, not telemetry)
- RFC-0085 (keeper namespace bulk promotion — similar SSOT discipline pattern)
- RFC-0131 (Shell Command Gate facade — multi-caller SSOT precedent)

---

## 1. Problem statement

The literal string `"runtime"` is used today as a **boundary redaction label** for external surfaces (dashboard SSE, OAS bridge, keeper telemetry) where the *real* provider/model identity is intentionally suppressed. The label is **scattered as inline literals or local module-level constants** across `lib/runtime/` and `lib/keeper/` with no compiler-enforced SSOT.

Direct measurement on `origin/main` (commit `aceefd562a`, 2026-05-19):

```
$ rg -n '"runtime"' lib/runtime/ lib/keeper/ | wc -l
~31 hit
```

Decomposed by shape:

**Group A — inline literals (no local SSOT, ~11 sites)**:

| File | Line | Shape |
|---|---|---|
| `lib/runtime/runtime_runner.ml` | 412–413 | `~provider_id:"runtime" ~model_id:"runtime"` (Dashboard_oas_bridge.record_response) |
| `lib/runtime/runtime_event_bridge.ml` | 247 | `"runtime", \`String "runtime"` (assoc emit) |
| `lib/runtime/runtime_runtime_candidate.ml` | 295 | bare literal |
| `lib/keeper/keeper_agent_run.ml` | 763 | `let model = "runtime" in` |
| `lib/keeper/keeper_generation_lineage.ml` | 120, 169 | `let model = "runtime" in` (2 sites) |
| `lib/keeper/keeper_oas_checkpoint.ml` | 71 | record field `model = "runtime"` |
| `lib/keeper/keeper_turn_driver_wrappers.ml` | 85, 89 | `model = Some "runtime"` + nested literal |
| `lib/keeper/keeper_rollover.ml` | 314 | `let model = "runtime" in` |
| `lib/keeper/keeper_status_detail.ml` | 812 | assoc key `("runtime", runtime_surface_json …)` |

**Group B — local module-level constants (~12 sites, not shared)**:

| File | Line | Constant name |
|---|---|---|
| `lib/runtime/runtime_catalog_runtime_probe.ml` | 14–15 | `public_runtime_provider_label`, `public_runtime_model_label` |
| `lib/runtime/runtime_observation.ml` | 49 | `public_runtime_model_label` |
| `lib/runtime/runtime_attempt_liveness_observer.ml` | 34 | `public_runtime_provider_label` |
| `lib/runtime/runtime_attempt_fsm.ml` | 556 | `public_runtime_provider_label` |
| `lib/runtime/runtime_attempt_liveness_config.ml` | 92 | `runtime_candidate_key` |
| `lib/keeper/keeper_runtime_contract.ml` | 214 | `runtime_lane_label` |
| `lib/keeper/keeper_turn_driver.ml` | 205 | `runtime_candidate_label` |
| `lib/keeper/keeper_unified_turn_success.ml` | 8 | `runtime_lane_label` |
| `lib/keeper/keeper_unified_turn.ml` | 18 | `runtime_lane_label` |
| `lib/keeper/keeper_agent_result.ml` | 62 | `runtime_lane_label` |
| `lib/keeper/keeper_hooks_oas.ml` | 48 | `runtime_lane_label` |
| `lib/keeper_hooks_oas_types/keeper_hooks_oas_types.ml` | 11 | `runtime_lane_label` |
| `lib/keeper/keeper_unified_metrics_support.ml` | 79, 187 | `runtime_lane_label`, literal |
| `lib/keeper/keeper_status_runtime.ml` | 13, 219 | array literal members |

**Group C — string-set membership (not redaction, but adjacent)**:

| File | Line | Shape |
|---|---|---|
| `lib/keeper/keeper_status_runtime.ml` | 219 | `[ "error"; "failed"; "timeout"; "graphql"; "model"; "runtime"; "provider" ]` — *NOT a redaction label*. Heuristic substring classifier. Out of scope for RFC-0132; tracked under RFC-0089 string-classifier policy. |

Sites in `keeper_unified_metrics.mli` (lines 113, 141) are doc-comment mentions of the redacted lane, not emit sites — they remain as documentation referencing `Boundary_redaction.runtime_provider_label`.

### Why this is a problem

1. **No compiler enforcement.** A new Runtime or Keeper module can introduce `"runtime"` as an inline literal without any lint or type signal. The `feedback_runtime_lens_boundary_carve_out` regression (#15040 / #15070 / #15089) is the empirical case — three separate PRs reintroduced inline literals because the boundary discipline lived only in commit history and runbooks.
2. **Drift surface.** Group B's local constants encode the *same* policy at 12+ sites independently. Any future change to the redaction label (e.g., `"runtime"` → `"redacted"` for downstream observability tooling) requires a manual sweep across 23+ sites. This is the canonical *Scattered Hardcoded Defaults* anti-pattern.
3. **Boundary ambiguity.** Without a typed surface, it is not visible at call sites *whether* a string is meant to cross the boundary (redact) or remain internal (real provider). Reviewers must trace data flow to verify. This makes Group B's local SSOTs especially fragile — they document a policy that cannot be enforced.

### Why this is not a workaround

RFC-0132 is a **root fix** of anti-pattern 1, not a counter, telemetry, or string classifier. The Workaround Rejection Bar checklist (§7) is satisfied:

| # | Check | Status |
|---|---|---|
| 1 | "makes X visible" only | ❌ No — replaces literals with typed value |
| 2 | string/substring classifier added | ❌ No — *removes* literal scatter |
| 3 | "PR #N only fixed K of M sites" | ❌ No — PR-2 closes all sites at once (PR-2a/2b split is optional, not required) |
| 4 | catch-all `_ ->` added | N/A |
| 5 | cap/cooldown/dedup/repair | N/A |
| 6 | test backdoor exposed | N/A |
| 7 | same typo at N sites without codemod | N/A — codemod is the mechanism |

---

## 2. Proposed solution

Introduce a private-type SSOT module that owns the redaction label vocabulary and forces all boundary-emit sites to route through it.

### 2.1 Module shape

`lib/types_boundary/boundary_redaction.mli`:

```ocaml
(** Boundary redaction labels — SSOT for external surface label vocabulary.

    External surfaces (dashboard SSE, OAS bridge, keeper telemetry exposed to
    the operator UI) intentionally redact the real provider/model identity
    behind a fixed label. This module is the only place that holds the label
    string. All emit sites must route through {!to_string}.

    Internal observability (logs, real provider records, FSM event payloads
    that stay inside the OCaml runtime) MUST continue to use the actual
    provider/model identity — do not route those through this module.

    Reference: RFC-0132. *)

type public_label = private string
(** Private alias — external constructors cannot fabricate a value. *)

val runtime_provider_label : public_label
(** The redaction label used for *provider_id* on external surfaces. *)

val runtime_model_label : public_label
(** The redaction label used for *model_id* on external surfaces. *)

val unknown_model_label : public_label
(** The label used for *model_id* on external surfaces when no model evidence
    exists. *)

val to_string : public_label -> string
(** Project a redaction label into a plain string at the emit boundary. *)
```

`lib/types_boundary/boundary_redaction.ml`:

```ocaml
type public_label = string

let runtime_provider_label = "runtime"
let runtime_model_label = "runtime"
let unknown_model_label = "unknown_model"
let to_string s = s
```

The two labels are *currently equal strings*. The private type still serves a purpose:

1. **Constructor capture.** External code cannot write `Boundary_redaction.foo_label = "runtime"` — only the two named values exist.
2. **Future divergence.** If the labels diverge (e.g., `"runtime"` → `"redacted-provider"` / `"redacted-model"` for clearer operator UX), the change happens in one file.
3. **Caller intent.** A function signature `… -> Boundary_redaction.public_label -> …` is self-documenting at the boundary type level.

### 2.2 Module location

`lib/types_boundary/` is a new sub-library directory. Rationale: keep the module out of `lib/runtime/` and `lib/keeper/` so neither subsystem owns the policy. A future RFC may move other boundary-redaction concerns (e.g., persona name redaction) here.

If a new sub-library introduces a build-graph cycle with existing godfiles (RFC-0085 territory), PR-1 will fall back to placing the module at `lib/types/boundary_redaction.{ml,mli}` instead. The directory choice is **not load-bearing for the RFC's typed-surface guarantee**.

---

## 3. PR plan

### PR-1 — Module introduction (< 100 LoC, no caller change)

- Add `lib/types_boundary/boundary_redaction.{ml,mli}` + `dune` file.
- Add `test/test_boundary_redaction.ml` Alcotest:
  - `to_string runtime_provider_label = "runtime"`
  - `to_string runtime_model_label = "runtime"`
  - *Compile-time negative test*: a commented-out attempt to construct a value externally, with a comment stating the compiler reject is the test. (OCaml's type system makes this a structural property; no runtime assertion possible.)
- No caller changes. Standalone, mergeable independently.
- Estimated diff: + 60 LoC source + 20 LoC test.

### PR-2 — Codemod across all sites

Replace Group A (inline literals) and Group B (local constants) with `Boundary_redaction.to_string` calls. The local constants in Group B become aliases (`let runtime_lane_label = Boundary_redaction.(to_string runtime_provider_label)`) for a *deprecation window* of one PR, then removed in PR-2's tail commit. This avoids breaking transitive callers of the local constants in test code.

**Site-by-site classification** (mandatory pre-codemod step):
- Each of the ~23 sites in Groups A+B is classified as **boundary-emit** (route through `Boundary_redaction`) or **internal observability** (leave as real provider string). Memory `feedback_runtime_lens_boundary_carve_out` documents this is *not* a mechanical sweep — past PRs misclassified some sites and caused regressions.
- The classification is recorded in the PR-2 body as a table with reviewer cross-check expectation.

**Split option**: If the codemod PR exceeds ~400 LoC or reviewer prefers smaller chunks, split into:
- **PR-2a**: `lib/runtime/` sites (~6 files).
- **PR-2b**: `lib/keeper/` sites (~12 files).
- Split is a *reviewer-comfort* choice, not an *N-of-M workaround* — both halves land in the same sprint, neither half stands alone as a value claim.

### PR-3 — Lint rule (compile-time inline-literal rejection)

Add a ppx or `dune` lint rule (following RFC-0126 Phase 2 lint stack pattern):

- AST walker rejects string literals equal to `"runtime"` *outside* `lib/types_boundary/boundary_redaction.ml`.
- Exception list: doc comments and test fixtures (matched by file path: `*.mli` doc comments, `test/**`).
- Group C site (`keeper_status_runtime.ml:219` heuristic classifier) is allow-listed with a `(* ALLOWLIST: RFC-0132 / RFC-0089 *)` comment that the lint rule recognizes.

Once PR-3 is merged, any future PR that adds an inline `"runtime"` literal at an emit site **fails the build** before review.

---

## 4. Trade-offs

### Advantages
- **Compiler-enforced SSOT.** Adding a new emit site without going through `Boundary_redaction` becomes a build failure (after PR-3).
- **Drift goes to zero.** Future label change touches one file.
- **Closes anti-pattern 1** at the *RFC-policy* level, not at individual-PR-review level.
- **Self-documenting boundary.** Function signatures carry the typed surface.

### Costs and risks
- **23-site changeset.** PR-2 is materially large (~300–400 LoC delta). Reviewer load is real. Mitigation: PR-2a / PR-2b split option (§3) without changing the RFC contract.
- **Misclassification risk.** Some current Group B sites may be *internal observability* incorrectly using the redaction label (or vice versa). Memory `feedback_runtime_lens_boundary_carve_out` is the documented regression case. Mitigation: per-site classification table in PR-2 body, reviewer cross-check required.
- **Sub-library placement.** `lib/types_boundary/` adds a new sub-library. If this introduces a build-graph cycle, the fallback (`lib/types/`) is acceptable — see §2.2.
- **Lint rule maintenance.** PR-3's ppx/dune rule is one more piece of the lint stack (RFC-0126). The rule is narrow (one literal, one allow-list).

### Rejection scenarios (when *not* to merge this RFC)
- If a future audit reveals that **most** Group B sites are actually internal observability that should keep real provider strings (i.e., the carve-out applies more narrowly than this RFC assumes), then PR-2 shrinks to <5 sites and PR-3's lint rule becomes too broad. In that case, downsize the RFC to PR-1 only and document the narrower scope.
- If RFC-0088's `Counter-as-Fix` umbrella absorbs this as a sub-case with a different mechanism (e.g., typed event payloads at SSE boundary make the label irrelevant), supersede this RFC.

---

## 5. Verification plan

| Phase | Verification |
|---|---|
| PR-1 | Alcotest: `runtime_provider_label \|> to_string = "runtime"` and `runtime_model_label \|> to_string = "runtime"`. Compile-time: attempting `let x : Boundary_redaction.public_label = "foo"` outside the module fails the build. |
| 2026-07-06 extension | Alcotest: `unknown_model_label \|> to_string = "unknown_model"` and the value is distinct from `runtime_model_label`. Governance dashboard model classification and keeper status model labels route missing model evidence through this typed label instead of a local string. |
| PR-2 | For each of the 23 sites: dashboard SSE / OAS bridge / keeper telemetry output byte-equality regression test. The boundary-emit byte stream must be identical to pre-codemod main. Regression count target: 0. |
| PR-3 | Adding a test fixture that places `let _ = "runtime"` at `lib/runtime/foo.ml` causes a build failure with the lint rule error message. Removing the fixture restores the build. |
| Overall | After PR-3 merge, `rg -n '"runtime"' lib/runtime/ lib/keeper/` should return only: (a) `boundary_redaction.ml` source, (b) `keeper_status_runtime.ml:219` allow-listed heuristic, (c) `.mli` doc comments. Total expected hits: ≤ 4. |

---

## 6. Status escalation path

| State transition | Trigger |
|---|---|
| Draft → Active | PR-1 merged. RFC body and `Boundary_redaction` module both in main; codemod (PR-2) in progress. |
| Active → Implemented | PR-2 merged (all 23 sites converted). RFC body updated with `implementation_prs` filled. |
| Implemented → Closed | PR-3 merged (lint rule active). `rg` final count verified ≤ 4. Closeout commit `docs(rfc-0132): closeout — lint rule enforced` lands. |

If the rejection scenario (§4) triggers after PR-1, this RFC transitions Draft → Withdrawn (or Superseded by a narrower RFC).

---

## 7. WORKAROUND-CARRYOVER

None. RFC-0132 is a root fix. No deprecated path is created; no symptom-suppression hook is introduced. The lint rule (PR-3) prevents the anti-pattern from recurring.

---

## 8. Open questions

1. **Naming.** Is `Boundary_redaction` the right module name, or should it be `Redaction_label` / `Public_surface_label`? Naming is reversible in PR-1 review.
2. **Should `public_label` be polymorphic over the label kind** (`provider` / `model`)? The current design has them be equal strings, so a plain private alias suffices. If divergence is anticipated, a tagged variant (`Provider | Model`) would be safer. Defer this decision to PR-1 review.
3. **Group C (`keeper_status_runtime.ml:219`).** Is the heuristic string list actually load-bearing, or can it be migrated to a typed sum (RFC-0089 territory)? Out of scope for RFC-0132 but worth a follow-up RFC if the list grows.

---

## 9. References

- Plan SSOT: `knowledge/research/2026-05-19-reverse-engineering-design-map-gap-tracking.md` Gap 2
- Bundle: PR #16480 §RFC B candidate
- Memory: `memory/feedback_runtime_lens_boundary_carve_out.md`
- Anti-pattern source: `instructions/software-development.md` §AI 코드 생성 안티패턴 §1
- Workaround Rejection Bar: `instructions/MANIFEST.md` Workaround Rejection Bar
- Related RFCs: 0085, 0088, 0089, 0126, 0131
