# Independent TUI source review

Candidate `bae45a3e0e70de9c238e2a16410ccf15d295a4be`, base `e16382ef5471e15cd5002c674d2e93b87faa20d6`. No unresolved P0, P1 or P2 source findings. The exact three source hashes are recorded in the JSON companion.

The command-menu change preserves every returned menu/viewport decision while skipping a status frame that no menu uses. The live-edge change selects the same first valid semantic source position, preserves the complete non-live/search/held-transient behavior, and avoids building source maps for unused positions.

One TUI background worker is supported by the existing pool contract and introduces no identified nested-submit deadlock: worker-context helpers run inline and the direct search submit originates on the UI daemon. HTTP transport remains on a separate domain. The policy changes client concurrency only.

The throughput tradeoff is real: local file reads, response decode and search share a single executor queue. A blocking Context.load, metrics read or long CPU decode can defer later background jobs. The inspected readers wait in separate workspace fibers, so this does not directly move those blocking reads into the main input loop. Existing cancellation still waits for an entered worker to settle and cannot preempt a blocking syscall. Native mixed proof should therefore distinguish input responsiveness from response/local-read completion.

The retained fast-profile sample supports allocation/GC/barrier pressure: 183 of 595 main samples under Array.init, including a 153-sample minor-collection subtree. The exact allocating callsite is unproven. Source-map construction at render_chat.ml:257 allocates an origin value per body byte and is a concrete hypothesis addressed by avoiding unused live-edge source maps. The sampled result is incomplete and includes sampler CPU, so it is diagnostic evidence rather than an improvement benchmark.

If row allocation remains material after this candidate, rows_of_entry is rebuilt for pin resolution and viewport gathering even with warm cumulative counts. A draw-local exact-key memo is a smaller next hypothesis than another persistent cross-frame cache. Repeated terminal-size getters already hit Terminal_size_cache, and the frame presenter emits one buffered diff write/flush; repeated ioctl/full-transcript terminal writes are not supported as the main source hypothesis.

This reviewer did not build, run a candidate probe, change product files, post a PR/review, or touch the user's TUI/preferences. Source approval does not establish measured GC/latency improvement or physical terminal paint.
