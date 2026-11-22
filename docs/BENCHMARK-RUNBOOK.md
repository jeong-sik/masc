# Benchmark Runbook

Use the benchmark whose evidence matches the question being asked.

## Tool-Calling Quality

Aggregate the checked-in evidence fixture:

```bash
./scripts/harness_tool_call_quality.sh
```

The case catalog is `benchmarks/data/tool_call_quality_cases.json`. The script
passes the catalog and the evidence file through the benchmark CLI.

## Keeper Continuity Observation

For a real Keeper's sequence of constraints, corrections, topic changes and
stop/resume, use the [temporal observation harness](guides/KEEPER-TEMPORAL-CONTINUITY.md).
It captures exact operation/turn identities, canonical prepared input, replies
and recorded tool calls. Its semantic assessment does not create a pass
threshold.

## Isolated Server Ports

An isolated benchmark or campaign server must not bind the production ports
8935 (HTTP), 8936 (gRPC), or 8937 (WebSocket). Pick a port at 9400 or above,
the way the harness smoke runners already do. A campaign that binds 8937
blocks the production server from restarting: on 2026-08-29 an E0 campaign
server holding `--port=8937` had to be killed to bring the workspace back.

## Evidence Boundary

- Wrapper success proves only the named benchmark phase and emitted evidence.
- Local benchmark output is not exact-head CI proof.
- Deployment proof requires a separately identified running binary and commit.

## E0 Campaign Rounds

A round is three acceptance-runner bundles on one pinned binary.

Run `keeper_multi_collaboration_acceptance.py --run` three times with the
same `--expected-source-sha`; keep every `bundle.json`. Fresh fleet creation
requires an explicit `--sandbox-profile` plus `--sandbox-image` for Docker;
microVM also requires `--microvm-backend`; SSH requires `--remote-endpoint`
instead of image/backend. Choose names configured on the campaign host.
The shell wrapper forwards `KEEPER_COLLAB_SANDBOX_PROFILE`,
`KEEPER_COLLAB_SANDBOX_IMAGE`, `KEEPER_COLLAB_MICROVM_BACKEND` and
`KEEPER_COLLAB_REMOTE_ENDPOINT`. A retained Keeper restart reuses its saved
declaration. Each run installs the composition Skills it measures from
`scripts/fixtures/keeper-multi-collaboration/skills/` into the campaign
workspace's `project-masc` skill source through `/api/v1/skills/editor/*`,
so the campaign `runtime.toml` must declare that source `read-write`.
`--preflight` only reads: before the first run it lists the fixtures as
`pending` and passes only if that source is writable.

### Sizing `--turn-settle-budget`

`--run` requires `--turn-settle-budget <seconds>`: how long one operator-started
keeper turn may take before the runner records it as not settled. It is a
property of the lane and the model, so it is measured per campaign, never
defaulted (`--timeout` is the HTTP request timeout and stays at its default).

1. Probe: run once with a generous budget (or read the previous round's
   evidence) and take, per operation, `terminal - operation_started_at`
   (server log `keeper_stream: request terminal ... request_id=<op>` joined
   with the runner's `turns/*.json`). That is exec time; `terminal - queued`
   adds queue wait, which only appears once an earlier turn overran.
2. Budget = the slowest role's p95 exec time with a 1.5x margin, rounded up
   to a minute. A budget below the max exec time turns product behaviour into
   harness failures and queues every later turn to that keeper behind the
   overrun (r8 run1 attempt 3, 2026-09-02: builders lost every turn that way).
3. Record the measurement next to the bundle; `resources.turn_settle_budget_sec`
   carries the value used.

Measured so far: r6 (2026-08-18, `glm-coding.glm-5-turbo`, docker) settled
inside 150s; r8 (2026-09-02, `glm-coding.glm-5.3`, microvm) — builder exec 41-362s (n=7), coordinator/reviewer/researcher 47-82s (n=4), measured on run1 of
2026-09-02 after the approval-stance fix (#32645), 11 settled operations at
the time of writing; the r8 round runs with `--turn-settle-budget 600`.
