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
checks join every original input, public operation and outcome reference to
its actual owner. Admission and terminal identities use `(Keeper, operation
ID)` pairs; two inputs cannot silently collapse to one operation. Closed
backups are reopened read-only, checked with `PRAGMA integrity_check` and
compared across all operation columns using their Python SQLite value types.
Provider handlers must drain and the owned process must be reaped. The original
base remains under `OUTPUT/owned-base` on success and failure, including SQLite
WAL files and runtime logs. Cleanup stops owned processes and listeners; it
does not delete evidence. A failed backup or integrity check must preserve its
source for diagnosis.

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

New packets declare `masc.keeper-scale-evidence.v3`. Validate the evidence
boundary without launching MASC, or independently audit a completed v3 packet:

```sh
python3 scripts/harness/perf/keeper_scale_fault_probe.py \
  --output /tmp/keeper-evidence-faults.json
mkdir -p artifacts/keeper-scale-probes
python3 scripts/harness/perf/keeper_scale_inventory_tail_fault_probe.py \
  --output artifacts/keeper-scale-probes/inventory-tail-new
python3 scripts/harness/perf/keeper_scale_packet_audit.py /tmp/keeper-session-new \
  --output /tmp/keeper-session-new-audit
```

The inventory-tail probe requires a new `--output` directory whose parent
already exists. It runs synthetic inventory and mocked output-ownership cases
without opening SQLite. `--packet PATH` optionally checks the four source JSON
files of the 650-record regression capture; it does not run a full packet audit.
`--baseline-reader PATH` optionally compares the candidate reader with a frozen
earlier reader and demonstrates its incomplete-tail rejection. `--reader PATH`
selects the candidate reader; without it, the sibling
`keeper_scale_packet_audit.py` is used. Results and any supplied-packet coverage
derivative are written only under the new output directory.

Before provider release, a single SQLite read transaction per Keeper records
all operation columns and batch membership together. Original source/input
bytes and admission/execution/member digests are checked against the exact
submitted text and the isolated dashboard principal. The canonical byte check
is restricted to this ASCII, null, object and list fixture, with no floats; it
is not a general Python/Yojson equivalence claim. Merged batch leaders and
cleared terminal inputs follow their distinct producer rules. The independent
reader reconstructs inputs from the workload and raw successful RPC requests,
then reopens both the retained original and backup databases. This additional
held observation cost belongs to the experiment, not released throughput.

The fault probe covers duplicate identities/inputs, ownership, missing replies,
corrupt or changed backups, original payload/digest/batch drift and failure
preservation of original DB/WAL/log bytes. The independent reader exclusively creates
its required `--output` directory outside the original packet; existing outputs,
symlink outputs and paths inside the packet are rejected. All derived reports and
audit-failure receipts go there, preserving raw receipts and the original workload
verdict. Full inventory coverage groups still require the exact expected-volume
Counter. A final unique known-volume subset is reported as incomplete, with its
observed count and missing volumes; it is not completed coverage or a producer
sweep ID. The reader then exits 3 after writing every derived record, and
`inventory_final_segment_complete` is false in `post-run-audit.json`; exit 0
means every observed coverage group was complete. Derived records name the
packet by its directory name and its receipts by their names inside it, never
by a host path. The reader accepts v3 only; older packets retain their frozen
original readers and results.

Report held, released and settled phases separately. Creation-to-completion
includes deliberate provider hold, admission pacing, queueing and runtime
work. Health wire times include client/OS/transfer cost. One scripted-model
session does not prove independent HTTP producers, external model throughput,
Keeper-to-Keeper tool calls, Addon Lanes, visible TUI behavior or the overall
0.1 ms goal. Compare exact source/binary/configuration identities and retain
shared-host and inventory-maintenance effects before inferring a speedup.
