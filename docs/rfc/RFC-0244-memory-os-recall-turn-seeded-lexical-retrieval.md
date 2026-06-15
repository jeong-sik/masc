---
rfc: "0244"
title: "Memory OS recall: turn-seeded deterministic lexical retrieval, with provenance and layered consolidation roadmap"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent
supersedes: []
superseded_by: null
related: ["0239", "0241", "0243"]
implementation_prs: []
---

# RFC-0244 — Memory OS recall: turn-seeded deterministic lexical retrieval

## §0 Context — what RFC-0243 did and did not fix

RFC-0243 made the score *signal* live: confidence, `access_count`, and
`last_verified_at` now move at write time (`reobserve_fact` upsert). That fixed
the **ranking quality** — facts no longer all collapse to a constant.

It did **not** touch a more basic defect: recall has no **query**. Ranking the
right facts is moot if recall always ranks the *same* candidate set regardless
of what the keeper is doing this turn. The 2026-06-15 memory-systems comparison
(`reports/memory-systems-comparison-2026-06-15.html`) scored this subsystem 검색
6/10 and last overall (36/70); the rank-1 system (OpenClaw, 52/70) won 검색 9/10
on hybrid vector+BM25→MMR retrieval. This RFC closes the retrieval gap, on
masc's terms (offline / deterministic / reproducible — no embeddings).

## §1 Problem — recall is a query-less ranked dump, not retrieval

`Keeper_memory_os_recall.render_if_enabled` takes only `~keeper_id` and `~now`
and returns a `string option` (`lib/keeper/keeper_memory_os_recall.mli:20-23`).
Its single call site passes only the keeper's own name and the clock
(`lib/keeper/keeper_run_tools_hooks.ml:350-355`). The result is appended
verbatim as a fixed-markdown `Memory_os_recall` block into the system context
(`keeper_run_tools_hooks.ml:356-359`).

The ranking, `score_fact` (`lib/keeper/keeper_memory_os_policy.ml:60-66`),
multiplies confidence × recency × truth-recency × stale-penalty × access-factor
— **all functions of fact fields and `now`, none of the current turn**. The
top 8 facts (`keeper_memory_os_recall.ml:5`) are selected from a 256-row
candidate window (`keeper_memory_os_recall.ml:178-182`, `keeper_memory_os_io.ml:302`).

Two consequences:

1. **The seed already exists, one argument away.** The current-turn messages are
   in scope at `keeper_run_tools_hooks.ml:282` but are not passed into recall.
   Adding relevance is plumbing, not architecture.
2. **A turn-aware matcher already exists and is dead.** `bump_access_for_turn`
   (`keeper_memory_os_policy.ml:107-126`) takes `turn_text` and matches facts
   against it — and has **zero callers** (confirmed; it is dead code). The
   machinery to do turn-relevant recall was built and never wired.

So every turn the keeper is handed the same recency/score-ranked dump,
independent of the task in front of it. That is not retrieval.

## §2 Design

Phased. Phase 1 is the concrete near-term change and the subject of the first
implementation PR; Phases 2–3 are designed here but gated behind Phase 1 and a
separate review (they change the fact schema and the cross-keeper topology).

### §2.1 Phase 1 — turn-seeded deterministic lexical relevance (concrete)

**Seed.** Add an optional `~seed:string option` to `render_if_enabled` /
`render_context`. `None` preserves today's behavior exactly (recency/score dump
— correct for an autonomous wake with no turn). The call site passes the
current-turn text already in scope at `keeper_run_tools_hooks.ml:282`.

**Relevance factor.** Add a sixth, deterministic factor to `score_fact`:
`lexical_relevance(seed, fact)` — a pure function over token overlap between the
seed and `fact.claim` (BM25-lite: term-frequency-saturated, length-normalized,
no global IDF table required for a per-keeper window; or a simpler
Jaccard/overlap coefficient if BM25's tuning is not worth it at N≤256). It is a
**continuous ranking weight**, not a classifier branch:

```
score = (RFC-0243 signal) × lexical_relevance(seed, fact)     when seed = Some _
score =  RFC-0243 signal                                       when seed = None
```

`lexical_relevance` returns `1.0` for `None` (multiplicative identity), so the
seedless path is unchanged. Pure function of `(seed, fact)` → **offline,
reproducible, no network, no embedding** (the explicit design tenet; user
decision 2026-06-15: deterministic lexical over embedding vector).

**Resurrect the dead matcher.** `bump_access_for_turn` already takes `turn_text`;
wire it to the seed so a fact that is both recalled *and* lexically matched gains
`access_count` — feeding RFC-0243's now-live `access_factor`. Relevance and
re-observation reinforce through the same signal. (This is a read-path write;
guard it behind the same hysteresis as the librarian so recall does not thrash
the file — re-assess against the RFC-0243 §2.5 cost note before enabling.)

**Why lexical, not embedding** (the trade-off, not a one-sided pitch): lexical
loses on synonymy and paraphrase, where embeddings win (and where OpenClaw's
검색 9 comes from). It wins on: zero new dependency (no RunPod/pgvector), bitwise
reproducibility (a test can assert exact recall output), and no per-turn network
latency. masc's memory-os is deterministic-by-design; embeddings would change
that contract. Embedding recall is **rejected for this RFC** and recorded as a
possible future opt-in tier behind a flag (§4), not a default.

### §2.2 Phase 2 — provenance fields (prerequisite for any sharing)

Two fields on the fact type, both `*_of_json`-tolerant of absence (so the
migration is read-compatible with existing stores):

- `keeper_scope : Keeper_id.t option` — `None` = global candidate, `Some k` =
  keeper-local. This is design (A) already proposed in the 456-paradox analysis
  (`~/me/docs/library/multi-keeper-fact-namespace-problem--456-paradox-analysis-20260615.md`).
- `observed_by : provenance` — the **set of distinct source keepers** that have
  observed this claim (not just a count). RFC-0243's `reobserve_fact` raises
  confidence on every re-observation; it cannot today tell **independent
  corroboration** (two keepers agree → real consensus) from an **echo chamber**
  (one keeper repeats itself). With `observed_by`, `blend_confidence` rises only
  on a **new distinct source**; a same-source repeat bumps `access_count`
  (quantity) but holds `confidence` (quality). This closes the echo-chamber risk
  that a shared store would otherwise amplify (the 456 docs name this "confidence
  inversion at uniform ~0.988").

Phase 2 changes only how `reobserve_fact` reads/writes these fields; it does not
yet share anything across keepers.

### §2.3 Phase 3 — layered consolidation (the "communal brain", done safely)

The instinct "one giant shared Obsidian brain across all keepers" is **rejected
as a flat merge** (§4): the 456 paradox is precisely what a flat shared
fact-store produces — three keepers counting the same live metric got 4/5/5 and
the store kept 5 and 6 as two facts, because the namespace is flat with no origin
tracking. Per-keeper isolation is not a bug; it is the sandbox-containment
property that protects keeper-local accuracy, and a global dedup would destroy
that accuracy. Both the 456 analysis and the runtime survey conclude the same
thing: the cross-keeper shared surface that already exists and is *correct* for
this is the **Board** (`lib/board/`), which carries provenance natively (author
`Agent_id.t`, threads, votes, durable `default_ttl_hours = 0`;
`lib/board/board_types.ml:253`). Cross-keeper influence today is attention-only
(`wake_reason`: `Explicit_mention` / `Stigmergy` / `Thread_reply`,
`lib/keeper/keeper_world_observation_board_signal.ml:73-217`) — it never copies
one keeper's knowledge into another's store.

So the topology is **layered**, mirroring the user's own HippoRAG
episodic→semantic consolidation (`hippo-consolidator`):

- **Tier 1 — per-keeper private** (today's `keepers/<id>.facts.jsonl`,
  `keeper_memory_os_io.ml:44-80`): working/episodic memory, stays isolated.
- **Tier 2 — shared semantic**: a *consolidator* (not every keeper writing
  directly) promotes a Tier-1 fact only when it is corroborated by **≥ 2 distinct
  keepers** (`observed_by` from Phase 2) **and** confidence ≥ threshold **and**
  its category is on a promotion whitelist. Promotion carries provenance, never
  collapses sources.
- **Recall reads both tiers**, private taking precedence; shared facts are
  surfaced as labeled, provenance-stamped context, never silently merged.
- **Contradiction at Tier 2** is resolved by **keep-both-with-provenance**, and
  surfaced to the Board (the existing correction channel) — never a silent
  winner-pick.

This buys the "공용뇌" value (shared, corroborated knowledge) without reopening
456, because origin is tracked (`observed_by`/`keeper_scope`) and contradictions
coexist instead of colliding.

## §3 Workaround screening (CLAUDE.md)

- **String/substring classifier?** The Phase-1 lexical factor is the closest
  call. It is **not** a classifier: it produces a *continuous relevance weight*
  that feeds rank, not a *discrete branch* that decides behavior, and it
  compresses no closed sum-type into a string (it reads the existing free-text
  `claim`). No `category` coupling is introduced (that would re-open RFC-0239 R1).
  The distinction is load-bearing — if a later change makes a substring decide
  *routing* rather than *ranking*, that crosses into the anti-pattern.
- **Telemetry-as-fix?** No — it changes what is recalled, not a counter.
- **N-of-M / catch-all?** No — `seed = None` is a total, explicit branch, not a
  catch-all default; one coherent change to the single recall site.

## §4 Deferred / rejected

- **Embedding / vector recall** — *rejected* for this RFC (user decision
  2026-06-15): breaks the offline/deterministic/reproducible tenet and adds a
  RunPod/pgvector dependency. Lexical chosen. May return later as an opt-in tier
  behind a config flag, never the default.
- **Flat shared fact-store (merge all keepers)** — *rejected*: reopens the 456
  paradox (contradiction collision, provenance loss, confidence inversion).
  Replaced by §2.3 layered consolidation.
- **Markdown / Obsidian vault format migration** — *deferred*: converting
  per-keeper JSONL to a `.md` vault buys browsability and consolidation-
  friendliness, **not** retrieval quality (recall quality is set by query +
  ranking, both addressed here without a format change). Even the reference
  vault — the user's own `~/.claude/.../memory/` (793 files, 303 with
  `[[wikilinks]]`) — does **not** machine-traverse its links; an LLM navigates it
  index-then-fetch. Revisit a vault format only when a dashboard navigator that
  actually traverses links exists, else the links are dead-on-write (the same
  dead-field pathology RFC-0243 just removed).
- **Link-degree / backlink centrality ranking** — *deferred*: there are no
  inter-fact links in the store today, so there is no graph to weight. Becomes
  viable only after a linking model (and a writer for it) lands.
- **Read-path access-bump hysteresis tuning** — Phase 1 wires
  `bump_access_for_turn`; the exact thrash-guard threshold is an implementation
  detail to settle against RFC-0243 §2.5 during the PR.

## §5 Verification plan

Phase 1 (first PR):

- **Seedless invariance**: `render_if_enabled ~seed:None` produces byte-identical
  output to pre-change recall on a fixed store (golden test) — proves the
  backward-compatible path.
- **Relevance reranking**: with a seed sharing tokens with fact B but not fact A,
  and A out-ranking B under the RFC-0243 signal alone, the seed lifts B above A —
  proves the factor actually steers selection.
- **Determinism / reproducibility**: `lexical_relevance(seed, fact)` and the full
  `render_context ~seed` are pure — same inputs yield the same output across runs
  (property test) — proves the offline tenet is kept.
- **Dead-code resurrection**: `bump_access_for_turn` now has a live caller; a
  recalled-and-matched fact's `access_count` increments (ties into RFC-0243's
  live `access_factor`).
- `dune build` green; `test/test_keeper_memory_os.ml` extended; no regression in
  the RFC-0243 32 tests.

Phases 2–3 are gated: each lands behind its own PR and review, after Phase 1, and
must carry the 456-paradox provenance invariants (no source collapse, contradiction
coexistence) as explicit tests before any cross-keeper read is enabled.
