# Lexical normal-form path reuse: interpreted helper evidence

Already normalized absolute and relative paths were split into fresh component strings/lists and assembled again on every call. The candidate classifies the exact existing slash grammar after the same trim and HOME expansion. A normal form has no empty, dot or parent component and no trailing slash except root `/`. Other forms keep the original reduction. No filesystem canonicalization, environment read, registry validation or final `.masc` stripping is skipped.

The code source commit is `9f7533779cbeef09213f677ab8fefb9055387ead`, based on `9edd5752ec3b81c3618f9e3953afb5072f0e0525`; complete candidate file hashes are in [provenance.json](provenance.json). The baseline normalizer bytes also match the separately qualified native 55a application source. This is an OCaml 5.5.1 **interpreter helper comparison** with explicit HOME-reader and `Common.masc_dirname` fixtures. It does not execute the production environment resolver, native application or a Keeper fleet.

## Semantic checks

The original explicit-path case and 28 added expectations execute against both extracted roles: 58 checks. Exhaustive strings over `/`, `.`, `a`, space and NUL through length7 produce 97,656 inputs. Another 20,000 seeded component paths, two long inputs (1 MiB ordinary component and 16,384 ordinary components), and 49 HOME fixture/input pairs compare both lexical and base-input helpers. All 235,472 checks pass. Relative `../.. -> .` keeps the current reduction behavior; it is not replaced with a different path convention.

Three changed files separately pass parsing-only `ocamlc -stop-after parsing`. Neither that check nor the stubbed helper execution is a project typecheck or the actual Alcotest suite. Focused config-directory CI is a separate requested check.

## All measured rows, including regressions

Each case uses fixed baseline/candidate/candidate/baseline order, two cells per role, no warmup or discarded outliers. A full major collection precedes every cell outside measurement. Values below are whole-cell medians. Calls count pure helper invocations, not Keepers. The 248-byte remaining counter includes measurement bookkeeping; it does not mean trimming or HOME expansion universally allocates nothing.

| Input case | Calls/cell | Baseline allocated B | Candidate allocated B | Baseline ms | Candidate ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| root | 50,000 | 7,200,248 | 248 | 17.144937 | 4.512125 |
| short_relative | 50,000 | 6,800,248 | 248 | 13.603562 | 9.840854 |
| relative_components | 50,000 | 18,000,248 | 248 | 47.583938 | 19.625500 |
| normal_owner_path | 50,000 | 39,200,248 | 248 | 106.336730 | 40.432062 |
| trimmed_owner_path | 50,000 | 44,400,248 | 5,200,248 | 106.122478 | 49.104792 |
| late_special_component | 50,000 | 38,400,248 | 38,400,248 | 99.618396 | 140.785730 |
| early_special_component | 50,000 | 43,200,248 | 43,200,248 | 106.787021 | 108.986084 |
| long_normal_component | 1,000 | 8,400,248 | 248 | 39.220125 | 41.776792 |

For the normal-owner fixture, allocation falls by 39,200,000 bytes per 50,000 calls; observed median time is 61.98% lower. The late `..` input allocates the same amount and is 41.33% slower because the candidate scans before falling back. The early-special case is 2.06% slower and the 4096-byte normal component is 6.52% slower in this interpreted sample. No stable or universal latency gain follows from two cells per role on a shared host. No new product cache, threshold or tunable is added to conceal these inputs.

The next hotspot was nominated by four visible cumulative allocated Memprof rows from a separate 55a diagnostic. Their 2,071 samples estimate 1,656,799,968 bytes. Those bounded top 30 excerpts omit other sites and do not establish CPU percentage, whole-function cost, exact allocation or exclusive production cause. The local report locator/hash is retained in provenance; raw profiler/RPC/DB/credential/executable material is not copied into this bundle.

## Reproduction and provenance

[plan.json](plan.json), [measurements.jsonl](measurements.jsonl), [summary.json](summary.json) and the renamed exact [generated program](probe.ocaml.txt) retain original bytes. [current-locations.json](current-locations.json) maps original capture paths and digests to selected retained files. `summary.json` keeps the original capture filenames; renamed files are located through that sidecar. All inputs and outputs remain under `artifacts/runs/extreme-perf-20261026/normalized-path-copy-helper-v1` locally. [reproduce.py](reproduce.py) extracts the specified Git baseline and current candidate files and refuses an existing output directory:

```sh
python3 -B -E docs/evidence/performance-normalized-path-copy-20261027/reproduce.py \
  --repo . --baseline-ref 9edd5752ec3b81c3618f9e3953afb5072f0e0525 \
  --output artifacts/runs/normalized-path-copy-new-run
```

Do not write new runs into this retained bundle. The source commit and file hashes bind this observation; edited current source requires a fresh run. Whole-program native behavior, startup/TUI, peer/broadcast/real Add-on work, deployment and the 0.1 ms goal remain unproven by this helper result.
