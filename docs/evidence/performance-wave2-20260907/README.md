# Response speed improvement wave 2: baseline and implementation

The requested target is 0.1 ms across TUI, WebDashboard, OCaml, and MCP.
It is **not achieved**. These observations describe the deployed baseline,
not this branch. No post-change binary or browser speedup has been measured.

HTTP baseline binary: `a4e66033110f6b3909e364045e3f4e2f8c3e8965`,
SHA-256 `63029d8f876e2fe25d478024e90ea716cd3b0ccc4d6e7ac828d775b4d301722d`.
Before/after runtime identity is recorded in both HTTP artifacts. The browser
showed a stale dashboard-bundle warning; its screenshot is evidence of that
installed UI, not an exact-source rendering of this branch.

| Measured path | Samples | p50 ms | p95 ms | Evidence |
| --- | ---: | ---: | ---: | --- |
| Anonymous health | 30 | 1.456 | 2.276 | `anonymous-http.json` |
| Anonymous light shell | 30 | 0.740 | 0.823 | same |
| Anonymous execution | 30 | 0.633 | 0.734 | same |
| Anonymous tools | 30 | 2.011 | 3.271 | same |
| Anonymous telemetry summary | 30 | 1.105 | 2.624 | same |
| Authenticated execution | 8 | 6.505 | 9.042 | `authenticated-http-mcp.json` |
| Authenticated MCP ping | 8 | 1.001 | 1.148 | same |

These are sequential persistent-connection HTTP/1.1 roundtrips including
transfer, under naturally changing Keeper/host load. The authenticated run
spaces rounds by 0.5 s and all 48 sampled requests succeeded. Eight samples
are preliminary observations, not a reliable tail characterization.
An earlier unpaced authenticated run hit 429s; it cannot prove a speedup.
An earlier 20-request execution sample had p95 19.9 ms on the same binary,
illustrating why two differently loaded windows are not a controlled A/B.

Browser: Chromium headless, 1440×1000; three real button-click round trips
between Overview and Keepers, with title assertions for each destination.
Click-to-second-requestAnimationFrame durations were 13.7–84.6 ms; long tasks
were 53–110 ms. This timing includes frame scheduling, not just JavaScript CPU
cost, and does not establish that all asynchronous data had rendered. Raw
clicks, resource timings, and long tasks are in `browser-interactions.json`;
the final rendered surface is `dashboard.png`.

TUI: the installed executable emitted `tui-first-exit.txt` after an initial
PTY navigation attempt (150 columns × 45 rows): build p95 1.75 ms, present
p95 0.09 ms, first-frame build 189.37 ms. Its driver timed out during shutdown,
so the report has incomplete process-exit/provenance coverage. A repeat with
a controlling PTY also failed to exit within the observation window and was
terminated; `tui-repeat-provenance.json` records that failure and binary hash.
The repeat produced no frame report. These are provisional TUI observations,
not repeatable acceptance evidence or proof of a TUI improvement.

Implementation prepares identity/gzip/zstd responses once for each immutable
default execution snapshot on a CPU worker. A typed Empty/Preparing/Ready
state shares preparation, checks the source snapshot and workspace at read
and publication, and releases waiters on failure/cancellation. Scoped,
forced, full, and error requests keep their own projection paths. H1 and H2
select prepared bytes and share ETag matching; H2 gains conditional responses.
This first change does not optimize authenticated actor-specific projections.

Server phase measurement now uses a monotonic clock and 0.001 ms wire
resolution. The [Server Timing specification](https://www.w3.org/TR/server-timing/)
defines the attribution surface; phase durations are not end-to-end latency.
Conditional responses omit a false zero Content-Length, following
[HTTP semantics section 8.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.6).

Validation added: independent codec decoding, representation reuse and request
scope, mutation/new-source races during preparation, failure recovery,
concurrent preparation sharing, waiter release, and sub-target timing precision.
Source/diff and live Python probe checks passed. OCaml behavioral and compilation
checks require CI; no local build was run, per the repository contract.

Remaining work: exact-head CI, post-change deployed-binary measurements,
actual worker cancellation and H2 wire validation, authenticated projection
caching, TUI frame construction, browser long-task attribution/removal, MCP
tool-dispatch costs, and repeated representative-load measurements. Passing
one endpoint or an unchanged-frame fast path does not complete the goal.
