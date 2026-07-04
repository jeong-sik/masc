Claim Filter Design
===================

## Objective

Prevent keepers from claiming work they cannot safely execute, especially
code-repo tasks claimed by design, monitoring, or offline-oriented keepers.
The target failure modes are anti-patterns #4 (claim-chain), #5 (false
force-release), #8 (re-claim cycle), and #11 (meta-anti-pattern).

This is a future admission-control design, not a provider/OAS behavior change.

## Current Anchors

The claim path already has useful gates:

- `lib/keeper/keeper_tool_task_runtime.ml` handles keeper-visible
  `keeper_task_claim` and applies goal scope before calling workspace claim
  functions.
- `lib/keeper/keeper_runtime_contract.ml` resolves `active_goal_ids` into a
  claim `task_filter`, with explicit fallback reporting when scope widens.
- `lib/workspace/workspace_task_schedule.mli` exposes `claim_next_r` with
  `task_filter` and `allow_scope_fallback`.
- `lib/task/tool_task_handlers.ml` handles the generic MCP claim/claim-next
  surfaces and must stay consistent with the keeper-visible path.
- `Masc_domain.task` already carries `files`, `contract`, `created_by`,
  `handoff_context`, and reclaim fields. It does not have a production
  `required_tools` field; that field was removed after fan-in/fan-out was 0.

## Rule Set

### 1. Claim Profile

Each keeper should have a derived claim profile from existing metadata:

- `tool_access` and `tool_denylist`
- `allowed_paths`
- `active_goal_ids`
- `persona`, `goal`, and instruction text
- sandbox/network profile

The profile is an operator-facing explanation as well as a gate input. It
should answer: "what work can this keeper execute without handoff?"

### 2. Task Affordance

Each task should get a derived affordance from existing task fields before a new
persisted schema field is added:

- `files` paths and repo scope
- linked goal IDs from `Workspace_goal_index`
- contract evidence and verification gates
- title/description keywords as weak hints only
- handoff/reclaim metadata when a task has bounced

Keyword matching alone is not authoritative. It may rank or explain, but it
must not be the only gate for code-vs-non-code assignment.

### 3. Claim Gate

A claim is admitted only when both are true:

- the task is in the keeper's current goal scope, including any explicitly
  logged scope fallback
- the keeper profile has execution capability for the task affordance

For code tasks, capability means enough repo/file access and action tools to
read, edit, test, and publish or hand off. A read-only or design-only keeper can
comment, route, write a spec, or create a follow-up task, but should not claim
implementation work by default.

Design keepers do not get a blanket cross-domain exception. Their default
cross-domain action is triage/routing; implementation claim requires either a
matching goal/capability profile or an explicit operator override.

### 4. Bounce Guard

Track claim denials and release/reclaim bounces per `(keeper, task)` and
`(task, affordance)` window. After repeated mismatch or hot-potato movement,
the next claim should reject with a structured workflow rejection that includes:

- rejected keeper
- task ID and derived affordance
- missing capability or scope reason
- recommended next action (`comment`, `handoff`, `ask operator`, or `override`)

This should be visible in dashboard and board evidence, not only in logs.

### 5. Operator Override

Operators can override the gate, but the override must be explicit and durable:

- task ID
- keeper name
- reason
- expiry or one-shot semantics
- evidence link or board post

An override should bypass the gate for the named claim only. It must not teach
the classifier that the keeper permanently owns the domain.

## Implementation Sketch

Prefer a small pure module first, then wire it into both claim surfaces:

- New module candidate: `lib/keeper/keeper_claim_filter.ml`
- Inputs: `keeper_meta`, `Masc_domain.task`, task-goal index
- Output: `Admit | Reject of workflow_rejection_payload`
- Keeper path: call it in `lib/keeper/keeper_tool_task_runtime.ml` after goal
  scope resolution and before either explicit or next-task claim.
- Generic MCP path: keep `lib/task/tool_task_handlers.ml` behavior aligned, or
  document why that surface intentionally bypasses keeper-profile admission.
- Scheduling path: keep using `Workspace.claim_next_r` filters; do not move
  keeper-specific policy into `Workspace` unless the policy is expressed as a
  generic `task_filter`.

## Tests

- pure unit tests for keeper profile derivation
- pure unit tests for task affordance derivation
- explicit code-task claim rejected for read-only/design keeper
- matching code keeper admitted for the same task
- design keeper can route/comment but cannot claim implementation by default
- explicit operator override admits only the named keeper/task pair
- repeated bounce returns structured workflow rejection, not a generic invalid
  transition
- regression check that `active_goal_ids` scope and scope-fallback observation
  still run before or alongside claim-affordance rejection

## Non-goals

- No OAS/provider/model changes.
- No resurrection of `required_tools`.
- No keyword-only task router.
- No broad "design keeper may claim anything" exception.

---

Author: rondo (design/flow keeper)
Board post: p-bcc9faf2
Related: task-1127, task-1129, task-1131
