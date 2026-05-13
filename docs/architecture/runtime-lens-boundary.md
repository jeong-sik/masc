# Runtime Lens Boundary

**Status**: Active (since #15040; refined by #15070 carve-out and #15089 test pins)
**Last updated**: 2026-05-14

This document codifies *where* the Runtime Lens redaction is applied
in the cascade subsystem, so that future iterations don't reintroduce
the over-application that #15040 originally shipped. The TL;DR: the
lens redacts at **external boundaries**, not at every serializer.

## What the lens redacts

The Runtime Lens replaces concrete provider/model identity strings
(`claude_code.claude-auto`, `ollama_cloud.ollama-cloud-deepseek-v4-pro`,
`https://ollama.com`, etc.) with `public_runtime_*_label` constants
(`"runtime"` / `"runtime"` / `""`). The intent is to prevent identity
leakage across the OAS/MASC boundary and into externally-exposed
surfaces.

## Where it applies (external boundaries — redact)

| Surface | Owner | Redaction site |
|---|---|---|
| Prometheus metric labels | `record_probe_metrics` (`lib/cascade/cascade_catalog_runtime.ml`) | `provider_name="runtime"`, `model_id="runtime"`. Pinned by `test/test_keeper_hooks_oas_telemetry.ml` (4 assertions, 43 tests pass). |
| Dashboard OAS bridge | `lib/dashboard/dashboard_oas_bridge.ml` | `provider_id` / `model_id` collapsed to `public_runtime_*_label`. |
| Dashboard harness health | `lib/dashboard/dashboard_harness_health.ml` | Same. |
| Provider error responses | `lib/core/provider_error.ml` | `provider` / `model_name` redacted in error envelopes. |
| Keeper unified metrics (redacted variants) | `lib/keeper/keeper_unified_metrics.ml` (`redacted_cascade_attempt_to_json` etc.) | `model_id` / `model_label` omitted entirely (stronger than placeholder). |

## Where it must NOT apply (internal observability — emit real)

| Surface | Owner | Carve-out site | Test |
|---|---|---|---|
| "Validated active cascade catalog" boot log | `Cascade_catalog_runtime.candidate_probe_to_yojson` (called from `server_runtime_bootstrap.ml`) | #15070 commit `fd50aa68f6` | `test/test_cascade_catalog_runtime_yojson.ml` "candidate_probe real identity" |
| Audit log (`record_cascade_audit`) | `Cascade_legacy_runner.cascade_attempt_to_json` / `cascade_fallback_event_to_json` (called from `cascade_observation_to_json`) | #15070 commit `f567e57272` | `test/test_cascade_catalog_runtime_yojson.ml` "cascade_observation audit-log real identity" |

## Decision rule for future serializers

When adding a new `*_to_yojson` function that touches provider/model
identity, ask:

1. **Who reads this JSON?**
   - HTTP response to OAS / external API client → **redact** via `public_runtime_*_label`.
   - Prometheus scrape target → **redact** (cardinality + boundary).
   - Dashboard JSON consumed by FE → **redact** (FE never needs ground truth identity).
   - `Log.Server.info` / `Log.Keeper.info` / `record_*_audit` → **emit real values**. These are operator inspection surfaces inside the masc-mcp process. Without real identity, a misconfigured cascade.toml is indistinguishable from a healthy one.

2. **Is there already a `redacted_*` companion?** If yes, treat the
   non-prefixed variant as internal and emit real. (See
   `Keeper_unified_metrics.redacted_cascade_attempt_to_json` paired
   with `Cascade_legacy_runner.cascade_attempt_to_json`.)

3. **Does a sibling field in the same envelope emit real values?** If
   yes, the inner record should match. #15040 introduced
   inconsistency where outer `selected_model` was real but inner
   `attempts[*].model_id` was `"runtime"` — operators couldn't
   correlate the two within a single record.

## Regression guard

`test/test_cascade_catalog_runtime_yojson.ml` pins both carve-out
sites with 8 test cases (4 status variants × 2 surfaces + 2 anti-regression
substring checks). A PR that reintroduces `public_runtime_*_label` at
either site fails this test before merge.

For new internal-observability serializers, the recommended test shape
is:

```ocaml
let test_my_serializer_emits_real_identity () =
  let record = make_record ~model_id:"specific.distinct" () in
  let json = My_module.to_yojson record in
  Alcotest.(check string) "real model_id" "specific.distinct"
    (assoc_string "model_id" json);
  let text = Yojson.Safe.to_string json in
  Alcotest.(check bool) "no runtime placeholder" false
    (substring text "\"model_id\":\"runtime\"")
```

Borrow the helpers from `test/test_cascade_catalog_runtime_yojson.ml`
(`assoc_string`, the `contains` substring scanner) when adding the
companion test for a new internal serializer.

## History

- **#15040** (`44b89707295`, 2026-05-13): introduced the Runtime Lens.
  Redacted both external boundaries and *all* base serializers
  (`candidate_probe_to_yojson`, `cascade_attempt_to_json`,
  `cascade_fallback_event_to_json`) to `public_runtime_*_label`.
  Operational regression: boot log + audit log became opaque.
- **#15070** (`b0c741bb7d`, 2026-05-13): carve-out for the two
  internal-observability sites. Real values restored. External
  boundaries unchanged; Prometheus tests still pass.
- **#15089** (this work): regression test pins both carve-out sites
  and this document.
