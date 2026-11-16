# Complete numeric allocation snapshots

The default memprof endpoint returns four cumulative top30 tables. A site missing
from one top30 is unknown, not zero, so intersecting two reports cannot account
for the full increase. This feature leaves that endpoint and wire format intact
and adds two explicit operator reads:

- `GET /api/v1/diagnostics/memprof/counters`: every registered site's numeric ID
  and raw allocated, starting-domain, major, direct-major and live sample counts;
  no callstack text or ranking. The response includes their totals, rate,
  sampling state, word size, dropped/pending observations, site bound and overflow ID.
- `GET /api/v1/diagnostics/memprof/stacks`: only the requested `id` query values.
  `runtime_instance_id`, `epoch` and `sampling_rate` are all required. Counters
  accepts the same three fields together as an optional guard for a second read.

Both use the existing token-bound CanAdmin GET wrapper, including observation
quota and workspace query preconditions. Matching `expected_base_path` and
`expected_masc_root` remain accepted; their admission header survives the
diagnostic's no-store scope. Responses are uncached and carry no-store.
Missing/malformed identity is 400, another process/profile is 409, and an unknown
registered-range ID is 404. Duplicate selected IDs collapse; there is no full-stack
default. IDs are positive and at most the existing 50,000-site bound plus overflow.

## Identity, locking and completeness

Each site gets one numeric ID when the existing reader creates it. The existing
string-keyed table remains the only persistent registry. Selected lookups scan
that bounded table and copy matching stack references; the requested-ID set is
temporary. No cache, TTL, retention rule, sampling control or durable mutation is
added by either endpoint.

A separate lifecycle mutex serializes the new reads with start/stop/reset; the
lock order is lifecycle then sites. Gc.Memprof start/stop/discard never execute
under the sites mutex. Callbacks retain their original lock-free event pushes.
Epoch/rate is checked before stack lookup. A successful start publishes its rate
and profile epoch together; a failed start restores the starting-domain marker
and reraises its original exception/backtrace. Stop and test reset invalidate old
identities. The existing counters are not reset by start/stop.

One counter read drains one pending batch, copies all registered rows and totals
under the sites mutex, then releases locks before JSON serialization. Every row
is retained, including zero-live rows. Pending/dropped metadata can change on
callback threads while a reader copies: this is not a process-wide quiescent cut.
The server envelopes the cheap immutable Build_identity runtime UUID, without
repository/provenance probes. Compare only the same UUID, epoch and rate. New IDs
in the later complete table had zero prior samples; a disappearing prior ID means
the proposed comparison is invalid. Join by ID rather than row order.

Raw samples are the additive authority. Estimated bytes include headers and use
the reported sampling rate and word size; rounding each row can differ from
rounding a total. Complete rows account for retained sampled counters, including
overflow, not all actual allocations. Dropped samples, merged overflow origins,
unattributed stack windows, CPU time and resident memory remain separate limits.
The act of reading also allocates and may be sampled in a later read.

## Executed evidence

Baseline `8269ef535d57e62f6a5913d9651802fd158a49e7`; OCaml5.5.2, arm64.
Source, interface, tests, source-extracted dependencies and replay helpers are
bound by hashes in [result.json](result.json). All generated files remained under
artifacts; the replay did not read a live workspace or send HTTP/provider calls.

- **15 actual core Alcotest cases passed.** Complete Alloc_profile/Heap_roots and
  real Gc.Memprof ran, including existing domain attribution, new complete-counter
  deltas beyond top30, stable IDs, direct-major/promotion/free lifecycle, all
  50,001 bound/overflow rows, zero-live rows and stale/unknown identity refusal.
  A real sampler with a concurrent systhread reader exercised start/stop and
  invalid-rate rollback without deadlock or partial sums.
- The two exact new pure API test bodies executed with the complete diagnostic
  implementation/interface. **31 further checks passed**, covering the real extracted
  token authorizer, permission predicate, read wrapper/quota and workspace-query
  control flow; compact/default wire parity and selected lookup were also checked.
- Those server probes explicitly fixture the credential store, Build_identity
  nonce, workspace-path comparison, router dispatch and HTTP encoding/response
  ports. They do not execute the real persistent auth store or full HTTP codec.
  The integrated real-router regression is added and typed but was not run as its
  full native executable.
- Seven actual-source checks typed against existing real dependency CMIs in a
  separate directory containing no fixture CMIs. Production interfaces, complete
  implementations, dashboard registration and core tests use fatal4/8/32/69.
  The whole existing test_server_route file uses fatal8/32/69, leaving warning4
  nonfatal for its unchanged cleanup wildcard at lines502–507. The exact isolated
  new pure API bodies still compile with all four warnings fatal. Dependencies
  were not rebuilt; a CMI check is not a complete product link.

## Synthetic payload and allocation

The fixture has 3,000 distinct six-frame stack keys with allocated, major, live
and starting-domain counters. Construction is outside timed reads and sampling
is not running during the measurements. The full comparison uses the existing
core `report ~top:(max_sites+1)` capability, not the unchanged default HTTP view.

| Three operations | Allocated bytes | CPU seconds |
| --- | ---: | ---: |
| Existing complete four-table report plus JSON | 102,191,736 | 0.066419 |
| Complete compact counter snapshot plus JSON | 11,184,624 | 0.008628 |
| Lookup of three selected stacks | 2,040 | 0.000165 |

The serialized full response is 7,030,091 bytes; the compact fixture response is
396,864 bytes. These are one-process synthetic totals, not runtime latency
distributions or a prediction of the application's CPU/RSS improvement. Complete
counter reads remain O(number of registered sites) and allocate/serialize every
numeric row. The maximum remains the existing 50,001 registered rows; only
selected lookup returns stack strings. No new whole-server bottleneck attribution
or installed behavior is claimed.

## Reproduce

With OCaml5.5.2 and installed Yojson/Alcotest/Eio/Httpun/Uri libraries, provide an
existing compatible project compiler-prefix JSON. It must include actual project
CMI directories; absence or incompatibility fails without a build fallback.

```sh
python3 docs/evidence/memprof-counter-snapshot-20261116/replay.py \
  --repo . --base 8269ef535d57e62f6a5913d9651802fd158a49e7 \
  --opam-prefix /path/to/ocaml-5.5.2-prefix \
  --cmi-prefix /path/to/existing/command-prefix.json \
  --out artifacts/memprof-counter-snapshot-20261116/reproduction
```

Use a new output directory. The retained local original is
`artifacts/memprof-counter-snapshot-20261116/run-4-final`. No Dune, full build, CI,
installation, restart or live runtime capture was performed.
