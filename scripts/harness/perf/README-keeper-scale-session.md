# Owned Keeper scale session

`keeper_scale_session.py` exercises actual Keeper owners and queued chat
operations against a supplied native server binary. Python 3.11 or newer and
the repository's release runtime fixture are required. It runs no build.

Start with two Keepers and four messages:

```sh
python3 scripts/harness/perf/keeper_scale_session.py \
  --binary /absolute/path/to/masc \
  --repo "$PWD" \
  --output /tmp/keeper-session-new \
  --keepers 2
```

For a 300-Keeper observation, use `--keepers 300 --settle-timeout 1200`.
The output directory must be new. Observation deadlines belong to this
experiment; they do not configure Keeper turn limits. An expired deadline
stops the owned server during cleanup and can cancel its pending operations.
Preserve that failure and distinguish it from spontaneous runtime failure.

Each run copies and hashes the native binary, creates an isolated base/HOME/
configuration, and binds ephemeral loopback server/provider ports. Runtime
health must identify that exact source, binary and base before any mutation.
Only the local scripted provider is configured, with fixture credentials.
Keepers declare a lazy microVM lane and an unused image pin; the model emits
text only. Guard wrappers deny every guest/daemon command with exit 126.
Exact read-only inventory forms are classified separately; an unexpected
command disqualifies the run. No image, guest or tool execution is proven.

The first model requests remain held until every Keeper has an actual
concurrent request and all messages have durable operation IDs. The harness
reads their Queued/Running states before release, then checks exact typed
replies and operation identities. Legitimate input batching is allowed.
After graceful shutdown, offline read-only SQLite reads and backup integrity
checks join every public operation and outcome reference to its actual owner.
Provider handlers must drain and the owned process must be reaped.

One admin producer encounters the existing server rate limiter. Only explicit
pre-dispatch HTTP 429 mutations are retried. Retry-After is honored; when it is
absent, a one-second client fallback wait is recorded. Ambiguous mutations
are never replayed. Lost read-only status observations are retained and
re-read for the same operation and live runtime until the observation deadline.

The packet contains exact identity, frozen harness/configuration, raw RPC and
model observations, phase-specific health samples, rejected requests and
waits, public terminal replies, offline SQLite backups and cleanup receipts.
It also contains a copied executable and ephemeral authentication data;
keep the packet local rather than committing it. `owned-process.json` and
`workload-phases.jsonl` support a separate read-only profiler. Such observers
add overhead and their success/failure is independent of workload completion.

Report held, released and settled phases separately. Creation-to-completion
includes deliberate provider hold, admission pacing, queueing and runtime
work. Health wire times include client/OS/transfer cost. One scripted-model
session does not prove independent HTTP producers, external model throughput,
Keeper-to-Keeper tool calls, Addon Lanes, visible TUI behavior or the overall
0.1 ms goal. Compare exact source/binary/configuration identities and retain
shared-host and inventory-maintenance effects before inferring a speedup.
