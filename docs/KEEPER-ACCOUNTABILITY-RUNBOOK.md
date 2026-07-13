---
status: runbook
last_verified: 2026-07-13
code_refs:
  - lib/keeper/keeper_accountability.ml
  - lib/dashboard/dashboard_http_keeper.ml
  - test/test_keeper_accountability.ml
---

# Keeper Accountability Runbook

This runbook defines the Keeper accountability surface as observation only. It
does not define a trust level, authorization policy, routing policy, Keeper
lifecycle constraint, or Task-completion rule.

## Where It Appears

- Dashboard read model: `GET /api/v1/dashboard/execution`
- Keeper compatibility projection:
  `keepers[*].trust_observatory.accountability`
- Runtime projection: `Keeper_status_metrics.accountability_summary_json`
- Durable ledger under the configured BasePath:
  `.masc/accountability/YYYY-MM/DD.jsonl`

The projection is omitted when `compact=true`. When requested, failures to
read, decode, or project the ledger must be returned and observed explicitly;
they must not become an empty, healthy, or allowed result.

## Boundary Contract

The ledger records attributable events. The dashboard is a read projection.
Neither is a decision authority.

Accountability data must never:

- allow or deny a Tool request
- select or demote a Keeper
- reroute, pause, stop, throttle, or ban a Keeper
- determine whether a Task or Goal is complete
- change reward or economy behavior
- become evidence that unrelated work should wait

Legacy derived quality-band and routing-advice fields are not part of the
target contract. Consumers must not recreate them from rates, ages, counts, or
other local thresholds.

## Recorded Facts

### Claim creation

A creation event records the claim exactly as made, together with stable
identity and provenance:

- `claim_id`
- `agent_name` and `keeper_name`
- `kind` and `subject`
- `surface` and `created_at`
- optional `task_id`, `trace_id`, and `turn_number`
- supplied `evidence_refs`
- whether the event originated from an explicit claim or a lifecycle
  observation

A lifecycle-generated event is provenance, not automatic proof that an
explicit completion claim is true.

### Resolution

A resolution event records an explicit result and its source:

- the referenced `claim_id`
- the resolution value
- `resolved_at`
- the stated reason
- supporting evidence references
- the model, operator, or domain event that produced the resolution when
  available

Elapsed time alone must not turn a claim into true, false, supported,
unsupported, safe, or risky. If a semantic resolution is required, the
configured LLM judges the concrete claim and evidence. The decision and model
provenance are then recorded as facts.

## Aggregations

Counts, rates, windows, and ages are optional observation views. They must not
be treated as quality ranks or control inputs.

For every derived ratio, expose the numerator and denominator. If the
denominator is zero, report the value as unavailable; do not substitute a
passing or failing default. For every time-window projection, expose the
window used. Fixed thresholds must not create bands, routing advice, claim
restrictions, or Keeper restrictions.

Recent history should preserve enough raw references for an operator or model
to inspect the concrete events instead of trusting a summary label.

## Operator Procedure

1. Inspect the relevant claim and resolution events.
2. Correlate their Task, turn, Tool receipt, and evidence references.
3. Treat missing or unreadable data as an explicit observability failure.
4. When a semantic verdict is needed, submit the concrete facts to the
   configured LLM judge rather than applying a local score threshold.
5. Record the verdict and provenance without constraining unrelated Keeper
   activity.

There is no recovery ladder or target band. A Keeper continues its independent
lane unless an explicit operator lifecycle command applies to that Keeper.

## Public Surface

Accountability facts are not a leaderboard. Do not publish universal scores,
punitive labels, or comparisons that imply claims from different Tasks,
Channels, or contexts are interchangeable.
