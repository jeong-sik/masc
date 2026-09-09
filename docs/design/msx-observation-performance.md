# Turn-based play and observation performance

This is an active measurement and implementation plan, not a completion report.
The objective includes reusable play Skills, responsive TUI and WebDashboard
surfaces, OCaml/MCP server speed, and a smooth spectator protocol without
flicker. The requested target is 0.1ms. Measuring individual stages does not
substitute one fast stage for the complete objective.

## Reproduce client-side read measurements

```sh
python3 scripts/harness/perf/response_latency_probe.py \
  --base-url http://127.0.0.1:8935 \
  --path /health \
  --path /api/v1/msx/frame \
  --path /api/v1/dashboard/shell \
  --path /api/v1/dashboard/bootstrap \
  --accept-encoding identity --samples 30 --interval 1 \
  --output artifacts/http-read-baseline.json
```

The existing probe samples GET surfaces and opens a read-only MCP ping session,
reusing an HTTP/1.1 connection. It retains each sample and separates response
headers, body reading and decoding. `total_ms` ends at wire receipt;
`decode_ms` includes decompression and JSON/SSE parsing; `client_total_ms`
includes both. These are client observations, not server CPU measurements.
Server-Timing is retained if the server supplies it.

The interval is between rounds, not individual requests. Keep the combined
path and MCP request rate within the server's operating limits. HTTP errors,
transport errors, malformed JSON, top-level error envelopes and explicit
warming responses are excluded from valid latency samples and retained in the
report. Stale/error cache states remain in percentiles but are counted as
stale and cannot satisfy the target verdict. A zero exit
code is not a performance or readiness verdict. Use the same
machine, active workload, media state, protocol and sample policy for a
before/after comparison. Record the running source and runtime instance
separately from a checkout's HEAD. The probe reads full health before and after
sampling and reports `same_runtime`; discard mixed-runtime comparisons.

Require meaningful state explicitly when timing one surface. For example, an
unloaded MSX response is valid HTTP but not evidence of active-frame performance:

```sh
python3 scripts/harness/perf/response_latency_probe.py \
  --base-url http://127.0.0.1:8935 --path /api/v1/msx/frame \
  --require-json /loaded=true --accept-encoding identity \
  --samples 30 --interval 0.2 --output artifacts/msx-frame-latency.json
```

`--require-json` accepts JSON pointers and JSON values and applies to sampled
GETs only. It does not constrain health identity or MCP replies. All selected
GET surfaces must satisfy the supplied conditions; run incompatible surface
contracts separately. Without conditions, measurements retain their stated
transport/protocol scope and do not establish application readiness.

## Initial live baseline

Measured with the initial client probe on macOS ARM64, loopback, sequential requests, 12 samples per surface,
100ms between requests. Runtime source was observed as
`d01b7bfb077439d50624986cb84669e0d005abfb`. Percentiles use nearest rank; with
12 samples p95 and p99 are the maximum sample. The table includes JSON decode
time, corresponding to `client_total_ms` in the shared probe. This baseline locates work;
it does not prove a sustained latency distribution.

| Surface | Median total ms | p95 ms | Maximum response bytes |
| --- | ---: | ---: | ---: |
| health | 1.54 | 4.60 | 8,443 |
| MSX frame | 5.94 | 7.44 | 434,323 |
| Dashboard shell | 3.57 | 151.28 | 49,176 |
| Dashboard bootstrap | 24.85 | 66.07 | 1,582,465 |

For MSX, median time through headers was 5.46ms and JSON decode was 0.36ms.
For Dashboard bootstrap, the respective medians were 13.77ms and 9.22ms.
Stage medians need not sum to the median total. None of these surfaces met
0.1ms. The removed `/api/v1/dashboard` endpoint returned 410 and is excluded.

A subsequent run of the extended shared probe required `/loaded=true` for
MSX and also measured an authenticated MCP ping session. Both health reads
identified the same runtime and source
`cdfc6ea4c4ce29be3948fec7a71b6a7c24b05828`:

| Surface | Valid samples | p95 wire roundtrip ms | Target met |
| --- | ---: | ---: | --- |
| Loaded MSX frame | 12/12 | 5.726 | No |
| MCP ping | 12/12 | 0.985 | No |

This is another baseline on a different runtime, not an improvement claim.
Its wire-only values exclude decode time, unlike the initial table.

## Concrete protocol work

The current MSX TUI poll calls `tick_msx`, advances the shared machine, fetches
its complete RGB payload and renders it. `Masc_tui_msx.render` starts each
paint with erase-display, while `place_rgb` transmits anonymous image data.
This bypasses the retained row presenter's synchronized/differential output.
An unchanged image is therefore erased and transmitted again as the frame
counter advances.

The next implementation units are:

1. Retain spectator pixels and presentation geometry. A counter-only update
   should update text without erasing or retransmitting the unchanged image.
   Commit the retained state only after successful output; invalidate it on
   resize, surface changes, protocol changes and failed writes.
2. Use explicit image and placement identities and synchronized presentation
   for changed frames. Preserve the old visible frame until its replacement
   is ready, and remove obsolete placements when leaving the surface.
3. Remove redundant frame rendering, encoding and transmission at the server
   boundary. Keep immutable frame identity distinct from simulation time and
   input attribution; a visual cache must not conceal a changed prompt,
   palette, disk, restoration or machine replacement.
4. Separate spectator observation from simulation-clock ownership. Multiple
   spectators must not accidentally multiply gameplay speed. Preserve a
   responsive input path while fetching or presenting frames.
5. Measure Dashboard rendering and input response in a browser, and measure
   OCaml execution, lock contention, serialization and MCP request latency
   separately. The HTTP table does not prove those unmeasured stages.

Kitty's protocol specifies image/placement replacement and chunk completion:
[terminal graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
Ghostty behavior must also be exercised: a protocol-compliant byte stream is
not evidence that a real terminal displayed it smoothly.

## Single-request retained tick protocol

The advancing spectator path is `POST /api/v1/msx/tick`, not the read-only
frame GET. Conditional GET/304 savings do not demonstrate steady spectator
improvement. The TUI requests `{"pixel_response":"retained"}` and, once it has
decoded pixels, includes `known_pixels` with their SHA256 `revision`, `width`
and `height`. This remains one advancing request per poll; it does not add an
image-fetch round trip or retry a failed mutation.

Every loaded response supplies fresh frame number, mode, media and players.
Its `pixels` object has `kind="inline"` with `rgb_base64`, or `kind="retained"`
without encoded pixels; both include the revision and dimensions. The server
captures the stepped frame and input ledger under one lock, then compares,
hashes and encodes immutable pixels in the strict worker. A separate response
worker serializes/compresses the result without replaying the mutation.
Ordinary tick requests and frame GETs continue to return complete images.
Deploy the updated server before or together with this TUI: an older server
rejects the new request fields. The client does not retry an advancing request
with a different body when a server refuses or fails it.

The client retains one pixel buffer scoped to host, port and captured auth
headers. A retained response must match what that request advertised. Fresh
metadata is rebuilt around those bytes; changed images replace them, an empty
machine clears them, and errors never become cached success. Late responses
cannot overwrite newer cached pixels. This cache does not change simulation
clock ownership or coordinate multiple spectators.

Measure actual POST ticks on unchanged and changing screens, including
concurrent MCP requests and the real TUI. Protocol byte savings alone do not
establish latency or smoothness, and the 0.1ms objective remains unproven.

## Acceptance evidence still required

- Real Keeper use of published primitive-based Skills, including newly learned
  transitions and verified campaign state changes.
- Actual Ghostty and browser spectator recordings: unchanged content remains
  visible, changed content appears coherently, and resize/reconnect recovers.
- Repeated latency distributions under representative concurrent Keeper,
  scrolling and spectator activity, with current binary/source identity.
- Separate timing evidence for primitive execution, MCP/HTTP delivery, TUI
  presentation and browser rendering; the requested 0.1ms target remains
  unachieved until its relevant measurements support it.
- A playable campaign with saved progress and honest victory/defeat evidence.
  A menu transition or an observer-only ending does not establish that result.
