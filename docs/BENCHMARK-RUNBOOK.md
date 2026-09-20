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

## Librarian Continuity Measurement

`masc-librarian-continuity` measures answers produced from explicit synthetic
snapshots. It generates a question from a reference turn, then answers in a fresh,
tool-free context containing only that question, the supplied facts, and unread
text. TypeSafe JEV Noul evaluates the answer against the reference. The existing
`masc-librarian-replay` remains a separate, read-only structural replay.

With an installed CLI, a configured Agent Core runtime, and the existing
`TYPESAFEAI_API_KEY` configuration:

```bash
masc-librarian-continuity \
  --config /path/to/runtime.toml \
  --runtime '<configured-runtime-id>' \
  --input benchmarks/data/librarian_continuity_synthetic.json \
  --output /path/to/continuity-report.json \
  --publish-base-path /path/to/masc-workspace
```

The runtime ID selects the question/answer model; the existing TypeSafe model
and endpoint configuration selects the judge. This command supports Agent Core
API runtimes. CLI runtime transports are rejected explicitly. It does not read
live Keeper history or change Memory, Librarian progress, or scheduling.

The output file is the canonical report. Choose a new output path: existing
files, including the input dataset, are refused before model calls. The report
is saved before any sample starts
and after each stage, retaining provider failures and incomplete work. Exit 0
means every sample was scored; exit 1 means some samples remain failed or
incomplete; exit 2 means configuration, input or report persistence failed.
No exit code depends on a Noul score threshold. Each scored sample keeps its actual response
models, question, answer, context, criteria and raw probability. Generation
request hashes describe prepared bytes before dispatch; they alone do not prove
that the remote provider received a request.

`--publish-base-path` is optional. It publishes the same final bytes in the
selected server's artifact store and prints their SHA. The artifact is a view
copy and may be collected when no durable consumer references it; keep the
output file. A failed copy is reported as `publication_error` in stdout JSON
and does not change the measurement's exit code or its retained report.

Each case declares `question`: a fixed string skips question generation; `null`
asks the selected runtime to generate one from the reference. The report records
provided and generated questions as different types; a provided question has no
invented model response metadata. Keep fixed questions unchanged when comparing
models or context snapshots. A rerun writes a new report; it does not resume an
old run.

The checked-in catalog has two controls (verbatim fact present/absent), three
semantic cases, and one generated-question example. The controls check whether
the measurement distinguishes available and unavailable information. The
semantic cases retain a rule in different words, retain its duration while
losing its temperature condition, or retain the complete rule only in unread
text. They test whether the same fixed question remains answerable from each
snapshot. A partial context need not produce a middle probability: Noul judges
the complete stated proposition, not the fraction of facts retained.

These synthetic cases do not establish continuity across a live Keeper's
Librarian updates or long-running fleet behavior. That requires separately
chosen snapshots and operational evidence.

[Source: official Noul contract](https://docs.typesafe.ai/primitives/noul),
checked 2026-09-21 KST: Noul is the probability that the stated proposition is
true, not a measure of the degree of memory retained.

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
- A Terminal-Bench task's `skills_dir` is common benchmark input, not a MASC
  Skill-treatment arm. The adapter snapshots it into the separate read-only
  `terminal-bench-task` source and refuses missing, rejected, or shadowed task
  packages before the episode. Arm b still excludes MASC seed Skills.

## E0 Campaign Scoreboard

A round is three acceptance-runner bundles on one pinned binary. One passing
run is evidence, never a score.

1. Run `keeper_multi_collaboration_acceptance.py --run` three times with the
   same `--expected-source-sha`; keep every `bundle.json`. Each run installs
   the composition Skills it measures from
   `scripts/fixtures/keeper-multi-collaboration/skills/` into the campaign
   workspace's `project-masc` skill source through `/api/v1/skills/editor/*`,
   so the campaign `runtime.toml` must declare that source `read-write`.
   `--preflight` only reads: before the first run it lists the fixtures as
   `pending` and passes only if that source is writable.
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
