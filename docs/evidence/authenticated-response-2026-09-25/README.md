# Authenticated response observations

The probe now accepts `--agent-name` and sends the same percent-encoded
`X-MASC-Agent` header as the TUI. The server resolves a bearer owner from the
token; the header is an identity hint, not evidence of authentication success.
`credential_supplied` replaces the misleading input-presence field
`authenticated`. No token value is retained.

## Executed checks

- `python3 test/test_response_latency_probe.py`: 10 tests passed, including
  credential owner/bearer delivery on GET, MCP initialization, ping and DELETE,
  plus absence of the synthetic secret from output and evidence.
- Python syntax and `git diff --check` passed; no local OCaml build.
- Adversarial and review-response inspection found no concrete defect.

## Live observations

Both records used the existing TUI credential at the user's requested runtime
base. Each round starts five GET requests and one MCP ping concurrently, with
separate persistent connections. All 360 sampled responses returned HTTP 200,
decoded, and reported no stale/warming marker. This is a short response probe,
not a proof of every feature or sustained operation.

| Observation | HTTP path p95 range | MCP ping p95 | Largest response time |
| --- | ---: | ---: | ---: |
| First 20 rounds | 61.381–98.447ms | 160.742ms | 364.866ms |
| 40 rounds with stack sampling | 13.907–17.580ms | 32.101ms | 783.539ms |

Both before/after identity checks reported commit
`0c7a2d4f6babd942179ed942a732d9320b305264`, executable SHA256
`d66654148abe6905d3616378b889cb318b7d9cef4ef59fdf5971faed500c8dc6`,
and instance `01a0d40a-75f8-7000-94c2-148fd0103ad1`. No deployment was made.

The runtime and host load were not held fixed between probes. Sampling adds
observer overhead. The second result is not an optimization speedup. The
0.1ms objective is not met by either record.

## Remaining attribution

Server-Timing on MCP ping reports time in authentication, identity and dispatch;
those wall times also include scheduler delays. The main-domain stack excerpt
contains gzip response preparation and GC work inside the compressor. This
establishes remaining work on that domain, but does not assign every long
response to compression or authentication. Repeated immutable response
preparation and cold-path computation need controlled follow-up.
