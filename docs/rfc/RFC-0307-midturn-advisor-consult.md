---
rfc: "0307"
title: "Mid-turn advisor consult for keepers — evaluation and deferral"
status: Draft
created: 2026-07-04
updated: 2026-07-04
author: vincent
supersedes: []
superseded_by: null
related: []
implementation_prs: []
---

# RFC-0307 — Mid-turn advisor consult for keepers

## 0. Summary

Anthropic shipped an **Advisor tool** (`advisor_20260301`, beta header
`advisor-tool-2026-03-01`): a fast/cheap **executor** model consults a
higher-intelligence **advisor** model *during generation* for strategic
guidance, then keeps executing. This RFC evaluates whether MASC should adopt a
**mid-turn advisor consult** for keepers.

**Recommendation: defer.** MASC already has a *second-model* pattern, but it is
**post-hoc** (verify/judge after a turn), whereas advisor is **mid-turn** (plan
during a turn). That "intervention timing" is the only orthogonal axis on offer.
The native tool is **unusable for MASC's actual keepers** (they route to
non-Anthropic providers), and a provider-agnostic self-build has a large blast
radius for unmeasured benefit. This RFC records the decision and the trigger
conditions that would reopen it, so the axis is not re-litigated ad hoc.

## 1. What MASC already has (post-hoc, not mid-turn)

A second, higher-capability model already participates in keeper workflows — but
*after* the producing turn, as a verifier/judge, never *inside* it:

- **Structured judge runtime**: a dedicated second runtime resolved via
  `Runtime.runtime_id_for_structured_judge ()`, consumed at
  `lib/verifier_oas.ml:133`. Validation of the judge runtime lives at
  `lib/runtime/runtime.ml` (`validate_structured_judge_runtime`, ~L185–213).
- **Fusion judge**: `lib/fusion/fusion_judge.ml:188` `run_composed
  ~judge_model …` (and `run` / `run_refine` wrappers) — a distinct judge model
  scores/refines fusion panel output.
- **Broadcast consult**: keepers can already ask a peer via `@mention`
  (`masc_broadcast`) — an *observable, auditable* cross-agent consult. This is
  MASC's existing "ask a smarter peer" mechanism.

The keeper turn itself runs on a **single assigned runtime**
(`Runtime.runtime_id_for_keeper`, `lib/runtime/runtime.ml:601`). There is no
built-in dual executor/advisor per turn.

**The delta advisor would add is narrow**: consult *during* the turn instead of
*after* it, and *inline* instead of *via broadcast*.

## 2. Hard constraint — native advisor is unusable for MASC keepers

Anthropic's advisor requires an **Anthropic executor** model (top-level `model`)
paired with an Anthropic-family advisor (the tool's `model` field), a valid
executor≤advisor performance pair, and is **API/AWS-only** (not Bedrock, GCP,
Foundry). (Source: platform.claude.com advisor-tool docs, confirmed 2026-07-04.)

MASC keepers are predominantly routed to **non-Anthropic** providers via OAS
(GLM, kimi, deepseek, ollama, runpod). For those keepers the native advisor tool
**cannot be attached at all** — there is no Anthropic executor to carry it.

Consequence: adopting advisor is not "turn on a flag." It is one of:

- **(A) Do nothing** — keep post-hoc judge + broadcast consult.
- **(B) Self-build a provider-agnostic mid-turn consult** — inject a second-model
  planning call inside the keeper turn, for any provider.
- **(C) Native advisor for the Anthropic-executor keeper subset only** — attach
  the real advisor tool where (and only where) a keeper is assigned an Anthropic
  executor model.

## 3. Blast radius (grounded)

| Option | Touches | Fan-out |
|---|---|---|
| A (do nothing) | — | 0 |
| B (self-build, provider-agnostic) | keeper turn driver + routing | `Keeper_turn_driver.run_named` (`lib/keeper/keeper_agent_run.ml:619`); **~36 files reference `Keeper_turn_driver`**; routing `runtime.ml:601` (2 read consumers) + `get_runtime_by_id` (15 callers) |
| C (native, Anthropic subset) | attach path + capability gate | narrow: advisor tool attachment where executor is Anthropic; no turn-driver surgery |

Option B is the high-blast path (the turn is MASC's most load-bearing seam).
Option C is bounded but only benefits Anthropic-executor keepers, a minority.

## 4. Adversarial evaluation

**Arguments for adopting mid-turn advisor:**

- Advisor's documented sweet spot ("most turns mechanical but good planning
  matters — coding agents, computer use, multi-step research") *is* the keeper
  workload. Mechanical turns dominate; occasional planning is decisive.
- Post-hoc judge catches a bad turn *after* tokens are spent; mid-turn guidance
  could prevent the bad turn. Different failure-prevention timing.

**Arguments against (why defer):**

1. **No measured gap.** There is no evidence that post-hoc judge + broadcast
   consult leave a quality gap that only *mid-turn* consult closes. Anti-hype
   rule: no "faster/better" claim without a benchmark. Adopting B/C now is a
   solution without a measured problem.
2. **Observability regression.** MASC's broadcast consult is auditable (it is a
   recorded room event). An inline advisor call is a black-box side-channel
   inside the turn — it weakens the harness-observability MASC is built on
   (MANIFEST: "좋은 에이전트는 좋은 하네스에서 나온다").
3. **Native path doesn't fit the fleet.** The cheap drop-in (native advisor)
   only works for Anthropic-executor keepers; the fleet is mostly non-Anthropic.
4. **Self-build cost.** Option B rewrites the busiest seam (~36-file turn-driver
   family) + adds a second per-turn model call (latency + cost) for an
   unquantified win.

## 5. Recommendation

**Defer. Do not implement B or C now.** Keep the post-hoc judge + broadcast
consult. Reopen this RFC only when a **trigger condition** is met:

- **T1 (measured gap):** a benchmark shows keeper turns where a mid-turn plan
  would have prevented a failure that post-hoc judge did *not* catch — quantified
  (e.g. task-success delta on a fixed keeper suite).
- **T2 (cheap native subset):** enough keepers are assigned Anthropic executor
  models that Option C is a near-zero-cost drop-in worth A/B testing against
  post-hoc judge.
- **T3 (broadcast insufficiency):** evidence that broadcast-consult latency or
  turn-boundary granularity is the actual bottleneck (not model capability).

If **T2** fires first (lowest risk), scope the first step to **Option C only**:
attach the native advisor tool behind a capability gate for the
Anthropic-executor subset, measure task-success and cost vs post-hoc judge on a
fixed suite, and **do not** touch the provider-agnostic turn driver until C shows
value. Avoid Option B until C (or a T1 benchmark) justifies the blast radius.

## 6. Non-goals

- Replacing the structured-judge / fusion-judge post-hoc path.
- Removing broadcast consult.
- Any change to `Keeper_turn_driver` in this RFC (deferred to a follow-up gated
  on T1/T2).

## 7. Provenance

Derived from an adversarial mapping of Anthropic's agents-and-tools surface
(advisor / tool-search / strict / code-execution / computer / text-editor) onto
MASC/OAS (2026-07-04). Of the six ideas, five were already covered by existing
MASC/OAS mechanisms or unfit at the boundary; **mid-turn advisor was the only
genuinely novel axis MASC lacks**, and this RFC resolves its disposition.
Companion analysis:
`reports/masc-oas-anthropic-tools-orthogonal-blastradius-2026-07-04.html`.
