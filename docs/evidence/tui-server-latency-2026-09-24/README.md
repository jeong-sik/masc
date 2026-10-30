# TUI and server latency observation, 2026-09-24

This is a baseline from the installed 0.37.0 TUI and running server. It does not measure the proposed ASCII layout change. The TUI SHA-256 is recorded, but its source commit was not independently established. The server reports embedded commit `5381527774287fecbc1dea66ed38540334dc5d2f`; both probes saw the same server instance before and after.

The runtime path was verified with `/health?full=1`: base `~/me`, runtime `~/me/.masc`. Machine paths are omitted from this packet. No server restart or configuration change was performed.

At 150 columns and 45 rows, ten Tab writes yielded 60 timed frames. Build p50/p95/max: 1.58/3.37/5.21 ms; present: 0.02/0.96/4.91 ms. PTY Overview readiness was 1.345 seconds. The probe observes writes and frame timings, not a terminal emulator's painted pixels or an acknowledgement for every input.

Twenty rounds of five concurrent persistent HTTP GETs returned 200 on all 100 samples. Endpoint p95 ranged from 3.7285 to 4.849208 ms. MCP initialization returned 401, so authenticated MCP latency remains unmeasured. One scheduler window reported p99 286.115292 ms and max 2039.853 ms; these are scheduler delays, not request timings.

A separate 4-second macOS `sample` capture of a probe-owned TUI showed `Masc_tui_message_layout.feed`, `drain`, `scalar_cell_width`, and `Uuseg_grapheme_cluster` on active stacks. This identifies avoidable segmentation as a candidate bottleneck; sampling does not establish a speedup.

The proposed change skips segmentation for wholly printable ASCII runs, and width-only scans avoid allocating a piece per character for printable ASCII plus recognised CSI sequences. Other input retains the Unicode path. ASCII followed by combining marks or emoji selectors must remain a whole cluster, consistent with [Unicode text segmentation](https://www.unicode.org/reports/tr29/#Grapheme_Cluster_Boundaries). MASC already presents changed rows; [Ratatui's rendering description](https://ratatui.rs/concepts/rendering/under-the-hood/) likewise separates frame construction from terminal output.

Reproduce using `scripts/harness/perf/tui_latency_probe.py` and `scripts/harness/perf/response_latency_probe.py`; the packet retains geometry, send times, server identity, raw request samples and frame histograms. For a candidate comparison, use a CI-built binary with independently verified source identity, identical geometry and controlled data/load. No local build was run.

Still required: candidate CI and execution, controlled before/after comparison, all TUI actions and wheel/page/keyboard scroll coverage, terminal screenshots, authenticated server surfaces, and sustained-load verification. The overall 0.1ms objective remains unachieved.
