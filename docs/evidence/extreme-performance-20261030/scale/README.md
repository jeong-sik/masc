# Installed-source 30/300 Keeper baseline

These sanitized derivatives preserve measurements from isolated, owned server
processes. The live shared server was not restarted or loaded with synthetic
Keepers. The installed binary reports source
`d55ec56c6227e65a07f3fefffec28e6d425ac47b`, executable SHA256
`71c11512a67643124f7236cc321a176de311a1b342d825d06c911bc7c68ecfb4`.
The harness checkout is `0b18418111a533b3dc10c33b8811b1d058f136fe`;
these are different source identities. Both scale runs used a pinned private
copy of the same installed binary, on one 16-CPU, 128-GiB macOS host.

Commands from the checkout, with new output directories:

```sh
python3 scripts/harness/perf/keeper_scale_session.py \
  --binary "$PINNED_MASC_BINARY" --repo "$CHECKOUT" \
  --output "$NEW_RUN_OUTPUT" --keepers 300 --settle-timeout 1200
python3 scripts/harness/perf/keeper_scale_packet_audit.py \
  "$NEW_RUN_OUTPUT" --output "$NEW_AUDIT_OUTPUT"
```

The 30 run used `--keepers 30 --settle-timeout 300`. The 300 deadline was an
experiment bound, not a product runtime budget. First provider calls were held
until the actual owners and durable queue operations were observed, then
released. The provider returned scripted text. There were 30/300 actual
concurrent provider requests, not 300 independent clients or real model calls.
One admin producer admitted two messages per Keeper, including recorded retry
waits. No guest, tool, browser, TUI or Add-on lane execution was tested.

| Observation | 30 Keepers | 300 Keepers |
| --- | ---: | ---: |
| Durable successful operations, public and exact-owner offline SQLite reread | 60/60 | 600/600 |
| Actual scripted provider calls | 60 | 600 |
| Maximum provider requests held concurrently | 30 | 300 |
| `/health/live` samples, all observed HTTP 200 | 81 | 1,279 |
| Released-phase health wire p50 / p95 / max, ms | 1.443 / 12.067 / 16.831 | 2.103 / 35.235 / 8,936.694 |
| HTTP 429 responses | 4 | 35 |
| Retry wait, seconds | 4.017 | 35.101 |
| MCP status transport timeouts | 0 | 3, approximately 15 seconds each |

Health wire measurements include a newly opened connection for each request,
through body receipt. They do not time the entire queue operation, JSON parsing,
or terminal display. Forced provider holds and sequential observation make
operation wall times unsuitable as production-throughput measurements. A
successful retry and durable completion do not erase failed observation attempts.

Both owned server children exited 0, were reaped without forced kill, and
drained provider requests; their bases and SQLite/WAL data remain retained.
The independent auditor confirms the workload and durable outcomes for both.
The 300 auditor nevertheless exits **3**: its last observed volume-inventory
coverage group contains 160 of 600 expected distinct names, following one
complete 600-name group. This is incomplete observation at shutdown, not proof
that 440 volumes or log entries were lost. Do not call the entire audit PASS.

The 300 run recorded 760 refused `container volume inspect` invocations, plus
two refused read-only inventory calls. Guards prevented guest/daemon execution;
wrapper invocation and host process costs still exist. The complete 600-name
observed group spans 36.85 seconds and overlaps model release. This temporal
overlap does **not** establish causation for the 8.94-second health outlier.
Server-Timing records a later status success taking 13.719 seconds, including
13.624 seconds labeled dispatch. Those labels include waiting, not exclusive
CPU attribution. The 60-second scheduler-lag snapshots have their own windows
and are not a trace of the earlier outlier.

The original packets live under ignored
`artifacts/extreme-perf-20261030/native-{30,300}-v1` and corresponding audit
directories. They contain credentials/configuration, raw responses, model
prompts, logs and databases and are intentionally excluded from Git.
[provenance.json](provenance.json) names and hashes source observations;
retained files are derivatives, not byte-identical originals. Summary fields
also derive from each packet's cleanup/owned-process records and the auditor's
post-run report. Bodies and private host paths were removed from samples.

`live-http-baseline.json` is a separate, sequential persistent-connection probe
of the already running shared server: 20 samples each for health/live, shell,
execution and MCP ping. Its 20-sample nearest-rank p99 equals the maximum; it
is not a stable tail estimate. `total_ms` ends at body receipt; `decode_ms` and
`client_total_ms` separately include Python JSON/SSE handling. The pre-sample
health/MCP setup may already have opened the connection, so the first sample
is not certified cold. No JSON requirements were supplied. Structural `valid`
and absence of a declared stale flag do not prove semantic completeness or
freshness; `timeout_fallback` is not included in the runner's stale enumeration.
The matching endpoint self-reports bind the ends, not each individual sample.
`credential_supplied` reports a header, not a demonstrated actor permission.
Later admin response inspection identified actor=admin and the parameterized
execution cache path; it does not retroactively identify every earlier sample.
