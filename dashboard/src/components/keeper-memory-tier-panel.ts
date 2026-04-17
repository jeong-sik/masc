import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  fetchKeeperStateDiagram,
  type KeeperCompositeSnapshot,
  type MemoryKindUsageEntry,
} from '../api/keeper'
import { EmptyState } from './common/empty-state'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { FilterChips } from './common/filter-chips'
import { buildCompactionSpec } from './keeper-fsm-specs'

interface KeeperMemoryTierPanelProps {
  keeperName: string
  currentPhase?: string | null
}

export type MemoryTierFilter = 'all' | 'saturated'

/**
 * Pure filter for memory-tier rows.
 *
 * - `query` is case-insensitive substring match on `row.kind` (trimmed).
 * - `filter === 'saturated'` keeps only rows where `used >= cap` (cap > 0).
 *   Rows with `cap === 0` are never saturated (avoid div-by-zero framing).
 * - Empty query + `filter === 'all'` returns the input reference unchanged.
 */
export function filterMemoryKindUsage(
  rows: readonly MemoryKindUsageEntry[],
  query: string,
  filter: MemoryTierFilter = 'all',
): readonly MemoryKindUsageEntry[] {
  const needle = query.trim().toLowerCase()
  if (needle === '' && filter === 'all') return rows
  return rows.filter(row => {
    if (filter === 'saturated' && !(row.cap > 0 && row.used >= row.cap)) return false
    if (needle === '') return true
    return row.kind.toLowerCase().includes(needle)
  })
}

/**
 * Memory tier saturation bars + compaction sub-FSM.
 *
 * Runtime-truth split:
 * - `/composite` is authoritative for the current KSM/KMC lifecycle state.
 * - `/state-diagram` is still used only for `memory_kind_usage`, because
 *   that payload joins policy caps with live memory-bank counts.
 */
export function KeeperMemoryTierPanel({
  keeperName,
  currentPhase,
}: KeeperMemoryTierPanelProps) {
  const [usage, setUsage] = useState<MemoryKindUsageEntry[] | null>(null)
  const [snapshot, setSnapshot] = useState<KeeperCompositeSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<MemoryTierFilter>('all')

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError(null)

    Promise.allSettled([
      fetchKeeperStateDiagram(keeperName, { signal: controller.signal }),
      fetchKeeperComposite(keeperName, { signal: controller.signal }),
    ])
      .then(([usageResult, compositeResult]) => {
        if (controller.signal.aborted) return
        let nextError: string | null = null

        if (usageResult.status === 'fulfilled') {
          setUsage(usageResult.value.memory_kind_usage ?? [])
        } else {
          setUsage(null)
          nextError = usageResult.reason instanceof Error ? usageResult.reason.message : 'memory tier fetch failed'
        }

        if (compositeResult.status === 'fulfilled') {
          setSnapshot(compositeResult.value)
        } else {
          setSnapshot(null)
          nextError ||= compositeResult.reason instanceof Error
            ? compositeResult.reason.message
            : 'composite fetch failed'
        }

        setError(nextError)
        setLoading(false)
      })
      .catch(err => {
        if (controller.signal.aborted) return
        setError(err instanceof Error ? err.message : 'memory tier fetch failed')
        setLoading(false)
      })

    return () => { controller.abort() }
  }, [keeperName])

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-[11px] text-[var(--text-dim)]">
        <span class="inline-block h-3 w-3 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin" aria-hidden="true"></span>
        메모리 티어 로딩중
      </div>
    `
  }

  if (error || !usage || usage.length === 0) {
    return html`<${EmptyState} message=${error ?? '메모리 티어 데이터 없음'} compact />`
  }

  const totalUsed = usage.reduce((sum, row) => sum + row.used, 0)
  const totalCap = usage.reduce((sum, row) => sum + row.cap, 0)
  const saturatedCount = useMemo(
    () => usage.filter(row => row.cap > 0 && row.used >= row.cap).length,
    [usage],
  )
  const visible = useMemo(
    () => filterMemoryKindUsage(usage, query, filter),
    [usage, query, filter],
  )
  const phase = snapshot?.phase ?? currentPhase ?? null
  const isCompacting = phase === 'Compacting' || phase === 'compacting'
  const compactionStage = snapshot?.compaction.stage ?? (isCompacting ? 'compacting' : 'accumulating')
  const compactionSpec = buildCompactionSpec(compactionStage, phase)

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center gap-2 text-[10px] text-[var(--text-dim)]">
        <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
          total ${totalUsed} / ${totalCap}
        </span>
        <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
          ${usage.length} kinds
        </span>
        <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">
          KMC ${compactionStage}
        </span>
        ${isCompacting ? html`
          <span class="inline-flex items-center rounded-full border border-[rgba(251,191,36,0.3)] bg-[rgba(251,191,36,0.1)] px-2 py-0.5 text-[#f59e0b]">
            compacting
          </span>
        ` : null}
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <input
          type="search"
          value=${query}
          placeholder="kind 필터"
          aria-label="memory kind 필터"
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          class="min-w-[120px] flex-1 rounded-md border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
        />
        <${FilterChips}
          chips=${[
            { key: 'all', label: 'all', count: usage.length },
            { key: 'saturated', label: 'saturated', count: saturatedCount },
          ] as const}
          value=${filter}
          onChange=${(key: MemoryTierFilter) => setFilter(key)}
        />
      </div>

      ${visible.length === 0 ? html`
        <div class="py-4 text-center text-[11px] text-[var(--text-dim)]">
          필터 결과 없음
        </div>
      ` : null}

      <div class="flex flex-col gap-1.5">
        ${visible.map(row => {
          const pct = row.cap > 0 ? Math.min(100, Math.round((row.used / row.cap) * 100)) : 0
          const saturated = row.used >= row.cap
          const barColor = saturated
            ? 'bg-[rgba(251,191,36,0.7)]'
            : pct >= 75
              ? 'bg-[rgba(34,197,94,0.7)]'
              : 'bg-[rgba(99,102,241,0.6)]'
          return html`
            <div class="flex items-center gap-2 text-[11px]">
              <div class="w-24 truncate text-[var(--text-body)] font-mono" title=${row.kind}>
                ${row.kind}
              </div>
              <div class="relative flex-1 h-4 rounded-full bg-[var(--white-4)] border border-[var(--white-8)] overflow-hidden">
                <div class=${`absolute inset-y-0 left-0 ${barColor}`} style=${`width: ${pct}%`}></div>
              </div>
              <div class="w-16 text-right text-[var(--text-muted)] tabular-nums">
                ${row.used}/${row.cap}
              </div>
              <div class="w-10 text-right text-[10px] text-[var(--text-dim)] tabular-nums">
                p${row.priority}
              </div>
            </div>
          `
        })}
      </div>

      <div class="mt-2">
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">
          Compaction sub-FSM (KeeperCompactionLifecycle.tla)
        </div>
        <${CytoscapeFsm} spec=${compactionSpec} height="200px" />
      </div>
    </div>
  `
}
