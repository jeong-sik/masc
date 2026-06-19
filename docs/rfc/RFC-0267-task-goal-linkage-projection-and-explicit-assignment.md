---
rfc: "0267"
title: "Make task↔goal links visible and explicitly assignable"
status: Draft
created: 2026-06-20
updated: 2026-06-20
author: vincent
supersedes: []
superseded_by: null
related: ["0245"]
implementation_prs: []
---

## 1. Motivation

The task↔goal association is stored in a side registry,
`goal_task_links.json`, managed by `Workspace_goal_index`. Task records carry
no `goal_id` field (`lib/workspace/workspace_task_create.ml:93-107`); the link
lives only in the registry, written by `link_task_to_goal`
(`lib/workspace/workspace_goal_index.ml:131`). A prior boundary refactor
removed the old fallback of deriving links from `task.goal_id`
(`lib/workspace/workspace_goal_index.mli:12-14`): the registry is now the sole
source of truth.

Two gaps follow from that refactor, and both are observable in the live
deployment (base-path `/Users/dancer/me`, server `:8935`, 2026-06-20):

**Gap A — links exist but no surface shows them (display path severed).**
The registry is *not* empty: `~/.masc/tasks/goal_task_links.json` holds real
entries — e.g. `goal-1779348737104-9783 → [task-984..988]`,
`goal-1781235828597-bc8b → [task-954, task-955, task-959, task-1057]` (≥3
goals, ≥9 task links). Yet:

- `GET /api/v1/dashboard/execution` emits its flat task array with **no
  `goal_id` field at all** (verified: 25 tasks, `goal_id` absent on every one).
  The Work board (`dashboard/src/components/work.ts:100,130,204`) nests jobs
  under goals via `tasks.value.filter(t => t.goal_id === goal.id)`, so that
  filter is **always empty** — goal cards show zero jobs and *every* task
  falls into the "미배정 작업" catch-all (`work.ts:283`,
  `unassignedTasks = allTasks.filter(t => !t.goal_id)`), regardless of real
  registry links.
- `GET /api/v1/dashboard/planning` emits 68 goals with **no `linked_tasks`
  field** on the goal objects; total linked tasks surfaced = 0.

The execution serializer (`lib/dashboard/dashboard_execution_builders.ml`)
references goals only as keepers' `active_goal_ids` (line 246), never as a
per-task projection. So the refactor severed `task.goal_id` from the *record*
(correct — the registry is SSOT) but never re-projected it at the
*serialization boundary*, where the Work board still expects it.

**Gap B — links are create-time only (no relink path).** `link_task_to_goal`
is additive and is exported (`workspace_goal_index.mli:60`), capable of linking
any existing `task_id`. But its only callers are the two task-*creation* paths
(`workspace_task_create.ml:118`, `:203`). No MCP tool, HTTP route, or dashboard
action links an already-created task to a goal. A task created goalless — the
default, since the generic create flow has no goal picker — can never be linked
afterward; the only remedy is delete + recreate.

The MCP tool schema previously *claimed* that omitting `goal_id` would
"auto-link a single active goal." That claim was false and was removed in
PR #21653. This RFC specifies the **correct** capability the false claim
gestured at: an *explicit*, operator/agent-driven assignment — never a silent
auto-pick.

## 2. Current state and invariants

- **SSOT.** `goal_task_links.json` is authoritative. Indexes are built on read:
  `build_goal_task_index_for_config` (goal → tasks) and
  `build_task_goal_index_for_config` (task → goals)
  (`workspace_goal_index.mli:68,73`).
- **The registry permits a task under multiple goals** (`build_task_goal_index`
  returns a `string list` per task). The Work board, however, assumes a single
  goal per task (`task.goal_id` equality). This RFC adopts the board's model:
  **a task has at most one goal** ("canonical goal"). The registry's multi-goal
  capacity is treated as legacy/undefined and is not surfaced (see Non-Goals).
- **RFC-0245** exempts `goal_id = None` tasks from the per-goal WIP cap
  (`workspace_task_capacity.ml:37,63`) because goalless tasks share no goal
  scope. Goalless is a *legitimate, intended* state, not an error.
- **No unlink exists.** `delete_task` does not remove registry entries
  (`server_dashboard_http_delete_actions.ml`), leaving dangling task_ids that
  the index-build step silently filters against the live task list.

## 3. Proposal

Two phases. Phase 1 is independently shippable and has immediate value
(it makes *existing* creation-time links visible). Phase 2 is the new
capability requested.

### Phase 1 — Project the canonical goal at the serialization boundary (bug fix)

The `/api/v1/dashboard/execution` task serializer projects a single
`goal_id : string option` per task, derived from
`build_task_goal_index_for_config`:

```ocaml
(* read-time projection only; the task RECORD stays goal_id-free (SSOT = registry) *)
let canonical_goal_id task_goal_index task_id =
  match Hashtbl.find_opt task_goal_index task_id with
  | None | Some []      -> None
  | Some (goal_id :: _) -> Some goal_id   (* deterministic: first registry match *)
```

- The wire field is `goal_id` (matching the FE `Task` type the board already
  reads), present-as-`null` when unlinked.
- When a task maps to >1 goal (legacy multi-goal registry rows), the first
  match is chosen deterministically and a `WARN` is logged with both ids, so
  the single-goal invariant violation is visible rather than silent.
- No FE change required: `work.ts` already groups by `task.goal_id`. Once the
  field is populated, goal cards nest their jobs and "미배정 작업" narrows to
  genuinely unlinked tasks.

This re-establishes a wire projection the refactor dropped; it does **not**
re-couple the record to `goal_id`.

### Phase 2 — Explicit assignment operation (new capability)

A new MCP tool plus its HTTP/FE surface, linking a **currently-goalless** task
to a goal. Total and explicit; never an auto-pick.

**Backend.** A new `Workspace.set_task_goal` wrapping the existing writer:

```ocaml
val set_task_goal :
  config -> task_id:string -> goal_id:string -> (unit, set_task_goal_error) result

type set_task_goal_error =
  | Unknown_task            (* task_id not in backlog *)
  | Unknown_goal            (* goal_id not in Goal_store *)
  | Already_linked of string (* task already has a goal; reassignment is a Non-Goal (v1) *)
```

Behaviour: validate `task_id` exists; validate `goal_id` exists in the goal
store (mirroring the add-task validation at
`lib/task/tool_task_handlers.ml:290-304`); reject if the task is already linked
to any goal (`build_task_goal_index_for_config` lookup non-empty); otherwise
call `link_task_to_goal`. Every failure is a typed `Error` — no silent no-op,
no "pick a goal for them."

**MCP tool** `masc_task_set_goal` (`lib/task/tool_task_schemas.ml` +
`tool_task_handlers.ml`):

```
masc_task_set_goal
  task_id  (required, string)
  goal_id  (required, string; validated against the goal store; unknown → error)
```

Both fields required. Omitting `goal_id` is a schema error, *not* an auto-pick —
this is the deliberate inverse of the removed #21653 claim.

**HTTP + FE.** Expose via the same FE→tool path `createTask` already uses
(`dashboard/src/components/.../task-manage-state.ts:17-38` → `masc_add_task`),
adding the sibling task mutation route. The Work board's "미배정 작업" section
(`work.ts:283`) gains a per-row "goal에 배정" control: a picker of active goals
that calls `masc_task_set_goal`, then refreshes `['goals','execution']`.

**WIP-cap interaction (RFC-0245).** Once linked, the task has a `goal_id` and
correctly enters the per-goal WIP bucket on its *next* claim — consistent with
RFC-0245 (the exemption is for genuinely goalless tasks; a now-scoped task
should participate in collision backpressure). The cap is evaluated at claim
time, so linking an in-progress task does not eject it.

## 4. Non-Goals

- **Auto-link / inferred goal.** Explicitly rejected — re-introduces the
  "Unknown → permissive default" anti-pattern removed in #21653.
- **Reassign an already-linked task (move A→B) and unlink-to-goalless.** v1
  rejects already-linked tasks (`Already_linked`). A true move needs the
  missing unlink writer; deferred to a Phase 3 follow-up. Goalless remains a
  valid state, so "unlink" is meaningful but not urgent.
- **Multi-goal-per-task display.** The board's single-goal model is adopted;
  surfacing a task under multiple goals is out of scope.
- **Fixing `delete_task`'s dangling registry entries.** Real but separate;
  tracked independently. (The Phase 3 unlink writer would also serve it.)
- **Forcing every task to carry a goal_id.** Per RFC-0245 §3, out of scope.

## 5. Verification

Phase 1:
- `dashboard_execution` test: a task linked in the registry serializes with the
  correct `goal_id`; an unlinked task serializes `goal_id: null`.
- multi-goal legacy row → deterministic first id + WARN emitted.
- FE `work.test.ts`: with a populated `goal_id`, a job nests under its goal card
  and is absent from "미배정 작업" (extends the existing unassigned-section
  tests).

Phase 2:
- `set_task_goal` returns `Ok` and writes the registry for a goalless task;
  `build_task_goal_index_for_config` then reports the link.
- `Unknown_task`, `Unknown_goal`, `Already_linked` each return the typed
  `Error` (no registry mutation).
- tool-schema test: `masc_task_set_goal` with `goal_id` omitted is a schema
  rejection (proves no auto-pick path exists).
- end-to-end: create goalless task → `masc_task_set_goal` → `/execution` emits
  the `goal_id` (Phase 1 projection) → board nests it under the goal.

## 6. Risk

- **Projection cost (Phase 1).** One `build_task_goal_index_for_config` per
  execution payload (already built elsewhere, e.g. `dashboard_goals.ml:73`);
  reuse the same index. O(k) lookups, negligible.
- **Single-goal invariant vs. multi-goal registry.** Legacy rows linking a task
  to >1 goal are possible. Mitigation: deterministic first-match + WARN
  (Phase 1) and `Already_linked` rejection (Phase 2) prevent *new* multi-goal
  states; a one-time registry audit can be a follow-up if WARNs appear.
- **Operator over-assignment.** Bounded by the same goal/repo/category caps at
  claim time; assignment itself does not bypass any gate.

## 7. Relationship to prior work

- **RFC-0245** establishes goalless as intended and exempt from the per-goal
  cap. This RFC does not change that: it adds an *explicit* path *out of*
  goalless, and a now-linked task re-enters the cap as RFC-0245 intends.
- **PR #21653** removed the false auto-link schema claim. This RFC supplies the
  real, explicit capability — closing the gap honestly rather than by silent
  default.
- **PR #21645** made the Work board render goals and an unassigned section.
  This RFC explains why that section currently catches *all* tasks (Gap A) and
  fixes the underlying projection so it catches only genuinely unlinked ones.
