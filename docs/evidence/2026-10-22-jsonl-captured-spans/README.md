# Captured JSONL span reading

Native server source `b43722cb596bed252b7c4bb626173773550d1438` was observed in `Dated_jsonl.drive`, `read_all` and `Buffer.add_char` while processing reaction-ledger evidence. These symbol names do not prove that all ledger bytes were reread: the incremental reader still validates and advances its append cursors. The confirmed source cost was insertion into a buffer once per byte of captured input. The reader now copies newline-delimited spans; complete lines within one chunk bypass the fragment buffer. It does not change caches, time limits or authoritative read rules.

The first span-copy version searched the whole allocated chunk, then clamped its index to the actual input length. The current version stops its search at that length, so a short read cannot inspect the unused suffix. The three-lane probe retains both versions alongside the original byte-insertion reader.

## Reproduce

Requires OCaml 5.5.1, ocamlfind and Yojson. This compiles only a standalone probe, not the project or a server.

```sh
ocamlfind ocamlopt -package unix,yojson -linkpkg -o /tmp/jsonl-span-probe probe.ml
/tmp/jsonl-span-probe > /tmp/jsonl-span-result.json
```

`probe.ml` embeds exact reader bodies: Before from the recorded base, Previous from `previous_source_head`, and After from this source change. It uses the actual Yojson line decoder. Its minimal error/entry types provide only the isolated reader's dependencies. `source.json` records source/probe/result hashes. No live content or credentials are used.

Each fixture uses the same temporary regular file and actual JSON decoder, six rounds per lane with cyclically rotated three-lane order. Timings cover file open/read/close, framing and decoding, including in-window GC. Fixture construction and the forced full GC preceding each sample are outside timing. Compiler flags are the command above; product optimization flags and runtime consumers are not reproduced. Absolute times across different probe runs must not be compared as one controlled host-load window.

## Observed CPU medians

| Fixture | Rows | Original | Previous span | Bounded span |
|---|---:|---:|---:|---:|
| Short JSON | 50,000 | 8.9225 ms | 8.7920 ms | 8.3795 ms |
| Approximately 1 KiB JSON | 4,096 | 34.2975 ms | 27.8440 ms | 27.3670 ms |
| Approximately 144 KiB UTF-8 JSON | 30 | 31.7715 ms | 24.8045 ms | 24.4730 ms |

The final reader used 20.21% less median CPU than the original on 1 KiB rows and 22.97% less on large UTF-8 rows in this run. Changes relative to the previous span reader were -1.71% and -1.34%; these small differences do not establish a general speedup from bounding the delimiter search alone. Short-row observations are small absolute times and sensitive to host conditions. No universal allocation reduction is claimed: final versus original median allocated bytes changed by +1,176 B, +10,200 B and -54,216 B respectively.

All 54 raw samples and wall times are retained in `result.json`; `summary.json` is derived from them. These same-host samples do not prove throughput, server latency, retained-memory or UI improvements.

## Behavior evidence and limits

The probe performs 20 Before/After comparisons of decoded rows and complete-line boundaries, including captured extents around a chunk boundary, large UTF-8 data, blank/malformed/partial rows and a nonzero start. Two additional checks require Before and After to propagate a callback's `Not_found`. Malformed detail is normalized to null, so detailed decoder errors are not compared. These fixtures vary the captured extent but do not force or record a short return from `input`; the stop before unused capacity is additionally established by source review.

The public `fold_file_appended_entries_result` scenario in `test/test_dated_jsonl.ml` covers a large UTF-8 row across chunks, blank/malformed rows and callback append beyond the captured extent, then verifies incremental consumption and no replay. Existing strict tests cover incomplete rows and replacement. Prior focused run 39737387310 passed 73 Dated_jsonl and 45 reaction-ledger tests at the previous source head; it does not execute this bounded-search change. A new focused run is required to establish that execution stage. No project build was run locally.

The delimiter search and row construction retain the same captured extent, callback and cursor behavior. No API, authorization, file-identity check, error or callback boundary is relaxed.

Related issue: #45051. Overall performance and memory work remains open under #44998 and #42201. No workflow was enabled and no operating server or Dashboard assets were installed or restarted.
