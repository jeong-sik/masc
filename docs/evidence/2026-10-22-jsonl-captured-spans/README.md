# Captured JSONL span reading

Native server source `b43722cb596bed252b7c4bb626173773550d1438` was observed in `Dated_jsonl.drive`, `read_all` and `Buffer.add_char` while processing reaction-ledger evidence. These symbol names do not prove that all ledger bytes were reread: the incremental reader still validates and advances its append cursors. The confirmed source cost is insertion into a buffer once per byte of the captured input. This change copies newline-delimited spans; complete lines within one chunk bypass the fragment buffer. It does not change caches, time limits or authoritative read rules.

## Reproduce

Requires OCaml 5.5.1, ocamlfind and Yojson. This compiles only a standalone probe, not the project or a server.

```sh
ocamlfind ocamlopt -package unix,yojson -linkpkg -o /tmp/jsonl-span-probe probe.ml
/tmp/jsonl-span-probe > /tmp/jsonl-span-result.json
```

`probe.ml` embeds the exact before/after `fold_captured_entries_result` bodies and the actual Yojson line decoder. Its minimal error/entry types provide only the isolated reader's dependencies. `source.json` records the base and source/probe/result hashes. No live content or credentials are used. The same temporary regular file, actual JSON decoder, six rounds per lane and alternating order are used for each fixture. Timings cover file open/read/close, framing and decoding, including in-window GC. Fixture construction and the forced full GC preceding each sample are outside the timing window. Compiler flags are the command above; product optimization flags and runtime consumers are not reproduced.

## Observed CPU medians

| Fixture | Rows | Before | After | Change |
|---|---:|---:|---:|---:|
| Short JSON | 50,000 | 11.413 ms | 11.318 ms | -0.84% |
| Approximately 1 KiB JSON | 4,096 | 44.438 ms | 36.150 ms | -18.65% |
| Approximately 144 KiB UTF-8 JSON | 30 | 40.593 ms | 31.467 ms | -22.48% |

The short-row difference is too small to establish a useful speedup. Median allocations changed by +840 B, +7,128 B and -57,384 B respectively; this is not a general allocation reduction. Raw samples and wall times are retained in `result.json`; `summary.json` is derived from them. These small same-host samples do not prove a throughput, server latency, retained-memory or UI improvement.

## Behavior evidence and limits

The probe performs 20 before/after comparisons of decoded rows and complete-line boundaries, including captured extents around a chunk boundary, large UTF-8 data, blank/malformed/partial rows and a nonzero start. Two additional checks require each version to propagate a callback's `Not_found`. Malformed detail is normalized to null, so detailed decoder errors are not compared.

The added public `fold_file_appended_entries_result` scenario in `test/test_dated_jsonl.ml` covers a large UTF-8 row across chunks, blank/malformed rows and callback append beyond the captured extent, then verifies incremental consumption and no replay. It was added and source-reviewed; it has not been executed locally. Existing strict tests cover incomplete rows and replacement. Full module typing, these public API scenarios and live server behavior are separate verification stages.

The implementation still searches the unused capacity after a short `input`; it clamps the result to the actual read length before copying or publishing any row/cursor. That suffix can add search cost but never becomes input. No API, authorization, file-identity check, read extent, error or callback boundary is relaxed.

Related issue: #45051. Overall performance and memory work remains open under #44998 and #42201. No workflow was enabled and no operating server or Dashboard assets were installed or restarted.
