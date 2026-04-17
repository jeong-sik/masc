---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/cdal/
  - lib/keeper/
  - lib/eval_gate.ml
---

# Error Handling and Operations Spec

**Status**: Draft, production prerequisite
**Date**: 2026-03-28
**Scope**: Infra failure taxonomy, operational lifetime, and evaluator SLO guardrails
**One sentence**: Separate logical `Inconclusive` from infrastructure failure, and define the operating rules required before CDAL is production-ready.

## Related Documents

- `./contract-driven-agent-loop-rfc.md`
- `./cdal-contract-kernel-and-advisory-split.md`
- `./cross-run-loader-and-window-spec.md`
- `./check-evaluation-spec.md`

## 1. Goal

`Inconclusive` is not enough for production.
Production systems also need explicit handling for infrastructure failure, partial corruption, resource exhaustion, migration, retention, and rollback.

## 2. Error Taxonomy

| category | example | deterministic effect | retry policy | operator effect |
|---|---|---|---|---|
| `missing_artifact` | referenced file absent | `Inconclusive` if blocking | no automatic retry unless store is eventually consistent | review queue |
| `permission_denied` | unreadable artifact path | infra failure, not logical contradiction | retry after permissions fix | operator page if persistent |
| `parse_failure` | malformed JSON / JSONL | `Inconclusive` if blocking | no automatic retry on same bytes | review queue |
| `partial_bundle` | manifest readable but some selected refs unreadable | `Inconclusive` for active checks; partial friction only if policy allows | bounded retry | review queue |
| `serialization_failure` | verdict or friction artifact cannot be serialized | evaluator failure | retry with backoff | operator page |
| `schema_unsupported` | manifest or evidence version unknown | `Inconclusive` | no retry until compatible reader exists | review queue |
| `aggregation_limit_exceeded` | cross-run window exceeds configured bounds | aggregation failure | retry only with smaller declared window or higher limits | operator review |
| `tripwire_policy_error` | missing or invalid tripwire policy | friction failure | retry after config fix | operator page |
| `concurrent_eval_conflict` | duplicate writers race on same output | infra failure | retry idempotently | operator page if repeated |
| `store_timeout` | read path or listing operation times out | infra failure | bounded retry | operator page if SLO breached |

## 3. Logical vs Infrastructure Failure

Use these rules:

- logical insufficiency of supported evidence -> `Inconclusive`
- contradiction in supported evidence -> `Violated`
- infrastructure inability to read or persist required data -> infra error first, `Inconclusive` only if surfaced through documented fallback

The system must not hide repeated infra failure under a sea of logical `Inconclusive`.

## 4. Persistence and Retention

The following must be defined before production:

- retention by artifact class
- retention by enabled window type
- redaction and access control
- truncation policy for large traces
- compaction policy for long-term retained evidence

Minimum rule:

- no enabled window may exceed retained data

## 5. Migration and Compatibility

Production requires an explicit policy for:

- schema v1 / v2 dual-read period
- whether dual-write is required
- backfill strategy for old runs
- how unsupported old bundles surface in new evaluators

Recommended default:

- dual-read first
- additive v2 fields only
- old bundles remain replayable at least to their original support ceiling

## 6. Monitoring and SLO Guardrails

At minimum monitor:

- proof write success rate
- evaluator completion latency
- dereference failure rate
- parse failure rate
- queue depth
- cross-run aggregation lag
- duplicate-eval conflict rate

Recommended production guardrails:

- any persistent rise in dereference or parse failures pages operators
- any review-tripwire burst above configured threshold pages or escalates
- any aggregation lag beyond declared SLO disables cross-run surfaces before it silently serves stale results

## 7. Rollback and Forward-Fix

The system must define whether bad evaluator or contract changes are handled by:

- forward-fix only
- reactivation of previous evaluator/policy versions

Recommended default:

- contracts may be forward-fixed or rolled back under explicit operator control
- evaluator schema changes should prefer dual-read and forward-fix
- automated widening or rollback from friction alone is forbidden

## 8. Pre-Production vs Production

| capability | pre-production | production |
|---|---|---|
| single-run verdict | yes | yes |
| single-run friction | yes | yes |
| cross-run friction | no | yes, after infra closes |
| automatic policy update | no | optional, separately governed |
| manual review queue | yes | yes |
| explicit infra error taxonomy | partial | required |
| monitoring and SLOs | recommended | required |

## 9. Exit Criteria

Production readiness requires:

- explicit error taxonomy implemented
- monitoring dashboards and alerts defined
- retention and migration policy documented
- rollback / forward-fix rule documented
- cross-run windows disabled by default until their infra is ready
