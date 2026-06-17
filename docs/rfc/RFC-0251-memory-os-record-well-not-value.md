---
rfc: "0251"
title: "Memory OS: record well, do not value — remove the scoring layer"
status: Draft
created: 2026-06-17
updated: 2026-06-17
author: vincent
supersedes: []
superseded_by: null
related: ["0243", "0244", "0247", "0247-purge"]
implementation_prs: ["21372"]
---

# RFC-0251 — Memory OS: record well, do not value

## §0 Context — the scoring layer was never proven, and cannot be

Three RFCs built a valuation layer on the keeper Memory OS:

- **RFC-0243** made `confidence` mutable (write-side EMA upsert).
- **RFC-0244** ranks recall by `score_fact` = confidence × access-recency ×
  truth-recency × stale-penalty × access-factor.
- **RFC-0247** added decay / forgetting / promotion machinery on top.

None of it was shown to make memory better. The evidence runs the other way:

- The only observable output of score-promotion — the `_shared` store — is
  **87.5% coordination boilerplate** on the live fleet (2026-06-17:
  14 of 16 `_shared` facts are "continuation checkpoint saved" / "no claimable
  tasks" / "board curation submitted" / "desire·intention·blocker all none").
- `stale_factor` is **dead** — always `0.0`, no producer (RFC-0247 §1 admits it).
- `run_gc` has **0 callers**; `valid_until` is always `None` (RFC-0247 §1).
- There is **no value eval** and there cannot be a meaningful one: the worth of
  a remembered fact is a judgment, not a quantity. Computing a "value rate"
  requires a deterministic boilerplate classifier — exactly the string-classifier
  heuristic this project rejects.

The root is a category error: **valuation was applied as the decision
mechanism**. "Is this worth keeping / promoting / recalling first?" is a
*judgment*, and the project's own discipline says judgment is the LLM's, not a
score function's. A score is a *proxy* for that judgment, and the proxy inverts
on the most common failure mode — boilerplate is the most *frequent* claim, so
corroboration-by-count (noisy-OR over ≥2 keepers) *promotes it first*. The
scoring layer does not merely fail to help; it manufactures the pathology.

## §1 Thesis

> Record well. Do not assign worth.

Memory improves through **recording quality**, not through valuation. This
mirrors how a well-kept note system works: you do not score notes, you decide
what is worth writing, write it in a clear structure, mark what has gone stale,
and link related notes. The leverage is entirely at the *write* and *structure*
layers, exercised by judgment.

Boundary (unchanged project principle):

- **Deterministic** = structure and cheap candidate generation. Closed-sum
  types, JSONL/atomic I/O, `normalize_claim`, lexical-seed candidate selection,
  the index/window bound. These are reproducible and carry no opinion about worth.
- **Judgment (LLM)** = every actual *decision*. What to record, what to skip
  (boilerplate / derivable), what has gone stale, which candidates to surface.
  No score, threshold, decay constant, or count gate stands in for it.

## §2 What changes

### KEEP (deterministic structure / candidate-gen)
- Typed `category` closed sum (`Fact|Constraint|Decision|Open_question|Ephemeral|Unknown`).
- `fact` record, JSONL append, atomic I/O, `normalize_claim`.
- Lexical turn-seed candidate selection (RFC-0244 §2.1 Phase 1 *seed*).
- The librarian as an LLM call.

### REMOVE (valuation machinery — "do not assign worth")
- `Keeper_memory_os_policy.score_fact` (the ranking multiply).
- `confidence` as a *decision* input: `noisy_or`,
  `default_confidence_threshold`, `blend_confidence` EMA, the
  highest-confidence representative pick.
- `stale_factor` (dead), `truth_recency_factor` as a score term.
- The `confidence=%.2f score=%.3f` annotation injected into the keeper's recall
  context (the keeper is shown a fabricated worth — remove it).
- Count-based promotion to `_shared` (corroboration-by-frequency — the
  pathology's direct cause).

### REPLACE (decision → judgment; ranking → candidate order)
- **Recall order**: candidates are ordered by deterministic seed overlap
  (structural cue), not by a worth score. The set handed to the keeper is a
  *relevance-ordered candidate list*, never a ranked-by-value dump.
- **Recording quality (producer)**: the librarian skips what should not be
  recorded at write time — coordination boilerplate and facts derivable from
  the repo / board / lane — by judgment in its prompt, the way a good note-taker
  does not transcribe "I saved a checkpoint." (Mirrors claude-code's
  "don't save what the repo already records.") This is the positive half of the
  thesis and the root fix for the `_shared` boilerplate.
- **Stale handling**: a fact that names a file/symbol/PR is a point-in-time
  claim; staleness is surfaced as a *marker* for the reader to re-judge (already
  shipped, RFC-0232-adjacent staleness marker), not folded into a score.

## §3 Open decision — cross-keeper sharing without count-promotion

`_shared` exists so a fact learned by one keeper reaches others. Count-promotion
(≥2 keepers corroborate) is removed by §2. The replacement is a genuine design
choice and is **left to the author's decision**, not pre-judged here:

- **(a) Drop `_shared` promotion entirely.** Each keeper keeps its own store;
  cross-keeper sharing happens through the Board (explicit, judged), not through
  a silent frequency gate. Simplest; removes the boilerplate vector at the root.
- **(b) Promote by judgment.** A keeper (or the librarian) *decides* a fact is
  worth sharing and writes it to `_shared` deliberately — a recording decision,
  not a count threshold.

(a) is the smaller change and the more aligned with "record well, do not value."
(b) keeps a shared tier but moves the decision to judgment. **This RFC does not
decide between them; the implementing PR must pick one and say why.**

## §4 Phasing

1. **This RFC** — correct the SSOT so parallel keepers stop rebuilding the score
   layer from RFC-0243/0244/0247. Mark the valuation sections of those three as
   superseded by RFC-0251 (amend their `superseded_by`/related on merge).
2. **Recall de-scoring** — remove `score_fact` from recall; order by seed
   overlap; drop the `confidence=/score=` annotation. Read-side only.
3. **Producer recording quality** — librarian prompt skips boilerplate /
   derivable at write time.
4. **Consolidator** — remove `noisy_or` / confidence-threshold promotion; resolve
   §3. **Not in this PR; separate PR required.**
5. **Delete dead valuation code** — `stale_factor`, score terms, EMA, the
   `_shared` count path. The dark/inert organs removed first in PR #21372:
   - GC / decay forgetting (`Keeper_memory_os_gc`, `run_gc` fiber):
     default-off env gate + `valid_until` always `None` meant the TTL pass
     never fired.
   - Edges / spreading-activation recall (`Keeper_memory_os_edges`):
     activation alpha was `0` by default and phase-2 de-scoring left no base
     score to lift, so the machinery had no consumer.

## §5 Verification — honest about what cannot be measured

There is **no value-eval gate**, by design (§0): worth is not quantifiable here.
Verification is therefore:

- **Compiles + unit**: structure/candidate-gen behavior is deterministic and
  unit-testable (seed ordering, codec, `is_promotable`, atomic I/O).
- **Live observation, not scoring**: after the producer change, *read* the live
  `_shared` and per-keeper stores and judge whether boilerplate ingestion
  dropped — by looking, the way §0's baseline was taken (14/16). Recorded as an
  observation with the facts quoted, not reduced to a rate.
- **No faith**: each phase ships behind its own PR + review; no phase claims an
  improvement it did not observe.

## §6 Non-goals

- A value/worth metric, score, or eval harness (the thing this RFC removes).
- Changing the Board, wake-cascade (RFC-0246), or the lane-persistence reply
  path (that line must stay non-empty; RFC-0232 / #20870 watermark-stall).
- Re-introducing decay/TTL forgetting as a *scored* mechanism. Forgetting, if
  added, is judgment (a contradiction deletes the superseded claim), not decay.

## §7 Post-removal forgetter coverage (cross-PR sequencing)

PR #21372 removes the only active decay/TTL forgetter path. After it lands,
memory-os has **no automated forgetting** until PR #21319 (RFC-0247 purge
redesign / LLM-judgment contradiction-delete + structural keep-newest cap)
lands. That is intentional per §6 (forgetting is judgment, not decay), but it
is a sequencing dependency:

- **Merge order**: do not merge this PR before #21319's structural cap is
  committed and green, unless an explicit interim cap or store-size guard is
  added. Otherwise keepers accumulate facts without bound.
- **TODO**: verify #21319 covers (a) contradiction-delete tombstones for
  superseded claims, and (b) a hard per-keeper / per-store size or generation
  cap that triggers before unbounded growth becomes an OOM risk.
- **Same-file conflict caution**: `lib/keeper/keeper_librarian_runtime.ml` is
  also edited by PR #21376 and PR #21408 (librarian provider slot per-keeper).
  Rebase/merge order must be coordinated to avoid losing either change.
