# task-266 verification proof

## Contract evidence

- **lib/keeper/keeper_status_runtime.ml does not let keeper.snapshot_sec mask an old agent last_seen signal**
  - keeper_health_state no longer accepts or reads the snapshot cadence when classifying an agent-registry signal.
  - A running Keeper with a present agent status uses the existing 120-second agent-signal threshold.
  - Snapshot-based keeper_heartbeat_stale_after_s remains available for the separate operator-facing heartbeat freshness surface.

- **A regression test covers keepalive_interval_sec=30, snapshot_sec=3600, and last_seen_ago_s=180 as stale**
  - Test: test_snapshot_cadence_does_not_mask_stale_agent_signal in test/test_keeper_diagnostic_stale_last_error.ml.
  - The test sets Runtime_settings.keeper_keepalive_interval_sec to 30, Runtime_settings.keeper_snapshot_sec to 3600, supplies an active agent status with last_seen_ago_s=180.0, and asserts diagnostic health_state = stale.

## Verification

- ocamlc -stop-after parsing lib/keeper/keeper_status_runtime.ml: passed.
- ocamlc -stop-after parsing test/test_keeper_diagnostic_stale_last_error.ml: passed.
- ocamlformat --check lib/keeper/keeper_status_runtime.ml test/test_keeper_diagnostic_stale_last_error.ml: passed.
- git diff --check: passed.
- MASC_DUNE_THROTTLE=0 MASC_SKIP_OPAM_LOCK=1 MASC_DUNE_ALLOW_BARE_DUNE=1 bash scripts/dune-local.sh build test/test_keeper_diagnostic_stale_last_error.exe: passed.
- Focused regression execution, ./_build/default/test/test_keeper_diagnostic_stale_last_error.exe test supersede 4: passed.
- Running the complete focused binary still reports two pre-existing failures (fresh error stays visible and offline keeper keeps error) outside the changed liveness branch; the new regression case passes.
