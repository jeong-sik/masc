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

This document is a future-state release gate. The current product posture can still be `Not done for product promise` while diagnosis or hardening remains open.

## Release Gate

Keeper continuity is releaseable as an advanced feature only when all of the following are true:

1. OAS checkpoint diagnosis has a closed root cause and an implemented fix
2. the validated scenario includes explicit checkpoint-restore evidence from the OAS load path (for example diagnosis logs, scripted inspection output, or harness-linked artifacts)
3. `masc_keeper_msg` same-trace continuity succeeds in live runtime
4. `masc_keeper_status` and `masc_keeper_list(detailed=true)` report continuity fields consistently
5. rollback instructions are tested and documented
6. docs use bounded continuity language consistently

If any gate is missing, the feature remains internal or validation-only.

### Quantitative Gate

For production promotion, attach the output of:

```bash
scripts/keeper-production-readiness-gate.py \
  --base-path <runtime-base-path> \
  --keeper <keeper-name> \
  --output .release-evidence/keeper-production-readiness.json
```

Minimum thresholds:

- terminal turns: `>= 3`
- successful turns: `>= 3`
- receipt coverage: `100%`
- checkpoint coverage for successful provider turns: `100%`
- provider attempt closure: `100%`
- event-bus correlation coverage: `100%`
- memory-injection coverage: `100%`
- tool-log coverage when tools are used: `100%`
- timestamp parse coverage: `100%`
- missing linked artifacts: `0`
- timestamp/order violations: `0`
- dangling provider attempts: `0`
- max evidence span per turn: `<= 600 seconds`

These are release thresholds, not debugging hints.  Any missing metric or
unevaluated gate keeps continuity out of the production-ready bucket.

For this runbook, `diagnosis closed` means all of the following:

- one root-cause bucket from the diagnosis RFC (`H1`-`H4`) is selected
- the selected fix path is implemented or explicitly marked as no-code with rationale
- the validating artifact is attached in PR or release evidence

## Required Evidence

Each release or promotion decision should capture these artifacts:

- validation harness report from `docs/KEEPER-CONTINUITY-VALIDATION.md`
- checkpoint diagnosis note or structured inspection artifact proving the OAS load path used for truth
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

Compaction and handoff are therefore treated here as resilience evidence for release promotion, not as the minimum user-facing continuity contract.

`PARTIAL` is not production-ready for feature promotion. It is evidence for debugging only.

If pre-release validation returns `PARTIAL`, the release gate remains blocked and the result should be escalated back into diagnosis rather than accepted as launch evidence. Reuse one of the existing diagnosis buckets (`H1`-`H4`) when it fits; otherwise open a follow-up diagnosis work item with the harness artifacts attached.

### 2. Checkpoint truth validation

Use the OAS checkpoint load path as the source of truth.

- confirm the validated keeper trace restores from OAS checkpoint state
- confirm the restored messages match the continuity scenario being tested
- record this through a diagnosis note, scripted inspection output, or equivalent artifact that can be attached to the PR or release evidence bundle
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
- whether `continuity_summary` reflects the latest harness-validated continuity update, with `last_continuity_update_ts` from detailed status used as the tie-breaker when needed

For timing-sensitive interpretation, the harness result (`PASS` / `PARTIAL` / `FAIL`) remains authoritative. Read-model checks are used to confirm consistency, not to redefine the harness outcome.

## Monitoring And Alerts

At minimum, monitor:

- checkpoint save success rate
- checkpoint load failure rate
- empty-message checkpoint restore rate
- keeper continuity validation pass rate from periodic or pre-release validation runs
- keeper resume/restart failure rate from keeper status/metrics telemetry

Operator escalation rules:

- any sustained checkpoint load failure blocks keeper continuity promotion
- any empty-message restore regression pages or creates a release blocker
- any mismatch between live keeper state and read surfaces blocks promotion until resolved

If these metrics are not yet exported in the current telemetry stack, keeper continuity remains blocked from production promotion until equivalent dashboards or reports are defined.

`Equivalent dashboards or reports` means one reproducible command, dashboard, or generated artifact per required metric, referenced from the PR or release evidence so another operator can re-run the same check.

## Rollback And Containment

If continuity regresses after launch:

1. downgrade public wording from advanced feature to validation-only or internal in `README.md`, `docs/PRODUCT-OPERATING-PLAN.md`, and continuity-specific docs
2. if the release bundles runtime continuity code changes, either revert the offending continuity change or hold the release while keeping the downgraded wording in place
3. rerun the keeper continuity validation harness against the last known-good build or commit and store the result with the incident evidence
4. preserve checkpoint artifacts and validation evidence for diagnosis
5. prefer forward-fix with explicit evidence; do not widen the promise while diagnosis is open

Current default: there is no dedicated runtime feature flag for keeper continuity. Rollback is therefore a combination of product-promise rollback plus code revert or release hold when implementation changes are bundled.

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
