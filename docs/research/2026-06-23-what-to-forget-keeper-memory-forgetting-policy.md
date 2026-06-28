# What to Forget: Keeper Memory Forgetting Policy (Research Synthesis)

**Date**: 2026-06-23
**Status**: Research Synthesis (Stage 1 of Research → RFC → Implementation)
**Origin**: 5-lens parallel survey (workflow `wf_5c58a490-1ea`); synthesis hand-authored after the workflow's synthesize agent hit a session limit.
**Question (Vincent)**: "이건 그냥 TTL로 하는 게 이상하다. Judge 안 돌려도 되나? 비용은 안 중요. 이건 연구가 더 필요하다 — *무엇을 잊을 것인가?*"
**Context**: RFC-0285 (merged) closes the self-observation echo loop with a write-time typed `claim_kind` + finite TTL + stable `claim_id`. This research steps back from that implementation to the prior question: in a keeper agent memory, what should be forgotten, by what principle, and how — beyond a blind timer.

---

## 0. The question is real, and it is first-class

The echo loop (a keeper re-reading "I am idle / looping / tool-timed-out" 117× over 200 turns, re-confirming and re-emitting it) is a *symptom*. RFC-0285 treats it with a TTL. Vincent's objection — a blind timer feels arbitrary — is not a tuning quibble; it points at the design question RFC-0285 skipped: **forgetting is a policy, and "what to forget" must be answered before "when".**

Five independent lenses (cognitive science, AI agent memory systems 2023–2026, masc's current code, the epistemology of self-observation, failure-mode analysis) converge on the same answer. The convergence is strong enough to treat as a finding, not an opinion.

---

## 1. The converged principle: forget by need-probability and supersession, not by clock

**Forget a fact in inverse proportion to the probability it will be needed again — estimated from its KIND and from observed re-use, not from a fixed timer.**

- **Cognitive science (load-bearing):** Anderson & Schooler (1991, *Reflections of the Environment in Memory*) showed the brain does not forget on a timer; it forgets in proportion to estimated **need-probability** — the odds an item will be needed again, read off the environment's own statistics. Measured across three corpora (NYT headlines, parental speech, email senders): the probability of re-encountering an item declines with time-since-last-use as a **power function**, and human retention mirrors that same curve. A blind TTL is the **degenerate flat-prior special case** that throws away the two strongest predictors: the fact's kind and its observed re-use.
- **AI memory systems (convergent):** The field's answer is not a timer and not importance-weighting — it is **supersession of volatile state keyed by (entity, attribute)**. A memory is forgotten when a fresher observation concerns the same mutable slot (Mem0 UPDATE/DELETE, BeliefMem Merge, A-MEM evolution), with read-time deterministic freshness decay (BeliefMem `λ^τ`, SSGM Weibull, Generative Agents `0.995^t`, ACT-R activation) — never per-recall LLM re-judgment.

A self-observation ("I am idle") is a timestamped report about one moment; its need-probability collapses the instant the next turn changes the state. A durable fact ("this repo uses Eio") has high, roughly stationary need-probability. The right thing to forget is the class whose need-probability decays fastest — **first-person transient state** — and the right *when* is governed by two signals:

1. **Supersession** — a newer observation of the same first-person slot arrives → the old one's need-probability is now zero → **evict immediately** (interference theory + retrieval-induced forgetting). **This is the load-bearing mechanism; the timer is secondary.** It is also exactly what RFC-0285's stable `claim_id` already does (collapse competing duplicates into one slot, newest wins) — justified here not as dedup but as the forgetting trigger.
2. **Disuse decay** — not superseded, not re-observed for *k* cycles → recall-weight decays along a power/exponential curve (Ebbinghaus shape × Anderson-Schooler need-odds), as a **backstop**, not the primary gate.

---

## 2. The design space (six mechanisms, with trade-offs)

| Mechanism | What it forgets | Strength | Weakness / risk |
|---|---|---|---|
| **Blind TTL / decay** (RFC-0285 L3 as written) | by age | simple, deterministic, fail-safe (Unknown→durable) | collapses kind/entrenchment/freshness into age; arbitrary constant; forgets by clock when it should forget by supersession |
| **Importance/relevance scoring** (Generative Agents) | low-score memories | matches retrieval to context | reintroduces a learned score — the exact composite-score class RFC-0247 *purged*; needs a scorer (drift, unproven) |
| **Interference / supersession** (Mem0, BeliefMem; cognitive interference theory) | the prior occupant of a slot when a fresh observation arrives | **kills the 117× echo at its root** (one current reading per slot); event-driven, deterministic | depends on a **closed typed slot key** (free-string key = string-classifier workaround regression) |
| **Event-based invalidation** (the new finding, §3) | a standing claim falsified by the keeper's own later action | a **real deterministic oracle** that RFC-0285 §7 wrongly declared absent; no self-fulfilling regress (evidence is the act, not a re-read) | needs a structured action⇒claim-kind invalidation map (must NOT be a free-text matcher) |
| **Judge / reflection** (per-recall LLM re-eval) | claims the LLM judges stale | none that survives scrutiny **here** | **contraindicated** (§below): no oracle, self-fulfilling regress, category error, retrieval-strengthening |
| **Consolidate-then-forget** (MemGPT recursive summary) | detail, compressed into summary | good for the *durable episodic ledger* | summarization drift / hallucination — do NOT use as the primary forgetter for self-state |

### Why Judge is unfit — unanimous across lenses, independent of cost

Vincent removed cost from the table; the verdict holds anyway, on four grounds:

1. **No objective oracle.** `external_state` ("PR #N merged?") has GitHub. A self-observation ("am I idle?") has only the keeper's own report — a Judge reads the same self-report and is not an independent verifier.
2. **Self-fulfilling regress, mechanistically.** Retrieval is an *active* operation (Anderson/Bjork think-no-think; retrieval-induced forgetting): a Judge that **retrieves-to-evaluate strengthens what it reads**, so the regress is a *predicted outcome*, not a risk. Self-observation needs **suppression (don't retrieve)**, not **evaluation (retrieve and judge)**.
3. **Category error.** A Judge answers "is this *correct*?" (storage-strength). A self-observation's question is "is this *still fresh*?" (retrieval-strength) — answerable by recency-of-re-observation, per Bjork's storage-vs-retrieval split. Vincent named exactly this.
4. **Determinism.** memory-os deliberately purged its composite score (RFC-0247); a per-recall Judge re-introduces a non-deterministic scoring layer — the same class of move.

---

## 3. Self-observation is a distinct sub-problem (and §7's "no oracle" was too strong)

A self-observation is **token-reflexive, stage-level, and causally active when re-read**:
- *token-reflexive*: "I am idle" is true only relative to the turn that minted it ("yesterday-idle ≠ today-idle" — the exact analogue of RFC-0259's "PR-was-open ≠ PR-is-open").
- *stage-level*: it describes an on/off momentary stage, not a standing trait.
- *causally active*: re-injecting "I am idle" into the prompt is **not inert** — it is a control signal that helps make the observed state true (the observer effect that is the echo loop).

**The key correction to RFC-0285 §7 (High open question).** RFC-0285 says: "there is *no deterministic oracle* for 'is this self-observation still true'… do not pretend a reconciler exists." Two lenses (self-obs epistemics, AI memory) show this is **too strong**: the keeper's **own subsequent action stream is a deterministic oracle**. A keeper that claimed "no unclaimed tasks / I am idle" and then *claims a task or emits a tool call* has **falsified** the standing claim. This is:
- **a real oracle** — the evidence is the *act*, sourced from the keeper's action stream, mirroring RFC-0259's GitHub reconciler but internal;
- **not a Judge** — there is no re-reading of the claim, so no self-fulfilling regress;
- the **symmetric reconciler** RFC-0259 built for external state, which RFC-0285 declared impossible for internal state.

The caveat: it must be **structured action-event ⇒ structured claim-kind invalidation** (e.g. *any task-claim event invalidates an outstanding "no tasks available" self-observation*), **never a free-text phrase matcher** — otherwise it is a read-time string classifier and is rejected by the same logic as RFC-0285 §6 (workaround signature #2).

**The stronger default (L0):** because re-injection is causally active, the safest routing is to write self-observations to the **episodic/audit log, not the recall-injected fact store** at all. "Record, do not re-present." Only a de-indexed, de-tensed lesson ("approach X caused a loop") — which is *durable knowledge precisely because it is no longer about the transient self* — earns a place in recall. **Consolidation earns durability; it is not grandfathered.**

> Reflexive note from the epistemics lens, worth keeping: a research/keeper agent is subject to the identical failure mode. A note of the form "I am stuck / looping" is a token-reflexive stage claim; a future session re-reading it as standing fact inherits a context-shifted, self-fulfilling input. Discipline: write **event-records** ("at step N WebSearch returned X"), **de-indexed lessons**, and **externally-verifiable claims** — never standing first-person state into a durable channel.

---

## 4. Cross-map to masc's current machinery (code ground truth)

masc already forgets by **typed origin, deterministically — no score, no decay curve** (which is the right tradition; RFC-0247 purged the composite score):

| Layer | File:line | What it does |
|---|---|---|
| Write-time horizon | `keeper_memory_os_types.ml:235` `fact_valid_until` | routes Self_observation→short TTL, Ephemeral→TTL, else durable(None); external_ref is accepted for compatibility but context-only |
| Category TTL | `keeper_memory_os_types.ml:217` `category_valid_until` | only Ephemeral finite; Fact/Constraint/Lesson/… → None |
| Read-time recall filter | `keeper_memory_os_recall.ml:256, 274-277` `fact_is_current` | drops expired; **passes all durable** ← the echo gate |
| Cap-path expiry | `keeper_memory_os_io.ml:544, 627` `partition_expired` | sheds expired before ranking |
| Append-on-miss | `keeper_memory_os_io.ml:597` `merge_episode_facts` | **appends fresh-horizon row when `claim_identity` misses** ← the real 117× moot path |
| GC sweep | `keeper_memory_os_gc.ml:24-128` | hard-expiry + dedup; default-OFF, 600s cadence |
| Reconciler (external) | retired | The old GitHub grounding module was not compatible with the current context-only external_ref contract and was removed; there is no live external-state reconcile fiber. |
| Consolidation gate | `keeper_memory_os_consolidator.ml:57` `eligible = is_promotable && external_ref=None` | volatile never promoted fleet-wide |
| Anchor immutability | `keeper_memory_os_policy.ml:53-69` `reobserve_fact` | external_ref claim inherited whole; producer re-mint ≠ re-verification |

**What this research changes about the map:**
- The **load-bearing layer is the producer boundary** (write-time), not decay — masc already believes this for external state (RFC-0259 §3.7). Self-observation needs the same treatment: a `claim_kind` slot key (RFC-0285 L1) so re-mint **merges** at `merge_episode_facts:597` instead of appending.
- The **missing reconciler** is now only the structured self-observation case: there is **no `keeper_memory_os_self_reconcile`** grounding self-observations against the keeper's action stream. Any future implementation must use typed action events, not prose-derived external_ref inference.
- The **recall filter** (`recall.ml:256`) is where an L0 "self-observation is audit-only, not recall-injected" routing would live.

---

## 5. Safety constraints any forgetting policy must satisfy (failure-mode lens)

1. **Asymmetric fail-safe toward retain.** Uncertain classifier → default durable/keep, never forget. False-forget of a load-bearing fact is catastrophic and irreversible; false-retain is recoverable. masc already does this (`fact_valid_until`: Unknown/absent → None → durable). **Keep this invariant.**
2. **Protected class that never decays.** Durable_knowledge / Constraint / hard-won Lesson is a first-class never-decay set (SSGM Mcore analog). Forgetting is **opt-in by kind**; only kinds whose ground truth is **continuously re-derivable** are eligible. Never widen a global TTL across kinds.
3. **Forget by entrenchment, not age.** Eligibility = (inverse entrenchment) × (re-derivability) × (freshness-not-correctness). Self-observation maxes all three; a Lesson mins them.
4. **Anti-resurrection / no oscillation.** A forgotten claim re-minted from a stale source = zombie. Require a **stable conclusion-keyed id acting as a tombstone with a grace window** (Cassandra GC-grace analog) longer than the longest plausible re-extraction lag, AND suppress re-extraction at the producer. RFC-0285 §7 Medium (post-expiry oscillation) is exactly this gap.
5. **Forgetting is a producer concern first, decay second (L1 > L3).** Decay-only is the telemetry-as-fix family's cousin — it makes the symptom expire while the source keeps re-minting.
6. **No Judge inside a self-referential loop.** Re-evaluation is valid only against an **external** oracle. Self-observation's oracle is the **action stream** (§3), not an LLM re-read.
7. **`re-injection ≠ re-observation` (the ACT-R trap).** Any frequency/recency-aware scheme must NOT count prompt re-injection as a new observation — or it amplifies exactly the claim it should retire. Only a fresh extraction from a genuine new tool result resets staleness.
8. **Slot key must be a closed typed enum.** Free-string slot keys regress into the string-classifier workaround the codebase rejects. Parse-don't-validate at the slot boundary.

---

## 6. RFC-0285 re-evaluated against the research

**Right (keep):**
- L1 producer typing (`claim_kind`) — reframed as a **need-probability prior by kind** (directed forgetting at encode-time, where context is richest). Field-standard (Mem0, BeliefMem, SSGM all decide at write time).
- L1(b) stable `claim_id` — reframed as **slot supersession**, the load-bearing echo killer, not mere dedup.
- L3 > nothing, and the L1 > L3 priority (producer over decay) — correct.
- Default-to-durable degrade — satisfies safety constraint #1.

**Insufficient / wrong-emphasis:**
- **L3 as a *blind* TTL is the weakest layer**, and Vincent is right to distrust it as the headline. It should be (a) a **disuse-decay backstop** (recency-of-re-observation), not an absolute clock, and (b) explicitly secondary to supersession and event-invalidation.
- **§7 "no oracle, do not build a reconciler" is too strong** — the action-stream reconciler (§3) is the missing symmetric piece.
- **No L0 routing** — RFC-0285 still injects self-observations into recall (just with a horizon). The stronger position is audit-log by default, recall only for de-indexed lessons.
- **`re-injection ≠ re-observation`** is not stated as an invariant and must be.

**Open / unsolved (honest limits):**
- The masc-specific decay constant is **not derivable from theory** — Anderson-Schooler validates the steep prior by kind, not the exponent. Do not put a 2-decimal constant in an RFC without measuring it against transcripts.
- **Tagging-recall bound:** effectiveness is bounded by how reliably the librarian tags self-observation; untagged self-obs still echoes. Producer-bound, not decay-bound.
- **Legacy durable rows** on disk are not retrofitted (inherited whole) — needs the RFC-0285 §5 cleanup.
- **The continuity/summary prose channel** (`keeper_memory_policy_summary_filter.ml`) does not honor `valid_until` — self-narrative leaking into prose is untouched by any fact-decay policy. Separate, uncovered vector.
- **Harness-First gap (critical):** there is currently **no eval scoring memory quality** (recall precision, keeper outcome) — only mechanism tests. Any of these layers risks being another unproven scoring layer (like the purged composite score) unless gated on an outcome eval: *did quieting the echo improve keeper progress?*

---

## 7. Recommended next steps (sequenced)

1. **Ship RFC-0285 as the producer-boundary fix (L1), reframed.** The stable `claim_id` (supersession) + `claim_kind` (need-probability prior) are the load-bearing, theory-backed core. Keep L3 but **demote it in the RFC's own framing to a disuse-decay backstop**, not the headline mechanism. (This is mostly a framing + a decay-on-recency tweak over the merged RFC-0285 design.)
2. **New RFC: self-observation action-stream reconciler (the real finding).** A `keeper_memory_os_self_reconcile` would invalidate a standing self-observation when a **structured** later action contradicts it (task-claim event ⇒ retract "no tasks"; tool-success ⇒ retract "tool timing out"). Closed typed action⇒claim-kind map, never a phrase matcher. **This is the part RFC-0285 §7 said was impossible and the research says is possible.**
3. **New RFC or §-amendment: L0 recall routing + `re-injection ≠ re-observation` invariant.** Self-observation defaults to audit-log, not recall-injection; only de-indexed consolidated lessons enter recall; staleness clocks never advance on prompt re-injection.
4. **Build the memory-quality eval first (Harness-First).** Before tuning any decay constant, build the outcome eval. Otherwise every layer here is an unproven scoring layer. This is the gating prerequisite, not an afterthought.
5. **Defer the decay constant.** Set it from the eval + transcript measurement, not from a guess in the RFC.

**Bottom line for Vincent's question:** "what to forget" = the class of facts whose ground truth is continuously, freely re-derivable and whose truth is a property of a moment — i.e. first-person transient state. "How" = supersede on a fresh same-slot observation (primary), invalidate on a contradicting action (the real oracle), and decay by disuse as a backstop (not a blind clock). The Judge is the wrong tool here for reasons that survive removing the cost constraint. The blind TTL is not wrong, just demoted: it is the floor under a supersession + event-invalidation mechanism, never the mechanism itself.

---

## 8. Measured baseline (the eval now exists — §7 step 4 executed)

The Harness-First gate (§7 step 4) is satisfied: `test/memory_quality_eval.ml` is an
offline, deterministic, read-only eval. Self-test 10/10; two runs over the same store
are byte-identical. Reproduce:

```
dune exec test/memory_quality_eval.exe                # self-test only (CI-safe)
dune exec test/memory_quality_eval.exe -- \
  --recall-dir <base-path>/.masc/recall_injections \
  --keepers-dir <base-path>/.masc/keepers            # live baseline
```

Baseline over the live store (recall-injection ledger, 2026-06; measured 2026-06-23):

| metric | value |
|---|---|
| recall records (turns) | 24,399 |
| distinct fact_keys | 2,982 |
| total injections | 202,866 |
| echo max / p99 / p90 / p50 | **7,092** / 509 / 137 / 34 |
| top global echo | `claim:no unclaimed tasks exist.` (7,092×) |
| per-keeper max (issue_king / idealist / executor) | 2,662 / 1,793 / 1,559 |
| recall churn (fact_keys per turn) | mean 8.3, max 10 |
| near-duplicate fragmented slots (≥2 keys, shared 6-word prefix) | **213** |
| largest fragmented slot | `unstructured_note: librarian parse fallback …` — **203 distinct keys** for one failure mode |

**What the numbers confirm (and exceed) versus RFC-0285 §2's 117× anecdote:**
- The worst echo is **7,092×**, ~60× the figure the RFC cites; even the *median* fact is
  re-injected 34×. Echo is not a tail event — it is the steady state.
- **Supersession is the load-bearing mechanism, quantitatively.** 213 conclusions are split
  across ≥2 slots that a stable `claim_id` would merge. The pathological case — the librarian
  parse-fallback — fragments **one** failure into **203** distinct fact_keys because the raw
  (empty/invalid-JSON) payload is stored verbatim each time. A blind TTL cannot fix this: each
  variant expires independently while the conclusion is regenerated every cycle. Only a
  write-time stable identity collapses it to one decaying slot. This is direct evidence for
  §3's claim that supersession (not the clock) is the echo killer.
- Fact store composition metrics are skipped: `keepers/*.facts.jsonl` is currently 0 files
  (memory-crisis-20260618 cleanup), so the volatile/durable split is unmeasurable from disk
  right now — the recall-injection ledger is the only live signal, and it suffices for echo.

This baseline is the before-state. Any forgetting policy (RFC-0285 L1/L3, the action-stream
reconciler) must move these numbers, not assert that it will. The eval makes that falsifiable.

---

## Appendix: sources by lens (as surfaced; primary-source page numbers not independently verified here)

- **Cognitive science:** Anderson & Schooler 1991 (rational analysis / need-probability); Bjork & Bjork New Theory of Disuse (storage vs retrieval strength); Ebbinghaus 1885 (forgetting curve; Murre & Dros 2015 replication); Anderson, Bjork & Bjork 1994 (retrieval-induced forgetting); Anderson & Green (think/no-think, directed forgetting); Keppel & Underwood (proactive interference).
- **AI agent memory:** MemGPT/Letta; Stanford Generative Agents; A-MEM; Mem0; BeliefMem; Temporal Semantic Memory; SSGM; ACT-R activation.
- **Failure modes:** catastrophic forgetting literature; AGM belief revision (entrenchment); SSGM Mcore protected set; Cassandra GC-grace (tombstone + grace window).
- **masc current:** code at `lib/keeper/keeper_memory_os_*.ml`, `docs/rfc/RFC-0247/0259/0244/0285`.

*Confidence: power-law form of need-probability-vs-recency = High (replicated primary corpora). The keeper-specific decay exponent = unknown, must be measured. The action-stream-oracle finding = High on principle, unbuilt in code.*
