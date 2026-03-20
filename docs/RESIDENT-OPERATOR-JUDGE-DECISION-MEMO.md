# Resident Operator Judge Decision Memo

Status: Proposed canonical direction
Date: 2026-03-10
Priority: Trust and evidence over minimal disruption

## One-line decision

Adopt a resident `operator/warroom keeper` as the canonical live inferred judgment layer, keep `command-plane` and `operator snapshot` as truth layers, demote current rule-based `operator digest` and `swarm_status` recommendations to explicit fallback/read-model status, and keep `Gardener` out of real-time war-room judgment.

## Why this memo exists

The current dashboard mixes four different things under one visual surface:

1. truth from command-plane and operator state
2. derived rule-based read models
3. cached MODEL narrative in `Mission`
4. actionable operator hints

That is enough for observability, but not enough for a human to trust the system as a live judgment surface. The main problem is not missing data; it is missing provenance and missing ownership of the judgment layer.

## Current-state map

| Layer | Current source | Current role | Trust level | Notes |
|---|---|---|---|---|
| Truth | `command-plane snapshot/summary`, `operator snapshot` | canonical state | High | Raw units, operations, detachments, decisions, traces, sessions |
| Derived | `operator digest`, `swarm_status` | intervention hints and summarized state | Medium | Mostly rule-based translation of truth |
| MODEL narrative | `Mission` briefing | human-facing summary | Medium | Snapshot-based, cached, not the command canonical path |
| Ecosystem manager | `Gardener` | spawn/retire population control | High for its own domain | Not a room/session/war-room judge |

### Concrete findings

- `command` is explicitly documented as `command-plane truth`, not an inferred judgment surface.
- `operator digest` is explicitly documented as a translated intervention surface, not a raw truth API.
- `Mission` already has an MODEL judgment layer, but it is snapshot-based, cached for 300s, and designed as narrative rather than control-plane judgment.
- `swarm_status` computes lanes, gaps, blockers, and `recommended_next_action` from snapshot inputs with deterministic functions.
- `operator digest` computes `attention_items` and `recommended_actions` from summary signals and session digests with deterministic filtering and templated messages.
- `Gardener` is a background loop for ecosystem homeostasis and optional MODEL-assisted spawn decisions, not an always-on operator judge.

### Source anchors

- `docs/DASHBOARD-INTEGRATION.md`: `command` is the command-plane truth surface.
- `docs/REMOTE-MCP-OPERATOR.md`: `masc_operator_digest` is an intervention-oriented translated read model.
- `lib/swarm_status.ml`: lane/gap/blocker/recommendation generation is deterministic.
- `lib/operator_control.ml`: room and session `attention_items` / `recommended_actions` are deterministic translations of signals.
- `lib/dashboard_mission_briefing.ml`: `Mission` briefing is MODEL-based, fact-only, and cached.
- `lib/gardener.ml`: `Gardener` is a resident loop for ecosystem management, with optional MODEL-assisted spawn decisions.

## The mismatch

The current system says "operator-first dashboard" but the command/intervene surfaces do not have a canonical live inferred judge.

### What is true today

- The system has live truth.
- The system has derived hints.
- The system has one separate MODEL narrative card in `Mission`.
- The system has a resident loop, but it belongs to `Gardener`, whose job is population management.

### What is missing

- one always-on owner for "what should the operator believe right now?"
- durable judgment records with freshness, evidence, and supersession
- explicit separation between `truth`, `derived fallback`, and `MODEL judgment`
- a single place where humans can see "this was inferred by a model, from these facts, at this time"

### Resulting trust failures

- a derived hint can look like a live judgment
- stale projections can feel current
- cached `Mission` MODEL text can disagree with fresher command truth
- recommendations look authoritative without showing whether they are truth, heuristics, or model inference

## Options considered

| Option | Summary | Trust/evidence | Freshness | Architectural fit | Cost/ops | Verdict |
|---|---|---:|---:|---:|---:|---|
| A. Keep current rules, add better labels | Improve wording only | Low | High | High | Low | Reject |
| B. On-demand MODEL at render time | Judge on page load/request | Medium | Medium | Medium | Medium | Reject |
| C. Resident operator keeper only | Always-on MODEL judge replaces current hints | High | High | High | Medium | Close, but too brittle without fallback |
| D. Resident operator keeper primary + derived fallback | Always-on MODEL judge, truth stays base, heuristics stay explicit fallback | Highest | High | Highest | Medium | Recommend |

### Rejected options

#### A. Keep current rules, just label them better

Rejected because labeling alone does not create a real judgment owner. It improves honesty but does not solve the absence of live inferred supervision.

#### B. On-demand MODEL only

Rejected because it has no continuity, no durable memory of prior judgments, weak operator traceability, and higher risk of flicker between reloads. It also does not behave like a real control-room presence.

#### C. Resident keeper with no fallback

Rejected because the control surface must degrade safely when the model is unavailable, stale, rate-limited, or contradictory. Removing deterministic fallback entirely makes the operator surface fragile.

## Recommended architecture

Choose option D:

- `command-plane snapshot/summary` remains the truth layer
- `operator snapshot` remains the truth-oriented operator state layer
- a new resident `operator/warroom keeper` becomes the canonical judgment producer
- existing `operator digest` and `swarm_status` stay alive as deterministic fallback and compression layers
- `Mission` briefing remains a narrative layer, not the control-plane judge
- `Gardener` remains ecosystem manager only

## Required role split

### 1. Truth layer

Read-only, canonical state:

- command-plane snapshot/summary
- operator snapshot
- trace and session/event history

These surfaces never pretend to be judgments.

### 2. Resident judgment layer

Owned by one long-running keeper, for example `operator-judge` or `warroom-keeper`.

Responsibilities:

- continuously read live truth snapshots
- produce durable judgment records
- revise or supersede prior judgments when newer evidence arrives
- surface confidence, freshness, and evidence
- emit recommended operator actions as judged recommendations, not as raw heuristics

### 3. Deterministic fallback layer

Existing:

- `operator digest`
- `swarm_status`

New role:

- provide fallback when no fresh resident judgment exists
- provide deterministic compression of truth for low-cost reads
- remain visible as `derived`, never as `MODEL judgment`

### 4. Narrative layer

Existing `Mission` briefing remains:

- human-oriented summary
- cached narrative
- not authoritative for command/intervene decisions

### 5. Ecosystem layer

`Gardener` remains:

- spawn/retire decisions
- gap maturity and homeostasis
- never the owner of room/session/operation judgment

## Canonical judgment contract

The resident keeper must write durable `operator judgment` records with this minimum shape:

```json
{
  "judgment_id": "judg-...",
  "target_type": "room | team_session | operation | detachment | lane",
  "target_id": "string | null",
  "surface": "command.warroom | command.swarm | intervene",
  "status": "active | stale | superseded | error",
  "severity": "ok | watch | risk | bad | unclear",
  "summary": "human-facing judgment",
  "confidence": 0.85,
  "generated_at": "ISO-8601",
  "expires_at": "ISO-8601",
  "model_used": "provider:model",
  "keeper_name": "operator-judge",
  "evidence": [
    {
      "kind": "operation | decision | trace | session | message | keeper | alert",
      "ref": "stable id or synthetic key",
      "summary": "brief fact"
    }
  ],
  "recommended_action": {
    "action_type": "optional",
    "target_type": "optional",
    "target_id": "optional",
    "reason": "why",
    "payload_preview": {}
  },
  "fallback_used": false
}
```

### Provenance contract

Every operator-facing recommendation or judgment in the dashboard must expose one of:

- `truth`
- `derived`
- `judgment`
- `fallback`
- `narrative`

This is not optional. A card without provenance should be treated as a design bug.

## UI interpretation rules

### Command / Intervene

- Base rendering starts from truth.
- If a fresh resident judgment exists for the same target, show it as the primary judgment layer.
- If no fresh resident judgment exists, show deterministic fallback labeled `fallback`.
- Never let fallback visually masquerade as `judgment`.

### Mission

- Continue to show the MODEL briefing.
- Label it as `narrative`.
- Do not let it override fresher command/intervene judgments.
- If `Mission` later summarizes resident judgments, it should reference them secondarily rather than become a judgment target itself.

### Swarm / War Room

- `lanes`, `gaps`, `blockers`, and checklist remain valuable, but must be labeled `derived`.
- The resident judge may interpret them, but they are not themselves the final human trust object.

## Freshness and failure policy

### Freshness

- SSE remains freshness transport only.
- The resident keeper must read canonical snapshot endpoints and use events as triggers, not as sole truth.
- Judgments must expire aggressively enough that stale inference cannot survive longer than truth drift.

Default policy:

- `command.warroom` judgments: 30-60s TTL
- `command.swarm` judgments: 2-5m TTL
- `intervene` judgments: 2-5m TTL
- `mission` narrative can keep its existing cache, but must show age clearly

### Failure behavior

- If resident keeper is down or model-unavailable, UI falls back to deterministic derived hints.
- Fallback must set `fallback_used=true` and `provenance=fallback`.
- If truth and judgment disagree, truth remains visible and judgment is marked as disagreement, not silent override.
- Superseded judgments must remain queryable for audit, but not rendered as current.

### Supersession rules

- A newer judgment supersedes an older one only when `target_type`, `target_id`, and `surface` match.
- `active` becomes `superseded` when a fresher successful judgment for the same target/surface is written.
- `error` never supersedes `active`; it only records that a refresh attempt failed.
- `stale` is time-based expiry, not semantic supersession.
- UI renders only the freshest non-superseded judgment per target/surface.

## Why this should be a keeper, not Gardener

`Gardener` already has a resident loop, but it manages ecosystem population and maturity. It decides whether new agents should be spawned or retired. That is a different problem from active room/session/operation judgment.

Using `Gardener` as the war-room judge would collapse two responsibilities:

- ecosystem homeostasis
- real-time operator inference

That would make provenance and failure handling worse, not better.

Therefore:

- keep `Gardener` for ecosystem management
- introduce a separate resident keeper for operational judgment

## Migration sketch

### Phase 1. Make provenance explicit

- label current dashboard cards as `truth`, `derived`, or `narrative`
- stop presenting `operator digest` and `swarm_status` as if they were inferred judgment

### Phase 2. Add resident judgment write path

- add durable judgment storage and read model
- start with room-wide and session-wide judgments
- keep all existing deterministic surfaces unchanged

### Phase 3. Overlay command/intervene with judgment

- war-room and swarm surfaces read truth plus resident judgment
- use resident judgment as primary when fresh
- use deterministic fallback when missing or stale

### Phase 4. Narrow current heuristic responsibilities

- shrink `operator digest` recommendations toward fallback and compression
- keep deterministic summaries for low-cost polling and degraded-mode operation

### Phase 5. Decide whether Mission briefing should consume the same records

- preferred direction: `Mission` may later summarize resident judgments
- but it should remain narrative, not become the source of operational truth

## What this changes conceptually

Today:

- `command` = truth
- `operator digest` = translated hints
- `Mission` = cached MODEL narrative

Target:

- `command` = truth
- `resident operator keeper` = canonical live inferred judgment
- `operator digest` and `swarm_status` = explicit fallback/read-model helpers
- `Mission` = narrative summary of truth plus, optionally later, resident judgments

## Final recommendation

Implement a separate resident `operator/warroom keeper` and treat it as the canonical inferred judgment layer.

Do not overload `Gardener`.
Do not make render-time MODEL calls the main operator brain.
Do not keep mixing truth, heuristics, and MODEL output without provenance.

The winning architecture is:

- truth first
- resident judgment second
- deterministic fallback third
- narrative summary last

That is the smallest change that materially improves human trust.
