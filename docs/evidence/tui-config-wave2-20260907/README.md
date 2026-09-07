# TUI configuration read evidence — 2026-09-07

TUI initialization previously called seven independent setting readers, each resolving, reading, and parsing the entire runtime.toml. The observed runtime file was 165667 bytes. Startup sampling captured five named setting-reader frames; the count of seven reads is established by the source, not by sampled stacks.

The change resolves and parses once into an immutable snapshot of all seven optional settings. Each later load reads disk again. Writers, default choices, and explicit false values are retained. The behavioral test covers retained choices after a file rewrite and freshness on the next load.

No post-change executable was built locally or measured. This change targets startup work; it does not establish a steady-frame speedup.

The accompanying frame report is a separate baseline from the installed binary with embedded commit 01ef94a84037f1aff6cf57d3f3919131e24a4f6f. Its SHA-256 stayed unchanged during observation. A synthetic 150x45 PTY waited for Overview output, sent four Tab keys, and terminated its own process with SIGTERM after the measurement window; exit 0, no forced kill. First Overview output appeared after 0.925s. This is output readiness, not terminal-display latency. No terminal screenshot is claimed by this packet.

59 recorded frames: build p95 6.24ms, present p95 10.45ms; one Memory build took 695.17ms. These mixed-pane, profiler-instrumented measurements demonstrate remaining work, not acceptance of the 0.1ms target. Native sampling during the frame window mostly captured idle/wait stacks and did not attribute the Memory spike. Actual runtime/provider load was uncontrolled.

Validation at submission: independent review found no blocking issue; git diff --check passes. OCaml compilation and behavioral execution are delegated to CI.
