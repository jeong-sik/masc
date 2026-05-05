# GOAL LOOP fixture replay

This fixture bundle is a local, deterministic replay of the startup evidence
used by the GOAL LOOP tooling tests.  It proves that Observe, Orient, Decide,
Act linkage, Verify, and aggregate status stay wired together without needing a
live production log.

Run from the repository root:

```bash
python3 scripts/decide_goal_loop_findings.py \
  test/fixtures/goal_loop/orient.startup.json \
  --act-map test/fixtures/goal_loop/act-map.startup.json \
  > /tmp/goal-loop-decide.json

python3 scripts/goal_loop_status.py \
  --observe-json test/fixtures/goal_loop/observe.startup.json \
  --orient-json test/fixtures/goal_loop/orient.startup.json \
  --decide-json /tmp/goal-loop-decide.json \
  --verify-json test/fixtures/goal_loop/verify.fail.json \
  --loop-iteration "#fixture" \
  --format text
```

Expected key facts:

- `overall_status` is `critical`.
- Decide reports `act_linked_count=5` and `act_missing_count=0`.
- Act is no longer critical in the fixture: every startup decision has at least
  one linked PR artifact.
- Verify remains `FAIL` because the startup replay is pre-ACT evidence, so the
  loop must not be marked complete until a post-ACT live verify passes.

Use the JSON status form when another tool needs to consume the replay:

```bash
python3 scripts/goal_loop_status.py \
  --observe-json test/fixtures/goal_loop/observe.startup.json \
  --orient-json test/fixtures/goal_loop/orient.startup.json \
  --decide-json /tmp/goal-loop-decide.json \
  --verify-json test/fixtures/goal_loop/verify.fail.json \
  --loop-iteration "#fixture"
```

Validate that the fixture's ACT artifacts point at known PR numbers:

```bash
python3 scripts/validate_goal_loop_act_map.py \
  test/fixtures/goal_loop/act-map.startup.json \
  --known-prs-json test/fixtures/goal_loop/known-prs.startup.json \
  --require-pr-ref \
  --fail-on any
```

For live validation, capture a current PR snapshot first and pass that file as
`--known-prs-json`.

Replay the external 206-audit claim catalog through Orient:

```bash
python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  > /tmp/goal-loop-orient-audit.json

python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --format text
```

Expected key facts:

- `audit_catalog` is `INCOMPLETE`.
- The manifest covers all 12 prompt-supplied source documents.
- The source documents disagree on the aggregate audit total: 206 vs 214.
- The source documents claim 206 findings for the current catalog total, but
  only 18 finding IDs are itemized in the checked artifacts.
- `--require-complete-catalog` intentionally exits non-zero until the full
  row-level corpus is attached or checked in.

Use the catalog-enriched Orient output in aggregate GOAL LOOP status when
checking whether the goal can be closed:

```bash
python3 scripts/goal_loop_status.py \
  --observe-json test/fixtures/goal_loop/observe.startup.json \
  --orient-json /tmp/goal-loop-orient-audit.json \
  --decide-json /tmp/goal-loop-decide.json \
  --verify-json test/fixtures/goal_loop/verify.fail.json \
  --loop-iteration "#fixture"
```

Expected key fact: `phases.orient.summary.audit_catalog` preserves the
source-document coverage, missing row count, and open consistency finding.
