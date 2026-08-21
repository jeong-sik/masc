---
status: reference
last_verified: 2026-04-19
code_refs:
  - lib/
  - docs/PRODUCT-OPERATING-PLAN.md
---

# Root-Cause Rubric

> Supersedes the ad-hoc 5-category list in `PRODUCT-OPERATING-PLAN.md` (Model-Agnostic MASC Epic, #6715) and the 4-category grouping in `memory/2026-04-09-masc-tool-failure-root-causes.md`.
> Status: Living — markers are refined when detection signal drops on the BookShelf benchmark (`~/me/lab/keeper-benchmark/`).
> Last Updated: 2026-04-19

## Purpose

Every open issue in `masc` and `agent core` should be classifiable into one or more of seven categories, each defined by a **structural marker** — a pattern a `rg` grep or an LLM pass can detect without prose interpretation. Prose interpretation has been empirically shown to produce false pairings (see `~/me/memory/handoff-2026-04-19-issue-close-sweep.md` for the 0/17 triage hallucination incident).

The rubric is applied two ways:

1. The issue body declares `root: <value>[, <value>]` in its `masc-triage` block for each marker that matches;
   the `Issue Taxonomy` workflow projects those onto `root/*` labels. The vocabulary lives in
   `.github/issue-taxonomy.json` and carries one value this rubric does not yet describe: `ndt`
   (non-determinism not embraced - retry, fallback, or jitter absent).
2. Benchmark: `~/me/lab/keeper-benchmark/bookshelf/` seeds one bug per category and measures whether the Keeper agent detects, fixes, and self-classifies them.

## The 7 Categories

### SSOT — Single Source of Truth Violation

| Field | Content |
|-------|---------|
| Label | `root/ssot` |
| Color | `#aa0000` |
| Marker | Same literal or constant appears in ≥2 sites AND at least one site does not go through `Env_config_runtime` / `Config.*` |
| Example | `"127.0.0.1"` inlined in 6 files with one using a different host (`#8387`) |
| Issue body triggers | "hardcoded", "drift", "duplicated in N files", "not using Env_config" |

### TEL — Telemetry Gap

| Field | Content |
|-------|---------|
| Label | `root/telemetry` |
| Color | `#0066cc` |
| Marker | A request path, state transition, or error branch exists without a corresponding metric / span / `correlation_id` propagation |
| Example | `emit_task_activity ~correlation_id:_` signature exists but no caller wires a real value (`#7520`) |
| Issue body triggers | "metric", "correlation_id", "OTel", "span", "observability gap" |

### BND — agent core-MASC Boundary Violation

| Field | Content |
|-------|---------|
| Label | `root/boundary` |
| Color | `#ff6600` |
| Marker | MASC-side code reimplements something agent core already provides: lifecycle, budget, retry, approval hook, context injector |
| Example | `context_agent_core_sync` manually tracking token counts duplicates agent core context_injector |
| Issue body triggers | "agent core 재구현", "lifecycle", "budget", "retry", "approval hook", "MASC-side reimplement" |

### SIL — Silent Failure

| Field | Content |
|-------|---------|
| Label | `root/silent` |
| Color | `#990066` |
| Marker | Error / unknown branch coerced to a default without caller signal: `try ... with _ -> default`, `match ... Error _ -> ""`, `Result.value ~default`, `_ -> Unknown → Some Default` |
| Example | `timeout_s >= interval_s silently clamps across 3 components` (`#7695`) |
| Issue body triggers | "silent", "fail-open", "swallow", "wildcard default" |

### VAR — Variant Miss

| Field | Content |
|-------|---------|
| Label | `root/variant` |
| Color | `#006633` |
| Marker | A `match` uses `| _ -> fallback` where the wildcard collapses a constructor added later; or a schema enum hand-rolled drifts from a Variant type |
| Example | A schema enum is maintained separately from its typed variant and omits a constructor |
| Issue body triggers | "variant miss", "match wildcard", "schema enum drift", "exhaustive", "new constructor" |

### STR — Naive String Matching

| Field | Content |
|-------|---------|
| Label | `root/string` |
| Color | `#cc6600` |
| Marker | Control flow branches on `String.contains`, `Str.regexp`, or substring check where a structural parse exists |
| Example | Title-similarity triage pairing PRs with issues produces 0/17 valid matches (2026-04-19 incident) |
| Issue body triggers | "string match", "substring", "String.contains", "regex dispatch", "magic string" |

### DET — Deterministic Assumption

| Field | Content |
|-------|---------|
| Label | `root/det` |
| Color | `#333399` |
| Marker | Code assumes a single input shape, a race-free ordering, or a stable LLM tool-call format without synchronization or parsing fallback |
| Example | Admission queue lacks fd/memory saturation gate (`#7500`); shared `ref` counter without `Atomic.int` or `Mutex` |
| Issue body triggers | "race", "concurrent", "deterministic assumption", "single input shape", "LLM tool-call non-determinism" |

## Mapping from Prior Categorizations

The Model-Agnostic MASC Epic (`#6715`, 2026-04-12) and the 2026-04-09 tool-failure memory used partially overlapping taxonomies. The 7-category rubric subsumes them:

| Prior category | New categories |
|----------------|----------------|
| `classify_model_family` stringly-typed | STR + VAR |
| Inference parameter hardcoding | SSOT + BND |
| Spawn CLI hardcoding | SSOT |
| Vendor-specific branching | STR + DET |
| Runtime-specific fallbacks | SIL + VAR |
| Guard false positives (`#6166`) | SIL |
| Read-path mismatch (`#6167`) | DET |
| Readonly bash crash (`#6168`) | STR |
| Dashboard loss of detail (`#6169`) | TEL |

Complex issues carry multiple labels. Empirically ≥30% of open issues fall into 2+ categories (e.g. `#7716` null `pause_reason` is both DET and TEL).

## Application Procedure

For a new or existing issue:

1. Read title + body first 800 chars.
2. For each of the 7 triggers above, check marker match.
3. Put the matching value in the issue body's `masc-triage` block under `root:`. Do not add the label by hand;
   the workflow reconciles labels from the block and will remove one that the block does not declare.
4. If no marker matches, do not apply a default label — either the rubric is underspecified for this case (data for next iteration) or the issue is a pure feature request, not a root-cause fix.

## Benchmark Linkage

The `~/me/lab/keeper-benchmark/bookshelf/` synthetic project seeds one bug per category. When Keeper processes the benchmark, its Detection rate against the 7 bugs directly measures whether this rubric's markers are concrete enough for an LLM agent to apply.

If Detection drops below 5/7, the markers are too abstract and need to be tightened — this document gets updated, not the Keeper prompt.

## Non-Goals

- This rubric does not rank categories by severity.
- It does not prescribe fixes — only classification.
- It does not replace PR review; it makes triage machine-readable.
