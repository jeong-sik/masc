import { html } from 'htm/preact'
import { signal, type Signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { ActionButton } from './common/button'
import { DistributionBars, SegmentedBar, type DistributionItem } from './common/distribution-bars'
import { TimeAgo } from './common/time-ago'
import { fetchDashboardPerf, type DashboardPerfComparisonRow, type DashboardPerfResponse, type DashboardPerfRow } from '../api'

const perfSnapshot: Signal<DashboardPerfResponse | null> = signal(null)
const loading: Signal<boolean> = signal(false)
const error: Signal<string | null> = signal(null)
let inflightPerfRefresh: Promise<void> | null = null

async function refreshPerfSnapshot(): Promise<void> {
  if (inflightPerfRefresh) return inflightPerfRefresh
  loading.value = true
  error.value = null
  inflightPerfRefresh = (async () => {
    try {
      perfSnapshot.value = await fetchDashboardPerf()
    } catch (err) {
      error.value = err instanceof Error ? err.message : String(err)
    } finally {
      loading.value = false
      inflightPerfRefresh = null
    }
  })()
  return inflightPerfRefresh
}

function formatMs(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '-'
  return `${Math.round(value)}ms`
}

function shortPath(path?: string | null): string {
  if (!path) return '-'
  const parts = path.split('/').filter(Boolean)
  return parts.slice(-2).join('/')
}

function verdictTone(verdict?: string): string {
  if (verdict === 'improved') return 'text-[var(--ok)]'
  if (verdict === 'regressed') return 'text-[var(--bad)]'
  if (verdict === 'mixed') return 'text-[var(--warn)]'
  return 'text-[var(--text-muted)]'
}

function PerfStat({
  label,
  value,
  detail,
}: {
  label: string
  value: string
  detail?: string | null
}) {
  return html`
    <div class="rounded border border-card-border/45 bg-[var(--white-5)]/10 px-3 py-3">
      <div class="text-3xs font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">${label}</div>
      <div class="mt-1 text-2xl font-bold text-[var(--text-strong)]">${value}</div>
      ${detail ? html`<div class="mt-1 text-2xs text-[var(--text-muted)]">${detail}</div>` : null}
    </div>
  `
}

function DiffRow({ row }: { row: DashboardPerfComparisonRow }) {
  const avgDelta = row.avg_delta_ms > 0 ? `+${row.avg_delta_ms}` : `${row.avg_delta_ms}`
  const p95Delta = row.p95_delta_ms > 0 ? `+${row.p95_delta_ms}` : `${row.p95_delta_ms}`
  return html`
    <div class="flex items-center justify-between gap-3 rounded border border-card-border/35 bg-[var(--white-5)]/8 px-3 py-2">
      <div class="min-w-0">
        <div class="truncate text-xs font-semibold text-[var(--text-strong)]">${row.benchmark}</div>
        <div class="text-2xs text-[var(--text-muted)]">avg ${avgDelta}ms · p95 ${p95Delta}ms</div>
      </div>
      <div class="shrink-0 text-2xs font-semibold uppercase tracking-[0.14em] ${verdictTone(row.verdict)}">${row.verdict}</div>
    </div>
  `
}

function metricDetail(row?: DashboardPerfRow | null): string | null {
  if (!row?.note_tags) return row?.notes ?? null
  if (row.benchmark === 'oas_runtime_status') {
    const configured = row.note_tags.configured_capacity
    const healthy = row.note_tags.healthy_runtime_count
    if (configured || healthy) return `healthy ${healthy ?? '-'} / configured ${configured ?? '-'}`
  }
  if (row.benchmark === 'oas_runtime_single') {
    const ceiling = row.note_tags.measured_ceiling
    if (ceiling) return `measured ceiling ${ceiling}`
  }
  return row.notes || null
}

function benchmarkTone(row: DashboardPerfRow): DistributionItem['tone'] {
  if (row.p95_ms >= 1000 || row.avg_ms >= 1000) return 'bad'
  if (row.p95_ms >= 500 || row.avg_ms >= 500) return 'warn'
  if (row.avg_ms > 0) return 'accent'
  return 'muted'
}

function comparisonTone(verdict?: string): DistributionItem['tone'] {
  if (verdict === 'improved') return 'ok'
  if (verdict === 'regressed') return 'bad'
  if (verdict === 'mixed') return 'warn'
  return 'muted'
}

function benchmarkDistribution(data: DashboardPerfResponse | null): DistributionItem[] {
  const highlightRows = [
    data?.highlights?.session_init,
    data?.highlights?.worst_live_mcp,
    data?.highlights?.runtime_single,
    data?.highlights?.runtime_status,
  ].filter((row): row is DashboardPerfRow => row != null)
  const seen = new Set<string>()
  const preferred = [...highlightRows, ...(data?.benchmarks ?? [])]
  const items: DistributionItem[] = []

  for (const row of preferred) {
    if (seen.has(row.benchmark)) continue
    seen.add(row.benchmark)
    if (row.p95_ms <= 0) continue
    const label = row.benchmark.replace(/^mcp_/, '').replace(/^oas_/, '')
    items.push({
      label,
      value: row.p95_ms,
      detail: `avg ${formatMs(row.avg_ms)} · max ${formatMs(row.max_ms)}`,
      tone: benchmarkTone(row),
    })
    if (items.length >= 6) break
  }

  return items
}

function comparisonSegments(data: DashboardPerfResponse | null): DistributionItem[] {
  const verdictCounts = data?.comparison?.verdict_counts
  return [
    { label: 'improved', value: verdictCounts?.improved ?? 0, tone: 'ok' },
    { label: 'stable', value: verdictCounts?.stable ?? 0, tone: 'muted' },
    { label: 'mixed', value: verdictCounts?.mixed ?? 0, tone: 'warn' },
    { label: 'regressed', value: verdictCounts?.regressed ?? 0, tone: 'bad' },
  ]
}

function topChangeDistribution(rows: DashboardPerfComparisonRow[]): DistributionItem[] {
  return rows.slice(0, 4).map(row => ({
    label: row.benchmark,
    value: Math.max(Math.abs(row.p95_delta_ms), Math.abs(row.avg_delta_ms)),
    detail: `avg ${row.avg_delta_ms > 0 ? '+' : ''}${row.avg_delta_ms}ms · p95 ${row.p95_delta_ms > 0 ? '+' : ''}${row.p95_delta_ms}ms`,
    tone: comparisonTone(row.verdict),
  }))
}

export function PerfSnapshotPanel() {
  useEffect(() => {
    if (!loading.value) {
      void refreshPerfSnapshot()
    }
  }, [])

  const data = perfSnapshot.value
  const generatedAt = data?.latest_run?.started_at ?? data?.generated_at ?? null
  const worstMcp = data?.highlights?.worst_live_mcp ?? null
  const runtimeSingle = data?.highlights?.runtime_single ?? null
  const runtimeStatus = data?.highlights?.runtime_status ?? null
  const sessionInit = data?.highlights?.session_init ?? null
  const topChanges = data?.comparison?.top_changes ?? []
  const verdictCounts = data?.comparison?.verdict_counts

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-[var(--text-muted)]">Perf Snapshot</div>
          <div class="mt-1 text-sm text-[var(--text-body)]">
            ${generatedAt
              ? html`최근 run <strong class="text-[var(--text-strong)]"><${TimeAgo} timestamp=${generatedAt} /></strong>`
              : '최근 run 없음'}
          </div>
          ${data?.source?.result_file
            ? html`<div class="mt-1 text-2xs text-[var(--text-muted)]">${shortPath(data.source.result_file)}</div>`
            : null}
        </div>
        <${ActionButton}
          variant="ghost"
          size="md"
          disabled=${loading.value}
          onClick=${() => {
            void refreshPerfSnapshot()
          }}
        >
          ${loading.value ? '갱신 중...' : '새로고침'}
        <//>
      </div>

      ${error.value
        ? html`<div class="rounded border border-bad/35 bg-bad/10 px-3 py-3 text-xs text-[var(--bad)]">${error.value}</div>`
        : null}

      ${data?.status === 'empty'
        ? html`<div class="rounded border border-card-border/35 bg-[var(--white-5)]/10 px-3 py-3 text-xs text-[var(--text-muted)]">
            benchmark artifact가 아직 없습니다. <code>benchmark.sh</code>를 한 번 돌리면 latest summary와 baseline diff가 여기에 나타납니다.
          </div>`
        : null}

      ${data?.status === 'ok'
        ? html`
            <div class="grid grid-cols-2 gap-3 max-[960px]:grid-cols-1">
              <${PerfStat}
                label="Session Init"
                value=${formatMs(sessionInit?.p95_ms ?? sessionInit?.avg_ms)}
                detail=${'p95'}
              />
              <${PerfStat}
                label="Worst MCP p95"
                value=${formatMs(worstMcp?.p95_ms)}
                detail=${worstMcp?.benchmark ?? null}
              />
              <${PerfStat}
                label="Runtime Avg"
                value=${formatMs(runtimeSingle?.avg_ms)}
                detail=${metricDetail(runtimeSingle)}
              />
              <${PerfStat}
                label="Runtime Status"
                value=${formatMs(runtimeStatus?.avg_ms)}
                detail=${metricDetail(runtimeStatus)}
              />
            </div>

            ${verdictCounts
              ? html`
                  <${SegmentedBar}
                    title="Baseline Diff"
                    subtitle=${data.comparison?.baseline_file
                      ? `baseline ${shortPath(data.comparison.baseline_file)}`
                      : 'baseline 대비 verdict 분포'}
                    items=${comparisonSegments(data)}
                    valueFormatter=${(value: number) => `${value}`}
                  />
                `
              : null}

            <${DistributionBars}
              title="Benchmark p95"
              subtitle="최근 snapshot에서 눈에 띄는 benchmark 지연"
              items=${benchmarkDistribution(data)}
              valueFormatter=${(value: number) => formatMs(value)}
              emptyLabel="시각화할 benchmark row가 없습니다."
            />

            ${topChanges.length > 0
              ? html`
                  <div class="grid grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)] gap-3 max-[960px]:grid-cols-1">
                    <div class="flex flex-col gap-2">
                      <div class="text-2xs font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">Top Changes</div>
                      ${topChanges.slice(0, 4).map(row => html`<${DiffRow} row=${row} />`)}
                    </div>
                    <${DistributionBars}
                      title="Delta Magnitude"
                      subtitle="변화폭이 큰 benchmark 우선"
                      items=${topChangeDistribution(topChanges)}
                      valueFormatter=${(value: number) => `${Math.round(value)}ms`}
                    />
                  </div>
                `
              : null}
          `
        : null}
    </div>
  `
}
