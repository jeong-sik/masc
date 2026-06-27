---
rfc: "0247"
title: "Memory OS as a brain: typed associative graph, spreading-activation recall, sleep consolidation, and forgetting"
status: Draft
created: 2026-06-16
updated: 2026-06-16
author: vincent
supersedes: []
superseded_by: null
related: ["0239", "0241", "0243", "0244"]
implementation_prs: ["#21299 CLOSED — recency-gate consolidation, withdrawn as wrong-layer scoring (see §-1)"]
revision: "2026-06-16 — decision-layer correction; see §-1 (READ FIRST)"
---

# RFC-0247 — Memory OS as a brain

## §-1 — Revision 2026-06-16: decision-layer correction (READ FIRST; supersedes the deterministic-decision framing below)

**Trigger.** A side-by-side with Claude Code's own memory system
(`~/me/.tmp/claude-code-memory-prompts.html`, the production reference) showed this
RFC put determinism on the wrong layer. PR **#21299** (recency-gate consolidation)
was **closed** as the concrete instance of the error. This section re-aims the RFC.
§0–§6 below are kept for the typed-*structure* design they contribute, but every
*decision* mechanism they specify (count-promotion, TTL-decay forgetting,
spreading-activation as the recall decision) is reclassified here.

**Verified evidence the scoring layer is unproven** (live store
`<base-path>/.masc/config/keepers/`, 2026-06-16):
- **Value never measured.** No eval/harness scores memory *quality* (recall
  precision, keeper outcome). `test_keeper_memory_os.ml` tests *mechanism*
  (noisy-OR is monotone) — "the code does what the code says," not "memory got
  better." Direct **Harness-First violation** (CLAUDE.md §1).
- **The only observable output is noise.** `_shared` — the sole product of the
  count + noisy-OR promotion — is **17/17 coordination boilerplate**.
- **A scoring input is dead.** `stale_factor` = `0.0` across **all 6462** live facts.

The burden of proof is on the scoring machine; it has none. Claude Code's judgment
approach is the production-proven reference — but is *also* unproven in masc's
autonomous 16-keeper context. Neither is proven *here*; therefore **eval comes first
(P-1) and gates everything.**

**The layer error.** Claude Code makes exactly ONE thing deterministic —
*structure*: the closed-union type taxonomy, file format, index-size limits, and a
staleness mtime trigger. Every *decision* is LLM judgment expressed as a prose
prompt: what to save, what NOT to save, whether a recalled memory is still true
(verify-then-recommend), which memories are relevant (a separate selector call),
how to consolidate (the consolidation pass), what to forget (delete on
contradiction). There is no confidence float, no noisy-OR, no decay score, no count
threshold anywhere. This RFC inverted that: it made the *decisions* deterministic
and treated LLM judgment as a soft defect to engineer away (§2.6 deliberately
extracted only claude-code's "deterministic subset" and rejected its judgment core).
That extraction is the mistake. A deterministic proxy for a semantic judgment is
what produces the boilerplate-promotion pathology: `noisy_or(confidences)` cannot
tell "common" from "valuable"; a one-line LLM judgment can.

**Corrected principle (the boundary):**

> **Determinism = structure + cheap candidate generation. Judgment = the actual decision.**

Scoring/graph/count are not deleted — they are **demoted** from *decider* to
*candidate generator* feeding an LLM judgment that makes the call. This keeps
reproducibility (candidate-gen is deterministic and testable) while putting semantic
decisions where they belong. It is consistent with the anti-workaround bar: the
opposite of LLM judgment is not determinism, it is *heuristics* (string classifiers,
count thresholds, decay curves) — all of which the bar already rejects. Typed
structure wrapping LLM judgment is the non-heuristic answer.

**Re-classification of the organs** (decision-layer moves to judgment; structure stays typed):

| organ | §below | KEEP (structure / candidate-gen) | MOVE to judgment (the decision) | REJECTED as a decision mechanism |
|---|---|---|---|---|
| Encoding | §2.5 | closed-sum `category`, parse-once, `Unknown` arm — **KEPT** (P0a merged) | **producer "what NOT to save" judgment gate is now PRIMARY**: the librarian drops ephemeral/coordination *before* it becomes a fact (claude-code WHAT_NOT_TO_SAVE + "ask what was surprising / non-obvious"). The typed category is the *structure* the judgment fills, not a substitute for it | — |
| Consolidation | §2.2 | the single off-hot-path sweep; ≥2-keeper co-occurrence as a **candidate** signal | **Consolidation pass (LLM)**: read candidates, merge into topic facts, **delete contradicted**, write durable-only — judgment decides what is canon | **count / noisy-OR promotion *as the decision*** |
| Forgetting | §2.3 | `lifecycle` closed sum as a *recorded state* | **forget = delete-on-contradiction by judgment** + **read-time staleness reminder** surfaced to the recalling agent (claude-code `memoryAge`) | **TTL / `Low_confidence_decayed` auto-decay eviction** |
| Recall | §2.1 | lexical seed (RFC-0244) + 1-hop graph as **candidate generators** | **judgment selection** — an LLM picks the relevant few from the candidate set (claude-code's selector) and *verifies before recommending* | **spreading-activation graph-walk *as the recall decision*** (demoted to candidate-gen; `α` is a candidate knob, not the ranker of record) |
| Reconsolidation | §2.4 | entity-ref existence check — **KEPT** (a real deterministic structural fact, feeds judgment) | the *consequence* (demote / keep) is a judgment | **automatic confidence-cap-as-truth** |

**P-1 (new binding phase) — eval-first, before any removal or replacement.** Build a
harness that measures memory *value*, baseline the current scoring machine (finally
answering "효과적인가" with numbers), then gate every later phase on it. Metrics —
LLM-as-judge over a **frozen, reproducible snapshot** + a hand-labeled calibration
fixture, **never substring-matching**:
- **`_shared` noise rate** — fraction of shared facts an LLM judges ephemeral vs
  durable. Baseline ≈ 100%.
- **store boilerplate rate** — fraction of all facts that are ephemeral-class.
- **injected-recall usefulness** — of facts recalled into a turn, the fraction
  plausibly useful for that turn (best-effort offline; disclose if traces are
  insufficient rather than faking a number).

Anti-fake-success discipline (user directive 2026-06-16 "가짜 성공 테스트 금지"):
- **Non-vacuity** — prove durable knowledge *exists* in the store (the count=1
  keeper-local constraints, e.g. "rondo sandbox blocked", "Write tool destructive
  guard blocks `${}`") so "0% durable in `_shared`" is a real finding, not "there is
  no durable knowledge to find."
- **Teeth** — the eval must be *able to fail*; the current system must score badly
  (it does). An eval that can't separate good from bad memory is vacuous.
- **Calibration / anti-rig** — the judge must label both ways; feed it known-ephemeral
  and known-durable fixtures and confirm correct classification before trusting it on
  live data.

**What still stands from §0–§6.** The typed substrate (category / edge / lifecycle as
*data*), the anti-embedding stance, the v2 four-node graph as a *candidate /
visualization* substrate, and the entity-ref reconsolidation check are all retained.
Withdrawn is their use as *decision-makers*. P0a (typed category) stays merged; P2a
(edges) stays as candidate-gen, **not** the recall ranker. Phasing (§5) is reordered:
**P-1 eval → P0 producer judgment gate → consolidation pass → recall judgment
selection → delete dead scoring (`stale_factor`, TTL-GC).**

## §0 Context — the organs already built, and the ones missing

Three RFCs moved the Memory OS from a static dump toward a living store:

- **RFC-0243 (MERGED `22bdf658c`)** made confidence *mutable*: the librarian write
  path upserts via `reobserve_fact` keyed by `normalize_claim`, so confidence /
  `access_count` / `last_verified_at` move on re-observation (synaptic
  strengthening). Accuracy-inversion's *first* half is closed.
- **RFC-0244 P1 (MERGED #21224)** gave recall a *cue*: `score_fact` takes a
  turn-derived `seed_tokens` and a deterministic `lexical_relevance` factor, so
  recall ranks against the current turn instead of returning a fixed dump
  (hippocampal cue retrieval).
- **RFC-0244 shared tier (#21237 MERGED `72fc3d190`, then gated OFF by #21244)**
  adds a `_shared` semantic store whose consolidator promotes claims held by **≥2
  distinct keepers** (noisy-OR confidence) on an off-hot-path fiber
  (`lib/server/server_bootstrap_maintenance.ml`). #21244 (`6e60ec7f2`) set the
  fiber's kill switch default `true → false` after a live dry-run (15 keepers,
  6017 facts) showed the only corroborated claims are ephemeral coordination
  boilerplate the librarian mislabels as `fact` — so the sleep cycle is **built but
  switched off**, waiting on the §2.5 producer fix.

And encoding is **already wired** (verified at HEAD `876365f7a`, not assumed):
`keeper_agent_run_finalize_response.ml:192` → `Keeper_agent_run_post_turn_memory.run`
→ `Keeper_librarian` (LLM extraction over scrubbed conversation `messages`,
`keeper_librarian.ml:8,62-68`) → `Keeper_memory_os_io.merge_and_cap_facts`
(`keeper_librarian_runtime.ml:203`). The 2026-06-12 pipeline-diagnosis claim "no
conversation→memory write path / 0 consumers" is **superseded**.

What a brain still lacks here:

| brain organ | masc today | status |
|---|---|---|
| associative cortex (links between memories) | facts are an **unlinked** flat list | **MISSING** |
| spreading activation (recall a cue → neighbors light up) | recall ranks an independent list; no neighbor traversal | **MISSING** |
| synaptic pruning / forgetting | `run_gc` (`keeper_memory_os_gc.ml:76`) has **0 lib callers**; `valid_until`/`stale_factor`/`expected_lifetime_cycles` are inert ×1 theatre (set once, no producer) | **MISSING** |
| reconsolidation (is this memory still true?) | no re-verification of a fact against current code/state | **MISSING** |
| sleep / consolidation | consolidator promotes, but does not link or forget — **and is switched off** (#21244) until encoding is typed (§2.5) | **BUILT, GATED OFF** |

This RFC adds the four missing organs, on masc's terms: **deterministic, offline,
no embeddings**; links are a **closed sum**, not a string; activation is a
**bounded graph walk**, not vector similarity.

## §1 Problem — a flat scored list is not a memory

The unit of memory is `fact` (`keeper_memory_os_types.mli:18-31`):

```
type fact = { claim; confidence; category : string; source : provenance_event;
              access_count; first_seen; last_accessed;
              valid_until : float option;        (* always None — dead *)
              stale_factor : float;              (* always 0.0  — dead *)
              last_verified_at : float option;
              expected_lifetime_cycles : int option;  (* always None — dead *)
              schema_version }
```

There is **no edge type**. A fact knows its single origin (`source`) but nothing
about *other facts*. So:

1. **Recall cannot follow a thread.** RFC-0244 ranks the candidate window by
   lexical overlap + score, then stops. The keeper that recalls "compact() holds
   the round lock" does not also surface "the commit that introduced compact()"
   or "the goal this blocks" — even though those are the facts it needs next.
   The v2 design already drew this exact graph (`keeper-v2/memory-graph.jsx`:
   node kinds `memory|goal|task|board`, typed edges `진단/파생/검증/기원/해소/게시`,
   a 1-hop Memory Lens and a causal Lineage Rail). The data model to back it does
   not exist.
2. **Nothing is ever forgotten.** With `valid_until = None` always, `run_gc`'s
   TTL pass (`keeper_memory_os_gc.ml:25-29`) can never fire; and `run_gc` is
   never called regardless. The store grows append-only; stale claims keep
   whatever confidence they were last upserted to. The 2026-06-15 comparison
   scored masc lowest on 잊음 (forgetting) — correctly.
3. **Nothing is ever re-verified.** claude-code's memdir recommends a memory only
   after checking the referenced file/function/flag still exists
   (truth-recency). masc has the *field* (`last_verified_at`) but no verifier:
   confidence rises on re-observation but never falls because the world moved.

These are three faces of one absence: the store records facts but models neither
their **relationships**, their **mortality**, nor their **continued truth**.

## §2 Design — the four organs

All four share one home: the off-hot-path consolidation fiber from #21237 (the
"sleep" cycle). Links, decay, and re-verification are exactly the work a brain
does while not serving a turn.

### §2.1 [P0] Association — typed edges (the cortex)

Add an edge as a first-class, typed value. Edges are **directed** and carry a
**closed-sum relation**, mirroring the v2 vocabulary so the graph the dashboard
already designed has a backend:

```
type relation =
  | Diagnoses      (* memory → goal:   "this insight diagnoses that goal"   진단 *)
  | Derives        (* memory → task:   "this spawned that task"             파생 *)
  | Verifies       (* memory → task:   "this validated that task"           검증 *)
  | Origin         (* memory → memory: "regression starts here"             기원 *)
  | Supersedes     (* memory → memory: "this replaces that"                       *)
  | Contradicts    (* memory → memory: "these disagree"                          *)
  | Relates        (* generic co-occurrence, weakest                              *)

type endpoint =
  | Fact of claim_key                 (* normalize_claim fingerprint *)
  | Goal of string | Task of string | Board_post of string

type edge = { src : claim_key; dst : endpoint; relation; weight : float;
              created_at : float; observed_by : keeper_id list }
```

- **No `_ ->` catch-all** anywhere edges are matched: a new relation forces a
  compile error at every consumer (the FSM-sparse-match rule, CLAUDE.md §AI4).
- **`endpoint` reaches existing entities** (goal/task/board are already first-class
  in masc), so the memory graph is the v2 four-node graph, not a fact-only island.
- Edges live in a sibling store `*.edges.jsonl` keyed by `src`, reusing the IO
  pattern of `keeper_memory_os_io` (no new codec architecture).

**Edge producers (deterministic, no LLM-as-classifier):**
- *Lineage* from `provenance_event`: facts sharing a `trace_id`/`turn` window get
  `Relates`; a fact whose claim references a commit/PR that another fact also
  references gets `Origin`. (Producer = structured provenance, not prose parsing.)
- *Cross-entity* from the librarian episode: `episode.open_items` / `constraints`
  already name goals/tasks; emit `Derives`/`Diagnoses` from the episode's claims to
  those entities at write time. This is a typed projection of data the librarian
  already extracts (`keeper_librarian.mli` episode fields), **not** a new
  free-text classifier.
- *Contradiction* from the consolidator (§2.2): two facts with the same
  `normalize_claim` head but incompatible tails, or an explicit negation marker
  the librarian emits, become a `Contradicts` edge — never a silent overwrite.

**Spreading-activation recall.** Extend RFC-0244 recall with one bounded,
deterministic step: after lexical ranking selects the top-k seed facts, add their
1-hop neighbors with an activation bonus `α · relation_weight · src_score`
(`α` a named constant, default `0.5`; relation weights a fixed table, e.g.
`Origin=1.0, Verifies=0.8, Derives=0.7, Diagnoses=0.7, Supersedes=0.6,
Contradicts=0.5, Relates=0.3`). Re-rank the union; cap total at the existing
recall budget. `α=0` reproduces RFC-0244 exactly (additive, safe default-off per
flag). This is a single deterministic graph hop — reproducible, no embeddings.

### §2.2 [P0-dep] Consolidation — the sleep cycle (re-enable + extend #21237)

**State at HEAD `876365f7a`:** #21237 is **MERGED** (`72fc3d190`) — the off-hot-path
fiber (`lib/server/server_bootstrap_maintenance.ml`) and the `_shared` tier exist.
But #21244 (`6e60ec7f2`, 2026-06-16) **flipped the fiber's kill switch default
`true → false`**: a read-only dry-run over the live fleet (15 keepers, 6017 facts)
found the *only* ≥2-keeper-corroborated claims are ephemeral lifecycle/coordination
boilerplate ("checkpoint saved", "remains scheduled", "no tasks") that the librarian
**mislabels as `category=fact`**, so promotion just injects recall noise. The
consolidator/recall code is correct; the *producer* is wrong. **Re-enabling the
sleep cycle is therefore gated on §2.5** (the librarian must emit ephemeral events
as a structurally non-promotable category). This makes §2.5 the binding P0, not a
trailing hardening.

Once re-enabled, extend the consolidator's single sweep to do the brain's three
nightly jobs:

1. **Promote** (already in #21237): claims held by ≥2 distinct keepers → `_shared`,
   noisy-OR confidence — now over a closed-sum, promotable-only category set plus
   the stricter `is_outcome_positive_for_shared_promotion` gate. That gate is a
   temporary category proxy until #22447 outcome-eval metadata replaces it.
2. **Link**: run the deterministic edge producers (§2.1) over the batch, so links
   are built off the hot path.
3. **Forget**: run the lifecycle/GC pass (§2.3).

Contradictions found during promotion are **kept with both provenances** and
surfaced to the **Board** (`lib/board/`), which the RFC-0244 design already names
as the cross-keeper correction channel — not auto-resolved in the store.

### §2.3 [P1] Forgetting — typed lifecycle + wire `run_gc`

Give a fact a **closed-sum lifecycle** instead of three inert float/option fields:

```
type lifecycle = Live | Stale of stale_reason | Superseded of claim_key
type stale_reason = Ttl_expired | Entity_gone | Low_confidence_decayed
```

- **Producer at write** sets `valid_until` from a per-category default lifetime
  (category becomes a closed sum — §2.5 — so the table is exhaustive, no magic
  numbers), making the existing TTL pass (`gc.ml:25-29`) actually reachable.
- **Verifier transition** (the sweep) moves `Live → Stale` when TTL expires,
  confidence decays below a floor, or the truth-recency check (§2.4) fails.
- **Wire `run_gc`** into the consolidation sweep — its first real caller. GC
  *demotes/prunes by lifecycle*, it does **not** dedup-on-read (that would be the
  cap/cooldown/dedup/repair workaround the bar rejects; dedup already happens
  write-side via `merge_and_cap_facts`). Fold `gc.ml:31` `normalized_claim_key`
  onto the `normalize_claim` SSOT (currently divergent/dead).

### §2.4 [P1] Reconsolidation — truth-recency verifier

A fact whose claim references a code entity (file path, function, flag, PR/commit
SHA) is re-checked against the current tree during the sweep; if the entity is
gone, the fact transitions `Stale Entity_gone` and its confidence is capped, so
recall demotes it. This is the producer-side, structured form of claude-code's
"check it still exists before recommending" — the reference is a typed entity-ref
extracted from structured provenance, **not** found by substring-scanning the
claim prose. A fact with no checkable entity-ref is never spuriously staled
(absence ≠ gone).

### §2.5 [P0] Encoding — typed category that separates durable knowledge from ephemeral events

Ingestion is wired (§0), but its category is a free string the LLM fills in, and
that single gap is what currently has the sleep cycle switched **off** in
production (§2.2 / #21244). The fix is the canonical "free-text → closed sum, parse
once at the producer, mandatory `Unknown` arm":

```
type category =
  | Fact            (* durable, promotable knowledge claim          *)
  | Constraint      (* durable rule / invariant                     *)
  | Decision        (* durable choice with rationale                *)
  | Open_question   (* durable unknown to resolve                   *)
  | Ephemeral       (* lifecycle/coordination boilerplate — NOT promotable,
                       short TTL: "checkpoint saved", "no tasks", "remains
                       scheduled". The #21244 dry-run's entire ≥2-keeper set. *)
  | Unknown of string   (* visible escape; never a silent default   *)

val category_of_string : string -> category   (* parse-once at librarian boundary;
                                                  legacy "fact"/"constraint" map through,
                                                  everything else → Ephemeral|Unknown *)
val is_promotable : category -> bool           (* exhaustive match; Ephemeral/Unknown = false *)
```

- **`Ephemeral` is the load-bearing new arm.** #21244's live dry-run proved the
  only cross-keeper-corroborated claims today are coordination boilerplate. Giving
  them a *structurally non-promotable* category is what lets the consolidation
  fiber be turned back on without injecting recall noise — the producer-side fix
  the #21244 commit message explicitly asks for ("emit ephemeral events as a
  non-promotable category").
- The consolidator whitelist (`["fact";"constraint"]` strings,
  `keeper_memory_os_consolidator.ml:28,60`) becomes an **exhaustive `match` on
  `is_promotable`** — a new/typo'd category can no longer silently fall outside the
  set, and a future durable kind must be classified at compile time.
- The persisted `category : string` field migrates via codec (`to_string`/
  `of_string`); the 6017 existing facts keep working (legacy strings → their arm or
  `Unknown`), matching claude-code's `parseMemoryType` graceful-degrade.
- The librarian extraction prompt gains the `ephemeral` option with the boilerplate
  examples, so the *producer* labels them correctly at write time. This is the
  encoding-quality fix that also feeds the per-category lifetime table (§2.3) and
  the truth-recency reconsolidation (§2.4).

### §2.6 Convergent reference signals (claude-code / OpenClaw / Hermes — deterministic subset only)

The four references independently converge on mechanisms that survive the
offline/no-embedding tenet and slot onto the organs above (full extract:
`reports/masc-keeper-brain-memory-and-harness-plan-2026-06-15.md` §refs):

- **Earned promotion, not declared confidence** (OpenClaw `minRecallCount=3 /
  minUniqueQueries=2`; Hermes trust-on-reobserve). A fact becomes `_shared` canon
  only after demonstrated re-retrieval/outcome usefulness. Current code gates
  #21237 promotion with `is_promotable` plus the stricter
  `is_outcome_positive_for_shared_promotion` category proxy until #22447 supplies
  explicit outcome-eval metadata. Directly kills the uniform-0.988
  confidence-inversion failure mode.
- **Read-time age + staleness reminder, not write-time confidence mutation**
  (claude-code `memoryAge` + freshness `<system-reminder>`; OpenClaw read-time
  `exp(-ln2/halfLife·age)` multiplier with evergreen exemption). An alternative/
  complement to §2.4: surface a fact's age and force re-verification at recall
  rather than silently decaying a number. Wires the dead `valid_until`/`stale_factor`
  fields as a read-time score multiplier, not a stored mutation.
- **MMR-over-Jaccard diversity re-rank** (OpenClaw, deterministic — Jaccard on the
  existing `tokenize` SSOT, *not* cosine). Add on top of RFC-0244 lexical recall,
  default-off, to stop returning N near-duplicate facts (the 456-redundancy churn)
  without any embedding.
- **Single-writer consolidation pipeline** (OpenClaw Light-stage / Deep-promote /
  REM-reflect; claude-code nightly consolidation distill; rehydrate-from-source before
  promote). Confirms the §2.2 shape: exactly one writer to durable memory, staging
  and reflection non-mutating, text re-grounded at promote time — the antidote to
  the 1800→89-line confabulation drift.
- **Compaction circuit breaker** (claude-code `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES
  =3`, cited against 250K-wasted-calls/day thrash). Out of scope for memory-os but
  the single highest-value transferable anti-thrash control for the keeper
  compaction path — tracked separately (Track C).

These are enrichments, not new organs; each is additive and default-off, gated the
same way as the core phases.

## §3 Non-goals / deliberately rejected (so they are not re-proposed)

- **Embeddings / vector retrieval — REJECTED** (breaks the offline / deterministic
  / reproducible tenet; RunPod/pgvector dependency). Spreading activation replaces
  it with a deterministic graph hop. Standing owner decision, not a deferral.
- **Flat shared "공용뇌" — REJECTED** (it *is* the 456 namespace paradox). The
  shared tier is layered (per-keeper episodic, promotion-gated semantic), not a
  flat merge.
- **Read-side dedup / repair / sanitize — REJECTED** as a fix shape. All
  reconciliation is write-side (`merge_and_cap_facts`) or sweep-side (consolidator);
  recall never repairs.
- **LLM-as-edge-classifier — REJECTED.** Edges come from structured provenance and
  the librarian's already-typed episode fields, not a prose classifier. (A
  free-text "what relates to what" LLM call would be the string-classifier
  anti-pattern in disguise.)
- **Markdown vault migration — DEFERRED** (browsability ≠ retrieval; revisit only
  with a link-traversing navigator). The graph here is the retrieval substrate the
  vault would only visualize.

## §4 Anti-workaround self-check (CLAUDE.md bar)

- Telemetry-as-fix? No — changes data model + recall behavior, not a counter.
- String/substring classifier added? No — `relation`, `lifecycle`, `category`
  become **closed sums**; the only string is `Unknown of string`, the *visible*
  escape, and it shrinks (category) rather than grows.
- N-of-M? No — edges/lifecycle apply uniformly via one producer + one sweep, not
  K-of-M site patches.
- cap/cooldown/dedup/repair? Forgetting is lifecycle-typed write/sweep-side, not a
  read-side cap. Activation is a bounded, named-constant graph hop, not a cooldown.

## §5 Phasing & verification (harness-first)

| phase | scope | gate |
|---|---|---|
| **P0a** | `category` closed sum (`Ephemeral` + `Unknown` arms) + parse-once at librarian + `is_promotable` exhaustive match + codec migration + librarian prompt option (§2.5) | unit: legacy `"fact"/"constraint"` round-trip; ephemeral→non-promotable; unknown is `Unknown` not defaulted; live dry-run shows ephemeral set no longer promotes |
| **P0b** | re-enable the consolidation fiber (#21244 kill switch `false → true`) now that ephemeral is non-promotable; live re-run of the 6017-fact dry-run as the gate | live smoke: `_shared` populates with **durable** claims only; no "checkpoint saved"-class promotions |
| **P1a** | `lifecycle` closed sum + write-side `valid_until` producer (per-category default lifetime, now exhaustive) + wire `run_gc` into sweep | unit: TTL pass now reachable; GC demotes by lifecycle, never dedups-on-read; `normalize_claim` SSOT folded |
| **P1b** | truth-recency verifier (entity-ref → Stale Entity_gone) | unit: entity-present ⇒ Live; entity-gone ⇒ Stale+capped; no entity-ref ⇒ never staled |
| **P2a-1** | `relation` closed sum + `edge`/`association` types + `*.edges.jsonl` IO + the **co-occurrence `Relates` producer** wired at the librarian write path (§2.7) — write substrate only, no recall change | unit: codec round-trip incl. `Unknown` degrade; `n` distinct claims ⇒ `n*(n-1)/2` canonical edges; within-episode dedup; aggregate Hebbian weight; append→read IO round-trip — **DONE** |
| **P2a-2** | spreading-activation recall (`α` flag `MASC_KEEPER_MEMORY_OS_ACTIVATION_ALPHA`, default 0 = byte-identical to RFC-0244) consuming `read_associations`; one-step neighbour boost applied to the Tier-1 path only | unit: pure boost math (linked lifted, unlinked none, `α≤0` empty); `α=0` ⇒ rendered output byte-identical even with an edge store present (non-empty precondition); `α>0` lifts a linked low-base fact into top-2 above an unlinked higher-base fact — **DONE** |
| **P2a-3** | adversarial-review hardening: (1) gate the WRITER behind the same `α` (`Edges.writes_enabled`), so a fleet with activation off accumulates **no** edges — the organ is one feature behind one knob, not an always-on writer with a dark reader; (2) restore the RFC relation discount — boost = `α` × Σ(`relation_weight`·count·base)/Σ(count), `relation_weight Relates=0.3`, `Unknown=0.0` (exhaustive), so co-occurrence enters discounted and an unrecognized relation never drives recall; (3) realistic-`α` gate test (3.0, not 50.0); (4) `.mli` order-preservation claim corrected | unit: `writes_enabled` tracks `α` sign; `Unknown` relation yields no boost; lift holds at `α=3.0` — **DONE** |
| **P2b** | contradiction→Board surfacing; earned-promotion gate (§2.6); optional MMR-Jaccard re-rank (default-off) | unit: contradiction emits a Board post, not a store overwrite; promotion requires ≥N recalls by ≥M queries |

**Producer-first taxonomy (P2a invariant).** The `relation` sum grows one arm at a
time, each arm landing WITH a deterministic producer. P2a-1 ships only `Relates`
(co-occurrence within one episode — the only fully-deterministic inter-fact signal
available, since episode claims are co-extracted by construction). Causal labels
from the v2 design (diagnoses / derives / verifies) are **deliberately absent**:
they would require an LLM classifier, which this RFC rejects. `Supersedes`
(same-claim upsert in `merge_and_cap_facts`) and `Corroborates` (cross-keeper
promotion in the consolidator) have real producers and are the next arms — added
when wired, not speculatively. GROWTH BOUND (after P2a-3): edges are written only
when `α>0` (`Edges.writes_enabled`), so a fleet with activation off accumulates
nothing; within an opted-in fleet the per-keeper edge store is still append-only
and the §6 out-degree cap / weight-floor / GC is deferred to a measured-trigger
slice (disclosed in `keeper_memory_os_io.edges_path`, not silently capped).

P0a is the binding constraint (it unblocks the production sleep cycle, #21244);
P2a is the user's headline "brain" organ (the v2 memory-graph). Each phase is
additive and independently mergeable; `α=0` and lifecycle-default `Live` keep every
step backward-observable. No phase ships a counter as its
deliverable. A TLA+ model (sibling of `KeeperOASAdvanced.tla`) asserts the sweep
invariant **`ContradictionNeverSilentlyOverwrites`** (a `Contradicts` edge or a
Board post always exists when two incompatible same-key facts are observed).

## §6 Risks / open questions

- **Edge explosion.** `Relates` from trace co-occurrence could fan out. Mitigation:
  cap out-degree per fact (named constant) and only persist edges above a weight
  floor; `Relates` is the lowest weight and the first pruned by GC.
- **Truth-recency cost.** Re-checking entity existence per sweep is O(facts with
  entity-refs); bound it to the consolidation batch and cache tree lookups per
  sweep. Off the hot path, so latency-tolerant.
- **`endpoint` to goal/task/board** couples memory-os to those id types — confirm
  the dependency direction (memory-os should depend on opaque id *values* minted by
  those modules and validated at the edge producer, not import the coordination
  modules — else a boundary violation).
- **#21237 has landed and is gated off.** The sleep fiber and `_shared` tier exist
  (`72fc3d190`) but #21244 set the kill switch default `false`. P2a/P1 build on the
  existing fiber; P0a/P0b's job is to make re-enabling it safe (ephemeral
  non-promotable), not to build new infrastructure.
- **`Ephemeral` vs `Unknown` boundary.** Both are non-promotable, but they differ:
  `Ephemeral` is a *recognized* short-lived coordination event (typed, short TTL),
  `Unknown` is an *unrecognized* producer label (visible escape, surfaces a
  taxonomy gap). Collapsing them would hide drift — keep them distinct so a rising
  `Unknown` rate signals the librarian prompt needs a new arm.
