# TUI latency observation

Run against an installed or CI-built binary and an already running local server:

```sh
python3 scripts/harness/perf/tui_latency_probe.py \
  --binary "$MASC_TUI_BINARY" --base-path "$MASC_BASE_PATH" \
  --output-dir "$TUI_OBSERVATION_DIR"
```

Python 3.11+ on POSIX is required. Output directory must be new. Optional `--port`, `--rows`, `--columns`, `--tabs`, `--tab-interval` and `--settle` parameters are retained in the report. The ready deadline and termination grace bound only this observation. No build is run.

The probe verifies the server's runtime identity and effective base path before launching its own TUI child. It waits for a complete Overview output frame, records timed Tab writes, and sends SIGTERM to that child so the existing frame histogram is flushed. The raw terminal stream is retained only with `--capture-screen`. A child that exceeds the termination grace is killed and the observation is marked incomplete. Normal TUI behavior remains active, including automatic server start after a connection failure; server lifecycle changes invalidate the observation.

`result.json` records TUI binary hashes before/after, server identities and scheduler/GC observations, geometry, options, key-write times, observed surfaces and process exit. Missing final executable bytes remain failure evidence rather than discarding the packet. `frame-timing.txt` is the TUI's build/present histogram. A complete observation means inputs were sent and timing output collected under matching identities; it does not acknowledge each navigation transition.

`observed_surfaces` lists the surfaces of every frame the TUI wrote, in the order each first appeared. It comes from the `masc.tui.surface_run.v1` lines of `frame-timing.txt` and their `masc.tui.surface_runs.v1` count (`tui_request_surfaces.py`), not from the histogram, whose per-surface `build[...]` lines cover only the first 512 frames of each phase. The TUI keeps 4096 surface runs; past them the list ends in `null`, and `surface_record.unknown_from_written_frame` names the first written frame whose surface is unknown. `surface_record` also gives the frames written and the runs read. When the report is missing or unreadable, or its surface runs are absent or cannot be read, `observed_surfaces` is `null` and `surface_record.error` says why. The list names what the TUI recorded writing; it does not count the frames the PTY received or place them in time. For surfaces per input window, use the [TUI request probe](README-tui-requests.md).

Readiness is time until a complete Overview frame was received through a PTY. The PTY drains bytes without a real terminal emulator or physical display; it does not reply to terminal capability queries. Build/present timings, output readiness and physical input-to-display latency are different measures. The report does not declare the 0.1ms goal achieved. Repeat against a source-verified binary with the same geometry and controlled data/load before claiming an improvement; separate cold frames from steady frames and retain outliers.

For files already collected, use the [offline startup-record report](README-tui-startup-report.md). It reads an explicit packet without launching a native child and retains missing, invalid and interrupted samples. Its descriptive deltas do not certify execution, source-to-binary identity, paint or speed.
