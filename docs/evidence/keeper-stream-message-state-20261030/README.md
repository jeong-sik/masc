# Keeper stream message-start state

Baseline: `7b7b2fe745deacf55847b01600f6aaa087db17d5`.
Candidate source and tests: `293840d2f64ce4104ca970930ca44339aee13313`
(module blob `6ebe046d90c13d71c3c290047378eef6520b11e3`, test blob
`a309da9305f1cda59d10496d83ff5e7cbd0feff4`).

The tool stream collector stored both the current message-start tuple and a
separate mutable provider-message ID. They now belong to one immutable start
observation. The original raw ID remains part of replay comparison; an ID
whose trimmed form is empty still has no provider ID, while a nonblank ID is
retained byte-for-byte, including surrounding whitespace. A scope without a
message start still has no provider ID. Exact-replay comparison no longer
constructs temporary tuple and option values for each check.

## Reproduction and scope

On arm64 macOS 26.6.1, OCaml 5.5.1 `ocamlopt -O3` without flambda,
[`reproduce.py`](reproduce.py) extracts the exact old and new scope-advance,
message-start, replay, ensure-scope and provider-ID selection code. The
[`harness`](harness.ml.txt) compares 200,000 seeded synthetic actions and
observations, including absent starts, blank and whitespace-surrounded IDs,
NUL bytes, repeated or conflicting starts, synthetic usage values including
NaN, scope changes, progress, tool presence and stopped phases. It compares the
simulated state, quarantine count and selected provider ID after each action.

```sh
python3 docs/evidence/keeper-stream-message-state-20261030/reproduce.py \
  --baseline 7b7b2fe745deacf55847b01600f6aaa087db17d5 \
  --candidate 293840d2f64ce4104ca970930ca44339aee13313 \
  --out artifacts/keeper-stream-message-state-20261030/reproduction
```

This is an isolated comparison, not the complete stream collector. Its state
record, usage and stop-reason types, invalidation, tool inventory and
quarantine effects are shims; the usage values are synthetic, not an actual
provider usage record. Some generated states need not be reachable from real
stream events. The repository test added for provider-ID handling across a
missing start, blank IDs and whitespace-surrounded ID has not been run locally.
No Dune build, provider stream, journal, or live Keeper behavior was run.

## Captured measurements

[`samples.csv`](samples.csv) contains seven alternating-order samples of
500,000 synthetic iterations per case. Medians:

| Operation | CPU old → candidate | Wall old → candidate | Allocated bytes old → candidate |
| --- | ---: | ---: | ---: |
| Replay an open message start | 8.831 → 3.516 ms | 8.892 → 3.521 ms | 56,000,096 → 96 |
| Advance and start a fresh scope | 12.369 → 8.678 ms | 12.477 → 8.738 ms | 32,000,096 → 36,000,096 |
| Read a provider ID | 0.996 → 1.058 ms | 0.995 → 1.056 ms | 96 → 96 |

Fresh scopes allocate more in this sample and the provider-ID read is slower.
These short helper-only measurements exclude real stream processing and do
not establish a whole-Keeper speedup. CI remains unobserved.
