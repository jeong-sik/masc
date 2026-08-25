---
rfc: "0362"
title: "Goal owner and the intake contract"
status: Draft
created: 2026-08-05
updated: 2026-08-05
author: vincent
supersedes: []
superseded_by: null
related: ["0267", "0245", "0357"]
---

## 1. Motivation

A Goal cannot name who is responsible for it, so nobody turns a Goal into
Tasks.

Measured on the live workspace (base path `/Users/dancer/me`, 2026-08-05):

```
goals.json                     15 goals — executing 10, completed 4, blocked 1
owner/assignee/responsible     no such field on the goal record
executing goals with a task    0 of 10
keepers with active_goal_ids   0 of 8
goal_events.jsonl              12 lines, entire history
```

The ten executing Goals have produced no Task between them. The only
keeper-side pointer, `keeper_meta.active_goal_ids`, is empty for every keeper.

Work still enters the system, but through one accident:

```
tasks/backlog.json     169 tasks
  kidsnote    121  (74 done, 47 cancelled)   72%
  lane-smith   19
  other 10 actors combined  29
created per day        07-29: 104 · 07-30: 23 · 08-03: 16 · 08-04: 11 · 08-05: 0
```

`kidsnote` is 72% of all intake, and its config is the only one that looks
outward (`제품과 프로젝트의 실제 사용 흐름을 점검`, `Github ... deployment
상태를 확인`). That is a property of one keeper's instructions, not of the
system's design. When that keeper went quiet, intake went to zero, and 47 of
its tasks expired unclaimed.

Everyone else is a consumer of a queue nothing fills. The observable
consequences were measured separately and are already recorded: 11,316 reads
against 5 creations over two months, a keeper posting the same unchanged
status 26 times in 4.7 hours (#26861), 23 of one keeper's 29 stored memory
facts being board snapshots written in place of work, and keepers writing
rules that narrow their own scope (#26862).

## 2. What already exists

- **`Goal`** (`lib/goal/goal_store.ml:9`) —
  `{ id; title; metric; target_value; due_date; priority; phase;
  parent_goal_id; last_review_note; last_review_at; created_at; updated_at }`.
  No owner.
- **`masc_goal_upsert`** accepts `id, title, metric, target_value, due_date,
  priority, parent_goal_id`. No owner.
- **`masc_goal_list`**, **`masc_goal_transition`** — read and phase change.
- **`keeper_meta.active_goal_ids`** — a keeper-side list, and **not a dead
  field**. 113 files carry 360 references. Beyond the dashboard renderers it
  drives behavior: `Keeper_goal_assignment_wake` (RFC-0315 P3 W0) enqueues a
  `Keeper_event_queue.Goal_assigned` stimulus for each id that newly enters the
  list and signals the keeper's Running lane, with edge semantics that fire only
  on additions; `Keeper_goal_reconciliation_wake` is its sibling. It is also
  read by `keeper_unified_prompt` (`<available_goals>` and `### Active Goals`),
  `keeper_world_observation`, the board-attention `keeper_context`, the TOML
  parser, and the four `keeper_turn_up` modules.

  Its emptiness on the live workspace (0 of 8 keepers) means **nobody assigns**,
  not that nobody reads.
- **Task↔Goal linkage** is solved and shipped (RFC-0267, PRs #21704/#21722):
  `masc_task_set_goal`, `POST /api/v1/dashboard/tasks/assign-goal`, and the
  `goal_id` projection on `/execution`. This RFC does not revisit that axis.

## 3. The failure this RFC must not repeat

A field is not a contract. The contract is the sentence some code path says to
the owner, and the evidence that the path runs. `goal.owner` shipped without a
consumer would be a value the dashboard draws and nothing acts on.

The first draft of this section named `active_goal_ids` as that precedent and
was wrong: it reads behavior, not just pixels (§2). The correction does not
weaken the rule, it sharpens what the rule is about — **a field earns its place
from the path that reads it, and the claim that no such path exists has to be
measured, not assumed.** The measurement that produced the false claim was a
single grep whose hits happened to be dashboard files.

## 4. Proposal

Three parts, shipped together. Any two without the third is the failure in §3.

### 4.1 `goal.owner : string option`

On the Goal record, not on the keeper. A Goal is the thing that has an owner;
a keeper's list of goals is a projection of that, derivable on read the same
way `build_task_goal_index_for_config` derives task→goal.

`None` is legitimate and is the default: an unowned Goal is a stated intent
nobody has picked up, which is a real and reportable state — not an error.

### 4.2 `masc_goal_assign`

```
masc_goal_assign
  goal_id  (required)
  owner    (required; validated against the keeper registry; unknown -> error)
```

Both required. Omitting `owner` is a schema error, never an auto-pick. This
mirrors RFC-0267 §Phase 2 deliberately: that RFC records that the earlier
`masc_add_task` schema falsely claimed to "auto-link a single active goal",
and #21653 removed the claim rather than implementing the guess.

Reassignment and unassignment are in scope (an owner who cannot continue must
be able to hand the Goal back); `Already_owned` is not an error, the transition
is recorded in `goal_events`.

### 4.3 The consumer — one path, and it must be named here

The owner's turn states the Goal and asks for its next Task. Concretely: the
turn assembly that already renders `Current Goal` sections gains, for a Goal
this keeper owns whose phase is `executing`, the fact that **no Task is
currently linked to it** — which is exactly the measurement in §1 (0 of 10) and
is already computable from `build_goal_task_index_for_config`.

That is the whole consumer. It states a fact the owner is positioned to act on.
It does not add a gate, a cap, or a required action, and it names no empty case
(see #26901: naming the empty branch is what produced the flood it replaced).

**Acceptance:** a Goal with an owner and no linked Task must be observable in
that owner's turn, demonstrated on the live workspace by the count in §1
moving off 0. If it does not move, this RFC failed and the field should be
removed rather than kept as decoration.

## 5. Non-goals

- **No auto-assignment.** Nothing picks an owner for a Goal.
- **No required action.** The owner is told the state; whether to create a Task
  is judgment. RFC-0357 was withdrawn (2026-08-04) precisely because admission
  gating was the wrong lever and supply was the real problem; this RFC does not
  reintroduce a gate.
- **No multi-owner.** One owner or none. If shared ownership is needed later,
  sub-goals via `parent_goal_id` already express it.
- **Task↔Goal linkage is untouched** (RFC-0267, shipped).

## 6. Open questions

1. Does the owner projection replace `keeper_meta.active_goal_ids`, or coexist?
   They are not duplicates: `active_goal_ids` is keeper -> goals and **fires a
   wake on assignment**; `goal.owner` is goal -> keeper and states a fact. A
   replacement is only sound if changing `owner` produces the same
   `Goal_assigned` stimulus, and it costs 360 references across 113 files. Not
   attempted here.
2. Should `phase = executing` with `owner = None` be surfaced to the operator?
   It is the exact state of all ten live Goals and nothing reports it today.
