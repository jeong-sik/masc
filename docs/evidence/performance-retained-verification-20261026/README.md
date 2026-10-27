# Retained-file verification: bounded reread allocation

The running `1ce158d50d3eb48648e6deea7f668172f914fea3` server still allocates
heavily while restoring retained Lane requests. Two existing Memprof report
requests started 31.767 seconds apart; their counter differences estimate
127,685,600,000 allocated bytes and
109,614,400,000 bytes reaching the major heap. Dropped samples stayed at
4,270,314: no new drops in this window, with historical loss still present.
The two raw reports and their derived [summary](live-window-summary.json)
are retained here. The endpoint exposes only the largest 30 sites; common
site deltas are not a complete attribution. Sampling, report collection and
the shared host affect the observation.
The actual snapshots occur within their HTTP request brackets, so their
interval is bounded between 30.076157417 and 31.836511333 seconds. These
counters do not establish an exact allocation throughput.

All seven health observations identify the same source, executable and
runtime instance, with 25 Keeper fibers. Sampled RSS spans 18,424,840,192 to
22,770,925,568 bytes, and the rolling scheduler p99 spans about 710 to 815 ms.
These are operating observations, not a controlled workload or causal join.
The full health responses remain in the private local packet; the health
projection here omits configuration and operational details. Memprof's live
estimate is distinct from RSS and actual retained heap size.

One common allocation stack, `record_bytes → verify_record_bytes →
settle_verified_record → read_owned_tool_request_bytes`, accounts for an
estimated 10,414,400,000 allocated bytes in the window. The full-size second
read is one measured allocation source. This change does not remove the
window's other allocations or establish a whole-server improvement. In
particular, repeated gate restoration is separately addressed by PR #46143.

## Changed boundary

`Lane_addon_store.verify_record_bytes` still rereads every byte after the
existing sync calls, probes EOF, compares against the immutable first
observation, and checks the original file identity. Two reusable buffers of
`Sys.io_buffer_size` bytes replace the second full-size allocation for large
records. The direct path remains when it needs no more memory than that
pair. No cache, weaker digest comparison, skipped fsync, shortened input,
changed read envelope or runtime work limit is introduced.

Both buffers are filled before the first comparison. When a final short
chunk arrives, the remaining tails are equal from the preceding successful
full comparison. A prior mismatch stays false; the reader still reaches EOF
so shrink/growth errors retain their original precedence. Partial reads and
EINTR retain the original read-to-completion semantics. Scratch buffers
never alias or mutate the returned original string.

The shared helper also serves action/exact-request/observation/evidence
readers. Full-module behavioral verification is separate from the extracted
helper observations below.

## Exact helper execution

The [runner](run_probe.py) extracts the unchanged surrounding production
reader and the candidate reader directly from their complete source files.
The source and extraction SHA-256 values, generated-probe hash and file
digests are in [provenance.json](provenance.json). The baseline is the live
source above; the candidate file SHA-256 is
`0eb3f17cf3c4a0d9fea65c4adb652ab9a4b5174c00eae80d9f99e721ad514388`.
This source binding does not depend on the later documentation/changelog
commit identity.

OCaml 5.5.1 interpreted the extracted helpers, using real file and parent
fsync calls. There was no local Dune build or native compilation. All 52
checks passed: stable binary payloads including empty and boundary sizes,
changed bytes across the first/middle/final partial chunks, truncation,
growth, identical-content inode replacement and both real sync calls. The
fault-reader variants substitute only `Unix.read`, deliver three EINTRs
and cap each subsequent actual OS read at 97 bytes; four sizes pass on
both sources. The generated [probe](probe.ml) and complete
[output](stdout.txt) preserve the exact check scope. This is not an
execution of the full Store module or its Eio consumers.

Six read-count/size cases each ran once in fixed baseline/candidate/
candidate/baseline order. Every batch and outlier remains in
[measurements.csv](measurements.csv); no warmup, best-run selection or
GC reset was added. Earlier source/instrumentation runs remain separate in
the ignored local packet and are not pooled with this final-source run.
This packet uses `Mtime_clock.elapsed_ns`; timing includes interpreter,
filesystem, sync, GC and shared-host scheduling costs. There are only two
batches per role, so the medians below do not establish stable causal
speedup or tail latency.

| File bytes / reads | Allocated bytes, baseline → candidate | Median batch ms, baseline → candidate |
| --- | ---: | ---: |
| 64 / 300 | 609,848 → 609,848 | 11.895500 → 11.995604 |
| 65,536 / 300 | 39,893,048 → 39,893,048 | 48.034396 → 56.273062 |
| 131,072 / 300 | 79,214,648 → 79,214,648 | 186.652813 → 92.810750 |
| 1,048,576 / 30 | 62,971,928 → 35,486,888 | 58.236292 → 42.103688 |
| 1,048,576 / 300 | 629,717,048 → 354,866,648 | 821.293104 → 613.767250 |
| 4,194,321 / 30 | 251,716,568 → 129,976,808 | 173.007812 → 103.515750 |

The large-file allocation reductions are 43.65% and 48.36%; the small-path
allocation is unchanged. The 64-byte and 64-KiB elapsed medians worsen.
Read counts of 30/300 mean repeated reads of one controlled file, not
30/300 Keeper owners, concurrent operations or independent files. The
1-MiB/300 candidate median is about 2.05 ms per complete read, above 0.1 ms.

Reproduce from an OCaml 5.5.1 environment with `unix`, `mtime` and
`mtime.clock.os` installed. This invokes the interpreter only; choose a
new output directory under `artifacts/`:

```sh
python3 docs/evidence/performance-retained-verification-20261026/run_probe.py \
  --baseline-repo "$PWD" \
  --baseline-ref 1ce158d50d3eb48648e6deea7f668172f914fea3 \
  --candidate-repo "$PWD" \
  --output artifacts/retained-verification-new
```

## Review and remaining evidence

The independent [source review](source-review.md) binds the initial measured
three-file implementation/test diff and baseline. It found no P0/P1/P2
issues. The reviewer did not execute the helper or review these measurement
results; this is not a formal GitHub approval or a runtime verdict.
The original diff bytes are stored as `reviewed.diff.gz`; the review's diff
digest identifies the decompressed bytes. `provenance.json` records that
mapping and the retained file hashes.
Parsing and whitespace checks passed. [Test run 40329666119](https://github.com/jeong-sik/masc/actions/runs/40329666119),
workflow dispatch on `c3cb3715e3a36b56ae17c23820b6b7c83914a602`, ref
`perf/retained-verification-buffer-20261026`, explicitly selected five
suites on POSIX. All five executables built and ran: 162 passed, one failed,
zero skipped. The added large-original discovery scenario passed. The
[retained receipt](ci-selected-c3cb371.json) preserves the failure and scope.
The failed preexisting scenario sorted its actual identity list but left
the expected list unsorted. A test-only correction sorts both complete
lists with the same comparator, retaining exact identity and duplicate
checks. Product traversal and the measured production file are unchanged.
The corrected discovery suite requires a separate result; the original
failure is not replaced by the four other passing suites.

There is no current-source native comparison, installation, TUI/startup,
concurrent fleet, Keeper-to-Keeper/Add-on business or production speedup
claim. Server/TUI/files/Markdown/HTML/SQLite/queues/broadcast/multiple Add-on
lanes and 30→300 concurrent scaling remain part of the active goal.
The universal 0.1-ms objective is unproven. The prepared business30 harness
has separate path/cancellation/SQL-observation review findings and was not
executed or relabelled as a completed workload.
