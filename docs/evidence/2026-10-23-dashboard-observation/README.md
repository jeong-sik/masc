# Clock-only execution response invalidation

Live measurements located long response tails; a separate controlled reproduction
found and repaired a concrete prepared-response reuse defect. These are separate
evidence scopes. No candidate installation or operational after-measurement is
claimed here.

## Live baseline (2026-10-23)

Installed server: `68ec8fb2c52545c68600928524dcc12945e55ee7`.
Authenticated HTTP/1.1, identity encoding, 25 sequential rounds per path, 0.5s
between rounds, same runtime before/after, 150/150 valid, no stale samples.
`live-baseline-summary.json` retains numeric results and scheduler observations.

| Surface | p50 ms | p95 ms | max ms |
| --- | ---: | ---: | ---: |
| Execution | 53.74 | 639.85 | 1492.06 |
| Light shell | 2.86 | 35.25 | 62.31 |
| Tools | 0.94 | 4.50 | 4.81 |
| Telemetry summary | 1.38 | 5.34 | 5.39 |
| Health | 2.28 | 179.59 | 1269.75 |
| MCP ping | 2.63 | 19.26 | 46.73 |

Execution's `cache_compute` timing includes the whole fallback handler and fresh
observations even on a parameterized cache hit. It is not a cache-miss counter.
Scheduler p99 reached 119.86ms in this observation window. Background workload was
not controlled; these tails do not identify one sole cause.

A separate real-browser Overview observation loaded the document in 144ms; this
is not full data readiness. Later completed requests included scheduled automation
at 1783ms and Keeper tool-call reads at 678–2065ms. The visible installed Dashboard
was `25faf14776f1115e962a4c4873e668af386211ad`, different from the server.
A screenshot is retained in the operator's local measurement receipt. The
agent-owned browser task space was finished with no retained pages.

## Defect and repair

`Candle_observe.Ready` contains a balance replay state with `through_at` and
Keeper `last_at`. Whole-second read-clock changes alter that state even if every
inserted public observation stays identical. Comparing the opaque view therefore
advances `candle_observation_sequence`, making the freshly projected cached JSON
different and defeating prepared-response reuse.

The observation identity now uses the exact inserted summary and Keeper-name
bindings of Board address, portrait, wallet balance and Item-account revision.
The same immutable per-response fields populate the response and comparison key.
Every request still reads authority. In-flight gap/out-of-order rules, actor and
workspace partitions, invalidation generations and fixture exceptions are retained.
No TTL, Keeper autonomy limit, or scheduler policy was changed.

## Controlled before/after

Baseline source: `d6ec0b8412` (full base recorded by git). Both benchmark binaries
use the same harness source and toolchain (OCaml 5.5.1), with only the production
projection implementation changed. The frozen input is a real private execution
response (625014 bytes, 37 Keeper rows); public results omit its contents.
Fixture policies and ledgers are isolated: Half_life_set plus a Granted fact of
1,000,000 milli to a Keeper present in that input. Appraiser availability is
injected; no model appraisal is performed. Every measured read replays actual
fixture authority through Candle_observe.

Three fresh-process repetitions alternate before/after order, 200 iterations
each, with clock steps of 0 or 2 seconds. Values below are medians of each
repetition's metric, not pooled population percentiles. The output response is
approximately 624835 bytes (sequence width accounts for small differences).

| Scenario | Before p50/p95 ms | After p50/p95 ms | Reused before → after |
| --- | ---: | ---: | ---: |
| Half-life off, fixed clock | 1.291 / 1.982 | 1.065 / 1.479 | 200 → 200 |
| Half-life off, advancing clock | 4.542 / 7.534 | 1.064 / 1.453 | 0 → 200 |
| Half-life 1h, fixed clock | 1.174 / 1.586 | 1.117 / 2.100 | 200 → 200 |
| Half-life 1h, advancing clock | 4.117 / 5.514 | 3.894 / 4.792 | 0 → 0 |

For the clock-only scenario, p50 fell 76.6% and allocated words fell 74.0%
(117498622 → 30516080 across 200 reads). The fixed-clock decay control's p95
increased in this noisy window; no general speedup is claimed for all scenarios.
The runner asserts expected reuse/encoding counts in all four controls, readable
Ready authority, unchanged supply for fixed/off controls, and changed supply for
advancing decay. Real decay still replaces every response; stale money is not
masked to improve the reuse metric.

This measures fresh projection, equality checking and necessary JSON replacement
serialization. It does not run the HTTP response dispatcher, gzip, ETag serving,
network transport or UI paint, and does not establish production p95 improvement.
Raw repetitions: `gate-comparison-final.json`; aggregated values: `gate-summary.json`;
private input/binary/runner/fixture identities: `measurement-sha256.json`.

## Focused validation

- New deterministic t/t+2 clock-only assertion fails against original production
  implementation and passes after repair. Failure is the expected whole projected
  response inequality, not a clock/fixture setup failure.
- `test_dashboard_http_core.exe test executor_pool 34-44`: 11 tests pass,
  including prepared bytes, fixture isolation, equipment/unreadable authority,
  effective addresses, free purchase/price edits and overlapping observations,
  actor/query/workspace partition and invalidation scenarios.
- Explicit local targets only: `test/test_dashboard_http_core.exe` and
  `benchmarks/dashboard_observation/main.exe`. No full regression or full CI was run.
- Two independent source-review passes found no remaining P0–P2 in the repair
  and benchmark after direct-dependency corrections. This is not a GitHub approval.

## Remaining operational work

Land the independently reviewed current head, install matching server/Dashboard
artifacts in coordination with the operator, and repeat the same authenticated
HTTP and real-browser observations. The old Dashboard bundle, slow tool-call
queries, scheduler/GC tails, runnable backlog and overall degraded health remain
separate open observations. This patch does not claim to resolve those paths.
