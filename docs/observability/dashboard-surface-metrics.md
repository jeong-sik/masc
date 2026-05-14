# Dashboard Surface & Section Metrics

> RFC-0049 telemetry foundation — companion to
> `infrastructure/monitoring/grafana-dashboard-surface-dashboard.json`.

## Counters

| Counter | Labels | Description |
|---|---|---|
| `dashboard_surface_open_total` | `surface` | Top-level dashboard surface opens (cockpit, overview, monitoring, command, connectors, workspace, lab, code, logs). |
| `dashboard_section_open_total` | `surface`, `section`, `redirected_from` | Section-level opens within a surface. `redirected_from` carries the original `<surface>:<section>` key when the route arrived via `CROSS_SURFACE_SECTION_REDIRECTS` or `SECTION_REDIRECTS`, otherwise `none`. |

Aggregate-only. **No PII.** No operator label, session ID, or IP.

## Producers

| Layer | Module | Behavior |
|---|---|---|
| Client | `dashboard/src/lib/nav-telemetry.ts` | Subscribes to the `route` signal. Emits one event per unique `(surface, section)` transition; collapses identical re-emissions within 500 ms. |
| Client → server | `POST /api/v1/dashboard/nav-event` | One JSON body per transition: `{ surface, section, redirected_from }`. Best-effort, no retry. |
| Server | `lib/dashboard/dashboard_nav_event.ml` | Validates against the surface + section allowlist, then calls `Prometheus.inc_counter`. The body is discarded after the increment. |

Counters are registered at module load (`let () = Prometheus.register_counter …`) so they exist in `/metrics` immediately on server start, even before the first request.

## Consumers

- **Grafana**: `infrastructure/monitoring/grafana-dashboard-surface-dashboard.json` — surface ranking, section ranking with direct/total split, redirect provenance table, total opens stat, rate timeseries.
- **CLI report**: `scripts/dashboard-ia-usage.sh` — point-in-time Markdown report scraped from `/metrics`. No Prometheus dependency. Drives RFC-0048 PR-C deletion threshold decisions.

## Key derived metric: "direct opens"

The `redirected_from="none"` filter is the deletion-threshold metric per RFC-0048 §4.4. A section with high `Total` but low `Direct` is alive **only because of legacy bookmarks** — the redirect entry can stay in `CROSS_SURFACE_SECTION_REDIRECTS`/`SECTION_REDIRECTS`, but the section component itself can be deleted.

PromQL pattern:

```promql
# Direct opens per (surface, section), last 7d
sum by (surface, section) (
  increase(dashboard_section_open_total{redirected_from="none"}[7d])
)
```

## Cardinality bound

```
|surfaces|     × |sections|     × (|redirects| + 1)
       9       ×        20      ×              4    ≈ 720 distinct label combinations
```

Far below any Prometheus practical limit. RFC-0049 §5.5 caps further growth: if cardinality crosses 10k, an opt-in flag is added. As of 2026-05, growth would require either new surfaces or new redirect sources, neither of which is in flight.

## Failure modes

| Symptom | Cause | What to do |
|---|---|---|
| `/metrics` shows zero `dashboard_surface_open_total` | Server has not seen any dashboard navigation since start, or PR-1 (#14245) not yet deployed | Open the dashboard and click around; if still zero, check `dashboard/src/main.ts` calls `startNavTelemetry()` |
| `redirected_from` distribution off | URL leak — internal param escaped to URL, distorting counters from operator bookmarks | Run `dashboard/src/router.test.ts` regression cases (URL leak guards). Fix and ratchet down to clean counter |
| Timeseries flat after a deploy | Either `route` signal listener detached, or `effect()` dispose triggered prematurely | Check `nav-telemetry.test.ts` "disposer stops further emissions" inversion. Verify HMR didn't double-mount the observer |
| One specific section never registers | Section ID missing from `lib/dashboard/dashboard_nav_event.ml`'s `valid_sections` allowlist | Add to allowlist; the server returns 400 for unknown `(surface, section)` pairs and the client drops the event |

## Out of scope (future work)

- **Per-operator analytics**: aggregate-only by RFC-0049 §3 non-goal. Would require a session label and PII review.
- **Dwell time / bounce rate**: deferred until a consumer asks. Adding now expands surface area without justification (RFC-0049 §3).
- **A/B test routing**: not in scope — would require a treatment label and randomized assignment.

## Related

- RFC-0049 — `docs/rfc/RFC-0049-surface-telemetry-foundation.md`
- RFC-0048 — `docs/rfc/RFC-0048-dashboard-ia-phase-2.md` (primary consumer)
- PR-1 #14245 — telemetry foundation
- PR-1.1 #14251 — ocamlformat follow-up
- PR-2 #14256 — `scripts/dashboard-ia-usage.sh`
