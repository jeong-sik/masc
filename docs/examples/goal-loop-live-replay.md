# GOAL LOOP post-ACT live replay

Use this runner after ACT PRs have landed and the active runtime has been
restarted or otherwise re-entered the relevant code path. It captures a bounded
log window, then writes Observe, Orient, Decide, Verify, Status, and metadata
JSON artifacts in one directory.

Example:

```bash
python3 scripts/goal_loop_live_replay.py \
  --log /path/to/server.log \
  --duration-seconds 60 \
  --artifact-dir /tmp/goal-loop-live-verify-$(date -u +%Y%m%dT%H%M%SZ) \
  --act-map test/fixtures/goal_loop/act-map.startup.json \
  --runtime-source localhost:8935 \
  --base-path /Users/dancer/me \
  --loop-iteration post-act-live \
  --fail-on verify \
  --format text
```

Artifacts written:

- `metadata.json`: source log paths, captured log paths, runtime source, base
  path, evidence window, duration, policy, and loop label.
- `observe.json`: raw GOAL LOOP log pattern counts and samples.
- `orient.json`: finding-level classification from Observe evidence.
- `decide.json`: actionable decision queue and ACT linkage.
- `verify.json`: PASS/FAIL result plus `post_act_verify=true`,
  `evidence_kind=live_runtime_logs`, concrete evidence source, evidence window,
  and `checked_at`.
- `status.json`: aggregate GOAL LOOP status and next action.

Interpretation:

- `verify_status=PASS` means the captured post-ACT window did not contain
  evidence matching the configured Verify policy.
- `verify_status=FAIL` keeps the loop red and stores concrete samples in the
  phase artifacts.
- A PASS is only a bounded replay result. It is not a permanent proof that the
  failure cannot recur.
