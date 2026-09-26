# Isolated server artifact comparison

The existing `bench-tests.yml` workflow accepts `compare_server=true` and the
baseline/candidate run, artifact and full source IDs. It consumes successful
`linux-x64-probe.yml` outputs on Ubuntu 24.04; it does not compile or deploy.
`compare_tui` and `compare_server` are mutually exclusive.

The artifact verifier checks repository, source, workflow, successful run,
attempt, ZIP size/digest, exact five-member layout, all four executable hashes
and ELF64 x86-64 headers before launching a binary. A partial/failed run has
no overall performance summary. Raw responses and per-session failures remain
available through the workflow's unconditional artifact upload.

Default protocol: 250 synthetic tasks, 20 cycles per phase, three alternating
pairs for each of ASCII/multilingual text and identity/gzip request encoding.
Every one of the 24 sessions owns a fresh workspace, ephemeral loopback HTTP
port and model stub. The server receives an explicit environment allowlist,
no operator credentials and no Keepers. Only model discovery GETs are allowed;
any model POST invalidates the session. The workspace is deleted after cleanup;
only the two synthetic backlog copies, health, server log and receipts remain.
The ephemeral dashboard token is neither an input from the operator nor a
recorded response.

`server_tasks` and `server_workers` set the initial task count and synthetic
active-agent count (defaults 250 and 0). They are also `--tasks` and `--workers`
on the driver/session commands. Workers are ordinary agent JSON records in the
owned workspace, not Keeper processes. Their fixed 2001 presence timestamps
make their attention rows visible. Every execution response must contain all
seeded workers with unchanged status/identity fields, zero owned-task counts
and no offline rows; the fixture uses Todo tasks only. The final agent files
must match the initial fixture. This exercises per-agent task scanning but
does not measure claimed-task map updates or live Keeper behavior.

The driver retains full agent/brief receipts and compares them between builds,
including row order. Only `last_signal_age_sec`, derived from each render's
clock, is removed from that semantic comparison; the original value remains
in every HTTP receipt. Workload size is recorded in identity, plan and summary.
Runs with different worker/task counts are separate experiments.

## Measurement phases

1. Add one task, then read the first and cached execution projection. Validate
   exact task count, generation advance, expected cache timing metric, selected
   accepted response encoding, and identical decoded cold/warm response bytes.
2. In a separate phase, release an add-task request and `/health/live` request
   from a two-thread barrier. Record both complete request intervals and their
   client-side overlap count. This does not establish overlap with the server's
   encoding work, isolate scheduler delay, or guarantee overlap in every pair.

Each HTTP observation uses a fresh connection. Timing starts before the client
sends the request and ends after the complete response body, before gzip/JSON
decoding and evidence writes. It includes TCP, OS and client overhead. The
concurrent phase also depends on client thread scheduling. Request encoding is
a session axis; actual response encoding is recorded independently and counted
in every summary group. A gzip-accepting request may receive identity, including
the current execution route's cold JSON fallback; this is never reported as
observed gzip. An identity-only request must not receive gzip.

The driver independently validates receipts after every session, requires the
same tool inputs and task payloads across both builds/repetitions/encodings
within each text kind, and compares persisted task fields excluding only
`created_at` and `updated_at`. Primary/recovery bytes and revision progression
must agree. It reports each text/encoding/phase separately; no cross-axis or
historical pooling. P95 uses nearest rank. Whole-response target checks remain
0.1 ms and are separate from scenario correctness.

## Scope and tests

`test/test_server_artifact_comparison.py` exercises invalid provenance,
unfinished/wrong workflows, ZIP/checksum/architecture/symlink errors, incomplete
receipts, HTTP-200 tool failure, endpoint/identity drift, cleanup failure and
unexpected model calls. These synthetic validator tests do not run MASC or
prove the benchmark itself completed.

Successful fixture results do not establish production identity, deployment,
all-surface responsiveness, physical display latency or multi-turn Keeper
continuity. SIGINT/SIGTERM lets the session owner unwind its server and stub;
forced termination or runner loss can interrupt cleanup/upload, so acceptance
requires a complete cleanup receipt, not merely an exit notification.
