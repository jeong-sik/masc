import { html } from 'htm/preact'
import { signal, type Signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { ActionButton } from './common/button'
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
    <div class="rounded-xl border border-card-border/45 bg-black/10 px-3 py-3">
      <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">${label}</div>
      <div class="mt-1 text-[20px] font-bold text-[var(--text-strong)]">${value}</div>
      ${detail ? html`<div class="mt-1 text-[11px] text-[var(--text-muted)]">${detail}</div>` : null}
    </div>
  `
}

function DiffRow({ row }: { row: DashboardPerfComparisonRow }) {
  const avgDelta = row.avg_delta_ms > 0 ? `+${row.avg_delta_ms}` : `${row.avg_delta_ms}`
  const p95Delta = row.p95_delta_ms > 0 ? `+${row.p95_delta_ms}` : `${row.p95_delta_ms}`
  return html`
    <div class="flex items-center justify-between gap-3 rounded-lg border border-card-border/35 bg-black/8 px-3 py-2">
      <div class="min-w-0">
        <div class="truncate text-[12px] font-semibold text-[var(--text-strong)]">${row.benchmark}</div>
        <div class="text-[11px] text-[var(--text-muted)]">avg ${avgDelta}ms · p95 ${p95Delta}ms</div>
      </div>
      <div class="shrink-0 text-[11px] font-semibold uppercase tracking-[0.14em] ${verdictTone(row.verdict)}">${row.verdict}</div>
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

export function PerfSnapshotPanel() {
  useEffect(() => {
    if (!perfSnapshot.value && !loading.value) {
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
          <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-[var(--text-muted)]">Perf Snapshot</div>
          <div class="mt-1 text-[13px] text-[var(--text-body)]">
            ${generatedAt
              ? html`최근 run <strong class="text-[var(--text-strong)]"><${TimeAgo} timestamp=${generatedAt} /></strong>`
              : '최근 run 없음'}
          </div>
          ${data?.source?.result_file
            ? html`<div class="mt-1 text-[11px] text-[var(--text-muted)]">${shortPath(data.source.result_file)}</div>`
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
        ? html`<div class="rounded-xl border border-bad/35 bg-bad/10 px-3 py-3 text-[12px] text-[var(--bad)]">${error.value}</div>`
        : null}

      ${data?.status === 'empty'
        ? html`<div class="rounded-xl border border-card-border/35 bg-black/10 px-3 py-3 text-[12px] text-[var(--text-muted)]">
            benchmark artifact가 아직 없습니다. `benchmark.sh`를 한 번 돌리면 latest summary와 baseline diff가 여기에 나타납니다.
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
                  <div class="rounded-xl border border-card-border/35 bg-black/10 px-3 py-3">
                    <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">Baseline Diff</div>
                    <div class="mt-2 flex flex-wrap gap-2 text-[11px]">
                      <span class="rounded-full border border-[var(--ok)]/25 bg-[var(--ok)]/10 px-2 py-1 text-[var(--ok)]">improved ${verdictCounts.improved ?? 0}</span>
                      <span class="rounded-full border border-card-border/45 bg-card/25 px-2 py-1 text-[var(--text-muted)]">stable ${verdictCounts.stable ?? 0}</span>
                      <span class="rounded-full border border-[var(--warn)]/25 bg-[var(--warn)]/10 px-2 py-1 text-[var(--warn)]">mixed ${verdictCounts.mixed ?? 0}</span>
                      <span class="rounded-full border border-[var(--bad)]/25 bg-[var(--bad)]/10 px-2 py-1 text-[var(--bad)]">regressed ${verdictCounts.regressed ?? 0}</span>
                    </div>
                    ${data.comparison?.baseline_file
                      ? html`<div class="mt-2 text-[11px] text-[var(--text-muted)]">baseline ${shortPath(data.comparison.baseline_file)}</div>`
                      : null}
                  </div>
                `
              : null}

            ${topChanges.length > 0
              ? html`
                  <div class="flex flex-col gap-2">
                    <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">Top Changes</div>
                    ${topChanges.slice(0, 4).map(row => html`<${DiffRow} row=${row} />`)}
                  </div>
                `
              : null}
          `
        : null}
    </div>
  `
}
