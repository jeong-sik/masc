---
rfc: "0245"
title: "Exempt goalless tasks from the per-goal WIP claim cap"
status: Withdrawn
created: 2026-06-15
updated: 2026-07-04
author: vincent
supersedes: []
superseded_by: null
related: ["0034", "0067", "0124", "0153"]
implementation_prs: []
---

## 0. Withdrawal

This draft is withdrawn in favor of PR #23158. The chosen direction is to
retire the keeper WIP cap gate entirely instead of preserving that gate with a
special goalless-task exemption.

The live claim contract after PR #23158 is:

- keeper-visible claims resolve goal scope through the runtime contract;
- `Workspace.claim_next_r` accepts a generic `task_filter` plus explicit
  `allow_scope_fallback` reporting;
- no keeper claim path performs a per-goal/goalless WIP-cap decision.

## 1. Motivation

Historically, the keeper WIP-cap gate guarded `keeper_task_claim` with four
caps (`default_caps`): global 16, per-repo 6, **per-goal 3**, per-category 4.
Its purpose was to prevent active WIP scope collisions: stop multiple keepers
from working the **same goal/repo** at once (merge conflicts, duplicated work).

The per-goal cap buckets active WIP by `goal_key`:

```
goal_key = function
  | Some goal_id -> Printf.sprintf "goal:%s" (normalize goal_id)
  | None         -> "goal:<none>"
```

Tasks with **no** `goal_id` all fall into a single `goal:<none>` bucket and
compete for `max_per_goal = 3` slots **fleet-wide**. But goalless tasks share
no goal scope, so there is no collision to prevent — the cap's stated purpose
does not apply. The result is starvation: once 3 unrelated goalless tasks are
`Claimed`/`InProgress`, **no keeper can claim any other goalless task**.

### Live evidence (2026-06-15)

`masc_status` (hub, authoritative):

```
tasks active=5 todo=2 claimed=0 in_progress=3
task-1232 in_progress keeper-executor-agent   (goalless)
task-1236 in_progress keeper-garnet-agent      (goalless)
task-1238 in_progress keeper-mad-improver-agent (goalless)
```

A claim of a goalless todo (e.g. task-1230/1231) is rejected with
`goal_cap current=3 limit=3 scope=goal:<none>`. The count is **correct** and
read from the live backlog (`Workspace.get_tasks_raw` →
`(read_backlog config).tasks`), not from any cache or Memory OS fact — a
keeper-board claim to the contrary was refuted by code-trace + live API.

The cap is doing exactly what it was coded to do; the defect is that the
goalless bucket should never have been a per-goal collision group.

## 2. Proposal

This proposal is no longer the accepted implementation direction; see
§0. The historical proposal was:

Exempt the `goal_id = None` case from the per-goal cap. The global, per-repo,
and per-category caps continue to apply to goalless WIP, so blast-radius
backpressure is retained.

`decide` change (pure function, single site):

```ocaml
let goal_cap_check =
  match scope.goal_id with
  | Some _ -> reject_if_at_cap Goal_cap (goal_key scope.goal_id) goal_count caps.max_per_goal
  | None   -> None  (* goalless tasks share no goal scope to collide on *)
in
```

Exhaustive `Some`/`None` match (no catch-all), per the FSM/match discipline in
`software-development.md`.

## 3. Non-Goals

These were the non-goals of the withdrawn proposal:

- Changing the per-goal cap **value** (3) or making it config-driven — separate.
- Per-keeper (vs fleet-wide) WIP accounting — separate; this RFC keeps the
  existing fleet-wide semantics for the caps that still apply.
- Forcing every task to carry a `goal_id` (which would also eliminate the
  `<none>` bucket) — a larger process change, out of scope.

## 4. Verification

The withdrawn proposal expected dedicated WIP-cap unit coverage for:

- `goalless task exempt from goal cap` — `max_per_goal=1`, one goalless active
  item, goalless claim **admits** (would reject pre-change).
- `goalless tasks never goal-capped` — three goalless active items in distinct
  repos/categories, goalless claim **admits** (only the goal cap could fire).
- `goalless still bounded by global cap` — `max_global=1`, goalless claim is
  still **rejected by `global_cap`** (proves the exemption is goal-cap-scoped,
  not a removal of all caps).

Regression guard: the existing `rejects goal cap` test (goal-scoped claim at
`max_per_goal`) still rejects, proving the per-goal cap remains active for
real goals.

## 5. Risk

A keeper could accumulate many goalless `InProgress` tasks (now bounded only by
global 16 / repo 6 / category 4). That is the intended trade: goalless tasks
have no shared scope, so concurrency among them is safe w.r.t. the collision
hazard this gate exists to prevent. If unbounded goalless WIP becomes a real
problem, a per-keeper goalless cap (Non-Goal above) is the follow-up.
