# RFC-0035: Cognitive IDE Master Plan Integration

- **Status**: Draft
- **Author**: Claude (autonomous, /loop iteration 1)
- **Created**: 2026-05-06
- **Source basis**: self-contained summary of the operator-provided Master
  Report (137KB / 3417 lines / 12 chapters / 11 dimensions). This RFC records
  the actionable repo-owned mapping so reviewers do not need a local file.
- **Related**: #13768 cognitive-disclosure-cockpit, #13773 cognitive-mode-registry,
  #13779 event-stream-temporal-sync, #13781 event-stream-gradient-attraction
- **Out of scope**: dashboard credential/identity (RFC-0008 territory), oas/agent_sdk
  bumps (handled separately under `chore(oas)` PRs), cross-repo work outside
  `masc-mcp` and `oas`.

## Problem

The Master Report is a 137KB design document spanning 11 cognitive/UI dimensions
and a four-tier confidence ladder (P0/P1/P2/P3). Multiple agents in the fleet
have already started landing dashboard PRs that *resemble* fragments of the
report's P0 checklist:

| Master P0 checklist item | In-flight PR | Surface |
|---|---|---|
| #1 3-tier disclosure (L1/L2/L3) | #13768 cognitive-disclosure-cockpit | dashboard |
| #2 4-mode CognitiveMode state | #13773 cognitive-mode-registry | dashboard |
| #3 Gradient Attraction visual | #13781 event-stream-gradient-attraction | dashboard |
| #4 Temporal Synchronization | #13779 event-stream-temporal-sync | dashboard |
| #5 Semantic Gravity ranking | — (open) | backend lib |
| #6 Intentional Projection | — (open) | backend lib |

Without an integration RFC, the fleet has no shared vocabulary to decide:

1. Which PRs satisfy which Master Report deliverable.
2. Which dimensions belong on the **dashboard** surface vs. the **OCaml lib**
   surface vs. **agent_sdk (oas)**.
3. What "completion" of P0 actually means before P1 (Chronicle/Librarian) can
   begin without rework.

This RFC establishes the mapping table and the boundary discipline before any
further code is written.

## Goals

- Provide a **dimension → module** mapping for all 11 dimensions in the Master
  Report so that future PRs cite a target module instead of inventing one.
- Mark which dimensions are **already partially landed**, which are **owned by
  this RFC stack**, and which are **deferred** behind a confidence gate.
- Avoid duplicating P0 work that is already in flight in `dashboard/`.
- Keep the OCaml `lib/` surface independent of dashboard/UI layers, in line with
  the existing `(include_subdirs unqualified)` convention.

## Non-goals

- Reproducing the Master Report. The mapping table below is a routing manifest,
  not a re-derivation.
- Changing `agent_sdk` (oas). The Master Report's P0–P2 do not require oas
  surface changes; P3 ("Cognitive State Inference Engine") may, and that will
  be its own RFC.
- Touching credential or identity code paths. RFC-0008 territory.

## Mapping table (dimension → module)

| Dim | Master Report topic | Surface | Module / file | Status |
|-----|---------------------|---------|---------------|--------|
| 01 | Cognitive context flow (Progressive Disclosure) | dashboard | `dashboard/.../cognitive-disclosure*` | in-flight (#13768) |
| 01 | 4-mode CognitiveMode | dashboard | `dashboard/.../cognitive-mode-registry*` | in-flight (#13773) |
| 01 | Gradient Attraction (visual) | dashboard | `dashboard/.../event-stream*` | in-flight (#13781) |
| 01 | Temporal Synchronization | dashboard | `dashboard/.../event-stream-temporal-sync*` | in-flight (#13779) |
| 01 | **Semantic Gravity** (ranking) | **lib** | `lib/cognitive_gravity.ml` | **this RFC, PR-1** |
| 01 | Intentional Projection (history-based prediction) | lib | `lib/intentional_projection.ml` (TBD) | deferred to PR-2 |
| 02 | Chronicle data model | lib + dashboard | `lib/chronicle_event.ml` (TBD) | deferred (P1) |
| 02 | Librarian RAG pipeline | lib + adapters | TBD; reuse `pgvector` infra | deferred (P1) |
| 03 | Code-Plan Alignment metrics | lib | `lib/alignment_score*.ml` (TBD) | deferred (P2) |
| 04 | Category-theoretic code analysis | lib + ppx | TBD | deferred (P3) |
| 05 | Design Metrology (color/layout drift) | tooling | likely in `dashboard/` test harness | deferred (P2) |
| 06 | FSM-based Tools / Structured Bash | lib | overlaps with `keeper_shell_*`, `tool_*` | partial — already exists, audit pending |
| 07 | Transformer→IDE direct mapping | dashboard | overlaps with cockpit | deferred (P3) |
| 08 | Minority opinion (1..N agents) | lib | overlaps with `cascade_*` | partial — already exists |
| 09 | Goal-driven design | lib | overlaps with `goal_loop`, `goals.json` | partial — already exists |
| 10 | Orthogonal information UI | dashboard | TBD | deferred (P2) |

The "surface" column is a hard rule for this RFC stack: a PR that touches
multiple surfaces gets split. The mapping is also the discovery key for the
RFC-pre-flight check (`scripts/pr-rfc-check.sh`): future PRs in any of these
modules must cite RFC-0035.

## Decision: this RFC delivers Dim01 #5 in PR-1

Of the six P0 checklist items, items #1–#4 are already covered by in-flight
dashboard PRs. Item #6 (Intentional Projection) requires a history store and
is deferred to PR-2.

**PR-1 of this RFC stack** delivers item #5: a Semantic Gravity ranker as a
pure OCaml module in `lib/`, with no dashboard or oas changes.

### Why "gravity" is a pure-lib concern

Semantic Gravity is a ranker: given a query context (current task keywords,
focus tags) and a list of candidate items (board posts, tasks, episodes), it
produces a ranking that maximises *relevance × recency × frequency*. The
algorithm itself is decoupled from any UI surface. The dashboard PRs deal with
*how* to render attention; this PR deals with *which* items deserve attention.

### Out of scope for PR-1

- Adapting any existing call site to use the ranker. PR-1 is additive only.
- Persisting weight tunings. Default weights are hard-coded with a getter so
  future tuning can be plugged in via config without an API break.
- Mocking embeddings. The ranker uses keyword-overlap (Jaccard) as the
  similarity primitive; embedding-based similarity is a follow-up.

## Implementation plan (PR-1)

1. `lib/cognitive_gravity.mli` + `.ml`: pure OCaml module exposing
   `default_weights`, `gravity_score`, and `rank`.
2. `test/test_cognitive_gravity.ml`: 7 unit tests covering the empty-list,
   single-item, ordering, weight-zero, recency-decay, frequency-clamp, and
   case-insensitive properties.
3. `test/dune`: append `test_cognitive_gravity` to the synchronous test group.
4. `dune-project`: bump version `0.19.11` → `0.19.12`.
5. `CHANGELOG.md`: new `[0.19.12]` section.

No new dependencies. No `Eio`-required code. No filesystem or network access.

## Verification gates

PR-1 is mergeable only if all of the following hold:

- `dune build @check` clean from a fresh `dune clean`.
- `dune runtest --only-test=test_cognitive_gravity` passes.
- `bash scripts/verify_audit_claim.sh 1 'cognitive_gravity' lib/` returns 0
  (i.e. exactly one new module surface added).
- Self-review against `~/me/agents/best-programmer/AGENT.md` posted in the PR
  body.

## Future PRs in this stack

| PR | Topic | Confidence tier | Dependencies |
|----|-------|-----------------|--------------|
| PR-1 | `cognitive_gravity` (this iteration) | P0 | none |
| PR-2 | `intentional_projection` skeleton | P0 | PR-1 |
| PR-3 | `chronicle_event` data model | P1 | PR-1, RFC reviewed |
| PR-4 | Librarian retriever (lib only) | P1 | PR-3 + pgvector audit |
| PR-5 | Alignment score metric backbone | P2 | PR-1..3, separate confidence gate |

PR-2 onward will be sequenced in further `/loop` iterations and will not be
opened in parallel from this iteration.

## Risks

1. **Dim06 / Dim08 / Dim09 already partially exist.** Marking them as
   "partial" risks future agents writing duplicate modules. PR-1 does not
   touch these but a follow-up audit RFC (RFC-0036?) should reconcile.
2. **In-flight dashboard PRs may diverge from this routing manifest.** The
   mapping table above is the SSOT once this RFC merges; in-flight PRs are
   linked back via the table itself, not via cross-citation in PR bodies (to
   avoid noisy back-edits).
3. **The Master Report is a single author's synthesis.** Confidence tiers
   (★★★★★ down to ★★) are the author's own. This RFC respects that ladder
   but does not adopt the recommendations as a contract; each PR stands on
   its own evidence gate.

## Alternatives considered

- **Skip the RFC, open PR-1 directly.** Rejected: with #13768/#13773/#13779/
  #13781 already in flight, a Semantic Gravity PR with no integration manifest
  is indistinguishable from drift.
- **Wait until in-flight PRs merge.** Rejected: the Master Report's confidence
  ladder asks for PR-1 work to land *concurrently* with the dashboard layer
  so that the ranker is ready when the cockpit needs to call it.
- **Open the RFC against `~/me/docs/rfc/` instead of `masc-mcp/docs/rfc/`.**
  Rejected: the RFC's enforcement target is `masc-mcp` modules, so it must
  live in the same repo as the code it governs.
