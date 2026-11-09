# HTTP/2 response resources

The H2-only, Auto and HTTPS listeners read three restart-scoped settings from
`runtime.toml`. The process environment is not read for them; the second column
is the key the boot load stores the value under. Server push is never
advertised (RFC 9113 §8.4 deprecates it). The largest frame the server
accepts stays the library's 16384: the pinned h2 sizes the DATA frames it
writes by that value until the peer announces its own MAX_FRAME_SIZE, which
browsers and curl never do (#49940).

| TOML key | Boot-store key | Default | Scope |
| --- | --- | --- | --- |
| `transport.h2_max_concurrent_streams` | `MASC_H2_MAX_CONCURRENT_STREAMS` | 100 | Peer request streams per H2 connection |
| `transport.h2_max_pending_response_bytes` | `MASC_H2_MAX_PENDING_RESPONSE_BYTES` | 67108864 | Application payload bytes retained across all H2 connections of one listener |
| `transport.h2_initial_window_size` | `MASC_H2_INITIAL_WINDOW_SIZE` | 134217728 | Flow-control window each H2 stream starts with, in bytes. The default is the h2 library's 2^27, not the RFC 9113 65,535; request bodies are received against this credit |

Values must be positive integers. The stream limit and the window cannot exceed
2147483647;
invalid values fail configuration resolution instead of disabling admission.
The payload setting counts whole response copies and queued/in-flight SSE
frames. Protocol frames, source/cache values and serialization temporaries
remain outside this ledger. This is not a process RSS limit.

A whole response reserves its encoded payload before sending headers. If the
listener has insufficient capacity, it returns an empty 503 with `no-store`,
preserving CORS headers and removing the source representation's encoding and
cache validators. Accepted responses keep the existing flush-before-close
behavior, including clients that consume more slowly than the initial H2 window,
as long as each 16 KiB slice of the body drains within the stall bound below.
Reset and connection cancellation release reservations even when the writer's
flush callback cannot run.

Subscription callbacks reserve and enqueue immutable SSE frames without waiting
on the network while holding the shared publisher lock. A separate request
fiber drains one frame at a time. Capacity exhaustion resets that stream;
it does not silently drop events or end a partial SSE as successful. GitHub login
SSE uses a sequential, reserved write-and-flush path outside publisher locks.

A stream whose oldest response flush goes 90 seconds without an answer is
reset with RST_STREAM(INTERNAL_ERROR), and one warn line names the request
method and path, without the query (RFC-0518 D2). The time counts from when
that flush became the oldest one waiting. Bodies written through the ledger
get a flush at every 16 KiB slice (D3), so the 90 seconds run between one
slice and the next, not over the whole body. A client that opens its window
again only after reading a batch of bytes has to read each batch within 90
seconds: at 32 KiB per batch that is about 364 B/s. The reset releases the
stream's fibers and reservations.

An error answer h2 opened for a failed request ends differently when it
stalls: the client gets the bytes its window allowed and an empty
END_STREAM, then RST_STREAM(INTERNAL_ERROR) (anmonteiro/ocaml-h2#278). Two
error answers have no bound: one h2 opens on the connection reader, and one
for a fiber forked on the stream switch that raised before the response,
which is reported after the stream's scope ended. The bound is a code
constant, not a setting. gRPC listener responses are written by `Grpc_eio`
and are outside it.

The default stream capacity follows RFC 9113 section 6.5.2's recommendation to
allow at least 100 concurrent streams. The 64 MiB payload allocation also covers
the measured 100-stream workload of 25,810,100 payload bytes in
[#37956](https://github.com/jeong-sik/masc/issues/37956#issuecomment-6263101562),
while admitting larger bodies and streaming queues only within that allocation.

Focused behavioral targets are `test_h2_response_resources`,
`test_h2_response_window`, `test_h2_request_body_admission`,
`test_h2_request_fibers`, `test_h2_oauth_request_fibers`,
`test_h2_json_worker`, `test_keeper_runtime_config_leaf` and the H2 cached-payload
case in `test_dashboard_http_core`. Resource-core probes alone do not establish
gateway, bootstrap or configuration integration results.
