# Keeper Continuity Production Runbook

**Status**: Draft, production prerequisite
**Date**: 2026-03-29
**Scope**: Release gate, evidence, monitoring, and rollback for keeper continuity
**One sentence**: Treat keeper continuity as production-ready only when checkpoint truth, live validation, diagnostics, and rollback are all in place.

## Related Documents

- `./KEEPER-CONTINUITY-VALIDATION.md`
- `./design/keeper-continuity-product-rfc.md`
- `./design/keeper-continuity-diagnosis-rfc.md`
- `./design/error-handling-and-operations-spec.md`
- `./PRODUCT-OPERATING-PLAN.md`

## Product Scope

This runbook applies to the advanced keeper feature defined as:

- same-trace checkpoint-backed continuity for `masc_keeper_msg`
- restart/restore continuity within the same active trace
- diagnostic truth through keeper read surfaces

It does not certify:

- general memory
- cross-generation recall
- long-term assistant reply recall
- memory bank resurrection

## Release Gate

Keeper continuity is releaseable as an advanced feature only when all of the following are true:

1. OAS checkpoint diagnosis has a closed root cause and an implemented fix
2. `Keeper_checkpoint_store.load_oas` returns non-empty message state for the validated scenario
3. `masc_keeper_msg` same-trace continuity succeeds in live runtime
4. `masc_keeper_status` and `masc_keeper_list(detailed=true)` report continuity fields consistently
5. rollback instructions are tested and documented
6. docs use bounded continuity language consistently

If any gate is missing, the feature remains internal or validation-only.

## Required Evidence

Each release or promotion decision should capture these artifacts:

- validation harness report from `docs/KEEPER-CONTINUITY-VALIDATION.md`
- checkpoint diagnosis note proving the OAS load path used for truth
- example `masc_keeper_status` output showing `trace_id`, `generation`, `trace_history_count`, and `continuity_summary`
- operator note or PR evidence linking the implemented fix to the diagnosed root cause

Preferred evidence bundle:

- harness summary
- checkpoint inspection result
- keeper status snapshot
- rollback note

## Validation Flow

### 1. Live continuity validation

Run the existing harness in isolated mode:

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp
KEEPER_MODELS="default" \
scripts/harness_keeper_continuity_validation.sh
```

Minimum acceptable result for release:

- `PASS` for same-trace continuity
- no contradictory keeper status signals during the run

The existing harness `PASS` bar is intentionally stricter than the base product contract. It also expects compaction and handoff evidence, which makes it suitable as a production-readiness gate rather than only a minimal feature check.

`PARTIAL` is not production-ready for feature promotion. It is evidence for debugging only.

### 2. Checkpoint truth validation

Use the OAS checkpoint load path as the source of truth.

- confirm the validated keeper trace restores from OAS checkpoint state
- confirm the restored messages match the continuity scenario being tested
- do not rely on raw `<trace_id>.json` filesystem inspection unless the runtime is known to be in the fallback path

### 3. Read-model validation

Verify continuity-related read surfaces are coherent:

- `masc_keeper_status`
- `masc_keeper_list(detailed=true)`
- continuity harness artifacts

The read surfaces must agree on:

- active `trace_id`
- `generation`
- whether handoff occurred
- whether continuity summary moved forward after the validated turn

## Monitoring And Alerts

At minimum, monitor:

- checkpoint save success rate
- checkpoint load failure rate
- empty-message checkpoint restore rate
- keeper continuity validation pass rate
- keeper resume/restart failure rate

Operator escalation rules:

- any sustained checkpoint load failure blocks keeper continuity promotion
- any empty-message restore regression pages or creates a release blocker
- any mismatch between live keeper state and read surfaces blocks promotion until resolved

## Rollback And Containment

If continuity regresses after launch:

1. downgrade public wording from advanced feature to validation-only or internal
2. disable any newly promoted docs claims before attempting broader fixes
3. preserve checkpoint artifacts and validation evidence for diagnosis
4. prefer forward-fix with explicit evidence; do not widen the promise while diagnosis is open

If filesystem naming or migration work is bundled with continuity changes:

- quarantine on conflict
- no automatic data deletion
- continuity rollback takes precedence over cleanup completion

## Documentation Truth Checklist

Before merge or release note publication, ensure these are aligned:

- `README.md`
- `docs/PRODUCT-OPERATING-PLAN.md`
- `docs/PRODUCT-REVIEW.md`
- `docs/KEEPER-CAPABILITY-MATRIX.md`
- `docs/design/keeper-continuity-product-rfc.md`
- `docs/KEEPER-CONTINUITY-VALIDATION.md`

Required wording pattern:

- advanced keeper feature
- bounded continuity
- same-trace checkpoint-backed restore
- diagnosable via keeper status / validation

Forbidden wording pattern:

- general memory
- resurrected memory system
- remembers everything

## Exit Criteria

Keeper continuity is production-ready only when:

- diagnosis is closed
- validation is passing on live runtime
- read surfaces are truthful
- monitoring exists
- rollback is documented
- docs do not over-promise beyond bounded continuity
