# Keeper Continuity Product RFC

**Status**: Draft
**Date**: 2026-03-29
**Promise level**: Advanced keeper feature
**Scope**: Product contract for bounded keeper continuity
**One sentence**: Productize keeper continuity as same-trace checkpoint continuity plus diagnosability, not as general memory.

## Related Documents

- `./keeper-continuity-diagnosis-rfc.md`
- `../KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md`
- `../KEEPER-CONTINUITY-VALIDATION.md`
- `../PRODUCT-OPERATING-PLAN.md`
- `../PRODUCT-REVIEW.md`
- `../spec/05-keeper-agent.md`

## Summary

`masc-mcp` should describe keeper continuity as a bounded advanced feature.

The product promise is:

- a keeper can continue a same-trace conversation through OAS checkpoint-backed context restore
- continuity failures are diagnosable through keeper read surfaces and operator validation
- this is an advanced keeper capability, not the front-door product promise

The product must not describe this feature as long-term memory, general memory, or cross-generation recall.

## Product Contract

### Included behavior

- `masc_keeper_msg` preserves same-trace conversation continuity when checkpoint save/load/restore is healthy
- keeper restart or restore within the same trace preserves conversation continuity to the current checkpoint ceiling
- operators can diagnose continuity state through `masc_keeper_status`, `masc_keeper_list(detailed=true)`, and the keeper continuity validation harness
- continuity state is explained with checkpoint/read-model language, not raw filesystem assumptions

### Excluded behavior

- general conversational memory
- long-tail recall beyond the current checkpoint contract
- cross-generation or cross-trace recall
- assistant reply recall outside the active checkpoint window
- memory bank resurrection as part of the continuity promise

## Public Surface

This contract is anchored to existing keeper surfaces.

### Write surface

- `masc_keeper_msg`
  - primary user-facing continuity surface
  - success means the keeper can continue the same trace coherently after prior turns and restore events

### Read surfaces

- `masc_keeper_status`
  - primary diagnostic surface
  - guaranteed continuity-related fields must remain trustworthy: `trace_id`, `generation`, `trace_history_count`
  - `continuity_summary` is expected after a validated continuity update and may be empty before the first snapshot exists
  - `last_continuity_update_ts` is a detailed-status supporting field for operator tie-breaks, not part of the minimal product contract
- `masc_keeper_list(detailed=true)`
  - lightweight fleet view for continuity and handoff state
- `docs/KEEPER-CONTINUITY-VALIDATION.md`
  - operator validation harness and evidence format

Current implementation already emits the continuity fields above on keeper status surfaces. This RFC is narrowing the product promise around those existing fields rather than inventing a new API.

### Non-API implementation details

- raw checkpoint file paths are not part of the product contract
- the OAS checkpoint load path is the continuity source of truth for diagnosis
- fallback legacy checkpoint artifacts may exist, but they must not shape the user-facing promise

## Product Positioning

### Promise level

- Keep keeper continuity in the advanced layer of the product
- Do not promote it to the front-door repo-coordination promise in README or release framing

### Language rules

Use:

- `keeper continuity`
- `same-trace continuity`
- `checkpoint-backed restore`
- `diagnosable continuity`

Avoid:

- `memory resurrection`
- `general memory`
- `the keeper remembers everything`

## Readiness Conditions For Product Language

The feature may be described as a productized advanced capability only when all of the following are true:

- OAS checkpoint diagnosis has identified and closed the root cause of the current continuity regression, as defined in the production runbook
- same-trace continuity passes the validation harness on live runtime
- keeper read surfaces report continuity state truthfully enough for diagnosis
- the production runbook defines evidence, monitoring, and rollback
- docs use the bounded continuity wording consistently across README, product plan, keeper docs, and runbooks

Until then, the product posture remains `Not done for product promise` even though the design docs themselves are in `Draft`.

The current production promotion bar is intentionally stricter than the base user-facing contract. The existing validation harness also uses compaction and handoff evidence as resilience signals before promotion.

## Follow-On Work

Out of scope for this RFC, but explicitly related:

- history recall for current-trace user messages beyond the keep-last checkpoint window
- recall observability (`evaluate_memory_recall`, `memory_eval_to_json`, `memory_check`)
- naming cleanup for `keeper` / `keepers`
- filesystem cleanup backlog discovered during diagnosis

Any future expansion from bounded continuity to broader recall must ship in a separate RFC with an explicit contract for:

- recall target (`user`, `assistant`, or both)
- recall span (`same trace`, `trace history`, or broader)
- prompt budget and ranking policy
- observability and failure handling
