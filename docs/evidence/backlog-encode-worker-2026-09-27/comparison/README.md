# Backlog encoding: completed Linux comparison

[Run 36261792837](https://github.com/jeong-sik/masc/actions/runs/36261792837)
completed 24 owned sessions and 2,400 timed requests. The original comparison
artifact `10912841629` has ZIP SHA-256
`3e2905a6ffb61c93973076fb15896ec1f92ac9bc3ed0947c79fe5ccc0d7d2d00`.

## Identity and protocol

- Baseline: `e2108de673d313e08ae0fff623d74cff5be3fc25`, Linux probe run
  `36259842156`, artifact `10911978342`.
- Candidate: `59ac892798156870fd04860a14436e8644a46341`, Linux probe run
  `36259844483`, artifact `10911609517`.
- Observer: `637551d63fe6514860b4e2579ebd0319054e45c7` ([harness PR #39409](https://github.com/jeong-sik/masc/pull/39409)).

Both binaries passed repository/run/source/attempt, exact ZIP membership,
SHA256SUMS and ELF x86-64 checks. The runtime then reported the expected
embedded commit and executable hash before requests. The source difference
is exactly the backlog implementation/interface, test and changelog; see
`source-scope.json`.

Each of four text/request-encoding conditions ran three alternating pairs
(AB, BA, AB). Every session seeded 250 synthetic tasks, then performed 20
mutation/first-execution/repeat-execution cycles. A separate phase released
20 mutation/liveness pairs from a client barrier. Timers include fresh TCP,
OS and client overhead through complete body read, excluding gzip/JSON
parsing and evidence writes. The phases and text/encoding groups are not
pooled. Requested gzip is an input condition, not a claim about the response:
all cold execution replies were identity, all gzip-group repeat replies were
gzip, and the other timed replies were identity.

## Validation

Independent rereading of the original receipts confirmed all 24 sessions,
2,400 timed requests, 2,784 total recorded HTTP responses, identical inputs
and normalized task payloads across builds, generation advancement,
cold/repeat decoded-byte equality, and expected encoding/cache paths. All
48 final backlog copies have 290 tasks at revision 54; primary/recovery bytes
match per session. All server owners were reaped with exit zero, all stubs
stopped, and the model stubs received 24 discovery GETs and no POST.

All 480 concurrent request pairs overlap at the client. This does not prove
that the liveness handler ran during JSON encoding; it does not isolate
scheduler delay from networking or client scheduling.

## Observations and decision

Milliseconds; 60 observations per build in each row. Lower-pair counts compare
per-session medians, not the pooled median. The two can differ.

| Text | Requested encoding | Phase | Baseline median | Candidate median | Baseline p95 | Candidate p95 | Candidate median lower pairs |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| ascii | identity | mutation | 18.659782 | 19.116831 | 21.545057 | 22.038986 | 0/3 |
| ascii | identity | cold | 16.183787 | 16.331032 | 17.790074 | 19.317373 | 2/3 |
| ascii | identity | warm | 0.509983 | 0.498933 | 0.619797 | 0.640508 | 2/3 |
| ascii | identity | concurrent_mutation | 24.163138 | 24.167169 | 26.913770 | 29.632383 | 2/3 |
| ascii | identity | concurrent_liveness | 0.646621 | 0.647848 | 0.777601 | 0.807694 | 2/3 |
| ascii | gzip | mutation | 19.335729 | 19.279905 | 22.428043 | 24.560822 | 0/3 |
| ascii | gzip | cold | 16.262541 | 16.403410 | 18.738299 | 20.496356 | 1/3 |
| ascii | gzip | warm | 0.471719 | 0.455093 | 0.633467 | 0.562454 | 3/3 |
| ascii | gzip | concurrent_mutation | 24.795600 | 24.618623 | 30.403496 | 27.828284 | 1/3 |
| ascii | gzip | concurrent_liveness | 0.687960 | 0.681512 | 0.860001 | 0.796613 | 2/3 |
| multilingual | identity | mutation | 20.323655 | 20.874413 | 22.970154 | 23.219181 | 1/3 |
| multilingual | identity | cold | 16.316371 | 16.622899 | 17.740401 | 18.825142 | 1/3 |
| multilingual | identity | warm | 0.625296 | 0.622406 | 0.708527 | 0.761406 | 1/3 |
| multilingual | identity | concurrent_mutation | 25.417172 | 25.350612 | 27.546581 | 28.005373 | 1/3 |
| multilingual | identity | concurrent_liveness | 0.713832 | 0.756798 | 0.840434 | 0.855261 | 0/3 |
| multilingual | gzip | mutation | 19.976513 | 20.245223 | 24.112591 | 22.616392 | 2/3 |
| multilingual | gzip | cold | 16.341574 | 16.572862 | 17.700608 | 19.029329 | 1/3 |
| multilingual | gzip | warm | 0.505788 | 0.499386 | 0.574946 | 0.548197 | 3/3 |
| multilingual | gzip | concurrent_mutation | 25.823809 | 25.531174 | 29.238494 | 27.681519 | 2/3 |
| multilingual | gzip | concurrent_liveness | 0.726824 | 0.735718 | 0.858408 | 0.864760 | 2/3 |

The first execution GET's p95 is higher in all four conditions. Serial
mutation p95 and concurrent-liveness median/p95 are higher in three of four.
Repeat GET medians are slightly lower in all four, with mixed p95. This run
does not demonstrate a consistent responsiveness benefit from the worker
submission. The source PR is held as draft pending stronger evidence or a
revised change; no further identical run is scheduled just to seek a better
result.

The largest baseline observation is 332.556828 ms, ASCII/identity repetition
1, serial mutation cycle 3. Candidate maximum is 48.954104 ms, the same
condition/repetition, serial mutation cycle 16. Both remain in the data;
their causes are unknown and their difference is not attributed to the patch.
All 1,200 candidate observations exceed 0.1 ms (minimum 0.342451 ms).

## Retention and limits

All 293 original artifact members are retained under `raw/` with deterministic
gzip. `redaction.json` links original decoded hashes to published decoded
hashes. Only CI checkout/home and owned workspace/artifact prefixes change.
Where a response body changes, original `body_sha256` and `json_bytes` remain
and separate `published_body_sha256` / `published_json_bytes` describe the
public text. Timings, wire sizes, source/binary hashes and semantic values
are preserved. Full health, server logs, bodies, copies and exit receipts are
retained. The original private receipts passed the strict observer validator
before normalization; the public hash fields let readers check the copies.

`summary.json` is the observer output. `independent-audit.json` recomputes every
group, per-pair median count, overlap, encoding distribution and maximum from
the original receipts. P95 is nearest rank `sorted[ceil(0.95*n)-1]`.

This is one three-pair experiment per condition on a shared Linux CI host,
with fresh workspaces and no Keepers. It does not establish a general causal
regression or benefit, production deployment, macOS performance, physical
display latency, or multi-turn Keeper continuity. No CPU profile or encoding
entry/exit timing was collected. The 0.1 ms product goal remains unproven.
