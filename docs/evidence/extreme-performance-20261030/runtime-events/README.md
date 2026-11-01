# Runtime-events investigation and owned-process boundaries

The full 0.1 ms TUI/server goal remains unachieved. This unit improves how an
isolated Keeper workload is observed and records evidence for the next I/O and
scheduler investigation. It is not a product performance optimization or an
installation/deployment receipt.

## The 300-owner diagnostic observation

`legacy-300-summary.json` is an instrumented run of the same pinned installed
server used in the earlier baseline: embedded source
`d55ec56c6227e65a07f3fefffec28e6d425ac47b`, executable SHA256
`71c11512a67643124f7236cc321a176de311a1b342d825d06c911bc7c68ecfb4`.
It completed 600 durable operations and 600 scripted provider requests, with
maximum concurrency 300. The offline auditor confirmed public/exact-owner
SQLite outcomes and complete observed inventory coverage for this run.

Of 2,261 health samples, one failed. Released-phase successful health reads have
p95 141.554 ms and maximum 10,605.676 ms; these are not percentiles including
the failed read. The provider is scripted text, not a real external model.
There is no TUI, guest, peer/broadcast or concurrent Add-on proof here. Host
workloads were not stopped, and tracing adds CPU/memory/I/O overhead. This is
not a controlled before/after comparison with the uninstrumented baseline.

Both legacy readers report approximately 22.6 million events and zero loss
after backlog draining, over approximately 368 seconds. Their raw reports
show:

- Domain 0: 88 uninterrupted fiber intervals at least 100 ms, maximum
  2,213.9 ms. That maximum has 0.0 ms GC recorded by this consumer.
- Across domains: maximum recorded `stw_handler` approximately 842.961 ms.
- Intervals around file operations, append and fsync deserve further study.
  They do not identify a single cause of the 10.61-second HTTP observation.
  Fiber elapsed time can include OS descheduling/blocking; it is not exclusive
  CPU. Concurrent/nested span and lock sums can exceed the observation window.

The common `30.jsonl` label is ambiguous: the owned base contains 1,614 such
daily ledgers, totaling 24,880,003 bytes, with the largest 4,748,180 bytes.
Do not attribute a basename-only interval to a particular ledger or assume
multi-gigabyte retained history caused this isolated run's stalls.

`legacy-300-reader-receipt.json` retains the original, **weaker** collection
predicate. Its `complete=true` is not upgraded to the later stop/flush protocol.
The old consumers did not acknowledge post-workload stop or explicit final
report flush. The reports remain diagnostic observations, with original
digests and sanitized path substitutions described in `provenance.json`.

## What the current collector checks

`keeper_scale_session.py --tracers DIR` privately copies `rtev_watch.exe` and
`rtev_fibers.exe`. Both must acknowledge backlog draining before any Keeper
creation, and both plus the owned server must still be live within the
monotonic setup deadline when admission starts. After the workload, the driver
signals stop and reaps the readers before stopping its server. Acceptance
requires nonzero observed events, zero post-drain ring loss, unchanged private
binary hashes, stop acknowledgement and final report-flush acknowledgement.
Wall-clock inequalities are supplemental; the ready/stop handshake establishes
causal ordering without relying solely on wall-clock stability.

The consumers retain their bounded summaries: pre-window names/open spans/locks
are not reconstructed from discarded backlog, individual short runs are omitted
from detailed lists and output is top-N. Satisfying collection conditions does
not establish complete causal tracing, per-request synchronization or exclusive
CPU attribution.

The installed native 2-owner qualification completes four durable operations
with both acknowledgement types and zero post-drain loss. It is deliberately
separate from the legacy 300-owner diagnostic. Tool sources and native compiler
receipts are frozen by version; capture script hashes bind each qualification
to the code that actually ran. Older/historical observations certify only their
recorded source bytes.

The final-source qualification in `native-2-v7-*` uses `tools-v3/`, completes
four durable operations and passes the independent packet auditor. That short
run observed zero volume-inspect commands/complete inventory groups; its complete
final-segment flag means no partial observed group, not four inspected volumes. It records
32 successful health samples, zero post-drain loss and both reader acknowledgements;
these small-run observations do not certify the 300-owner workload under the new
protocol. `owned-write-failure-v2-result.json` and `final-provider-*.json` bind the
final runner source. The older `native-2-v5-*` also uses `tools-v3/`; the earlier
`native-2-v4-*` uses `tools-v2/` and is preserved separately. `source-identities.json`
binds private reader hashes, copied script hashes and the installed server
identity. The prior canonical component's 18-test CI success is recorded
separately in `prior-component-ci.json`; it is not performance acceptance for
the observation tools or installed fleet.

## Failure boundaries

The manual probes use new output directories and never operator credentials.
Result records bind the tested session/trace module bytes where specified. The
manifest hashes the current reproduction helpers; the helper bytes at execution
time were not separately snapshotted in these result records. Do not infer an
execution-time helper digest from the current reproduction-source digest.
`probe-owned-write-failures.py` injects a first workload error, a finalization
write error and a trace-receipt write error around real owned native processes,
including a one-hour provider-delay setting. The delay is cancelled; the first
error and subsequent cleanup errors remain distinct, server/readers are reaped,
and model listener/sampler/handler counts drain. A failed write cannot be a
precondition for attempting the other resource cleanups.

`probe-reader-protocol.py` uses synthetic reports and actual owned OS children
to reject a missing final-flush marker and an early reader termination even
when numerical wall containment passes. It is not runtime-events or performance
evidence. `probe-late-provider.py` sends one additional actual request to the
owned loopback provider after the early projection. Final validation must reject
the duplicate after the listener and handlers have stopped, rather than certify
the earlier four-call projection.

The same late-provider probe supports `--case malformed`, `--case http-method`
and `--case outcome-write`. Each first establishes four normal model calls.
It then sends JSON `[]`, a PUT that receives HTTP 501, or an extra valid call
whose outcome-record write fails. Expected final rejection must specifically
come from the provider-error validation, so an unrelated workload failure does
not count as this probe passing. Unsupported HTTP and unexpected handler/record
errors remain in the final failure snapshot even after their handlers drain.

Reproduce against an explicit existing binary and separately compiled frozen
tracing tools, always selecting **new** `artifacts/` output paths:

```sh
python3 scripts/harness/perf/keeper_scale_session.py \
  --binary "$PINNED_SERVER" --repo "$CHECKOUT" --keepers 300 \
  --settle-timeout 1200 --tracers "$TRACER_TOOLS" --output "$NEW_RUN"
python3 scripts/harness/perf/keeper_scale_packet_audit.py \
  "$NEW_RUN" --output "$NEW_AUDIT"
python3 docs/evidence/extreme-performance-20261030/runtime-events/probe-owned-write-failures.py \
  --repo "$CHECKOUT" --binary "$PINNED_SERVER" \
  --tracers "$TRACER_TOOLS" --output "$NEW_FAILURE_PROBE"
python3 docs/evidence/extreme-performance-20261030/runtime-events/probe-reader-protocol.py \
  --repo "$CHECKOUT" --output "$NEW_PROTOCOL_PROBE"
python3 docs/evidence/extreme-performance-20261030/runtime-events/probe-late-provider.py \
  --repo "$CHECKOUT" --binary "$PINNED_SERVER" --output "$NEW_LATE_PROBE"
```

Copy a chosen frozen tool version into a new working directory before compiling
it with the argv recorded in its build receipt. No local full product/Dune build
is part of this evidence. Raw owned packets, private configuration, prompts and
SQLite/WAL remain under ignored `artifacts/extreme-perf-20261030/`.
