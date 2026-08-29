# Keeper Full Lifecycle Behavior

Status: Living product SSOT  
Last evidence update: 2026-08-03 19:34 KST
Evidence rule: source code and green tests are not live proof.

## 1. Who uses MASC

MASC has two first-class user experiences.

- **Vincent, the operator**: creates the intent, sees the team, understands blockers, and intervenes only when needed.
- **An agent, the collaborator**: uses MASC to assemble a team, delegate work, follow progress, exchange results, and finish a project without knowing model or provider details.

A feature works only when both users can complete the same lifecycle through their own surface.

The collaborating agent is the Full Feature user. Shell access, direct JSON edits,
database writes, and private module calls may diagnose or repair the product, but
they do not prove a product behavior. A behavior is agent-usable only when the
agent completes it through the public MASC command/API/tool surface.

## 2. The product in one sentence

Give MASC a project, let the active declarative Keeper fleet keep working through typed Runtime slots, and always show what is moving, what is blocked, why, and what happens next. The application-owned system LLM verifier reviews typed completion evidence outside the Keeper lifecycle.

## 3. North star

The normal path is continuous context maintenance.

```text
new turn delta
  -> deterministic technical cleanup
  -> LLM semantic update
  -> deterministic validation
  -> atomic checkpoint replacement
  -> next Keeper turn
```

Deterministic code may remove protocol shells, exact duplicates, whitespace, and typed disposable tool mechanics. It must not invent, summarize, or discard semantic meaning.

If an LLM cannot produce a valid semantic update, MASC preserves the source, tries the next declared Runtime slot, reports the reason, and keeps the Keeper alive.

## 4. Fresh-state fleet

The first proof fleet is the set of Keeper declarations selected by the active
workspace configuration. This document describes behavior and evidence; it is
not a second roster or Runtime-assignment SSOT.

The verifier is an application-owned system LLM agent. It is not a Keeper, is
not registered as a Keeper, does not claim a Keeper lane, and does not use
Keeper task actions. An authenticated HITL operator is a separate authority
path. Neither authority belongs in the Keeper roster or Keeper count.

Keeper configuration contains no model or provider policy. Runtime assignment is the only routing SSOT.

Librarian, judgment, board-attention, and other ordinary LLM
sub-lanes accept any general text Runtime in a frozen declared order. Different
lanes may use different first slots for load distribution. Runtime order is
never inferred from price, tier, provider name, or error prose.

Native JSON mode and JSON Schema are optional agent core wire optimizations, not MASC
admission requirements. Without them, agent core uses the ordinary text path and the
domain validator decides whether the result is accepted. Only intrinsically
different work such as image, audio, embedding, or another non-text modality
may require a special Runtime capability.

## 5. What "Full Lifecycle works" means

One fresh-state proof must show this uninterrupted sequence:

1. The server materializes every selected declarative Keeper.
2. Vincent or an agent creates a project Goal and Tasks.
3. An agent uses MASC to assemble or select the team.
4. Keepers claim and start distinct work without duplicate ownership.
5. A Keeper completes at least one normal turn.
6. A Runtime failure advances to the next frozen compatible slot.
7. A new transcript delta produces an LLM-authored semantic context update.
8. Validation succeeds and the existing checkpoint CAS installs it atomically.
9. A failed semantic update preserves the original source and does not stop the Keeper.
10. Task, Goal, Board, Schedule, HITL, Fusion, and memory surfaces consume the resulting domain state.
11. The next Keeper turn uses the updated context.
12. Vincent and an agent see the same status, reason, receipt, and next action.
13. Every selected Keeper remains alive or visibly blocked with a reason.
14. Each Keeper can clearly distinguish its Keeper, current Goal, assigned Task, recent decisions, and another Keeper's evidence.
15. The collaborating agent completes the project through public MASC surfaces; direct filesystem access is used only to verify evidence.

Partial source evidence does not satisfy this definition.

## 5.1 Input and output ownership

| Layer | Owns | Must not own |
|---|---|---|
| MASC domain | the question, domain schema, semantic validator, and use of the accepted value | provider names, model quirks, wire dialects, or candidate ranking |
| Runtime slot | opaque identity plus the declared execution specification | hidden policy inferred from pricing, tier, or past preference |
| agent core | provider/model resolution, capability facts, vendor wire encoding, strict output parsing, typed transport errors, and frozen-order failover | MASC domain meaning, Task state, Keeper lifecycle, or domain persistence |
| Dashboard/API | read-only projections of the same MASC domain state and agent core evidence | a second status calculation or mutable execution truth |

For an ordinary LLM judgment, MASC sends input and consumes either an accepted
domain value or a typed exhausted result. It does not select a provider-specific
code path.

## 6. User-visible behavior cards

### B01. Start a team

**Middle-school explanation:** Ask for a project team and see the selected workers appear.

**Vincent sees:** the selected Keepers, their role, current task, state, and next action.

**Agent can do:** join MASC, inspect the fleet, choose or create work, and delegate without supplying a provider or model.

**Current verdict:** `NOT_PROVEN_FRESH`

**Observed:** the historical runtime materialized eight fibers and seven
produced turn records. The historical roster included a `verifier` entry, but
that entry was the system LLM verifier rather than a Keeper. This observation
does not prove the current declarative Keeper roster or its liveness.

**Missing:** every selected Keeper must execute through the same declarative
config authority without an operator filesystem repair, and the system LLM
verifier must be evidenced as a separate lane.

### B02. Create and finish work

**Middle-school explanation:** A task moves from waiting, to working, to finished.

**Vincent sees:** Goal progress derived from Task state, not a second hand-maintained counter.

**Agent can do:** create, claim, start, update, and complete work through typed transitions.

**Current verdict:** `NOT_PROVEN_FRESH`

**Missing:** one agent-created Goal with parallel Keeper Tasks and a completed transition chain.

### B03. Keep a Keeper alive

**Middle-school explanation:** One bad turn does not kill the worker.

**Expected behavior:** every blocked state has a typed reason and next action. No silent failure and no permanent stop from an ordinary provider, parsing, judgment, or capacity failure.

**Current verdict:** `NOT_PROVEN_FRESH`

**Observed:** the historical evidence attributed repeated turns and a Gemma
HTTP 500 to `verifier`. That lane is the system LLM verifier, not a Keeper, so
the observation is not Keeper liveness evidence.

**Missing:** a post-checkpoint failure must preserve the remaining frozen
Runtime suffix for the next turn; every blocked Keeper must expose that pending
target and reason.

### B04. Runtime failover

**Middle-school explanation:** If the first engine fails before producing an accepted answer, try the next compatible engine.

**Expected behavior:** frozen order, at most one POST per candidate attempt,
typed failure evidence, no model/provider branching in MASC, and no rejection
of an ordinary text Runtime merely because it lacks native structured output.

**Current verdict:** `WIRED_FAILING_LIVE`

**Observed:** the system LLM verifier produced one Gemma HTTP 500 to GLM
success trace. Subsequent Gemma failures had no rotation attempt because the
next Runtime suffix was discarded at the checkpoint boundary. This is verifier
lane evidence, not evidence of a Keeper-to-Keeper verifier.

**Missing:** the next actual turn starts at the preserved successor, a missing
successor terminates visibly instead of looping, and resumed success updates the
same declared lane preference.

### B05. Continuous context correction

**Middle-school explanation:** After each turn, keep the important meaning and remove only technical clutter.

**Expected behavior:** process only the new delta and bounded retry backlog. The LLM creates the semantic value. Deterministic code validates and installs it.

**Current verdict:** `NOT_IMPLEMENTED`

**Missing:** new-delta-only semantic update after raw checkpoint save.

### B06. Memory Librarian

**Middle-school explanation:** Turn useful new experience into reusable memory without blocking the next turn.

**Expected behavior:** asynchronous LLM extraction, typed validation, visible retry or blocker, and no duplicate semantic reinjection.

**Current verdict:** `PARTIAL_LIVE`

**Observed:** fresh Librarian episode and fact files were written and later
turn records show Memory OS recall blocks.

**Missing:** bounded extraction success across the fleet, visible typed failure,
and proof that source coverage does not advance over unextracted content.

### B07. Recall

**Middle-school explanation:** Bring back only memory useful for the current job.

**Expected behavior:** LLM relevance selection runs off the critical path. If it is late or fails, reuse the last valid selection and continue.

**Current verdict:** `WIRED_FAILING_LIVE`

**Observed:** recall blocks are injected, but their byte size grows and repeated
content dominates many turns.

**Missing:** relevant-memory selection that changes with the Task and does not
reinsert the same fixed block every turn.

### B08. Periodic consolidation (removed)

**Middle-school explanation:** Do not let a background LLM rewrite the entire memory store.

**Expected behavior:** Retention removes only facts whose producer-declared
`valid_until` has passed. Every other fact is preserved.

**Current verdict:** `REMOVED`

**Observed:** the periodic full-store consolidation route, prompt, schema,
runtime toggle, metrics, and maintenance fiber are absent.

**Missing:** typed supersession/tombstone support is separate future work; it
must not revive periodic full-store consolidation.

### B10. Board attention and Schedule

**Middle-school explanation:** Notice important work at the right time without waking every worker for every event.

**Expected behavior:** typed stimuli, bounded cadence, no duplicate wake marker persistence, and visible defer reasons.

**Current verdict:** `NOT_PROVEN_FRESH`

**Missing:** one scheduled wake and one board-triggered turn in the fresh fleet.

### B11. HITL and Task judgment

**Middle-school explanation:** Ask an LLM only when a human-like decision is actually needed.

**Expected behavior:** the domain owns the question and validates the answer. A judgment failure does not block unrelated Keeper work.

**Current verdict:** `NOT_PROVEN_FRESH`

**Missing:** accepted and rejected decisions with distinct user-visible reasons.

### B12. Fusion

**Middle-school explanation:** Ask several perspectives, combine them, and continue even if one perspective fails.

**Expected behavior:** non-blocking fan-out, typed partial results, one domain result, and no central mutable judgment store.

**Current verdict:** `NOT_PROVEN_FRESH`

**Missing:** fresh multi-Runtime panel evidence and downstream Task use.

### B13. One operator and agent surface

**Middle-school explanation:** Vincent and the agent read the same truth in different presentations.

**Vincent sees:** human wording, consistent icon/color, exact blocker reason, and next action.

**Agent receives:** typed state, stable identifiers, immutable evidence, and the same next action.

**Current verdict:** `CONTRADICTED_LIVE`

**Observed:** the `kinobot-frontend` config API reported
`proactive.enabled=true` while the composite Surface reported
`proactive_enabled=false`, `proactive_disabled`, and
`scheduled_autonomous_disabled`.

**Missing:** dashboard/API parity checks across the Full Lifecycle, starting
with immediate equality after an activation config POST.

### B14. Clear memory and context

**Middle-school explanation:** A worker remembers the right facts, knows which job they belong to, and does not confuse another worker's memory with its own.

**Expected behavior:**

- Keeper instructions remain recognizable without overriding the current Task.
- The current Goal and assigned Task are present and correctly prioritized.
- Recent decisions replace superseded decisions instead of appearing beside them as equal truth.
- Recalled facts retain source, owner, and time.
- Another Keeper's observation is attributed rather than copied into first-person memory.
- Exact duplicate memory is not injected again.
- Irrelevant memory stays out of the working context.
- After a semantic context update, the next turn preserves unresolved obligations and completed decisions.
- A fresh-state Keeper never claims knowledge sourced only from the retired runtime.

**Agent verification:** the collaborating agent asks each selected Keeper the same bounded questions and compares typed evidence with the answer:

1. Who are you and what is your role?
2. What Goal and Task are you working on now?
3. What was the latest relevant decision?
4. Which fact came from another Keeper?
5. What remains unresolved?
6. Which recalled item can be omitted from this turn?

**Live measurements:**

- `identity_correct`: correct Keeper and role
- `task_correct`: correct Goal and Task identifiers
- `decision_fresh`: latest decision selected over superseded history
- `provenance_correct`: owner and source preserved
- `recall_precision`: relevant recalled items divided by all recalled items
- `duplicate_injection_bytes`: exact repeated recall bytes
- `retired_state_leak_count`: claims supported only by retired state
- `continuity_correct`: obligations survive semantic replacement

**Current verdict:** `NOT_PROVEN_FRESH`

**Missing:** selected-Keeper probe after the first successful context-correction cycle.

## 7. Deliberately outside the MVP

### Failure Judge

MVP failover does not ask another LLM what an already typed runtime failure means.

The required path is:

```text
typed agent core failure
  -> next declared Runtime slot
  -> visible exhausted reason if none remain
  -> Keeper remains alive
```

A future Failure Judge may provide asynchronous postmortem advice. Its result must never gate a turn, Runtime failover, task progress, or Keeper liveness.

### Generic durable workflow facades

There is no new generic Store, Commit, Settlement, Lease, lifecycle nonce, or replay subsystem in the MVP. Existing domain SSOTs and checkpoint CAS remain the authority.

### Pricing policy

Pricing may be measured and displayed later. It does not limit, route, rank, admit, or fail over a Runtime.

## 8. Evidence ledger

| Checked at | Evidence | Result | Confidence |
|---|---|---|---|
| 2026-08-03 19:34 KST | live `GET /health?full=1` | `status=ok`, `overall_status=ok`; configured, materializable, running, and executable Keeper counts were all 8 (`analyst`, `code-reviewer`, `full-cycle-probe`, `kidsnote`, `lane-smith`, `rondo`, `sangsu`, `taskmaster`); `completion_authority_pending=false`; no operator action required | High for the current roster/authority boundary, not full behavior proof |
| 2026-07-27 17:31 KST | `GET /health?full=1` | old build `0.21.2@b91dcb6995`; `keeper_fibers=0`; five lifecycle authority blockers | High |
| 2026-07-27 17:33 KST | fresh-state filesystem operation | old `.masc` retired; only active config, Keeper TOML, Keeper, and prompts copied | High |
| 2026-07-27 17:38 KST | GitHub CLI open PR list and close results | all 13 previously open MASC PRs closed as superseded | High |
| 2026-07-27 17:37 KST | authenticated `POST https://ollama.com/api/show` | Qwen 3.5 Cloud and Gemma 4 31B Cloud available; both 262,144 context; tools/thinking/vision declared | High |
| 2026-07-27 17:38 KST | authenticated `POST https://ollama.com/v1/chat/completions` with `json_object` | Qwen and Gemma returned valid JSON; DeepSeek Flash reached the service but 32 output tokens were insufficient | High |
| 2026-07-27 17:42 KST | authenticated `json_schema` probe | Qwen and Gemma returned fenced JSON; DeepSeek returned non-JSON text. Native schema is not a portable admission requirement | High |
| 2026-07-27 17:46 KST | fresh declarative config edit | Keeper TOMLs were selected for autoboot; Runtime assignments were 4 Flash, 2 GLM, 1 Qwen Cloud, 1 Gemma Cloud | High for source, not live; not current Keeper-fleet evidence |
| 2026-07-27 22:24 KST | `GET /health?full=1` | current process reported `status=ok` and `keeper_fibers=8` | High for fiber presence only; Keeper role attribution was not proven |
| 2026-07-27 22:25 KST | `GET /api/v1/keepers/:name/turn-records?limit=1` over the historical configured roster | seven entries had fresh-runtime turn records; `kinobot-frontend` had none | High for endpoint observation, not current Keeper-fleet proof |
| 2026-07-27 22:28 KST | `kinobot-frontend` config, composite, turn records, and system log | config said proactive true; effective activation was false; scheduler skipped with `scheduled_autonomous_disabled`; turn record count remained zero | High |
| 2026-07-27 22:25 KST | latest turn records and earlier live trace comparison | the system LLM verifier had one Gemma-to-GLM recovery, but later post-checkpoint failures did not retain the successor; this is not Keeper failover evidence | High for the trace, not Keeper attribution |
| 2026-07-27 22:25 KST | fresh turn-record prompt blocks | recall was active, but representative blocks ranged from 1,455 to 9,962 bytes and continued accumulating without a semantic replacement cycle | Medium |

[Official Ollama Qwen 3.5 Cloud model page](https://ollama.com/library/qwen3.5%3Acloud)  
[Official Ollama Gemma 4 model page](https://ollama.com/library/gemma4)  
[Official Ollama Qwen 3 Coder Cloud model page](https://registry.ollama.com/library/qwen3-coder)

## 9. Promotion rule

A behavior moves to `WORKS_LIVE` only when the evidence ledger contains:

- the running build identity,
- the exact trigger,
- the public MASC action used by the agent,
- the typed state transition,
- the operator projection,
- the agent projection,
- the next successful lifecycle step,
- the memory/context clarity measurements,
- and a timestamp from the fresh-state fleet.

Anything less remains incomplete.
