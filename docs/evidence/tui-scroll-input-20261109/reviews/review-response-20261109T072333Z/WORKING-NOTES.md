# Scroll plus typing investigation

Active objective: reduce Keeper chat input latency while PageUp/PageDown and
wheel scrolling. No result below proves a physical terminal paint or completion.

Source baseline: installed `eb4e550c0450f21f22ffe712aeac9a4e9a1a752d` copied
to this directory. Candidate `bae45a3e0e70de9c238e2a16410ccf15d295a4be`
on `perf/tui-scroll-input-20261109`, base
`e16382ef5471e15cd5002c674d2e93b87faa20d6`.
The six involved TUI sources have no baseline-to-base diff. Candidate changes
the background worker count, defers an unused command status projection, and
stops live-edge source indexing at the first valid retained point.

Manual native check: **Minimal manual checks**, run `42578002082`, workflow
ref `main`, exact requested source `bae45a3e0e70de9c238e2a16410ccf15d295a4be`,
scenario `detail-ownership`. This is a selected macOS TUI compile and three
ownership suites, not full regression, release, installation, or latency proof.

## Measurement revisions

- `baseline-scroll-eb4e550c`: existing scroll-only observer on the live server.
  Build p95 61.90 ms, max 245.29 ms. Host load average exceeded 200. Does not
  measure typing, causal input output, or physical paint.
- `mixed-eb4-trial`, `mixed-eb4-800`, `mixed-eb4-profile`: heavy ANSI parsing in
  the live reader could stall PTY draining. Retained diagnostic failures;
  exclude their latency values from candidate comparisons.
- `mixed-eb4-fast-drain`: timestamped PTY chunks analyzed offline. PageDown
  began only ten pages back and then hit the tail, so exclude that direction
  from a sustained-scrolling claim. Offline CSI/OSC decoder review found
  potential split-sequence errors, but replaying the real captures with the
  corrected decoder reproduced all original ACK timestamps.
- `mixed-eb4-profile-fast`: independent profiler observation. Main-thread
  allocation/GC/STW occupied a large share of samples; `Array.init` is an
  allocation trigger, not a precise source callsite. Present p95 9.1 ms,
  Build p95 64.0 ms. Final-prefix ready check searched only a small recent
  output suffix and falsely timed out even though all characters were observed.
  Do not use this run's incomplete flag as a functional failure.
- `mixed-eb4-corrected`: PageDown starts 100 pages back; live reader only
  drains bytes; final prefix searched in the retained stream. This version
  preceded the final streaming OSC/DCS decoder and per-run script snapshots.

The final probe snapshots its source and both imported fixture modules for each
run, hashes the executable before/after, and preserves timestamped chunk sizes,
every key write, every draft-prefix observation, and all missing observations.
It uses a separate synthetic loopback workspace, never sends Enter, and checks
PTY echo is disabled. Input-to-PTY-output includes terminal scheduling and the
observer's read scheduling. It does not measure physical terminal rendering.

Host load has varied substantially, so a single before/after quantile is not
a controlled performance verdict. Final comparisons must alternate binaries
under the same workload, retain actual send gaps, and separate profiler runs.
