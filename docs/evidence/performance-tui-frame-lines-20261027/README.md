# Frame row splitting: native extracted-helper observations

The candidate preserves the immutable Buffer.contents snapshot and scans it backward, prepending each row once. This removes the accumulator's final List.rev and its duplicate list cells. It preserves the public signature, raw bytes, LF grammar, row order and detachment from later buffer mutation.

An earlier direct-Buffer scan was rejected: native40×120 allocation fell39.59%, but CPU time rose65.05% and wall time37.25%. Its interpreter CPU regression was126.26%. All rejected sources, records and rows remain in this bundle. The adopted candidate retains the flat snapshot rather than adding per-byte Buffer.nth calls.

## Correctness and measured scope

Each of three distinct actual experiments completed5,473 byte-partition checks for both roles, including exhaustive short ordinary/LF/CR/NUL strings, explicit terminators, all256 byte values, UTF-8/ANSI and output stability after buffer reuse. The oracle uses String.split_on_char and removes exactly one final terminator. Empty input yields no rows; a sole LF yields one empty row; multiple final LFs retain their preceding empty rows. No normalization, width interpretation or styling change occurs.

The adopted candidate's exact function digest is488da013c1a25f178bd7206d62f8c106290cdd8a1bac1f41588969e0e56c34a6. Its function text equals the production implementation. The baseline equals frozen468's original helper; the following parent68f differs only in changelog documentation. Both functions ran in one standalone stdlib/Unix executable built with local OCaml5.5.1 default native flags. This was a small extracted-helper compile, with no Dune or project build. It does not typecheck MASC's module interface, link the renderer or execute a new TUI.

Each experiment retains32 raw measurement rows across8 strata, in fixed baseline/candidate/candidate/baseline order,20 warmups before each phase and two measured phases per role. The adopted native compile/run and enclosing root tool exited0 and were reaped; compiler/run stderr were0B. The rejected interpreter retained926B of Unix auto-include deprecation alerts. [Actual root tool records](actual-tool-returns.json) remain separate from child receipts.

| Adopted native stratum | Allocation mean B/call baseline→candidate | CPU change | Wall-time change |
| --- | ---: | ---: | ---: |
| empty | 16.0192→16.0192 | −10.23% | −7.65% |
| LF | 128.0192→56.0192 | −10.00% | −10.59% |
| one120-byte row | 368.048→296.048 | −21.49% | −21.51% |
| 40×120 ASCII | 12,264.192→11,256.192 | −24.60% | −25.85% |
| 40×120 blank | 12,264.192→11,256.192 | −21.88% | −22.27% |
| Unicode40 rows | 16,384.192→15,376.192 | −21.64% | −21.44% |
| ANSI40 rows | 13,024.192→12,016.192 | −23.47% | −25.54% |
| 300×120 rows | 91,560.96→84,312.96 | −21.22% | −21.74% |

For40×120 ASCII, CPU means were6.690→5.044µs/call and wall means6.804→5.045µs/call. Allocation was8.219% lower. No allocation/time regression was observed across these eight strata; two short phases on a shared host do not establish a stable universal speedup. Empty/tiny batches approach clock/probe resolution, so their ratios are especially uncertain.

Allocation is the Gc.allocated_bytes counter difference and includes measurement overhead; CPU is process Sys.time, and wall time uses nonmonotonic Unix.gettimeofday. Raw before/after values and collection counts are preserved. Workloads ran on a shared host while separate offline audits could run; CPU frequency/scheduling/cache/order effects remain. These are extracted-helper observations, not function-exclusive in-product allocation, actual renderer gain, stable tail latency, native TUI speedup, physical paint or0.1ms/SLO acceptance.

The preceding468 held300 TUI diagnostic retained89 Builds with BuildP50.239666ms/max17.204875ms. It nominates row processing but is not this candidate's runtime proof. Nine stage medians do not isolate this helper's CPU or allocation. No helper ratio is multiplied into a whole-frame estimate. New project byte-grammar tests are added with this change; their selected CI results are reported separately in the PR. No full project regression ran for these captures.

## Retention and fresh reproduction

Sixteen selected captures retain exact original bytes; two source_text JSON wrappers decode to the exact original compiler configuration and interpreter warning text. Their transformed and original digests remain distinct. [capture-locations.json](capture-locations.json) preserves original addresses and SHA256 values. [recorded-capture-hashes.json](recorded-capture-hashes.json) is a newly authored manifest of selected staging byte revisions, not an original raw-run manifest; [current-locations.json](current-locations.json) locates those revisions in the repository. The captures include all96 measurement rows, all three carriers/plans/executions/summaries, compiler configuration, interpreter warnings and actual tool returns. Original absolute addresses are historical provenance, not portable qualification.

Check retained bytes with:

```sh
python3 -B -E scripts/check-evidence-locations.py \
  docs/evidence/performance-tui-frame-lines-20261027/current-locations.json
```

To run a fresh standalone comparison using an installed OCaml5.5.1 compiler, create an unused output directory and copy the retained carrier there:

```sh
mkdir artifacts/FRESH-frame-lines
cp docs/evidence/performance-tui-frame-lines-20261027/reverse-carrier.ml.txt \
  artifacts/FRESH-frame-lines/carrier.ml
ocamlopt -I +unix unix.cmxa artifacts/FRESH-frame-lines/carrier.ml \
  -o artifacts/FRESH-frame-lines/carrier
artifacts/FRESH-frame-lines/carrier > artifacts/FRESH-frame-lines/raw.jsonl
```

Compiler products and new observations stay outside this retained bundle. A new run needs its own compiler/source/binary/environment and actual-return records; it does not recreate these exact measurements or establish MASC integration. Native executables and raw TUI/workload/private database packets are not bundled.
