---
status: proposal
last_verified: 2026-04-19
code_refs:
  - lib/keeper/keeper_accountability.ml
  - lib/reputation.ml
  - lib/economy/economy.ml
  - lib/dashboard/dashboard_http_keeper.ml
  - docs/DASHBOARD-INTEGRATION.md
---

# Accountability and Reputation V2 Roadmap

**Status**: Draft roadmap for `task-074`  
**Date**: 2026-04-19  
**Scope**: Define the next-stage design for accountability, reputation, and their operator-facing surfaces without turning them into premature public rankings or hard scheduler gates.

## Related Documents

- `../DASHBOARD-INTEGRATION.md`
- `../rfc/RFC-0001-det-nondet-boundary-harness.md`
- `../OAS-MASC-BOUNDARY.md`
- `../VERSIONED-ROADMAP.md`

## 1. Why This Document Exists

MASC already has three separate v1 pieces:

- `keeper_accountability`: a 14-day operator risk summary derived from claim/resolution history
- `agent_reputation`: a lightweight score computed from task completion, mention response, and board activity
- `agent_economy`: an optional reward multiplier that can consume a reputation score

Those pieces are individually useful, but they are not yet a coherent system.
The current state is good enough for operator triage, but not strong enough for broader routing, economy, or public-facing interpretation.

This roadmap exists to make the next steps explicit:

- what stays operator-only
- what can graduate into stronger decision signals
- what data model changes are required
- what rollout risks must be controlled before promotion

## 2. Current V1 Baseline

### 2.1 Accountability today

Current source of truth:

- ledger: `.masc/accountability/YYYY-MM/DD.jsonl`
- summary builder: `Keeper_accountability.accountability_summary_json`
- dashboard exposure: `lib/dashboard/dashboard_http_keeper.ml`

Current behavior:

- summary window is fixed at 14 days
- output fields are `task_followthrough_rate`, `evidence_coverage`,
  `unsupported_completion_rate`, `open_overdue_commitments`,
  `recent_supported_claims`, `risk_band`, `routing_hint`, and recent `history`
- `routing_hint` is an operator advisory, not a hard block
- synthetic lifecycle support and explicit completion claims are separated

Current gaps:

- evidence is mostly counted, not weighted
- no contest or appeal path exists
- no peer verification model exists
- no anti-gaming protections beyond existing operational discipline
- the dashboard read path has already shown performance risk in the PR7162 follow-up lane

### 2.2 Reputation today

Current source of truth:

- implementation: `lib/reputation.ml`
- no dedicated storage; computed from existing `.masc/` task, mention, and board data

Current formula:

- completion rate weight: `0.4`
- mention response rate weight: `0.3`
- board activity weight: `0.3`
- board activity cap: `20`

Current gaps:

- weights are fixed constants, not governance-managed parameters
- score ignores evidence quality, task difficulty, decay, and challenge history
- score is easy to over-interpret as a global quality signal when it is really a coarse engagement/result proxy

### 2.3 Economy linkage today

Current source of truth:

- `lib/economy/economy.ml`

Current behavior:

- when `MASC_ECONOMY_REPUTATION_MULTIPLIER` is enabled, reward amount is scaled by a `0.5x-1.5x` multiplier derived from reputation score

Current gap:

- economy coupling exists before v2 calibration exists, so v2 should not expand this linkage until the underlying reputation/accountability signals are better governed

## 3. V2 Design Principles

1. Accountability stays evidence-first.
2. Reputation is not a public leaderboard.
3. Routing remains advisory until calibration proves otherwise.
4. Economy linkage must lag behind evidence quality, not lead it.
5. Anti-gaming and appeal paths are product features, not cleanup chores.
6. Additive schema evolution beats in-place rewrite of historical JSONL.

## 4. Non-Goals

The v2 roadmap explicitly does **not** aim to ship these on day 1:

- public keeper rankings
- automatic claim bans based on `risk_band`
- irreversible reputation penalties without appeal
- peer voting directly feeding reward logic
- hidden magic-number tuning without audit trail

## 5. Phased Roadmap

### Phase 0. Stabilize the Operator Surface

Goal: make the current operator-only read model reliable enough to trust as a baseline.

Scope:

- remove repeated dashboard scan costs from accountability summary paths
- keep synthetic vs explicit claim semantics documented and testable
- add read-model regression coverage for operator projections
- record baseline distributions for:
  - `evidence_coverage`
  - `unsupported_completion_rate`
  - `open_overdue_commitments`
  - number of explicit vs synthetic completions

Deliverables:

- stable operator docs and tests for the current summary contract
- performance guard for the dashboard accountability path
- baseline metric artifact for later calibration

Exit criteria:

- operator can explain every field without reading code
- dashboard hot path is regression-tested
- summary cost is bounded enough to run continuously

Primary risk:

- promoting a read path that is still expensive or semantically unstable will make later policy debates noisy and untrustworthy

### Phase 1. Evidence Model and Weighting

Goal: move from raw counts to a typed evidence model without breaking the current ledger.

Scope:

- define evidence classes such as:
  - task artifact
  - test proof
  - review verdict
  - operator acknowledgment
  - synthetic lifecycle support
- introduce explicit weighting policy for summary math
- keep weighting rules in a governance-visible parameter registry, not buried constants
- separate "support exists" from "support is strong"

Proposed additive fields:

- `evidence_items[]`
- `evidence_kind`
- `evidence_strength`
- `resolver_origin`
- `support_mode` (`explicit`, `synthetic`, `peer`, `operator`)

Exit criteria:

- weighted evidence rules are documented and reproducible
- test fixtures prove synthetic support cannot silently dominate explicit proof
- parameter changes are auditable

Primary risk:

- if weighting ships without traceable rationale, v2 becomes a more complex version of the same arbitrary system

### Phase 2. Decay, Recovery, and Task-Mix Fairness

Goal: prevent old failures or easy-task streaks from permanently distorting operator judgment.

Scope:

- add time decay to reputation and accountability aggregates
- separate task difficulty from agent quality
- treat repeated release/failure patterns as task difficulty inputs before turning them into permanent reputation penalties
- add rehabilitation-oriented reads for agents emerging from a failure streak

Proposed additive fields:

- `decay_bucket`
- `difficulty_score`
- `freshness_weight`
- `rehabilitation_state`

Exit criteria:

- a stale bad week no longer dominates a current healthy week
- hard tasks stop poisoning reputation as if they were low-effort misses
- operators can distinguish "difficult task lane" from "weak evidence lane"

Primary risk:

- bad decay choices can hide real problems or create cold-start favoritism

### Phase 3. Anti-Gaming and Peer Verification

Goal: make the system robust before it becomes more consequential.

Scope:

- add structured peer verification as an audit-only signal first
- forbid self-acknowledgment and cap repeated same-peer boosting
- record suspicious reinforcement patterns for review
- treat peer verification as supporting context, not final truth

Contestable scenarios to handle:

- mutual-upvote or mutual-ack loops
- low-quality high-volume board activity
- synthetic lifecycle support used as a substitute for real evidence
- repeated explicit done claims without attached artifacts

Proposed additive fields:

- `peer_review_state`
- `peer_review_count`
- `challenge_flag`
- `gaming_signals[]`

Exit criteria:

- peer signals are visible in operator tooling
- collusion-style patterns are detectable
- no peer-derived score affects routing or rewards before calibration

Primary risk:

- peer verification without anti-gaming controls will create social proof theater instead of trustworthy evidence

### Phase 4. Contest and Appeal Flow

Goal: add due process before stronger automation or incentives.

Scope:

- define how a keeper or operator contests a resolution
- define appeal states and ownership
- keep case details private to operator/governance surfaces
- add reversible transitions instead of one-way punishment

Proposed entities:

- `challenge_id`
- `appeal_id`
- `case_status`
- `adjudication_notes`
- `final_resolution_source`

Exit criteria:

- contested cases can be reviewed without editing raw JSONL by hand
- unsupported or partial judgments can be corrected with an explicit audit trail
- public surfaces never expose sensitive operator notes or reputational accusations

Primary risk:

- without appeal, stronger routing/economy signals become politically brittle and hard to trust

### Phase 5. Graduated Routing and Economy Linkage

Goal: let v2 influence higher-stakes decisions only after the previous phases are stable.

Scope:

- keep `routing_hint` advisory first, then graduate to stronger routing only for well-calibrated cases
- do not widen economy coupling beyond the existing legacy multiplier until:
  - evidence weighting is stable
  - decay is calibrated
  - anti-gaming guards are live
  - contest/appeal exists
- if economy linkage remains enabled, cap its influence and publish the rationale

Promotion gates:

- weighted evidence precision is stable on a golden set
- peer verification is still audit-only or demonstrably robust
- contest/appeal operational load is manageable
- no unresolved public/private boundary leak remains

Primary risk:

- reward coupling amplifies every hidden modeling mistake and invites optimization pressure before the system is ready

## 6. Data Model Evolution

V2 should evolve the current storage additively.
Do not rewrite old accountability rows in place.

| Area | V1 shape | V2 additive direction | Compatibility rule |
|---|---|---|---|
| Accountability claim | `claim_created` / `claim_resolved` with `evidence_refs`, `synthetic`, `reason` | add typed evidence items, support mode, challenge/appeal linkage, decay metadata | old rows remain readable; missing fields mean v1 semantics |
| Reputation summary | computed from tasks/mentions/board activity only | add decay-aware windows, difficulty context, explicit evidence quality inputs | keep current score path until calibration is ready |
| Dashboard projection | operator compatibility payload | add richer operator-only metadata behind explicit projection fields | never promote private fields into public summary by accident |
| Economy linkage | optional legacy multiplier | keep legacy path isolated; do not tie new v2 fields directly until Phase 5 | legacy behavior stays possible, but new v2 semantics are opt-in |

Recommended migration rule:

- new writer emits additive nullable fields
- new reader accepts both v1-only and v2-enriched records
- promotion from advisory to consequential behavior requires an explicit feature flag

## 7. Private vs Public Surface Boundary

This boundary must be explicit in v2.

Operator/private surfaces may show:

- `risk_band`
- `routing_hint`
- challenge and appeal status
- evidence mix details
- peer review anomalies
- adjudication notes

Public or broad-consumption surfaces must not show:

- raw challenge allegations
- operator-only rationale notes
- per-agent punitive labels
- any leaderboard that implies a universal score ordering

Rule:

- accountability remains an operator risk summary
- reputation remains a bounded internal signal unless a separate public product requirement is approved

## 8. Rollout Risks

### 8.1 Performance risk

If accountability remains expensive to compute, operators will stop trusting freshness and teams will disable the surface under load.

### 8.2 Incentive risk

If economy linkage grows faster than evidence quality, agents will optimize for the score instead of the work.

### 8.3 Social risk

If peer verification is visible before anti-gaming controls, cliques can manufacture legitimacy.

### 8.4 Governance risk

If there is no appeal path, unsupported claims become effectively irreversible policy judgments.

### 8.5 Boundary risk

If operator-only fields leak into public or semi-public surfaces, the system creates reputational harm from signals that were never designed to be public truth.

## 9. Recommended First Implementation Slice

The first slice after this document should be intentionally narrow:

1. finish the accountability read-path stabilization follow-up
2. keep accountability operator-only
3. add a typed evidence model proposal and tests
4. defer peer verification, appeal, and stronger economy coupling until calibration artifacts exist

That order gives v2 a trustworthy base instead of expanding influence before the core signal is stable.
