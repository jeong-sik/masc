---
rfc: "0360"
status: Draft
---

# RFC-0360: Task actor provenance

Status: Draft
Author: Claude Opus 5 (1M context)
Date: 2026-08-05
Related: #26820

## Problem

`Masc_domain.task.created_by` and `Masc_domain.Cancelled.cancelled_by` are plain
strings. They record *who acted* but not *what kind of actor* it was. Every
consumer that needs to know whether the string names a Keeper has to guess, and
every guess is a string comparison that a colliding actor id defeats.

The guessing is concentrated in `Keeper_task_cancellation_wake.notify_author`,
which must answer two questions before it can deliver a wake:

1. Does `created_by` name a Keeper lane to deliver to?
2. Is `cancelled_by` the same Keeper, making this a self-cancellation?

Neither can be answered soundly from a string. Four review rounds on #26820
found four distinct failures of the same class:

| Collision | Effect |
|---|---|
| Two lanes differing only by a `keeper-` prefix (`alpha`, `keeper-alpha`) both canonicalise to `keeper-alpha-agent` | Binding is `Ambiguous`; the author may be a candidate, so the self-check is undecidable |
| A non-Keeper actor id equal to a lane name (`sangsu`) | Resolved as that Keeper — either the author, dropping a wake, or a delivery target for a task it never created |
| A non-Keeper actor id equal to a Keeper agent name (`keeper-sangsu-agent`) | Same, through the agent binding rather than the lane name |
| A Keeper whose shutdown finalized with a retained dead tombstone | Still presents a lane; the durable intake gate admits every retention other than `Remove_meta` |

Each was fixed at its own site. That is the accumulation pattern
`software-development.md` names as **N-of-M 패치**: the same conversion done
separately at several sites, because no abstraction forces them to agree. The
compiler cannot help, so the fifth site will be found by the next reviewer
rather than by the type system.

## Proposal

Record actor kind alongside actor id at write time, and make the resolution a
total function over a closed sum instead of a string search.

```ocaml
type actor_kind =
  | Keeper_actor of { keeper_name : string }
  | Operator_actor
  | System_actor
  | Client_actor

type actor =
  { id : string
  ; kind : actor_kind
  }
```

- `created_by : actor option` and `Cancelled { cancelled_by : actor; ... }`.
- The writer knows the kind: `workspace_task_lifecycle` receives the acting
  identity and can classify it once, at the boundary, where the information
  exists.
- `notify_author` then matches on `actor_kind`. A non-Keeper canceller is not
  the author by construction, not by string comparison. An operator id that
  happens to spell a lane name is an `Operator_actor` and cannot be mistaken
  for one.
- Adding an actor kind breaks every consumer at compile time, which is the
  point: today a new kind is a new silent collision.

## Non-goals

- Migrating persisted tasks. Per `projects.md`, no migration code is written
  for past-version data; the decoder rejects what it cannot type and the
  workspace is reset.
- Changing the durable intake gate's retention policy
  (`Keeper_registry_event_queue.is_retired_for_identity`). Whether a retained
  dead tombstone should accept stimuli is a separate question that affects
  every stimulus producer, not only cancellation wakes. Filed separately.

## Why not keep patching

#26820 fixed four sites and each fix was correct in isolation. The fifth
collision costs another review round and another special case, and the special
cases do not compose: the lane-name fallback removed in one round had been
added defensively in an earlier one. Under
`software-development.md` §워크어라운드 거부 기준 the third occurrence of a
signature in one area forces an RFC rather than a fourth direct patch. This is
the fourth.

## Verification

- A property that no `Operator_actor` resolves to a Keeper lane for any id,
  including ids that spell lane names and agent names.
- Round-trip of the typed actor through the task backlog and the
  `Task_cancelled` stimulus payload.
- The existing collision tests in `test_keeper_task_cancellation_wake` become
  statements about `actor_kind` rather than about string shapes.

## Open questions

- Does any surface legitimately need the raw actor string without its kind?
  The dashboard renders `cancelled_by` as text; that stays, reading `actor.id`.
- `Keeper_identity_binding.resolve` remains for the paths that genuinely start
  from an agent name with no recorded kind. Whether those paths should exist
  after this change is worth deciding before implementation, not after.
