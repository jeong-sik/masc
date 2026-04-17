---
status: live
last_verified: 2026-04-17
code_refs:
  - lib/keeper/
  - lib/keeper/keeper_turn_lifecycle.ml
  - lib/mcp_server.ml
---

# MASC Capsule Execution Plan

Updated: 2026-04-02
Scope: `masc-mcp` only

This document is the execution companion for work that stays inside the
`masc-mcp` capsule.

We are the middle layer between:

- OAS, which provides agent-runtime primitives
- agent clients such as Claude Code, Codex, and Gemini
- the human operator who uses those agent clients
- the current development session maintaining MASC itself

The product only works if these layers can trust the same coordination truth.

## Product Thesis

`masc-mcp` is not just “an MCP server with many tools”.

Inside this capsule, MASC should behave like a coordination operating system for
persistent repo-local agent society:

- agents join a shared room
- agents claim work and leave observable ownership
- agents can be orchestrated as a team session or swarm
- operator and dashboard surfaces can inspect what happened
- proof and report artifacts can reconstruct the collaboration after the fact

OAS remains the agent runtime layer underneath that system.

## Boundary Rules

Keep these rules hard:

1. OAS owns reusable execution primitives.
2. MASC owns room, task, team-session, proof, operator, and governance semantics.
3. If a bridge is lossy, fix the MASC adapter first.
4. Only ask OAS for changes when the new shape is generic for non-MASC consumers.
5. MCP truth, persisted truth, dashboard truth, and proof truth must agree.

## What Stays In MASC

- team-session planning and worker-role semantics
- delegate readiness and routing policy
- room/task lifecycle and social runtime invariants
- proof/report contracts and evidence references
- operator workflows, diagnosis bundles, intervention surfaces
- dashboard read models and coordination-specific telemetry

## What Can Move Upstream To OAS

Only propose upstream work when it is clearly reusable:

- richer generic swarm entry metadata
- generic structured health-probe callbacks
- reusable harness/result/verdict primitives

Do not upstream:

- MASC delivery-contract semantics
- room/board/governance concepts
- team-session proof/report JSON contracts

## Execution Order

### 1. Truth Spine

Unify the truth exposed by:

- MCP status tools
- persisted `.masc/` artifacts
- dashboard read models
- operator snapshots

If these disagree, the product is not trustworthy.

### 2. Team Session Fidelity

Make `team_session` the strongest advanced workflow in the product:

- truthful delegate readiness
- less-lossy worker/session projection
- explicit runtime/model/tool visibility
- strong failure reasons when orchestration blocks

### 3. Proof and Evidence

Every important team action should leave reconstructable evidence:

- who acted
- what runtime/model/tool surface was used
- what was requested
- why it succeeded or failed

### 4. Operator Surfaces

Operators should be able to diagnose a failing session without guessing:

- blocked reasons
- runtime-health truth
- evidence availability
- intervention safety

### 5. Social Runtime Invariants

Treat these as tested product contracts, not conventions:

- no double-ownership confusion
- no invisible in-flight workers
- no delegate-to-broken-worker path
- no proof/report state that contradicts runtime history

## Immediate Slices

### Slice A. Delegate-Readiness Contract

Goal:

- status surfaces tell the truth about which workers are actually safe to delegate to
- delegate failures explain the blocked reason and guidance
- denial leaves an event trail

Primary modules:

- `lib/team_session/team_session_engine_status.ml`
- `lib/tool_team_session_step.ml`
- `lib/tool_team_session_step_exec.ml`
- `test/test_tool_team_session_step_routing.ml`
- `test/test_tool_team_session_misc.ml`

Done when:

- checkpoint-only workers are not misreported as delegate-ready
- in-flight workers are visibly blocked
- delegate denial says why, not just “not ready”

### Slice B. Worker-Proof Read Model

Goal:

- status, proof, and dashboard all surface the same worker-run evidence summary

Primary modules:

- `lib/team_session/team_session_report_proof.ml`
- `lib/dashboard/dashboard_proof.ml`
- `lib/team_session/team_session_store.ml`

Done when:

- worker proof metadata can be traced from session status to proof views
- missing evidence is distinguishable from unavailable evidence

### Slice C. Runtime / Model Visibility

Goal:

- operator can answer “which worker ran where, with what model, under what tool surface?”

Primary modules:

- `lib/team_session/team_session_oas_bridge.ml`
- `lib/team_session/team_session_engine_status.ml`
- `lib/tool_team_session_step_exec.ml`

## Review Gate

When a change touches the team-session or swarm contract, the review question is:

“Did this make MASC more trustworthy as the coordination layer, or did it only
make the runtime path work?”

If the answer is only the latter, the change is incomplete.
