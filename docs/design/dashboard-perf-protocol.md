# Dashboard Performance Protocol

> Status: Draft (PR-0.2.H scaffold). Budget thresholds are *initial* — not yet calibrated against a real build.
> Author: Vincent (jeong-sik) with Claude
> Created: 2026-04-30
> Tracks: PR-0.2.H (sibling of PR-0.2.F server perf, PR-0.2.G WS load).
> Related research: `knowledge/research/2026-04-masc-ide-strategy/ch4_dashboard.md` §4 (lines 230-378), `track-c-coordination-perf.md` §3 (line 148).

## 1. Scope

This document defines **synthetic** performance measurement for the masc-mcp dashboard SPA. It explicitly **does not** define a Real User Monitoring (RUM) pipeline; §4 records why.

In scope:
- Lighthouse CI run on every PR that touches `dashboard/**`.
- Performance budget JSON checked into the repo as the contract.
- Future hook: Playwright synthetic scenario calling `web-vitals.js` `onINP/onLCP/onCLS` inside automated flows (separate PR).

Out of scope (this PR):
- RUM endpoint, beacon ingestion, p75 aggregation. See §4.
- Production-runner Lighthouse baseline collection (sibling of PR-0.2.F, separate ops PR).

## 2. CI surface

| File | Role |
|------|------|
| `.github/workflows/dashboard-lighthouse.yml` | Builds the dashboard, runs Lighthouse against `vite preview`, uploads HTML/JSON artifact |
| `dashboard/test/perf/lighthouse-budget.json` | Performance budget — single source of truth for asserted thresholds |
| `docs/design/dashboard-perf-protocol.md` | This document |

The workflow is `continue-on-error: true` on the Lighthouse step *only*. Reason:

1. Budgets are **initial estimates**, not calibrated. Enforcing on the first run would block every PR until the first build passes.
2. The build step itself is not `continue-on-error` (per `feedback_ci_build_step_continue_on_error_masks_compile_break` — memory record).
3. Calibration plan: §4 step 1.

## 3. Budget rationale

Initial thresholds in `lighthouse-budget.json`:

| Metric | Budget | Rationale |
|--------|--------|-----------|
| Largest Contentful Paint | 2500 ms | Google CWV "Good" threshold |
| Time to Interactive | 3500 ms | LCP + 1s for hydration + signal-based reactivity |
| Total Blocking Time | 300 ms | CWV "Good" threshold |
| Cumulative Layout Shift | 0.1 | CWV "Good" threshold |
| Script bundle | 600 KB | Preact + cytoscape + vis-network + mermaid baseline; revisit after `build:report` profile |
| Stylesheet | 80 KB | Tailwind v4 + ppx_css output |
| Image | 200 KB | Dashboard is data-driven, minimal hero/screenshot use |
| Total transfer | 1200 KB | Sum of above + small overhead |
| Third-party requests | 5 | Almost all assets are bundled; this catches accidental CDN regressions |

These numbers will be revised after the first three CI runs land actual measurements. The point of shipping them now is **to make the contract visible**, not to set a final SLO.

## 4. Why synthetic-only (no RUM)

The original research (`ch4_dashboard.md` §4, line 230-238) explicitly recommends against RUM for this dashboard. The summary:

> INP의 p75 측정은 일반적으로 수백 건 이상의 interaction 표본이 필요하다. 두 자릿수 pageview 환경에서 web-vitals.js를 RUM으로 켜도 통계적 노이즈가 신호를 압도한다.

In plain terms:
- The dashboard is operated by ~12 keepers + a small operator team. Daily pageview is in the low double digits.
- Web Vitals percentile metrics (INP p75, LCP p75, CLS p75) require ~hundreds of independent interaction samples per page state to converge. With our traffic, the variance is larger than the threshold movement we'd be trying to detect.
- A RUM beacon endpoint would also introduce: (a) a new ingestion service, (b) a privacy decision, (c) noisy alerting.

**Decision**: ship Lighthouse-CI-only, deferred web-vitals-as-synthetic via Playwright (planned, not in this PR), no RUM endpoint.

This decision can be revisited if the dashboard's real-user reach grows by ≥10x. Re-evaluation criteria:
- Daily unique pageviews ≥ 500 sustained for ≥ 14 days, or
- Customer-facing dashboard variant ships (current scope is internal operators only).

## 5. Calibration plan

| Step | Owner | Signal |
|------|-------|--------|
| 1. First three CI runs | next PR author who touches `dashboard/**` | record actual LCP/TBT/transfer in PR comments |
| 2. Budget tightening | follow-up PR | move thresholds to the 95th percentile of observed values + 10% headroom |
| 3. Required-check promotion | follow-up PR | drop `continue-on-error` once 3 consecutive runs pass |
| 4. Synthetic web-vitals (Playwright) | separate PR (research PR-4.11) | deterministic INP/CLS samples in CI |
| 5. RUM re-evaluation | conditional, see §4 | only if traffic conditions change |

Each step is a separate PR. This document is the contract; the workflow is the runner.

## 6. Non-goals

- Performance regression *detection* on every PR. The goal is *visibility*. Treat the artifact as a PR review aid, not a hard gate, until §5 step 3.
- Lighthouse score targeting. Scores are derived from the metrics above; we measure the metrics directly.
- Bundle visualization. Already covered by `build:report` (`rollup-plugin-visualizer`); orthogonal.

## 7. References

- `dashboard/package.json` — `vite build`, `@preact/preset-vite`, `tailwindcss@^4.2.2`
- `.github/workflows/perf-baseline.yml` — sibling: server-side perf cron
- `.github/workflows/dashboard-ws-load.yml` — sibling: k6 WS load
- `knowledge/research/2026-04-masc-ide-strategy/ch4_dashboard.md` §4 lines 230-378 — anti-RUM rationale
- `knowledge/research/2026-04-masc-ide-strategy/track-c-coordination-perf.md` §3 line 148 — original lighthouse-vitals-pipeline scope

*작성: 2026-04-30 / 본 문서는 budget의 contract이며, 임계값은 calibration 후 갱신된다*
