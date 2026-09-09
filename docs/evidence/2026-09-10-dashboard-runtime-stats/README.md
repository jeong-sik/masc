# Runtime usage visible from Overview

Overview now displays the existing `/api/v1/models/metrics` data directly and
links to Monitor → Runtime → Cost for the fuller existing inspection surface.
Each runtime lane shows reported input/output tokens, non-error/error record
counts, p50/p95 latency and usage/telemetry reported/missing counts. Percentiles
are displayed per lane as returned; no aggregate percentile or success rate is
invented. Missing measurements remain explicitly unreported, while a reported
numeric zero remains zero.

Source behavior inspected for this change:

- `server_routes_http_routes_provider_runs.ml` serves a cached response and can
  initially return an empty placeholder. An empty array therefore appears as
  not yet observed, with no zero-usage claim.
- `model_inference_metrics_reader.ml` merges Keeper decision records with dated
  cost-ledger entries. Cost-ledger failures can leave decision-only results;
  `cost_ledger_read` diagnostics are now preserved by the dashboard decoder.
- `model_inference_metrics_aggregate.ml` computes token totals and latency
  percentiles from non-error records carrying those measurements. They are not
  Task completion outcomes. Source retention and decision-read completeness are
  not supplied in this API response.
- `model_inference_metrics_json.ml` supplies the nominal window and per-lane
  measurements, but no exact aggregate timestamp. The UI distinguishes that
  window from the browser's response receipt time and does not manufacture an
  exact observation interval.

Validation: eight new component/API scenarios and 103 existing Overview tests
passed. The existing targeted `fetchRuntimeModelMetrics` API scenario also
passed. Coverage includes real detail-route navigation, malformed inventories,
ledger failure, missing versus zero, empty-cache state, retry and superseded
period requests. Existing Overview teardown emitted abort/socket diagnostics;
the test runner exited successfully. No local build was run. CI artifact/browser
rendering and deployed behavior remain pending. TUI statistics are outside this
Dashboard unit and remain pending.
