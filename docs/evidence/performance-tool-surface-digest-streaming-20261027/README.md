# Deferred-surface digest: retained standalone experiment

The candidate hashes the exact canonical source/schema list one entry at a time, retaining the complete schema, identity, list order and SHA256 encoding. It reuses one call-local serializer buffer. The product MLI and receipt format are unchanged. No cache, writer flag or admission/validation skip is added.

These are **standalone, already-JSON carrier** results, not a real Agent_core/private-schema, persisted receipt, native or service measurement. The source-bound nomination came from the separately audited native8e held300 cumulative Memprof report:790 weighted first-frame samples/632,000,000 estimatedB at surface_digest. That nomination is neither CPU attribution nor a gain estimate. The old product ML was a42740967820c21188e37dce5ae145a9c941f5f813b0fdb2a9b76f609dd9d07b; the typed private candidate is aa61a71d34eb642eff78db0919aae9e4422854cd6fcada6653596655ea16fda4; the module MLI remains d1e7513a874b720aa5cbe9acd81430f0607db4d7578c587d6649dde757eac8af. Actual source HEAD/build/CI and these extracted helpers remain separate identities.

## Observed correctness

[Raw correctness](correctness.json) is one complete JSON, actual interpreter CLI0 and stderr0:47 unique old/new canonical-byte and SHA rows, three hand-authored goldens, three matched nonfinite errors across four byte/digest paths each, three injected conversion faults and three private iterator sink faults. Every decoded byte, length and SHA was independently recomputed. The v1 probe had wrongly treated nonfinite values as successful serializations; that source-only P2 remains preserved privately. Corrected v2 catches only the actual Yojson.Json_error and retains the expected failures.

Root's first external verifier wrongly required the permutation pair's A/B visitation order; the actual OCaml result visits B then A. The failed verifier summary remains retained, and the full failed command/traceback is in session history. Corrected unique-population validation passed without rerunning the producer. Arbitrary callback effects and resource-failure precedence remain outside equivalence claims; create still computes its digest before storing a new scope, and this does not imply rollback of an earlier restore.

## Fixed warm comparison

[Raw JSONL](warm-benchmark.jsonl) contains all240 records/224 phase rows, actual interpreter CLI0/stderr0. OCaml5.5.1 Bytecode,64-bit, Yojson3.0.0 and Digestif1.3.0 selected metadata/archives, Mtime2.1.0; driver requires digestif.c. Four serial ABBA cycles give eight phase observations per role per stratum in **one warm process**;82,888 timed calls per role plus42 explicit warmups and untimed preflight. Fixtures and the exact same projection callback are shared. A full major collection precedes each measured phase. Retained captured source comments describe preparation time; complete actual raw outputs are the execution authority.

The following medians divide actual Gc.allocated_bytes deltas by fixed calls, with measurement overhead included. Positive changes are regressions. All strata and regressions are retained; no cross-stratum mean is inferred.

| Synthetic stratum | Old allocated B/call | Candidate B/call | Allocation change | Elapsed change |
| --- | ---: | ---: | ---: | ---: |
| empty | 856.0496 | 920.0496 | +7.476% | -27.553% |
| singleton-builtin | 4880.124 | 4960.124 | +1.639% | +0.797% |
| singleton-attached | 6392.124 | 6464.124 | +1.126% | -1.417% |
| tiny-2 | 11496.248 | 10504.248 | -8.629% | -1.519% |
| tiny-16 | 88969.9375 | 73617.9375 | -17.255% | -0.352% |
| tiny-128 | 707559.5 | 578527.5 | -18.236% | -0.655% |
| tiny-512 | 2827974.0 | 2309646.0 | -18.329% | -10.476% |
| description16KiB-1 | 54081.9375 | 54161.9375 | +0.148% | +1.421% |
| description1KiB-16 | 152863.75 | 91415.75 | -40.198% | -3.954% |
| description1KiB-128 | 1229462.0 | 710158.0 | -42.238% | -5.898% |
| description16KiB-128 | 11029328.0 | 2707144.0 | -75.455% | -9.185% |
| mixed-large-first | 122031.5 | 122263.5 | +0.190% | +1.597% |
| mixed-large-middle | 129935.5 | 122831.5 | -5.467% | -0.006% |
| mixed-large-last | 138183.5 | 122831.5 | -11.110% | +0.776% |

[Observations](observations.json) retain full raw-derived medians/ranges for elapsed, caller-domain allocation and process CPU. Five allocation, four elapsed and five CPU regressions remain. Its historical independent-audit PENDING field predates the separately completed audit; its bytes have not been rewritten. Independent actual-data audit report SHA ce3ebb2f6a9a5b2aca23407963b96fb1c5c0300380d9c444f752625c7ccb609b checked47 cases, all14 full fixture byte/SHA reconstructions, all240 records and all42 medians/84 role ranges; it is evidence consistency, not formal GitHub or product approval.

The largest allocation reduction75.455% belongs only to128 synthetic16KiB-description entries; empty allocation increased7.476%, singleton builtin1.639%, singleton attached1.126%. The actual typed converter is absent. Per-row strings/largest buffer capacity remain; no peak-live/RSS, cold/startup, fleet latency, request/UI SLO, CPU percentage or0.1ms acceptance was measured. Raw quick_stat counters can lag collection and are not substituted for allocated_bytes. Eight phases are not eight independent process replications. Selected image bytes were pinned, but the loaded Digestif image-map was not captured. Selected environment records used CAMLRUNPARAM and omitted OCAMLRUNPARAM; they are incomplete. Five actual GC controls are retained in the raw metadata; no fully pinned/default environment is claimed.

## Provenance and reproduction

[Current locations](current-locations.json) and the newly authored flat [selected capture hashes](recorded-capture-hashes.json) locate13 byte-exact captures; no original run manifest was rewritten. Private original packets, source/image inventories, actual tool receipts, prior failures and audits remain under artifacts/runs/extreme-perf-20261026. No credentials, host-specific tool paths or executable bytes are copied here.

The portable run-correctness.ml and run-warm.ml adapters are newly authored location changes, **not the drivers used for the retained measurements**. The captured probe/benchmark/helper bytes are exact. Copy this bundle to a fresh owned artifact location, use the stated toolchain/packages, run each adapter from that bundle root, and capture stdout/stderr and actual exit to fresh external paths. Require a complete strict JSON correctness result and all240 benchmark records; rc0 or a footer alone is insufficient. The standalone drivers do not check MLIs. Real typed/persisted receipt suites and a separately qualified native comparison remain required before service/adoption claims.
