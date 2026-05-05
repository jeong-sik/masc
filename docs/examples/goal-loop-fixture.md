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
- Decide reports `act_linked_count=4` and `act_missing_count=1`.
- Act remains critical because `D-EMERGENCY-1` is still missing a linked ACT
  artifact.
- Verify remains `FAIL`, so the loop must not be marked complete.

Use the JSON status form when another tool needs to consume the replay:

```bash
python3 scripts/goal_loop_status.py \
  --observe-json test/fixtures/goal_loop/observe.startup.json \
  --orient-json test/fixtures/goal_loop/orient.startup.json \
  --decide-json /tmp/goal-loop-decide.json \
  --verify-json test/fixtures/goal_loop/verify.fail.json \
  --loop-iteration "#fixture"
```
