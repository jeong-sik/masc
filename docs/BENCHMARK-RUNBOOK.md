# Benchmark Runbook

Use the benchmark whose evidence matches the question being asked.

## Keeper Fleet Runtime Evidence

```bash
./scripts/harness_integrated_benchmark.sh
```

This runs the `control` phase and writes a machine-readable `summary.json` plus
the phase log. See [INTEGRATED-BENCHMARK-RUNBOOK.md](./INTEGRATED-BENCHMARK-RUNBOOK.md).

## Tool-Calling Quality

Aggregate the checked-in evidence fixture:

```bash
./scripts/harness_tool_call_quality.sh
```

Run fresh isolated Keeper cases:

```bash
./scripts/harness_tool_call_quality.sh --live
```

The case catalog is `benchmarks/data/tool_call_quality_cases.json`. The live
mode starts an isolated local server, executes the cases, writes raw evidence,
and passes it through the benchmark CLI.

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

## E0 Campaign Scoreboard

A round is three acceptance-runner bundles on one pinned binary. One passing
run is evidence, never a score.

1. Run `keeper_multi_collaboration_acceptance.py --run` three times with the
   same `--expected-source-sha`; keep every `bundle.json`.
2. Write `residuals.json` (`masc.keeper_campaign_residuals.v1`): one entry per
   assertion that failed in any of the three runs, with `cause` from the closed
   set `infra_rate_limit | harness | model_behavior | product` and the tracking
   `issue` (`owner/repo#N`, or `null`). A failed assertion without an entry
   leaves the round `counted=false` (`residual_unclassified`).
3. `scripts/harness/workload/campaign_issue_states.sh states.json <previous residuals.json>`
   records the GitHub state of every issue the previous round named.
4. `scripts/harness/workload/campaign_scoreboard.py --catalog scripts/fixtures/keeper-multi-collaboration/missions.json --bundle r1/bundle.json --bundle r2/bundle.json --bundle r3/bundle.json --residuals residuals.json --previous-residuals <previous> --issue-states states.json --out docs/evidence/keeper-e0-campaign-scoreboard.json`

Rules the scoreboard enforces:

- `k_of_3_passed` counts a mission only when all three runs passed every one
  of its assertions. Pass/fail comes from the assertions, never from the
  mission `status` label; a bundle whose label disagrees with its assertions,
  or that lacks a catalog assertion, is refused.
- An uncounted round has `k_of_3_passed: null`; the number it would have
  scored stays in `k_of_3_if_counted` so nothing is lost, but a Goal reading
  the score sees no score.
- Bands come from catalog `phase` values: the verification band is
  `verification` + `delivery_proof` (RW12, RW14, RW15, RW16, RW20 today), the
  pilot band is `claim_reproduction` (RW26).
- A round whose previous residual issues are still `OPEN` is run and recorded
  but not counted (`previous_issue_open`). Nothing waits on it; the next round
  is counted once those issues close.
- Mixed `source_sha`, duplicate `run_id`, fewer than three bundles, a cause
  outside the set, an issue not shaped `owner/repo#N`, or a residual naming an
  assertion the catalog does not declare are refused (exit 2), not scored.

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

Goal `goal-campaign-ratchet-20260902` reads `verification_band.k_of_3_passed`
from the scoreboard file. The first counted round is the r8 baseline.
