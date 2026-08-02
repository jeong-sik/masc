# Verification Pipeline Policy

## Purpose

Prevent rubber-stamp completion by giving the application-owned system LLM
agent one immutable, typed submit-time snapshot to review. This authority is
not a Keeper and is not another Keeper performing verification. A Keeper may
produce the work and submit evidence, but it never claims or approves the
pending obligation.

## 1. Evidence submission contract

Before `submit_for_verification` commits `awaiting_verification`, the request
must preserve the producer's submitted evidence without semantic inference:

| Kind | Wire form | Meaning |
|---|---|---|
| Artifact | `artifact:<producer-root-relative-path>` | bounded UTF-8 snapshot read from the producer sandbox |
| Narrative | `note:<text>` | submitter narrative context, not an independently inspected artifact |

The task contract's `required_evidence` and `verify_gate_evidence` are
requirements, not submitted evidence. They are persisted separately as
`required_artifacts`; the two lists must never be merged.

Completion `notes` and handoff `summary` are persisted as explicit `note:`
items. A bare path, absolute host path, URL, commit, or board id is not an
artifact. The system LLM lane does not fetch those references. If one is
required as proof, the producer must materialize the relevant content as an
`artifact:` snapshot. Invalid, unreadable, and truncated items remain typed
and visible; they are not silently treated as proof.

## 2. System LLM review contract

Before it emits a verdict, the application-owned system LLM agent receives:

1. the persisted verification request;
2. the persisted `required_artifacts` requirements; and
3. the typed `submitted_evidence` snapshot captured at submission time.

It may emit only the structured `report_review_verdict` result. It does not
enter Keeper registration, Keeper claims, Keeper lanes, or Keeper task
actions. `Workspace.commit_verdict_r` is the only task mutation boundary.

The agent must not approve from an unavailable or truncated artifact, or from
a narrative claim that a URL/file/commit was inspected. A rejection must carry
a specific reason. Missing or malformed model output is an unavailable review,
not an invented verdict.

The verdict is projected to the internal verification Board post, task
activity, transition subscription, audit log, and SSE. Projection failure is
logged with the typed boundary outcome; it cannot rewrite the task verdict.

## 3. HITL and producer routing

The authenticated operator route uses `Human_operator` and is independent of
the system LLM lane. A rejected verdict wakes or durably queues only the
producer Keeper. The rejection payload retains the typed authority,
`task_id`, `verification_id`, and reason. No other Keeper is assigned the
verification obligation.

If the system LLM runtime is unavailable or produces no structured verdict,
the task remains `awaiting_verification` and the reason is observable. The
runtime must not substitute a Keeper, a name-based role, a timer, or a local
string classifier.

## Revision History

- 2026-08-02: aligned the policy with the system-LLM authority and typed
  immutable evidence snapshot contract.
- 2026-07-08: Initial policy (task-1880, base)
