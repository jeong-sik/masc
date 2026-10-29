# Keeper reaction-presence accumulator comparison

Captured 2026-10-28 on Darwin arm64, Apple M3 Max, OCaml native compiler 5.5.1. Baseline source commit `af560d19cb104b4ae21d212b37a7d0c3ece2a582`; candidate source commit `072f764cb2e22482d51094f34fb7e3a9de82e72b`. The candidate source's SHA-256 is `ef1f60cf8e8016ccaff6714e79659fd1badc308092dfb1b2d7b76325d74f3f1c`; the baseline source's is `d14801ad59bf8cfc6fe98670e2ff8d80ccddd7f1b4ad2eb6bb55c7e9534d7ee0`.

## Scope and oracle

The `accumulator.ml` files contain the respective source's actual evidence record, accumulator, row-update and projection definitions, preceded by a simplified row decoder and type stubs. The decoder passes supplied valid rows through and returns supplied quarantine errors; it does not read real journal bytes or exercise the production JSON decoder. `bench.ml` feeds empty, all five kinds, out-of-order timestamps, duplicate identities, and corrupt/replayed rows through those extracted functions.

The readable `accumulator.ml` copies omit one trailing blank line from the compile-time inputs. Their corresponding `accumulator.ml.gz` files preserve those original input bytes: after decompression, the baseline SHA-256 is `62ac7accdcd2913d36c1eaabe9c8350ab69aa17238fce413601b49f237438914`, and the candidate SHA-256 is `e0d0f66fa33e06cb4a51b2c7a572d65236f44dca4d94df2fd4b11fe24b79afe1`.

The two oracle files contain their projected public evidence after each fixture event, encoded using OCaml Marshal with sharing disabled. Both are 1,550 bytes and SHA-256 `2473e3491ad7cdce86d05f53ade3741f9876ace79c72c4bdf463561ad0c59260`; `cmp baseline-oracle.bin candidate-oracle.bin` succeeds. This compares both implementations on the same inputs, not an independently specified expected result. These bytes are the fixture's encoding, not MASC's persisted JSON or wire bytes. The stub's damaged row has no ID, so this oracle does not prove that a damaged row and later valid row share one identity; the repository test covers that case separately.

## Measurements

Five process pairs were run for each mode, alternating baseline-first and candidate-first. Each process creates and retains its accumulators, measures allocated bytes (`minor_words + major_words - promoted_words`), live bytes after a full major collection, CPU time (`Sys.time`) and elapsed wall time (`Unix.gettimeofday`). `create` and `project` use 1,000,000 accumulators; `updates` uses 300,000 accumulators with five distinct valid fixture rows each. Both `project` and `updates` include accumulator creation in their timings; `project` projects empty accumulators. The timers stop before the final full major collection, which is used to measure retained bytes. The raw samples are in `measurements/`; the JSON files do not themselves contain run order, machine identity or executable hash, so those associations rely on this capture record.

| Mode | Version | Allocated bytes | Retained bytes | CPU seconds | Wall seconds |
| --- | --- | ---: | ---: | ---: | ---: |
| create | baseline | 136,000,208 | 136,000,224 | 0.093829 | 0.094073 |
| create | candidate | 96,000,208 | 96,000,224 | 0.074874 | 0.075430 |
| project | baseline | 280,000,208 | 136,000,224 | 0.109805 | 0.110427 |
| project | candidate | 240,000,208 | 96,000,224 | 0.095508 | 0.098704 |
| updates | baseline | 331,200,208 | 129,600,224 | 0.196651 | 0.197505 |
| updates | candidate | 319,200,208 | 117,600,224 | 0.187622 | 0.190038 |

Values are medians, not a server or fleet speedup. The retained-size difference is 40 bytes per accumulator in these fixtures. The one-pair pilot is transcribed from the console in `measurements/pilot.jsonl`, with version labels added; the original stdout was not separately captured. At 50,000 update fixtures its candidate CPU time was 0.031895 s versus baseline 0.031500 s, while its elapsed time was slightly lower. The first attempt to launch the five-pair driver failed before producing a sample because zsh did not split a space-separated variable; the retained samples come from the corrected array-based driver.

The compiled baseline/candidate probe executable hashes were `fc2545e4375b0bf17f33edb83fe6767a377131ad851e7f6cec9174ebea76e101` and `d6ce07eef7876f6dffb613e4f46b627be19c16ebf9cda1bb52f1a01ef1cb2868` respectively. Executables are not retained. A later compile of the normalized readable helpers produced different executable hashes; the timings above belong to the original executables. The benchmark controller `bench.ml` has SHA-256 `1c5b8126c326625d8ca7b231c1122398b210e5437ccdbba2d2c68c314a3a796c`.

To reproduce, copy `bench.ml` and decompress either `accumulator.ml.gz` into a new directory under `artifacts/`, then compile there with `ocamlopt -I +unix unix.cmxa accumulator.ml bench.ml -o bench.exe`. Run `bench.exe oracle` into a new file or `bench.exe create 1000000`, `bench.exe project 1000000`, and `bench.exe updates 300000`. A new run should keep its own output and environment record.

This isolated comparison is not a full Dune build, a real ledger scan, a concurrency test, or production performance evidence. The repository's focused tests are tracked separately on the final PR head.

## Repeated warm-cache projection

A second isolated probe, `warm.ml`, constructs 256 accumulators before timing, optionally feeds all five fixture kinds, performs 50,000 warm-up projections and then times 30,000,000 repeated projections. Five process pairs per state alternate baseline-first and candidate-first. The timer excludes construction and the preceding full major collection. Allocation uses `Gc.quick_stat`, so the byte count is approximate between collections. The median results are:

| State | Version | Allocated bytes | CPU seconds | Wall seconds |
| --- | --- | ---: | ---: | ---: |
| empty | baseline | 4,319,968,376 | 0.149149 | 0.149542 |
| empty | candidate | 4,319,968,376 | 0.133347 | 0.133642 |
| filled | baseline | 4,319,968,376 | 0.163810 | 0.164914 |
| filled | candidate | 4,319,968,376 | 0.152087 | 0.153057 |

The 20 raw paired samples are named `baseline-empty-*`, `candidate-empty-*`, `baseline-filled-*`, and `candidate-filled-*` in `measurements/`. As above, their run order, environment and binary associations come from this capture record rather than metadata inside the files. The smaller one-pair pilot is transcribed with version labels in `warm-pilot.jsonl`. The controller SHA-256 is `f1047bee6151818fa00198ab1f066f0b5881ede42f3a8979496c4ccf6dbbb74e`; baseline and candidate executables had SHA-256 `76ad32375be7329e50d686550244454556aeea61b895d78626d41a2867cb8d0e` and `1f89c139d6bcebf6ff6156195fdf87ca9bb83851afd772529705361c1363b32d`. These executables are not retained.

This repeatedly projects a small, uniform, already-resident fixture. It does not measure real journal decoding, contention, terminal rendering or multiple Keepers, and its elapsed-time differences do not establish production improvement. To reproduce in a new `artifacts/` directory, decompress the chosen original `accumulator.ml.gz`, copy `warm.ml`, compile with `ocamlopt -I +unix unix.cmxa accumulator.ml warm.ml -o warm.exe`, and run `warm.exe empty 30000000` or `warm.exe filled 30000000`.
