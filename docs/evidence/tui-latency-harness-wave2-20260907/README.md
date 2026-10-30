# Repeated TUI observations — 2026-09-07

The new PTY harness exercised the installed binary twice, using a 150x45 terminal and four timed Tab writes. Both children exited with status 0 after SIGTERM; no forced kill. Each run verified an unchanged TUI binary SHA-256 and server runtime instance. These are unprofiled live observations, not controlled before/after comparisons. The measured binary already reflects independent deployment activity; no speed gain from a particular PR is attributed here.

- Run a: 70 frames, Overview output readiness 2.437s, build p95 1.68ms and first-frame maximum 192.84ms; present p95 0.10ms. Surface tags: Overview, Acting, Keeper list, Memory, Approvals.
- Run b: 64 frames, Overview output readiness 0.717s, build p95 2.11ms and first-frame maximum 197.99ms; present p95 0.12ms. Surface tags: Overview, Acting, Keeper list, Memory, Board list.

The changing last surface is why Tab writes are recorded as inputs rather than treated as proof of exact navigation transitions. Background updates and availability alter visible surface selection. The raw timing reports retain all per-surface summaries and outliers. The harness does not emulate terminal capability replies or measure physical display latency. The full-path 0.1ms goal is not achieved.

Reproduce using `scripts/harness/perf/tui_latency_probe.py` with an explicit binary, base path and new output directory. The first run predates added option/surface-tag metadata; the second includes those fields. Subsequent failure-path hardening retains malformed after-health and missing executable evidence without changing normal measurement behavior.

Five fake-only failure scenarios passed against the final harness SHA-256: missing/empty/blank base identity rejects before launch; final executable removal and malformed after-health retain incomplete result plus timing. `fake_failure_probe.py --harness <probe.py> --output-dir <new-directory>` reproduces them without a real MASC process.
