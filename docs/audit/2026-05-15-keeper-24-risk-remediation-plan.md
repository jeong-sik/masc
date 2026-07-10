# Keeper 24 Risk Remediation Plan

Date: 2026-05-15

Inputs:

- Report: `/Users/dancer/me/memory/keeper-24-risk-report-2026-05-15.html`
- Runtime logs: `/Users/dancer/me/.masc/logs/system_log_2026-05-15.jsonl`
- Coverage gap: `/Users/dancer/me/.masc/telemetry-coverage-gaps/2026-05/15.jsonl`

## Finding

The likely fleet-stop mechanism is FD exhaustion plus write/spawn fanout, not a
single classical deadlock. The live log sequence at 2026-05-15T03:52:50Z shows
`fstatat`, `openat`, `mkdirat`, and `execve` failing with "Too many open files
in system". Once that starts, runtime manifests, coverage gaps, cost events,
tool logs, OAS events, activity events, keeper meta reads, checkpoint receipts,
and docker subprocess checks all fail in the same window.

## Code-Level Remediation

1. FD pressure guard:
   - Add a process-local circuit breaker for EMFILE/ENFILE text.
   - Trip it from central keeper error and keeper filesystem failure paths.
   - While tripped, block new keeper spawn slots and skip turn scheduling until
     cooldown expires.
   - Cap active keeper bootstrap when the process inherited `nofile` soft limit
     is below the 24-keeper floor.
   - Add proactive fleet-resource admission: compute the projected FD budget
     from current open FDs, active keepers, starting keepers, per-keeper
     estimate, and headroom. Block spawn/turn admission before the projected
     budget crosses the inherited `nofile` soft limit.
   - Pin the admission invariant with `KeeperFleetPressureAdmission.tla`: clean
     model must pass, buggy model must violate `Safety`.

2. Turn slot release:
   - Force-release held turn/reactive/autonomous slots before manual
     `stop_keepalive` marks a keeper stopped.
   - This prevents a stopped keeper from continuing to occupy a semaphore slot.

3. Event queue cost:
   - Replace list append enqueue with a two-list FIFO queue.
   - Preserve FIFO dequeue semantics while making enqueue O(1).

4. Tool metrics backpressure:
   - Keep the bounded 4096 queue, but drop best-effort metrics when full instead
     of blocking the tool completion path.

5. Memory cycle:
   - Read memory bank tails from the end of the file instead of loading the full
     file for recall.
   - Serialize memory bank append/rewrite per path with an Eio-aware mutex.
   - Preserve rows appended after compaction's initial read by re-reading under
     the lock before rewrite.

## Verification Plan

- Build focused targets for the touched keeper/runtime tests.
- Run:
  - `test_keeper_registry.exe`
  - `test_heartbeat_integration.exe`
  - `test_keeper_memory.exe`
  - `test_tool_metrics_persist.exe`
  - `test_keeper_event_queue.exe`
- Confirm the 2026-05-15 runtime logs still map to the patched failure paths:
  FD pressure, tool metrics backpressure, memory tail read, manual stop slot
  cleanup, and event queue cost.
- Check current local keeper runtime status. If no server is listening, record
  that live keeper verification is unavailable and use the focused keeper tests
  as the verification surface for this patch.

## Verification Status

Checked on 2026-05-15 from
`/Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-keeper-24-fleet-risk-controls`.

- `git diff --check`: passed.
- `env DUNE_JOBS=1 scripts/dune-local.sh build ./test/test_keeper_registry.exe ./test/test_heartbeat_integration.exe ./test/test_keeper_memory.exe ./test/test_tool_metrics_persist.exe ./test/test_keeper_event_queue.exe`:
  passed.
- `./_build/default/test/test_keeper_registry.exe`: passed, 89 tests.
- `./_build/default/test/test_heartbeat_integration.exe`: passed, 20 tests.
- `./_build/default/test/test_keeper_memory.exe`: passed, 79 tests.
- `./_build/default/test/test_tool_metrics_persist.exe`: passed, 5 tests.
- `./_build/default/test/test_keeper_event_queue.exe`: passed.
- Runtime log evidence still maps to this patch: system log seq
  `50483`-`50518` on 2026-05-15T03:52:50Z-03:53:43Z shows
  `fstatat`, `openat`, `mkdirat`, and `execve` failures with "Too many open
  files in system"; coverage gap line 1 records
  `tool_call_io_append_failed` for `imseonghan/keeper_broadcast`.
- Host limit check: `ulimit -n` returned `245760`; `sysctl kern.maxfiles
  kern.maxfilesperproc` returned `491520` and `245760`.
- Live endpoint check: `127.0.0.1:8935` was not listening, so live keeper
  endpoint verification was unavailable in this pass.

Follow-up hardening check after proactive admission/TLA+ addition:

- `bash scripts/audit-tla-ml-line-refs.sh`: passed, 34 keeper-state-machine
  specs checked.
- `env DUNE_JOBS=1 scripts/dune-local.sh build ./test/test_keeper_registry.exe ./test/test_heartbeat_integration.exe`:
  passed.
- `./_build/default/test/test_keeper_registry.exe`: passed, 89 tests.
- `./_build/default/test/test_heartbeat_integration.exe`: passed, 20 tests.
- `KeeperFleetPressureAdmission.cfg`: TLC clean model passed, 49 distinct
  states.
- `KeeperFleetPressureAdmission-buggy.cfg`: TLC buggy model violated `Safety`
  as intended, exit 12.

## Remaining Operational Work

- Host-level nofile configuration is still required for sustained 24-keeper
  operation. This patch degrades or cools down when the inherited process limit
  is unsafe; it does not raise the host limit.
- A future dashboard follow-up should expose FD-pressure cooldown as first-class
  partial-truth state, so missing telemetry is shown as "recording failed" rather
  than as an empty trace.
