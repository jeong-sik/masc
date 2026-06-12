---
rfc: "0234"
title: "Scheduled internal automation with separate execution approval"
status: Draft
created: 2026-06-12
updated: 2026-06-12
author: vincent
supersedes: []
superseded_by: null
related: ["0078", "0084", "0179", "0220", "0233"]
implementation_prs: []
---

# RFC-0234: Scheduled internal automation with separate execution approval

Status: Draft. A schedule is only an intent to run later; it is not execution
authorization. Any schedule that can produce side effects must be approved by a
different human principal before the runner can execute it.
Drafted by: Codex (GPT-5), from the 2026-06-12 owner design session.

> Anchors marked **(verified)** were read against `origin/main`
> (`5b90e1996`) on 2026-06-12.

---

## §1 Problem

MASC has several schedulers and time-adjacent mechanisms, but none represents
the product request "do this later after someone asks" as a first-class,
auditable internal object.

The missing execution chain is:

```text
scheduled request -> due observation -> separate execution grant -> consumer dispatch
```

Current adjacent mechanisms are not enough:

- proactive turn mechanisms decide whether an agent should wake; they do not
  carry an operator-authored future action request.
- domain-specific scheduler state
  (`<runtime_root>/goals_scheduler_state.json`, **verified** in
  `docs/BOOT-ENV-STATE-INVENTORY.md:208`) is not a general scheduled request
  store and must not be imported into the schedule core.
- verification scheduling in RFC-0220 is about making verification obligations
  satisfiable; it is not a general "run this at 18:00" user request surface.
- the approval queue already suspends or records tool execution approval
  (`lib/keeper/keeper_approval_queue.ml:1`, **verified**), has a typed
  pending approval record (`lib/keeper/keeper_approval_queue.mli:24`,
  **verified**), and emits `approval:pending` / `approval:resolved`
  (`docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md:171-177`, **verified**), but it
  starts at execution time. It does not persist future intent.
- tool descriptors already carry an approval axis
  (`lib/keeper/keeper_tool_descriptor.mli:25`, **verified**), but descriptors
  describe whether a live tool call needs approval; they do not represent
  future intent or separation of requester/scheduler/approver.

The missing layer is a durable schedule ledger whose entries can become due
later, be inspected, be cancelled, and only then request execution through the
normal MASC policy and approval machinery.

The safety boundary is the key requirement: schedule creation and execution
authorization must be different acts by different principals. Without that
boundary, "schedule something now" becomes a delayed self-approved action.

## §2 Design principles

1. Schedule creation is not permission to execute.
2. The actor who requested or scheduled a side-effecting action cannot approve
   its execution.
3. Side-effecting scheduled actions require a different human principal as the
   execution approver.
4. The runner is internal MASC automation, not an OS daemon contract. No cron,
   no launchd, and no direct shell execution path.
5. Scheduled execution reuses the existing descriptor, policy, sandbox, and
   approval surfaces. It does not create a bypass.
6. Every state change is append-only and replayable; projections are derived.
7. The schedule core stores opaque payloads only. It has no constructors or
   dependencies for keepers, tasks, boards, goals, tools, or any other consumer
   domain. Consumers observe due rows and decide what, if anything, to do.

## §3 Scope

In scope:

- create/list/get/cancel scheduled requests;
- request/reject/record execution approval;
- internal due scanning and blocked-due surfacing;
- exposing approved due requests for a consumer execution layer;
- dashboard/operator visibility for pending, due, blocked, and completed
  schedules;
- JSONL audit records and deterministic projection tests.

Non-goals:

- external schedulers (`cron`, `launchd`, cloud scheduler);
- arbitrary unattended shell execution;
- skipping live policy and approval checks in the consumer layer;
- replacing proactive scheduling;
- replacing verification scheduling from RFC-0220;
- adding a new public provider/runtime API.

## §4 Data model

Two records are deliberately separate.

```ocaml
type actor_kind =
  | Human_operator
  | Automated_actor
  | System

type actor =
  { id : string
  ; kind : actor_kind
  ; display_name : string option
  }

type risk_class =
  | Reminder_only
  | Read_only
  | Workspace_write
  | External_write
  | Destructive
  | Cost_bearing

type schedule_status =
  | Pending_approval
  | Scheduled
  | Due
  | Running
  | Succeeded
  | Failed
  | Rejected
  | Cancelled
  | Expired

type schedule_request =
  { schedule_id : string
  ; requested_by : actor
  ; scheduled_by : actor
  ; requested_at : float
  ; due_at : float
  ; expires_at : float option
  ; payload : Yojson.Safe.t
  ; risk_class : risk_class
  ; approval_required : bool
  ; status : schedule_status
  ; created_from : schedule_source
  }

type execution_grant =
  { grant_id : string
  ; schedule_id : string
  ; approved_by : actor
  ; approved_at : float
  ; decision : [ `Approve | `Reject of string ]
  ; evidence : Yojson.Safe.t
}
```

`payload` is intentionally opaque to the schedule core. It may be a text note,
a JSON envelope, or a consumer-defined command description, but this RFC does
not define a route enum. Keepers, tasks, boards, goals, tool names, and future
execution adapters belong outside the schedule domain. A consumer may observe a
due row and translate the payload later; the schedule ledger only preserves
time, approval, risk, and audit evidence.

## §5 Separation-of-duties invariant

The central predicate is:

```ocaml
val can_grant_execution :
  schedule_request -> approver:actor -> (unit, grant_rejection) result
```

It rejects when:

- `approver.kind <> Human_operator` for any side-effecting risk class;
- `approver.id = requested_by.id`;
- `approver.id = scheduled_by.id`;
- the schedule is already terminal;
- the approval evidence does not bind to the exact `schedule_id`,
  `payload` digest, `risk_class`, and `due_at`.

`Reminder_only` and clearly `Read_only` requests may be scheduled without a
grant when policy says no approval is required. Everything else starts in
`Pending_approval`.

Remembered approval rules are not enough by themselves. Existing approval rules
carry `created_by` (`lib/keeper/keeper_approval_queue.mli:52-68`,
**verified**), but scheduled execution must treat a rule as valid grant evidence
only when the rule was created by a different human principal than
`requested_by` and `scheduled_by`. If that identity is absent, the due request
remains blocked and emits an approval-required event.

This is intentionally stricter than ordinary immediate tool approval. A schedule
adds temporal distance: the person who asks for a future side effect must not be
able to hide the approval in the scheduling step.

## §6 State machine

Allowed transitions:

```text
create(requires_approval=true)  -> Pending_approval
create(requires_approval=false) -> Scheduled

Pending_approval --approve_by_other_human--> Scheduled
Pending_approval --reject------------------> Rejected
Pending_approval --cancel------------------> Cancelled
Pending_approval --expire------------------> Expired

Scheduled --due_at_reached-----------------> Due
Scheduled --cancel-------------------------> Cancelled
Scheduled --expire-------------------------> Expired

Due --approval_missing---------------------> Due        (blocked event only)
Due --policy_missing-----------------------> Due        (blocked event only)
Due --start-------------------------------> Running
Due --cancel------------------------------> Cancelled
Due --expire------------------------------> Expired

Running --success--------------------------> Succeeded
Running --failure--------------------------> Failed
```

The runner never changes `Pending_approval` directly to `Running`. Due but
unapproved requests stay due and blocked; they do not execute and do not
silently disappear.

Terminal states are `Succeeded`, `Failed`, `Rejected`, `Cancelled`, and
`Expired`.

## §7 Storage

Add a workspace-local store under the active runtime root:

```text
<runtime_root>/schedules/events/YYYY-MM/DD.jsonl
<runtime_root>/schedules/projection.json
```

The JSONL event log is authoritative. `projection.json` is a cache rebuilt by
folding events:

```ocaml
type schedule_event =
  | Created of schedule_request
  | Approval_requested of { schedule_id : string; reason : string }
  | Execution_granted of execution_grant
  | Execution_rejected of execution_grant
  | Marked_due of { schedule_id : string; observed_at : float }
  | Execution_blocked of { schedule_id : string; reason : string }
  | Started of { schedule_id : string; execution_id : string option }
  | Completed of { schedule_id : string; result : Yojson.Safe.t }
  | Failed of { schedule_id : string; error : string }
  | Cancelled of { schedule_id : string; cancelled_by : actor; reason : string }
  | Expired of { schedule_id : string; observed_at : float }
```

The event log must be append-only and replay deterministic. A corrupted
projection is deleted and rebuilt; a corrupted event row is a read error, not a
silent drop.

## §8 API surface

Initial internal tools:

| Tool | Purpose | Approval |
| --- | --- | --- |
| `masc_schedule_create` | create a scheduled request | policy-selected; high-risk requests become `Pending_approval` |
| `masc_schedule_list` | list projection rows | read-only |
| `masc_schedule_get` | inspect one request plus audit events | read-only |
| `masc_schedule_cancel` | terminal cancellation before start | policy-selected |
| `masc_schedule_approve` | record execution grant | human-only, cannot be requester/scheduler |
| `masc_schedule_reject` | reject execution | human-only |

Internal-only runner entrypoint:

| Entrypoint | Purpose |
| --- | --- |
| `Schedule_runner.tick` | scan due rows, emit blocked events, and enqueue approved work |

`Schedule_runner.tick` is not an LLM-native tool. It is called by MASC's existing
internal supervision loop, with batch limits and retry backoff. The runner
should enqueue or dispatch through typed MASC routes; it must not interpret a
stored string as shell.

## §9 Runner behavior

For each due row:

1. Re-read the projection under the schedule lock.
2. Reject terminal rows.
3. If `approval_required`, require a valid `execution_grant`.
4. Hand the opaque payload to the consumer layer for live policy resolution.
5. If policy now requires approval and no acceptable grant exists, emit
   `Execution_blocked`.
6. Mark `Running`.
7. Dispatch using the consumer-selected route.
8. Record `Completed` or `Failed`.

Step 4 is mandatory because policy can change between scheduling time and
execution time. The scheduled row records intent; the consumer remains the
execution authority and may refuse to run.

## §10 Dashboard and operator UX

Dashboard surfaces:

- Scheduled: future rows with requester, scheduler, due time, payload summary,
  and risk.
- Pending approval: rows that need another human principal.
- Due blocked: rows whose due time passed but approval or policy is missing.
- Running/completed: execution identity, result, and last event.

The approval view must show:

- requested_by;
- scheduled_by;
- approver candidate;
- whether the candidate is allowed to approve;
- payload digest;
- risk class;
- expires_at.

The UI must make self-approval impossible, not merely warn after submit.

## §11 Events and telemetry

Emit these events:

```text
schedule.created
schedule.approval_requested
schedule.approved
schedule.rejected
schedule.cancelled
schedule.expired
schedule.due
schedule.execution_blocked
schedule.started
schedule.completed
schedule.failed
```

Where a scheduled action causes later execution, join the schedule event to the
execution identity proposed by RFC-0233 once that identity exists. Until then,
carry `schedule_id`, payload digest, consumer execution identity if present, and
approval id in the schedule audit record.

## §12 Phases

P1 - RFC plus pure domain model:

- `Schedule_id`, `Actor`, `Risk_class`, `Schedule_request`,
  `Execution_grant`, and state-machine transition functions.
- Codec and replay tests.
- No runner.

P2 - storage and read/write tools:

- JSONL event store and projection.
- `masc_schedule_create/list/get/cancel`.
- Approval/reject tools with `can_grant_execution`.
- Dashboard read projection may be JSON-only at first.

P3 - due scanner without execution:

- `Schedule_runner.tick` marks due rows and emits `Execution_blocked` when
  approval is missing.
- No side effects beyond schedule events.

P4 - approved execution:

- dispatch approved opaque payloads through a consumer adapter;
- live policy recheck before execution;
- `Running -> Succeeded|Failed` records.

P5 - dashboard and telemetry polish:

- operator panels;
- SSE events;
- runtime trust snapshot count fields;
- RFC-0233 execution-id join when available.

## §13 Verification harness

Required tests:

- state-machine codec and replay produce deterministic projection;
- side-effecting create starts in `Pending_approval`;
- same `requested_by` cannot approve;
- same `scheduled_by` cannot approve;
- non-human actor cannot approve side-effecting execution;
- approval evidence fails if payload digest changed;
- due pending approval emits `Execution_blocked` and does not run;
- cancellation is terminal;
- descriptor policy is rechecked at due time;
- corrupted projection is rebuildable from JSONL;
- corrupted JSONL event row fails loudly.

Operational checks:

```text
python3 scripts/rfc_enforcer.py --check-numbering --base-ref origin/main --head-ref HEAD
git diff --check
```

## §14 Open questions

1. Whether `Reminder_only` should be allowed to auto-run as a consumer-owned
   reminder or should always require a user-visible pending row.
2. Whether schedule approval should reuse `approval-rules.json` directly or get
   its own `schedule-approval-rules.json` with explicit requester/scheduler
   exclusion baked into the key.
3. Whether recurring schedules belong in the first implementation. The default
   answer is no: one-shot schedules first, recurring schedules only after the
   approval and replay model is proven.

## §15 Ledger note

This RFC was allocated with `bash scripts/rfc-allocate-next.sh`, advancing
`.next-number` from 0234 to 0235 in the same commit as the RFC file.
