# HTTP/2 response resources

The H2-only and Auto listeners read two restart-scoped settings from
`runtime.toml`. The process environment is not read for them; the second column
is the key the boot load stores the value under.

| TOML key | Boot-store key | Default | Scope |
| --- | --- | --- | --- |
| `transport.h2_max_concurrent_streams` | `MASC_H2_MAX_CONCURRENT_STREAMS` | 100 | Peer request streams per H2 connection |
| `transport.h2_max_pending_response_bytes` | `MASC_H2_MAX_PENDING_RESPONSE_BYTES` | 67108864 | Application payload bytes retained across all H2 connections of one listener |

Values must be positive integers. The stream limit cannot exceed 2147483647;
invalid values fail configuration resolution instead of disabling admission.
The payload setting counts whole response copies and queued/in-flight SSE
frames. Protocol frames, source/cache values and serialization temporaries
remain outside this ledger. This is not a process RSS limit.

A whole response reserves its encoded payload before sending headers. If the
listener has insufficient capacity, it returns an empty 503 with `no-store`,
preserving CORS headers and removing the source representation's encoding and
cache validators. Accepted responses keep the existing flush-before-close
behavior, including clients that consume more slowly than the initial H2 window.
Reset and connection cancellation release reservations even when the writer's
flush callback cannot run.

Subscription callbacks reserve and enqueue immutable SSE frames without waiting
on the network while holding the shared publisher lock. A separate request
fiber drains one frame at a time. Capacity exhaustion resets that stream;
it does not silently drop events or end a partial SSE as successful. GitHub login
SSE uses a sequential, reserved write-and-flush path outside publisher locks.
There is no response idle timeout.

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
