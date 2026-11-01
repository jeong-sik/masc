# Keeper stream message presence

Baseline: `51d0e4fdb920826b32fe603b329b52c905cd8f46`.
Candidate source and tests: `7f424be01afb68ec7db34626184362b4bfab9a09`
(module blob `574964204980a74a392e75679bcc0be1a752e269`, test blob
`e6fbbf5be5c23ffb238b0355627e4ee2551edbaf`).

The tool stream collector kept whether a message had been seen and whether it
was open in separate mutable flags. One `Message_unseen`, `Message_open` or
`Message_closed` value now represents those observations. Closing a scope
before seeing a message leaves it unseen; an open replay, a closed message,
implicit content and invalidated scopes retain their previous transitions.
This is a turn-local state representation, not cross-domain synchronization.

## Reproduction and scope

On arm64 macOS 26.6.1, OCaml 5.5.1 `ocamlopt -O3` without flambda,
[`reproduce.py`](reproduce.py) extracts the exact old and new scope-advance,
message-start, replay and ensure-scope helpers and candidate close helper.
For the baseline close operation it uses an adapter containing the existing
`message_open <- false` statement; it checks that statement's occurrences in
the original source. The [`harness`](harness.ml.txt) compares 200,000 seeded
synthetic actions after each step, mapping the three new states back to the
two old flags. It includes closing before a start, repeated opens and closes,
missing or conflicting starts, progress, tool presence and stopped phases.

```sh
python3 docs/evidence/keeper-stream-message-phase-20261030/reproduce.py \
  --baseline 51d0e4fdb920826b32fe603b329b52c905cd8f46 \
  --candidate 7f424be01afb68ec7db34626184362b4bfab9a09 \
  --out artifacts/keeper-stream-message-phase-20261030/reproduction
```

The state record, usage and stop-reason types, invalidation, tool inventory
and quarantine effects are shims; this is not the full event handler. Some
generated combinations need not be reachable from real provider events. The
new repository test sends a stop-reason delta before a start, with and without
a following MessageStop, and checks that later tool content is not admitted.
It does not assert that the late MessageStart itself is rejected or cover a
standalone MessageStop as the first event. The test has not run locally. No
Dune build, real stream, tool execution or journal was run.

## Captured measurements

[`samples.csv`](samples.csv) contains seven alternating-order samples of
500,000 synthetic iterations per case. Medians:

| Operation | CPU old → candidate | Wall old → candidate | Allocated bytes old → candidate |
| --- | ---: | ---: | ---: |
| Replay an open message start | 4.678 → 4.465 ms | 4.691 → 4.469 ms | 96 → 96 |
| Advance and start a fresh scope | 11.066 → 10.883 ms | 11.065 → 10.891 ms | 36,000,096 → 36,000,096 |
| Read a provider ID | 1.342 → 1.344 ms | 1.340 → 1.345 ms | 96 → 96 |
| Close and reopen | 1.185 → 0.901 ms | 1.188 → 0.901 ms | 96 → 96 |

The provider-ID sample is slightly slower. Close/reopen CPU samples range from
0.891 to 1.317 ms before and 0.891 to 1.325 ms after, so the median difference
should not be treated as a stable speedup. These short helper-only samples
exclude the real stream and do not establish an application speedup. CI is
unobserved.
