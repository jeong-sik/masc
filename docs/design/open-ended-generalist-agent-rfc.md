---
status: draft
last_verified: 2026-04-25
code_refs:
  - lib/keeper/
  - lib/procedural_memory.ml
  - lib/goal/
  - lib/cdal/
---

# Open-Ended Generalist Agent RFC

- **Status**: Research RFC, implementation not started
- **Date**: 2026-04-25
- **Scope**: MASC keeper autonomy, procedural memory, Goal Store, CDAL advice surface
- **One sentence**: Bring the useful parts of Voyager and Eureka into MASC as supervised skill and curriculum research, without giving reward advice authority over verdicts, cascade policy, or keeper configuration.

## Related Documents

- `../spec/05-keeper-agent.md`
- `../spec/12-memory-systems.md`
- `../spec/17-keeper-behavioral-regime.md`
- `./contract-driven-agent-loop-rfc.md`
- `./cdal-contract-kernel-and-advisory-split.md`
- `./tool-calling-quality-and-self-healing-rfc.md`
- `./external-agent-framework-patterns-rfc.md`
- `../OAS-MASC-BOUNDARY.md`

## 1. Research Trigger

CS25 Lecture 20 frames generalist agents around active learning in open-ended worlds:

- MineDojo: an open-ended environment plus internet-scale task and knowledge substrate.
- Voyager: an LLM agent that uses automatic curriculum, executable skill library, and iterative environment feedback.
- Eureka: an LLM reward-designer that proposes reward code, runs RL, observes results, and mutates the next reward.
- VIMA: a multimodal-prompt robot policy that treats language and images as task specification tokens.

MASC already has enough adjacent primitives that the useful next step is not to clone Minecraft agents. The useful step is to define which parts become first-class MASC research surfaces and which parts remain explicitly unsafe.

## 2. Current MASC Mapping

| Open-ended agent concept | Current MASC primitive | Decision |
|---|---|---|
| Environment observation | `keeper_world_observation` plus room, board, task, repo, and runtime signals | Adopt as the MASC world-state boundary |
| Action module | Keeper tool calls through OAS-backed autonomous paths | Already present; do not replace with code-agent default |
| Iterative feedback | Tool results, execution receipts, proof artifacts, keeper metrics | Adopt as evidence inputs |
| Skill library | `procedural_memory.ml`, institution procedural patterns, OAS memory bridge | Extend by curation, not by new memory silo first |
| Automatic curriculum | Goal Store, task backlog, keeper active goals, work discovery | Add advisory candidate generation |
| Learned reward | CDAL `friction_projection` and `advice`, benchmark results, verifier outcomes | Advisory only; never gate authority |
| Multimodal prompting | Dashboard screenshots, future visual evidence, VIMA-style task specs | Future work only |

## 3. Design Principles

### 3.1 Active Feedback, Not Passive Recall

Keeper learning should come from executed actions and observed outcomes, not from summaries alone. A skill candidate must cite runtime evidence: tool calls, task/verifier outcomes, proof artifacts, or execution receipts.

### 3.2 Skill Promotion Is Supervised

Procedural memory can already crystallize repeated patterns. The next layer should curate and rank skill candidates before injection, not automatically trust every repeated behavior.

Promotion states:

- `observed`: evidence exists but no reuse contract.
- `candidate`: enough evidence to be reviewed.
- `approved`: safe to inject or recommend.
- `retired`: evidence is stale, unsafe, or no longer useful.

Only `approved` skills may become default prompt material.

### 3.3 Curriculum Is Advisory

Automatic curriculum should propose next goals or tasks, not silently modify active goals. Candidate generation may read:

- stalled or empty executing goals
- repeated keeper idle signals
- high-success procedural patterns that lack a linked goal
- high-friction proof/eval clusters
- tool diversity entropy and underused-capability hints

The output is a queue of goal/task proposals. Existing `masc_goal_*`, task, verifier, and human approval paths remain the write authority.

### 3.4 Eureka-Style Reward Stays Outside the Gate

Eureka is useful as a model for generating and mutating evaluation hypotheses. In MASC, that means:

- propose verifier clauses
- propose benchmark cases
- propose skill promotion criteria
- explain which friction metric might improve

It must not:

- change `contract_verdict`
- relax deterministic gates
- modify `config/cascade.json`
- rewrite keeper TOML/meta fields
- auto-apply model/provider/cascade selection

This follows the CDAL split: `contract_verdict` is authoritative; `friction_projection` and `advice` are observability and recommendation surfaces.

## 4. Proposed Research Surfaces

### 4.1 Skill Candidate Registry

Add a design target for a future registry that can be backed by existing procedural memory and proof artifacts.

Minimal candidate shape:

```json
{
  "id": "skill-candidate-...",
  "agent_name": "keeper-name",
  "pattern": "When X, do Y",
  "evidence_refs": ["proof-store://...", "task://...", "procedure://..."],
  "success_count": 3,
  "failure_count": 1,
  "confidence": 0.75,
  "applicable_tools": ["masc_task_claim", "masc_goal_review"],
  "promotion_state": "candidate",
  "risk_notes": ["requires repo write approval"]
}
```

Implementation note: this should initially be a read-side projection over existing procedural memory and evidence, not a second source of truth.

### 4.2 Curriculum Candidate Queue

Add a design target for candidate next work:

```json
{
  "id": "curriculum-candidate-...",
  "source_signal": "empty_executing_goal",
  "linked_goal_id": "goal-...",
  "proposed_title": "Curate keeper skill library from repeated verified actions",
  "proposed_next_action": "Create a focused task with verifier policy",
  "verifier_requirement": "human_approval_or_existing_goal_verifier",
  "approval_state": "needs_review"
}
```

This maps Voyager's automatic curriculum to MASC without bypassing Goal Store governance.

### 4.3 Reward Advice Artifact

Add a design target for Eureka-like advice:

```json
{
  "id": "reward-advice-...",
  "basis_refs": ["benchmark://...", "contract-verdict://...", "friction://..."],
  "proposed_scorer": "Measure skill reuse rate after approved procedure injection",
  "expected_improvement": "Lower repeated failed-tool loops",
  "risk_notes": ["do not use as contract verdict input"],
  "authority": "advisory_only"
}
```

This artifact can inform future verifier or benchmark work, but it cannot write policy.

## 5. Phase Plan

### Phase 0 - Documentation and Backlog

- Land this RFC.
- Create follow-up issues for skill candidate projection, curriculum candidate queue, and reward advice artifact.
- Link each issue to the existing owner boundary: keeper, memory, goal, or CDAL.

### Phase 1 - Read-Only Skill Projection

- Build a read-only projection over `procedural_memory.ml`, task/verifier outcomes, and proof artifacts.
- Surface top candidates with evidence refs and confidence.
- Do not inject new prompt material by default.

### Phase 2 - Curriculum Candidate Queue

- Generate candidate goals/tasks from stalled goals, idle keepers, repeated procedures, and high-friction clusters.
- Keep writes behind existing Goal Store and task creation surfaces.
- Require explicit approval before changing active goals.

### Phase 3 - Reward Advice Lab

- Generate benchmark/verifier/scorer proposals from historical eval and friction data.
- Persist output as advisory artifacts.
- Add tests that prove advice cannot override deterministic verdicts or policy gates.

### Phase 4 - Multimodal Evidence, Later

- Consider VIMA-style multimodal task specs only after proof/evidence contracts can carry visual artifacts safely.
- Keep this out of the first implementation wave.

## 6. Non-Goals

- Do not build a Minecraft/Voyager clone inside MASC.
- Do not make keeper default behavior code-generation-first.
- Do not auto-modify cascade config, keeper config, or Goal Store state from reward advice.
- Do not treat `friction_projection` or `advice` as a merge gate.
- Do not add a new vector database. Supabase pgvector remains the vector DB SSOT.
- Do not add Qdrant code, docs, or integration.

## 7. Acceptance Criteria For Future Implementation

- Skill candidates cite concrete evidence refs and never rely only on free-text memory.
- Candidate promotion has an explicit state and can be reviewed.
- Curriculum candidates are proposals until an existing Goal/Task write path accepts them.
- Reward advice carries `authority = advisory_only`.
- Tests cover that advisory artifacts cannot change `contract_verdict`.
- Dashboard or operator surfaces visually separate verdict, friction, advice, and candidate queues.
- OAS remains coordinator-agnostic; MASC-specific state stays in MASC adapters and coordination surfaces.

## 8. Evidence

- [근거] Voyager paper, arXiv `2305.16291`: https://arxiv.org/abs/2305.16291 ; 확인일시 2026-04-25 ; 신뢰도 High.
- [근거] Eureka paper, arXiv `2310.12931`: https://arxiv.org/abs/2310.12931 ; 확인일시 2026-04-25 ; 신뢰도 High.
- [근거] MineDojo paper, arXiv `2206.08853`: https://arxiv.org/abs/2206.08853 ; 확인일시 2026-04-25 ; 신뢰도 High.
- [근거] VIMA paper, arXiv `2210.03094`: https://arxiv.org/abs/2210.03094 ; 확인일시 2026-04-25 ; 신뢰도 High.
