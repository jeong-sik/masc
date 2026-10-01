# Candle currency: native and terminal evidence

[Test run 36595091066](https://github.com/jeong-sik/masc/actions/runs/36595091066)
completed successfully at source `f86dfe04f95a4ef608b92cc0985d6cff56b8a9d7`.
The original suite log records 17 successful suites: 16 Alcotest executables
with 653 cases, plus the real TUI currency PTY alias with four scenarios.
No targeted failure line occurs. [Provenance](provenance.json) preserves source
hashes, artifact IDs/digests and the exact suite list.

## What ran

The terminal scenario starts the CI-built TUI against an isolated loopback HTTP
fixture. Its input currency JSON is synthetic. It checks exact values above
JavaScript's integer precision boundary in Overview and Keeper Info, then:

| Response | Visible result | Control/recovery |
|---|---|---|
| Disabled | Currency unavailable; old amounts withdrawn | Real pause POST accepted; Ready restores balance |
| Malformed supply | Currency unavailable; old amounts withdrawn | Real pause POST accepted; Ready restores balance |
| Malformed balance | Currency unavailable; old amounts withdrawn | Real pause POST accepted; Ready restores balance |
| Off | Currency labels hidden | No pause/recovery assertion in this case |

The three pause requests have exactly `{"action":"pause"}` and the terminal
shows `alpha pause accepted`. This proves client interaction with the fixture,
not that a live Keeper paused. Keeper identity remains visible during errors.
The fixture deliberately leaves unrelated endpoints unavailable.

Readable `.txt` frames and request receipts are retained alongside the native
binary hash in [manifest.json](manifest.json). Raw original PTY streams are in
`terminal-streams.tar.gz`; `scenario.py` is the executed source at the tested
commit. The archive changes no stream bytes.

The same run separately executes real isolated ledger Paid 1000 → purchase 200 →
equip → public roster → strict TUI decoder assertions: issued 1000, burned 200,
circulating 800 and wallet 800, followed by damaged-ledger withdrawal with
healthy Keeper lifecycle retained. It also verifies aggregate issuance beyond
OCaml max_int and strict canonical decimal/conservation parsing. Those native
ledger cases and the synthetic terminal replay are distinct evidence.

## Scope

This run predates SSE correction `7a5cdd1326` and the integration with main's
Dashboard layout. It does not validate either change, live SSE ordering,
actual-model grade quality, deployed binary identity or long-running Keepers.
The older warm HTTP case uses its original free-item fixture; the later actual
1000→800 warm HTTP/SSE scenario is not attributed to this run.

`ci-run-tests.log.gz` is a lossless compressed copy of the complete suite log.
`SHA256SUMS` covers the bundle, excluding itself. No production workspace or
configuration was modified for these scenarios.
