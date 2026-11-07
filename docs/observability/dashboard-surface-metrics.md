# Dashboard Surface & Section Metrics

> RFC-0049 telemetry foundation.

## Counters

| Counter | Labels | Description |
|---|---|---|
| `dashboard_surface_open_total` | `surface` | Top-level dashboard surface opens. The values are the `valid_surfaces` allowlist in `lib/dashboard/dashboard_nav_event.ml`. |
| `dashboard_section_open_total` | `surface`, `section` | Section-level opens within a surface. The pairs are the `valid_sections` allowlist in the same file. |

Aggregate-only. **No PII.** No operator label, session ID, or IP.

## Producers

| Layer | Module | Behavior |
|---|---|---|
| Client | `dashboard/src/lib/nav-telemetry.ts` | Subscribes to the `route` signal. Emits one event per unique `(surface, section)` transition; collapses identical re-emissions within 500 ms. |
| Client → server | `POST /api/v1/dashboard/nav-event` | One JSON body per transition: `{ surface, section }`. Best-effort, no retry. |
| Server | `lib/dashboard/dashboard_nav_event.ml` | Validates against the surface + section allowlist, then calls `Otel_metric_store.inc_counter`. The body is discarded after the increment. |

Counters are registered at module load (`let () = Otel_metric_store.register_counter …`) so they are available to the configured OTel export path immediately on server start, even before the first request.

## Consumers

- **OTel query/report**: query the configured OTel backend for `dashboard_surface_open_total` and `dashboard_section_open_total` to evaluate section usage.

## Cardinality bound

`dashboard_surface_open_total` has one label value per entry of `valid_surfaces`.
`dashboard_section_open_total` has one `(surface, section)` pair per entry of
`valid_sections`. Both lists live in `lib/dashboard/dashboard_nav_event.ml`.
On 2026-11-07 that is 15 surfaces and 36 pairs.

Far below the practical cardinality limit for this bounded OTel surface.
RFC-0049 §5.5 caps further growth: if cardinality crosses 10k, an opt-in flag
is added. Growth would require new surfaces or sections.

## Failure modes

| Symptom | Cause | What to do |
|---|---|---|
| OTel backend shows zero `dashboard_surface_open_total` | Server has not seen any dashboard navigation since start, OTel export is not configured, or PR-1 (#14245) not yet deployed | Open the dashboard and click around; if still zero, check `dashboard/src/main.ts` calls `startNavTelemetry()` and the OTel exporter pipeline |
| Timeseries flat after a deploy | Either `route` signal listener detached, or `effect()` dispose triggered prematurely | Check `nav-telemetry.test.ts` "disposer stops further emissions" inversion. Verify HMR didn't double-mount the observer |
| One specific section never registers | Section ID missing from `lib/dashboard/dashboard_nav_event.ml`'s `valid_sections` allowlist | Add to allowlist; the server returns 400 for unknown `(surface, section)` pairs and the client drops the event |

## Out of scope (future work)

- **Per-operator analytics**: aggregate-only by RFC-0049 §3 non-goal. Would require a session label and PII review.
- **Dwell time / bounce rate**: deferred until a consumer asks. Adding now expands surface area without justification (RFC-0049 §3).
- **A/B test routing**: not in scope — would require a treatment label and randomized assignment.

## Related

- RFC-0049 — `docs/rfc/RFC-0049-surface-telemetry-foundation.md`
- PR-1 #14245 — telemetry foundation
- PR-1.1 #14251 — ocamlformat follow-up
