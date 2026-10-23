# Curator original progress: one receipt validation per replay event

Base: `aa0fea67e03a1fc8d40b4d5844ec8be836a82566`. Observation date: 2026-10-23.

The large-original incident in #41927 included JSON serialization/SHA256 work
inside original observer progress restoration. `Progress.of_json` decoded each
wire event, called public `append` (encoding/decoding it again), and then called
`Receipt.append` (encoding/decoding the observer event again). Each observer
intent rebuilt the same receipt digest three times.

The receipt type is private. Only `make` and strict `of_json` construct it.
Typed receipt append can therefore reuse that validated immutable value while
checking acknowledgement text and transition order. A private progress fold
accepts already decoded events; public events with open JSON payloads still
pass the canonical event codec. Wire decoding still validates all fields,
canonical payloads, digest, time and transition order. No wire format changes.

## Direct narrow execution

OCaml 5.5.1 `ocamlopt` compiled both changed ML/MLI pairs with warning4/32/69
and warnings-as-errors. The standalone codec experiment linked real Yojson and
Digestif C. Dependencies were the exact `canonical` helper source slice from
`lane_addon_action.ml` and exact `digest` expression from `lane_addon_store.ml`,
with a transparent call counter. No filesystem/Runtime dependency was mocked
as having passed a real-store scenario.

One history contained registration and completion receipts, each with 2MiB of
input, and actual dispatch/judgment/commit/ACK transitions. Three complete
history replays were measured. Input construction and the typed history's
initial creation were outside the replay measurement in both versions.

| Measured boundary | Baseline | Candidate |
| --- | ---: | ---: |
| SHA256 calls for 3 complete history replays | 18 | 6 |
| Allocated bytes for those replays | 113,810,256 | 37,960,248 |
| Elapsed seconds, single local observation | 0.145621 | 0.048729 |
| SHA256 calls when appending an existing opaque registration receipt | 2 | 0 |

Both versions passed strict roundtrip and invalid-history probes: corrupted
digest, invalid time, duplicate payload fields, repeated intent, ACK without
intent, wrong ACK, early completion and invalid public payload. The candidate
also preserves physical identity of an appended opaque receipt.

The exact new pure scenario from `test_lane_addon_request_progress.ml` was
compiled and run against those codec modules: 1/1 PASS. Existing real-store
scenarios were not run. `ocamlc -stop-after parsing` and `git diff --check` passed.
This is a codec-only native experiment, not a complete Masc type/build result,
full suite result, installed latency improvement or proof about total server RSS.

## Remaining repair and verification

#45214, #45228 and #45246 address the primary architecture: store capture/body
once and restore only originals that the pass acts on. They are separate from
this codec optimization. No giant record was loaded/deleted for this experiment,
no live configuration changed and no server was restarted. Record/commit ledger
snapshots and other original discovery costs remain outside this change.
