# GOAL LOOP Runtime Scheduler

`scripts/goal_loop_scheduler.py` is the repo-local runtime entrypoint for the
GOAL LOOP cadence contract:

| Phase | Default cadence |
| --- | ---: |
| Observe | 5 seconds |
| Orient | 60 seconds |
| Decide | 3,600 seconds |
| Act | 86,400 seconds |
| Verify | 300 seconds |

The scheduler does not replace the phase tools. It wraps them, records when each
phase was due, runs configured commands, writes observable state JSON, and forces
an immediate Observe re-entry when the last Verify phase reports `FAIL`.

## Config

Use JSON with one command per phase. Commands are argv arrays, not shell strings.

```json
{
  "schema_version": 1,
  "phases": {
    "observe": {
      "cadence_seconds": 5,
      "command": ["python3", "scripts/observe_goal_loop_logs.py", "/var/log/masc.log"],
      "output_path": "/tmp/goal-loop/observe.json",
      "timeout_seconds": 30
    },
    "orient": {
      "cadence_seconds": 60,
      "command": ["python3", "scripts/orient_goal_loop_logs.py", "/tmp/goal-loop/observe.json"],
      "output_path": "/tmp/goal-loop/orient.json"
    },
    "decide": {
      "cadence_seconds": 3600,
      "command": ["python3", "scripts/decide_goal_loop_findings.py", "/tmp/goal-loop/orient.json"],
      "output_path": "/tmp/goal-loop/decide.json"
    },
    "act": {
      "cadence_seconds": 86400,
      "command": ["python3", "scripts/validate_goal_loop_act_map.py", "test/fixtures/goal_loop/act-map.startup.json"]
    },
    "verify": {
      "cadence_seconds": 300,
      "command": ["python3", "scripts/verify_goal_loop_logs.py", "/tmp/goal-loop/orient.json"],
      "output_path": "/tmp/goal-loop/verify.json"
    }
  }
}
```

## Run

One tick:

```sh
python3 scripts/goal_loop_scheduler.py \
  --config /tmp/goal-loop/scheduler.json \
  --state /tmp/goal-loop/scheduler-state.json \
  --status-out /tmp/goal-loop/scheduler-status.json
```

Long-running loop:

```sh
python3 scripts/goal_loop_scheduler.py \
  --config /tmp/goal-loop/scheduler.json \
  --state /tmp/goal-loop/scheduler-state.json \
  --status-out /tmp/goal-loop/scheduler-status.json \
  --loop
```

Dry-run planning:

```sh
python3 scripts/goal_loop_scheduler.py \
  --config /tmp/goal-loop/scheduler.json \
  --state /tmp/goal-loop/scheduler-state.json \
  --dry-run \
  --format text
```

## State Contract

The state JSON exposes, per phase:

- `last_started_at`
- `last_completed_at`
- `last_status`
- `last_exit_code`
- `last_error`
- `next_due_at`
- `lateness_seconds`
- `missed_deadline`
- `runs_total`
- `consecutive_failures`

Command exit failures are recorded as `ERROR`. JSON outputs with
`{"status": "FAIL"}` are recorded as `FAIL`, which keeps the scheduler
`overall_status` critical and schedules Observe immediately on the next tick.
