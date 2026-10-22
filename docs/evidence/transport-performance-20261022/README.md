# MASC transport measurement, 2026-10-22 KST

Related issue: #44998. These are transport measurements, not installed UI speedup evidence.

## Conditions

The two isolated runs use the **same installed native binary**, source
`b43722cb596bed252b7c4bb626173773550d1438`, SHA256
`5753a7d54b223acb673462a8ebe17ad1588535129fc2f143ba39144600a5e7e3`.
Each run owns a separate temporary workspace and loopback port, with zero
Keeper fibers and workspace authentication disabled only in that fixture.
The fixture's model endpoint is the dead loopback port in the repository's
release-evidence runtime config. Each owned server terminated with exit 0.
No production server was replaced or reconfigured by this experiment.

Host: Apple M3 Max, 128 GiB RAM, macOS 26.6.1 arm64; client Node v26.3.0.
HTTP uses persistent HTTP/1.1 and identity encoding. Each lane has a separate
connection, setup and one method warmup are retained separately, and request
order rotates. Each method has 30 samples per transport, spaced by 1200ms
between rounds. This is a light loopback workload, not a saturation test.

All lanes validate the RPC ID/result before the end timestamp, and compute
the canonical result hash after that timestamp. Every valid response matches
the HTTP JSON warmup reference. HTTP JSON uses the MASC force-JSON header;
HTTP SSE is the finite POST response, not an observer subscription.

## Results

Each cell is p50 / p95 latency in milliseconds, including transfer and client
parse/RPC validation. All **180 measured requests** across the two isolated
runs passed, as did six method warmups, six setup operations and session cleanup.

| Operation | HTTP JSON | HTTP SSE | WS |
|---|---:|---:|---:|
| MCP `ping` | 0.752 / 1.624 | 0.682 / 1.222 | 0.383 / 0.669 |
| MCP `tools/list`, about 81KB | 2.145 / 6.024 | 2.306 / 5.022 | 2.053 / 3.749 |

Median Node client process CPU per request window, in microseconds:

| Operation | HTTP JSON | HTTP SSE | WS |
|---|---:|---:|---:|
| `ping` | 414 | 427 | 174 |
| `tools/list` | 866 | 923 | 631 |

These CPU windows include any unsolicited WS work in that client process.
They are not server CPU or browser CPU attribution. Body sizes in the raw
receipts exclude headers, WS framing and TLS; they are not full wire sizes.
The tools/list JSON and WS response bodies have the same byte total. SSE
adds 36 body bytes per response in this fixture (1080 bytes over 30 replies).

WS had lower latency and client CPU in these samples. Its median advantage
over HTTP JSON shrank from about 0.37ms for ping to about 0.09ms for tools/list.
Session setup was about 10ms for WS versus 1.5–2.5ms for the HTTP lanes, so this
does not establish an advantage for opening a new connection per operation.
Small sample counts, ambient host load, a single machine and the auth-disabled
fixture limit generalization. No automatic winner or performance threshold is imposed.

## Authenticated live usability

[`live-auth.json`](live-auth.json) uses the same runner hash against the live
server. Dashboard hello authenticated successfully, but generic MCP ping over
WS returned **-32001** in its warmup and all six measured attempts. HTTP JSON
and HTTP SSE each completed all six requests. The runtime identity remained
unchanged within that run and all temporary sessions were closed.

The live run therefore correctly has `passed:false`; its WS errors are not
successful low-latency samples. A fast auth-disabled WS result is not evidence
that authenticated general MCP clients can use that path. Dashboard's own
WS methods are a separate contract.

## Evidence and limits

- [`ping.json`](ping.json), [`tools.json`](tools.json): final runner raw samples,
  setup/warmup/cleanup, result hashes, Node client CPU and before/after identity.
- [`context.json`](context.json): binary/environment and fixture identity.
- Missing-runtime-ID HTTP fixture: the final runner exited 1, wrote
  `passed:false`, `before:null` and `initial_health` diagnostics. This checks a
  negative evidence boundary, not server performance.
- Node syntax and whitespace checks passed. No local Dune build or CI was run
  for this JavaScript measurement change. Independent source review found no
  unresolved P0–P2 issue at runner SHA256
  `9543ead0698597854a6dd0ae20aa61d0079d2b063b2ed494fbab9c03139ea85d`.

Server CPU/RSS attribution, sustained throughput, compression comparisons,
remote networks, observer event fanout, TUI frames and browser rendering have
not been benchmarked by this harness. It does not prove a production speedup.

The operational choice supported here is to retain WS for persistent Dashboard
interactions while retaining Streamable HTTP for authenticated MCP. Large
snapshot/download and browser-render decisions still need their own workload
measurements; this result does not justify migrating every request to WS.
