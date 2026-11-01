# Keeper-list sampling and same-draw reuse candidate

The 100 us objective remains unmet. These are sampling-instrumented native TUI
observations at original source `5297349b101d61bb901b3729d43c4dec8bb30ec4`, **not
executions of the frame-reuse candidate and not a before/after comparison**.
The [native-owner bundle](../native-tui-owners/README.md) documents the exact
native pair, their digests and the successful focused build wrapper. The shared
installation/server was not changed. Each new observation owns its base/HOME,
server, provider and TUI. The provider is a scripted local final-text fixture.

## Observation and failure boundaries

The adapter copies the previously qualified observer, sends one complete Keepers
key write, then runs `/usr/bin/sample PID 5 1 -mayDie -file REPORT` against only
its own TUI. It waits for that sampler's exit before ending the observation,
with an owned-process observation window, and explicitly reaps it. The sampler
spends additional time resolving symbols. Both sampler direct children and TUI children exited
zero and were reaped without forced termination; provider handlers drained after server shutdown.
Original replacement-server denial, direct loopback health, PTY EOF draining,
phase-count validation and clock separation remain in the observer. The
`cleanup.json` field `sampler_stopped` refers to the HTTP latency thread; OS
profiler settlement is recorded separately in `observation.json.profiler`. No
claim covers every descendant or every abnormal termination path.

| Held Keeper owners | Native list Builds | List Build p50 / p95 ms | Main-thread snapshots | Overall owner workload |
| ---: | ---: | ---: | ---: | --- |
| 2 | 113 | 0.254 / 0.552 | 4,089 | 4/4 original operations validated and durable |
| 300 | 103 | 5.151 / 11.096 | 4,131 | Failed: settlement status observation deadline |

`capture_qualified` only qualifies the TUI/profiler transport and phase record.
It does not make the 300-owner workload successful. Build distributions span the whole TUI observation, rather than only the
profiler collection interval. Quantiles use `int(q*(n-1)+0.5)`. Sampling affects
execution; these distributions cannot replace an uninstrumented baseline or estimate a
candidate speedup. Surface tags do not prove UI-loaded cardinality, applied-key
state, deep scrolling or physical paint. Population is actual held server-owner
count, not a measured row count in the TUI. The native clock is process-relative
and is never joined to the Python input/health clock.

At 300 owners the main-thread graph includes four `keeper_reading` →
`liveness_of_roster` branches with 77+4+55+5 = 141 inclusive sample occurrences.
Those are the **same 141 occurrences** under two symbol names, not 282, function
call counts, exclusive CPU time or CPU percentages. Their upper frames contain
`List.map`; tail-call/unwind ancestry does not establish that they came from a
particular render, Build or the duplicate invocation removed by the candidate.
No named reading sample at two owners is an absence-of-work proof.

The 300 run later exhausted its read-only settlement observation window while
the owned server remained live. The stored API terminal receipt has zero entries.
The harness then requested server shutdown. Only **after shutdown** did it back
up and reopen all 300 operation databases. Those exports contain 321 succeeded,
268 failed with `Turn_cancelled`, and 11 queued operations. Shutdown cancels live
turns, so the 268 cancellations are not independently attributed to a preexisting
product fault. These post-shutdown states do not certify settlement before the
deadline or a successful 600-operation run. Failure, cleanup and all selected
store exports remain intact. No deadline was enlarged or failed run overwritten.
The server settlement delay is unresolved.

## Candidate and next measurement

The source change in PR #46941 removes a separately verified duplicate path:
`render_keeper_list` already has ordered `model_rows`, while `selected_keeper`
reached `keepers_for_selection` → `ordered_keepers` → `keeper_list_rows` and
rebuilt that model. A separate roster map supplied only health `exists` and
runtime-width `max` folds. Selection and those commutative folds now read the
original rows in that same synchronous draw.

The sole renderer call is the `Keepers Keeper_list` branch. The model maps every
original Keeper into a keeper/reading pair and stable-sorts without dropping
duplicates. Cursor meaning, invalid/partial roster semantics and input authority
are preserved. There is no new mutable field, retained row cache or worker/UI
state. Independent adversarial and response source reviews found no new P0–P2;
that is source review, not formal GitHub approval or runtime proof. Parsing both
changed files passed. An exact-source native pair is needed to execute the actual
candidate; no faster-frame result is claimed here. The exact
`5de2eb7684f0e4fecee1c48caef50010c2f951fa` native pair was requested via
**Minimal manual checks**, run
[41025395547](https://github.com/jeong-sik/masc/actions/runs/41025395547), wrapper
ref main, scenario `workspace-files`. The retained dispatch is not a successful
build receipt or an execution of the candidate. Its three accompanying file
suites do not verify Keeper-list rendering. At the later work-boundary read,
this workflow was `in_progress`, conclusion null, execution wrapper main head
`06e43272be3f4bec7d2798f7d8d464774536895c`; the requested native source is
separate. No artifact was downloaded at that boundary.

This removes one renderer-local duplicate. Other callers still prepare their own
selection models, and each model still performs fleet-wide joins. These remain
measurement and architectural work within the full 30/300-owner, I/O, peer,
broadcast, Add-on, scroll/Page Down, DAW/Draw and flicker objective.

## Retention and reproduction

`provenance.json` pins selected exact source/capture pairs. Original output stays
under ignored `artifacts/`. Synthetic admitted inputs, terminal replies, selected
SQLite fields, held-health response bodies and native image addresses/paths
are included. Original configs,
auth tokens, raw terminal output streams, complete model/request logs, native
executables and complete SQLite/WAL packets are excluded.

Both analysis versions remain. V1's `line` is relative to the `Call graph:` section;
v2 records `call_graph_relative_line` and actual `report_line` separately and makes
the ancestry limit explicit. Named occurrence counts are unchanged. The manifest
separately pins classification-dependent failure/summary/execution files and
records absent originals at the later provenance recheck; these observations
do not retroactively bind v1/v2 classification inputs at their earlier execution
time. They are not among v1/v2 `inputs` hashes. Current values and the retained
execution receipt remain independently comparable. The retained
helpers contain capture-time output paths; do not rerun them over the captures.
With Python 3.11+, macOS `sample`, the pinned native pair and the same fixture
checkout, the probe can write a new ignored output:

```sh
python3 docs/evidence/extreme-performance-20261030/keeper-list-sampling/probe/keeper_scale_session.py \
  --binary "$PINNED_SERVER" --tui-binary "$PINNED_TUI" --repo "$CHECKOUT" \
  --output "$NEW_IGNORED_OUTPUT" --keepers 300 --messages-per-keeper 2
```

That command can fail as the retained 300 run did. A new invocation is new
evidence, not a replacement for a failed or incomplete original receipt.
