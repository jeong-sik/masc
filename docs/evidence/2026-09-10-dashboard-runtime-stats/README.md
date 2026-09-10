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
  initially return `cost_ledger_read.state=pending` with an empty placeholder.
  Pending is preserved as a typed preparing state and followed through with
  the shared visibility-aware panel refresh lifecycle. Completed empty aggregates
  and absent read-status responses remain distinct, with no zero-usage claim.
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

Validation: twelve focused component/API scenarios passed after the pending
repair. Before that repair, the eight original scenarios and 103 existing
Overview tests passed. The existing targeted `fetchRuntimeModelMetrics` API scenario also
passed. Coverage includes real detail-route navigation, malformed inventories,
ledger failure, missing versus zero, empty-cache state, retry and superseded
period requests. Existing Overview teardown emitted abort/socket diagnostics;
the test runner exited successfully. No local build was run. CI artifact/browser
rendering and deployed behavior remain pending. TUI statistics are outside this
Dashboard unit and remain pending.

The refresh lifecycle uses the existing `setupVisibleAutoRefresh` helper and its
shared `DEFAULT_PANEL_REFRESH_MS` cadence, plus focus/visibility notifications.
It skips overlapping reads, disposes interval/listeners and aborts old requests
when unmounted or when the period changes. There is no retry cap or elapsed-time
failure. Added tests exercise the actual pending envelope followed by available
metrics, available-but-empty results, unmount cleanup and an old pending request
finishing after a period change.

## CI-built browser verification

Verified source `3766afb7ce0a1a536585f9626c85a4f8539e0ade` using preview
artifact 10121768265 from run 34396472298. The harness checked every asset hash
against preview provenance before rendering. Desktop and 390px mobile screenshots
were visually inspected; mobile records now use readable per-runtime blocks.
Pending-to-available refresh, missing versus zero, period changes, ledger failure,
HTTP failure/retry and navigation to details passed, with no page errors or mobile
overflow. `browser/receipt.json` and PNGs contain the evidence.

The metric responses are explicit synthetic fixtures over a live backend, not
measured production usage. The visible build mismatch warning is expected because
CI frontend assets run over the separately deployed server. This is not a
production deployment or proof of actual ledger totals.

## Actual backend data rendered

`verify-runtime-stats-live-preview.mjs` renders the same hash-verified CI assets
while reading the actual authenticated metrics endpoint. Seven runtime rows
were returned; every displayed row identity and input/output token value matched
that response. Desktop/mobile screenshots were visually inspected and no page
errors occurred. `live-browser/receipt.json` retains the observed response.
The token is read only from a supplied file and is not part of the evidence.

This confirms API-to-screen values, not independent reconciliation against raw
ledger rows or production deployment. The API currently uses opaque runtime-lane
IDs; translating those to usable provider/runtime identities remains a UX gap.
