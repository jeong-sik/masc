# Named metric snapshots for FSM observation

The FSM breakdown used to copy every metric series before selecting
`masc_fsm_guard_violation_total`. It now copies that name's series through the
store's existing name index. Both reads copy detached records under the same
mutex. Registration, metric keys, values and the full snapshot API are unchanged.
Named row order is unspecified; the observer keeps its existing count/action/stage
sort, duplicate buckets and selection of eight buckets.

## Source and verification scope

Baseline: `522764cc5c7fd62b00a15232728d30a8be3b1b3f`.
`result.json` records SHA-256 identities of every baseline/candidate source used.
The candidate sources were read from the isolated worktree before committing;
their content hashes identify the measured candidate independently of its commit.

The helper directly compiled the complete baseline and candidate metric store
implementations and interfaces, the real metric-key and Cancel_safe sources, and
the exact extracted old/new FSM bucket type and reader functions. Only
`Log.Metrics` was stubbed; the tested paths do not log. The actual
`test_otel_metric_total.ml` source passed all seven cases in a separate native
executable against the candidate store. No Dune command was run.

The compiler was the repository's OCaml 5.5.2, with Eio and Alcotest versions
recorded in the JSON. This does not establish whole-project compilation
or linking, a complete Keeper observation, concurrency behavior, HTTP behavior,
installation, or a running server's CPU/RSS improvement.

## Equality and allocation observations

The extracted readers passed 135 assertions. These include exact public bucket
ordering/multiplicity, more than eight eligible buckets, count/action/stage ties,
duplicate public tuples with different labels, missing labels, zero/negative/NaN
values, and 64 deterministic update rounds. Named snapshots were compared with
the full snapshot's selected rows, including every record field and the float
value's bit representation. The store tests check fresh values and isolation
from a renderer mutating its detached copy.

These are single-process synthetic measurements, with 200 reader calls per row.
The larger cases retain 15 FSM series while adding unrelated series. Allocation
uses `Gc.allocated_bytes`, not a minor-counter snapshot.

| Unrelated series | Before allocated bytes | After allocated bytes | Before CPU s | After CPU s |
| ---: | ---: | ---: | ---: | ---: |
| 0, one FSM series | 112,096 | 113,696 | 0.000072 | 0.000037 |
| 0, fifteen FSM series | 830,496 | 832,096 | 0.000337 | 0.000231 |
| 1,000 | 15,230,496 | 832,096 | 0.004801 | 0.000240 |
| 50,000 | 720,830,496 | 832,096 | 1.789520 | 0.000265 |

The sparse nonempty cases add eight allocated bytes per read. The very short CPU
times are not a stable latency distribution. The synthetic series counts do not
describe the production metric inventory or predict its improvement.

## Reproduce

Run from a checkout containing the recorded candidate source hashes, with the
listed compiler and packages available. Use a new output directory under
`artifacts/`; the helper refuses to overwrite an existing directory.

```sh
python3 docs/evidence/fsm-named-metric-snapshot-20261116/probe.py \
  --repo . \
  --base 522764cc5c7fd62b00a15232728d30a8be3b1b3f \
  --out artifacts/fsm-named-metric-snapshot-20261116/reproduction
```

The original working output remains in
`artifacts/fsm-named-metric-snapshot-20261116/run-3-ocaml552`. This retained bundle contains
only synthetic input logic, source identities and measurement metadata.
