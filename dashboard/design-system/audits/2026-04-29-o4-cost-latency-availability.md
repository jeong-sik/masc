# O4 Cost & Latency — backend availability check (2026-04-29)

Phase 2 spec card `cb-group-f.jsx:O4` (Cost & Latency) describes three
variants over a single zone-shape payload. The Phase 2 closure plan
gated O4 implementation on **live verification** that the production
backend already exposes that payload. This note records the result.

## Spec data shape

`dashboard/design-system/preview/data-p2.js:199-237` plus the variant
bodies (`cb-group-f.jsx:291-429`) require:

```ts
costs: {
  perAgent: [{ agent, in_tok, out_tok, cost, p50_ms, p95_ms }, ...],
  matrix: {
    providers: string[],
    models: string[],
    grid: number[][]
  },
  latencyBuckets: [{ lo, hi, n }, ...],
  p50: number,
  p95: number,
  total_cost_usd: number
}
```

Three variants consume it:

- **CostPerAgent** (`cb-group-f.jsx:291-349`) — per-agent table + 4-cell KPI strip
- **CostMatrix** (`cb-group-f.jsx:351-389`) — provider×model heatmap with z0-z4 zones
- **CostLatency** (`cb-group-f.jsx:391-429`) — histogram + 4 distribution bands

## Production verification

**Method**: read `DashboardShellResponse` definition (the type that
parses `/api/v1/dashboard/shell`) and grep for the spec field names
across the dashboard frontend.

`dashboard/src/types/dashboard-execution.ts:118-133`:

```ts
export interface DashboardShellResponse {
  generated_at?: string
  status: ServerStatus
  counts?: { agents?, tasks?, keepers?, total_runtimes? }
  configured_keepers?: number
  providers?: Record<string, unknown>
  auth?: ... | null
  config_resolution?: ... | null
  runtime_resolution?: ... | null
}
```

**No `costs` field.**

Grep across the dashboard:

| Pattern | Hits | Where |
|---------|------|-------|
| `perAgent` | 0 | — |
| `latencyBuckets` | 0 | — |
| `matrix.*provider` | 0 | — |
| `costs:` (object key) | 0 | — |
| `costs\.` (object access) | 1 | `keeper-detail-panels.ts:1056` — local array sum, not the spec field |
| `cost_usd` | many | scattered: `Metric.cost_usd`, `BudgetSummary.total_cost_usd`, `HopRecord.cost_usd`, etc. — **not** the zone payload |

The scattered `cost_usd` fields (single-event cost on a metric / hop /
budget hook) are the **building blocks** that a backend aggregator could
compose into the zone payload, but no aggregator exists today and no
endpoint emits the composed shape.

## Decision

**O4 demoted to backend wave.** Frontend implementation is blocked on
backend exposing the composed `costs` payload (or a dedicated
`/api/v1/dashboard/cost-latency` endpoint with the spec shape).

## Effort revised

| Original (Plan A) | Revised (post-check) |
|-------------------|----------------------|
| Step 2 = 3 frontend PR (~470 LOC), routing in `monitoring?section=cost-latency` | **Cancelled.** Replaced by Step 3 backend RFC issue (`[Phase 2 backend] O4 Cost & Latency aggregator`) |
| Anchor reuse: `keeper-token-stats.ts` table, `safe-autonomy.ts` KpiStrip | Defer until backend lands |

## Note on prior audit hallucination

The exploratory subagent that produced the initial O4 sizing (in the
plan's Phase 1 verification round) reported `dashboard.ts:318` as the
"costs payload parsing site". On direct verification this turned out to
be a false positive — line 318 is unrelated, and the field shape
(`perAgent`, `matrix`, `latencyBuckets`) does not appear anywhere in the
production tree.

This is consistent with the memory feedback
`feedback_evidence_first_before_speculation_pr` (verify before assuming
upstream capability) and is the precise reason the Phase 2 closure plan
gated O4 on a live verification step rather than dispatching the 3 PRs
straight.

## Cross-link

- Plan: `/Users/dancer/me/planning/claude-plans/20m-me-workspace-yousleepwhen-masc-h-curious-dusk.md` § "Phase C/D/E/F Closure Plan / Step 1"
- Spec: `dashboard/design-system/preview/cb-group-f.jsx:291-429`
- Mock: `dashboard/design-system/preview/data-p2.js:199-237`
- Type: `dashboard/src/types/dashboard-execution.ts:118-133`
- Backend issue (to be filed in Step 3): `[Phase 2 backend] O4 Cost & Latency aggregator`
