# TUI operation and terminal replay observation

Baseline: `23672ff4dfd8694ed9e73d9b410d92fa5486c49d`.
Candidate source and tests: `9d31d1ea57e27f05cff30ed0df3ec47eb37cd8b1`
(log blob `8b7a5e48c1c352347db43c030d882434c36b08b9`, test blob
`bd4bf8ad8c1f984d81442de95f0cae91373da5e7`).

An operation's retained state and the receipt for a post-terminal journal
read now occupy one immutable observation behind a single mutable cell. A
`Replayed` observation is constructed only after the retained operation is
checked terminal; the constructor's option type alone does not encode that
predicate. The existing first-terminal retention, pre-terminal refusal,
autonomous-source behavior, revision increments and retained option identity
are unchanged. The revision remains a separate mutable field: this is not a
cross-domain synchronization primitive or a claim of atomicity with revision.

## Reproduction and scope

On arm64 macOS 26.6.1, OCaml 5.5.1 `ocamlopt -O3` without flambda,
[`reproduce.py`](reproduce.py) extracts the exact observation-related prefix
of the old and new log modules, the operation state definitions and terminal
predicate from the unchanged production source, and the new regression test
from the repository test file. The extracted test passed against both
versions. The test covers queued/running/cleared states, all three terminal
states, attempted pre-terminal replay, repeated replay, terminal retention,
option identity, revision increments, and an autonomous source.

```sh
python3 docs/evidence/tui-operation-replay-state-20261030/reproduce.py \
  --baseline 23672ff4dfd8694ed9e73d9b410d92fa5486c49d \
  --candidate 9d31d1ea57e27f05cff30ed0df3ec47eb37cd8b1 \
  --out artifacts/tui-operation-replay-state-20261030/reproduction
```

The extraction uses minimal shims for the turn ID, event log and live delta;
it does not compile the complete module, interface, journal decoder or TUI.
The [`harness`](harness.ml.txt) compares both extracted versions after 100,000
seeded operation/replay observations across operation and autonomous sources,
including repeated states and a NaN timestamp. It checks retained option
identity, replay state and revision after each observation. No real Keeper
operation, terminal replay or Dune build was run.

## Captured measurements

[`samples.csv`](samples.csv) contains seven alternating-order samples of
500,000 synthetic iterations per case. `changing_state` makes two observations
per iteration; the other cases make one. Medians:

| Operation | CPU old → candidate | Wall old → candidate | Allocated bytes old → candidate |
| --- | ---: | ---: | ---: |
| Read a replayed terminal | 1.289 → 1.433 ms | 1.378 → 1.526 ms | 96 → 96 |
| Reobserve the same state | 4.883 → 5.013 ms | 4.883 → 5.012 ms | 96 → 96 |
| Change running ↔ queued | 11.096 → 11.410 ms | 11.094 → 11.437 ms | 96 → 16,000,096 |

Each changed observation allocates a new wrapper, so this refactor trades
allocation for a single state owner. The samples are short synthetic loops,
not end-to-end timing or retained-memory measurements; no overall performance
improvement is asserted. CI, terminal interaction and live operation behavior
remain unobserved.
