---
title: RFC-0299 — Typed-Boundary Sweep (string-classifier → closed-sum, dead SSOT reclamation)
status: Draft
updated: 2026-07-13
---

# RFC-0299: Typed-Boundary Sweep

| Field | Value |
|---|---|
| Status | Draft |
| Repo | `jeong-sik/masc` (refs `jeong-sik/oas`) |
| Supersedes / absorbs | masc #22071, #18840, #20674, #22042, #22246, #22639, #15257, #22177 (workaround-rejection signature #2/#3 cluster) |
| Relates | oas #2051 (capability ingestion 4 paths), manifesto "NO string-match / NO SSOT violations", CLAUDE.md workaround-rejection §2 |
| Audit | 2026-06-29 8-lens manifesto audit — the single most repeated structural anti-pattern (7+ sites). |

## 0. Summary

A cluster of open issues share one root: **closed-sum variants reverse-classified by raw string match with `|_ -> None/Unknown` catch-alls**, plus **dead SSOT modules whose consumers reimplement the same logic as strings**. Each new variant silently drifts — dead match arms, defeated safety gates, mis-ranking — and that drift is itself a silent failure. This RFC proposes a domain-by-domain **typed-boundary sweep**: one closed-sum type + one SSOT `of_string` (exhaustive, fail-closed) per domain, with a lint that forbids `_`-catch-all string classifiers going forward.

This is explicitly NOT N-of-M patches. Each domain is its own PR; the RFC fixes the *abstraction boundary* so the compiler enforces parity (manifesto: "use OCaml's strengths — exhaustive match").

### Scope amendment (2026-07-13)

The former evidence-spec and tool-capability phases are withdrawn. A closed sum
is appropriate for objective wire vocabulary, but typing a local semantic
classification does not make it objective. Task completion is judged by its
configured LLM; concrete external effects use the product-neutral Keeper Gate.
Neither path may be authorized or rejected by evidence kind, tool name, or a
registration-time effect class. The remaining phases are representation/codec
SSOT work only.

## 1. Why a sweep, not per-issue fixes

The 2026-06-29 audit found the pattern compounds: `string catch-all` → `silent drift` (dead arm / defeated gate) → `silent failure` (operator-invisible). Fixing one site leaves the structural hole that regrew the drift (e.g. #15257's `config_category_enum_strings` was supposedly collapsed by RFC-0057 Phase 1 but re-accumulated across 5 files by 2026-05-14). Per-site patches are exactly the workaround-rejection signature #3 ("N-of-M patch admits abstraction failure"). The sweep closes the boundary so the compiler blocks the next regression.

## 2. Inventory (line-pinned, from issue bodies)

| Domain | Issue | Current anti-pattern | Proposed SSOT |
|---|---|---|---|
| Keeper lifecycle / blocker_class / disposition / tool_failure_class | #22071 | variants reverse-classified via string match, `_ -> None/Unknown`. HIGH site `server_dashboard_http_execution_surfaces.ml:395-441`: 4 patchers silently stop on new variant | closed-sum + exhaustive `of_string` per type; one SSOT module |
| Evidence gate | #18840 | Historical substring and magic-threshold defect | **Withdrawn phase** — structured evidence is LLM context, not a completion classifier |
| Tool capability axis | #22042 | Historical name-based semantic classification | **Withdrawn phase** — descriptors do not authorize, hide, or rank tools |
| Attempt state | #22246 | `Attempt_state` (SSOT from #8930) has **0 production consumers**; sidecar reimplements `attempt_record` with `last_attempt_result:string` + ISO-string time | retire sidecar record; route through `Attempt_state` (result as closed variant, not string) |
| Health / keeper status | #22639 | stringly-typed status + severity rank reimplemented 6 places; `health_level_of_string` doesn't recognize `'blocked'` → `HL_unknown` → rank 0 (silently down-ranks a blocked fleet) | `health_status` closed-sum + single rank function SSOT |
| Config category enum | #15257 | `config_category_enum_strings` duplicated 5 files (regrew after RFC-0057) | `config_category` variant + single SSOT |
| masc_run_* tool schemas | #22177 | 4 tool JSON schemas defined twice (`tool_schemas_run.ml` vs `tool_run.ml:115-184`) with divergent fields (`additionalProperties:false` vs descriptions) | single schema SSOT, both consumers import |

oas #2051 (capability ingestion 4 paths) is the same shape in the sibling repo; referenced for cross-repo coordination, not migrated here.

## 3. Goal — the typed boundary

For each domain:
1. One **closed-sum variant** type (e.g. `health_status`, `claim_scope_mode`, `evidence_spec`).
2. One **SSOT module** owning the type + `to_string` + `of_string` where `of_string` is **exhaustive** (no `_ ->` catch-all) and returns `(t, string) result` — unknown strings are a `Result.Error`, never a permissive default.
3. Every consumer imports the type; no local string match.
4. Where a string wire-format is unavoidable (JSON/SSE), the parser lives in the SSOT module and the boundary is the only place strings cross.

This makes "illegal states unrepresentable" (Parse-don't-validate) and turns new-variant addition into a compile error at every consumer.

## 4. Phases (each = own PR, own gate)

- **Phase 1 — `health_status`** (#22639): the latent fleet-down-rank landmine. Closed-sum + single rank SSOT; migrate 6 sites. Gate: dashboard rank test pins `'blocked'` → correct rank; no string match remains.
- **Phase 2 — `claim_scope_mode`** (#20674): variant + retire dead fossilized arm. Gate: dead-arm removal verified; consumers exhaustive.
- **Phase 3 — evidence classification: Withdrawn.** Evidence may be parsed and resolved, but no local kind/count classifier decides Task completion.
- **Phase 4 — tool capability classification: Withdrawn.** Tool schemas remain visible and actual external effects reach the ordinary Keeper Gate.
- **Phase 5 — `Attempt_state` reclamation** (#22246): make the SSOT module load-bearing — sidecar routes through it; delete string-typed `attempt_record`. Gate: 0 string-typed result fields; `Attempt_state` has production consumers.
- **Phase 6 — `config_category`** (#15257): variant + SSOT, collapse 5 files. Gate: 5-file dup gone; RFC-0057 drift cannot regrow.
- **Phase 7 — masc_run_* schemas** (#22177): single schema SSOT, both consumers import. Gate: compiler enforces field parity.
- **Phase 8 — lifecycle/blocker/disposition/tool_failure_classifiers** (#22071): the HIGH dashboard site; 4 patchers become exhaustive. Gate: a new lifecycle variant is a compile error at every patcher.

## 5. Drift guard (CI lint)

After Phase 8, enforce the boundary structurally:

```bash
# Forbid raw string catch-all reverse-classifiers of known closed-sum domains.
# Allow-list: the SSOT of_string sites (which are exhaustive by construction).
PATTERN='_ -> (None|Unknown)'   # in files touching health/claim_scope/evidence/attempt/config_category/lifecycle
```

Plus an ocaml warning scope (`-w +8` inexhaustive is already on; this targets the *string* match analogue the compiler can't see). Review-checklist item until automated.

## 6. Relationship to concurrent operator work

The 2026-06-29 audit noted every issue here *reports* a violation and proposes an aligned fix; the operator is actively fixing several mascot defects in parallel (e.g. Eio mutex substrate). This RFC coordinates the **typed-boundary abstraction** so individual fixes converge on the SSOT rather than regrowing drift (the #15257 / RFC-0057 regression is the cautionary precedent). Each phase is mergeable independently; the RFC is the convergence target, not a blocker.

## 7. Non-goals

- Per-issue behavioral fixes beyond the type boundary (e.g. #22042's anti-thrash semantics are the issue's scope; this RFC only fixes the classification type).
- oas #2051 capability ingestion (sibling repo; coordinated, not migrated).
- The silent-failure sink cluster (#21990 `write_json` `Result.t`) — separate axis; covered by its own issue, not this RFC.

## 8. Open questions

1. `of_string` policy for genuinely forward-compatible wire fields (e.g. a new provider kind from an older mascot reading a newer workspace) — fail-closed vs versioned tolerance? Default proposal: fail-closed + explicit migration, never silent permissive default.
2. Should the drift guard lint be a new CI check or folded into the existing `code-smell-ratchet`? Fold is cheaper; standalone is clearer.
3. Phase ordering vs operator's in-flight #22071 dashboard work — coordinate so the HIGH site lands with, not against, the operator's reskin.
