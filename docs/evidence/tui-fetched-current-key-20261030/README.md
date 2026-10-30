# TUI fetched-source current key

Baseline: `9781d427e0327d337c6a86552144cea81c97253b`.
Candidate source and tests: `db4658f87f2c7a6a8310e561780c5c98e03081d4`
(source blob `a41831153247cb6f7a291c3b9a7c68cef02447e2`, test blob
`05adcc1374cda5b58c998cf2d969732f03d6a394`). `current_key` now projects the
key from the existing `current_request`, rather than constructing the current
observation and discarding it. The request, generation, transitions, stale
value and failure behavior are unchanged; both paths select the same key.

## Reproduction and scope

On arm64 macOS 26.6.1 with OCaml 5.5.1, `ocamlopt -O3` without flambda,
[`reproduce.py`](reproduce.py) compiled the exact old/new module, unchanged
public interface and candidate repository test against Alcotest. Both passed
the same nine tests, including the new check of keys across absent, loading,
ready, failed, retrying, refreshing, stale, refreshing-stale and cleared
states. These are real module and test sources with no product shims, compiled
in isolation; no Dune build or real terminal interaction was run.

```sh
python3 docs/evidence/tui-fetched-current-key-20261030/reproduce.py \
  --baseline 9781d427e0327d337c6a86552144cea81c97253b \
  --candidate db4658f87f2c7a6a8310e561780c5c98e03081d4 \
  --out artifacts/tui-fetched-current-key-20261030/reproduction
```

The benchmark compiles complete old and candidate module sources under
different names without their interfaces, compares their observations for the
nine synthetic states, and times one million accessor calls per sample. Seven
samples alternate order. No request worker, pane rendering, terminal, or
application frame is measured.

## Captured measurements

[`key-samples.csv`](key-samples.csv) and
[`request-samples.csv`](request-samples.csv) retain all samples and the two
exploratory implementations. Selected medians for one million calls:

| Accessor and state | CPU old → candidate | Wall old → candidate | Allocated bytes old → candidate |
| --- | ---: | ---: | ---: |
| current key, loading | 3.957 → 3.053 ms | 3.967 → 3.065 ms | 56,000,096 → 32,000,096 |
| current key, ready | 3.830 → 3.015 ms | 3.829 → 3.015 ms | 72,000,096 → 32,000,096 |
| current key, stale | 3.970 → 3.043 ms | 3.976 → 3.050 ms | 80,000,096 → 32,000,096 |
| current key, absent | 1.743 → 1.796 ms | 1.758 → 1.794 ms | 96 → 96 |
| current request, loading | 1.582 → 1.646 ms | 1.581 → 1.644 ms | 16,000,096 → 16,000,096 |

The absent and request-loading samples show opposite-direction timing results;
they are extremely short synthetic measurements and do not prove a whole-TUI
speedup. The `direct` alternative matched every status twice to avoid an
intermediate option. The `project` alternative shared one status match through
a callback, but in the loading request sample its CPU was 1.582 → 1.992 ms
with unchanged allocation. The selected `via` implementation keeps the existing
request lookup and a single definition of its status selection. These variants
and the selected change have not been measured in a live TUI.
