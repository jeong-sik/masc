# Allocation-profile key scan

The key builder now stops classifying raw entries after finding the six entries
the key keeps. It preserves the classifier, formatter, 192-entry window, order,
unknown/inline behavior, fallback marker and public interface. It still creates
the complete `Printexc.raw_backtrace_entries` array. Sampling, tracking, report
tables, caches and registries are unchanged.

This bundle supports a small allocation/scan cleanup. It does not identify the
profiler as the cause of the server's sustained CPU or retained heap.

## Exact source and verification

Baseline: `607419c653251c46470eabee1b71f0ac8bd61b48`.
`source-manifest.json` binds the complete baseline/candidate ML bytes, unchanged
public MLI, extracted key spans, common helpers and fixture sources. The candidate
body also exactly matches the separately measured investigation candidate.

The two key-related hashes have different byte bounds. `candidate_key_span_sha256`
(`72a5af6397d2f917809f6173e258a21deee3ed94ff0dd58f96e0af5c78f8b5d7`)
covers the raw source span from the function header through the separators before
`let block_of`. This is the span executed by replay. The supplementary
`candidate_function_body_sha256` and `investigation_candidate_body_sha256`
(`42fe58afa56c5e8ed11c4b09db3c16e66c5b7e8aca92a9f4ece13b9635a99228`)
include that same function header, omit the trailing OCaml phrase terminator
and separator whitespace, and end with one LF. Their exact normalization is:

```python
span = text[text.index("let key_of_callstack callstack ="):
            text.index("let block_of (allocation")]
function_text = span.split("\n;;", 1)[0].rstrip() + "\n"
body_sha256 = hashlib.sha256(function_text.encode("utf-8")).hexdigest()
```

Here `text` is the complete candidate ML. The normalized text equals the earlier
investigation's function text after its `open Shared` prefix, with no source
statements changed. It is a supplementary cross-run source comparison; the
whole-ML and raw-span hashes bind the actual public replay.

`typing.json` records successful direct typing of the **actual whole candidate
ML and unchanged MLI**, OCaml 5.5.2 with fatal warnings 4/8/32/69, against existing
Heap_roots/Yojson interfaces. Host paths were removed from that public derivative;
the dependency hashes and source hashes remain. Existing dependency CMIs are not
an exact-head whole-program build receipt. No Dune, full build, product CI,
installation or running-server verification was performed.

The portable replay was executed against the exact current candidate. It passed
90 assertions and complete key-byte equality on 84 raw captures, including:

- Empty, shallow and deep stacks, including raw arrays longer than 192.
- Actual Stdlib Buffer and Yojson encoder allocation callstacks, captured only
  inside the isolated fixture process. There were 28 actual Yojson captures
  whose entire 192-entry window was skipped.
- Real native inline-expanded entries and a native module compiled without debug
  information. A kept raw entry can contain several formatted slots.
- A purpose-built `Stdlib__Key_scan_fixture` module for skip-prefix boundary
  controls. It is not actual Stdlib implementation code.

`observed.json` retains source bindings, aggregated capture coverage, all measured
rounds and median/range summaries. It is a curated derivative: its curation fields
identify the original local receipt digests; per-capture metadata was aggregated
and timing/allocation rounds are unchanged. The complete originals remain in
ignored artifacts. It contains no raw address array or saved key text.
The oracle is the exact baseline function extracted from Git,
not a second formatter or a fixed wording snapshot. No additional production
unit test was added for this pure-equivalence change; full callback/event/report
integration and the existing `test_alloc_profile` suite remain unexecuted.

## Measurement

Each row is one representative captured stack: five alternating-order rounds,
2,000 calls per variant per round. The compiler used relative fixture filenames,
so debug-info paths do not contain the host checkout. Byte counts use
`Gc.allocated_bytes`; CPU uses `Sys.time`; full major collection precedes each
measurement. The original and candidate see the same warmed raw stack.

| Group | Classifications, before → after | Allocated B/call, before → after | Median CPU µs/call, before → after |
| --- | --- | --- | --- |
| Shallow attributed, 6 raw entries | 6 → 6 | 12,968 → 12,688 | 2.43 → 2.27 |
| Deep attributed, 135 raw entries | 135 → 6 | 125,112 → 18,032 | 13.48 → 2.99 |
| Synthetic all-skipped 192-entry window | 192 → 192 | 105,848 → 96,680 | 13.96 → 12.59 |
| Actual Stdlib allocation, 9 raw entries | 9 → 9 | 19,360 → 18,936 | 3.46 → 3.39 |
| Actual Yojson allocation, 384 raw / 192 skipped window | 192 → 192 | 120,032 → 106,256 | 16.82 → 14.88 |
| Missing-debug module, 4 raw entries | 4 → 4 | 9,496 → 9,312 | 1.80 → 1.83 |

The deep-attributed allocation reduction is 85.6% for this input. Its CPU range
is 13.16–14.15 µs before and 2.98–3.18 µs after. The actual Yojson input still
requires all 192 classifications and the full 384-entry array; avoiding the
intermediate full lists reduces allocation by 11.5% for that input.

Short-stack CPU does not support a general improvement claim. In the earlier
exploratory run, shallow ranges overlapped (4.56–4.70 µs before, 4.50–4.65 µs
after), with medians 4.57 and 4.61 µs. Its retained per-round derivative is in
`historical-context.json`. That run used absolute scratch filenames in debug
information; it is separate from this relative-filename replay. The current
unknown-debug ranges also overlap. Do not combine timings across those runs.

Fixture-only Memprof collection uses 0.01 sampling and returns no tracked
blocks. Collection is stopped/discarded before byte equality and measurement;
`sampling_during_measurement` is false. Production's sampling rate is unchanged.
This measures key-building allocations directly because profile callbacks'
own allocations are not sampled. It does not measure whole-profiler overhead.

Input proportions, source-path length, warm debug information and the shared
machine affect these microbenchmarks. There is no measured whole-server CPU,
RSS, latency or retained-memory saving. Raw-array creation remains unavoidable
in this change. A retained historical PID22599 native sample had only two
explicit key-builder tree nodes, each count 1. `historical-context.json` is a
sanitized derivative with the original capture digest; the original capture is
not included. Those nodes establish no dominant CPU attribution or percentage.

## Replay

With OCaml 5.5.2 and its Yojson package available:

```sh
opam exec --switch=5.5.2 -- python3 docs/evidence/alloc-profile-key-scan-20261116/replay.py
```

The helper reads the local baseline Git object and exact candidate source,
checks their hashes, and writes all compilation/run output to a fresh ignored
`artifacts/alloc-profile-key-scan-20261116/<run>/` directory. It performs no fetch,
Dune build or product launch. It never writes new output into retained evidence.
Use `--candidate-ref <reviewed-commit>` to replay after checking out a different
branch, `--ocamlopt`/`--ocamlfind` to select a toolchain, or `--output` to select a
new output directory. A changed source binding stops replay rather than silently
testing another candidate. Memprof collection is stochastic; counts and timings
may vary, while complete baseline/candidate key-byte equality remains required.
