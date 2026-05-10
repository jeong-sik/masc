import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  fetchKeeperStateDiagram,
  type KeeperCompositeSnapshot,
  type MemoryKindUsageEntry,
} from '../api/keeper'
import { EmptyState } from './common/empty-state'
import { InlineSpinner } from './common/inline-spinner'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { buildCompactionSpec } from './keeper-fsm-specs'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'

const REFRESH_MS = 30_000

interface KeeperMemoryTierPanelProps {
  keeperName: string
  /** RFC-0046: parent-supplied composite snapshot. When provided,
   *  this panel reads the SSOT from the shared FsmHub fetch instead
   *  of issuing its own /composite call. */
  snapshot?: KeeperCompositeSnapshot | null
}

type MemoryTierFilter = 'all' | 'saturated'

function MemoryTierBadge({
  tone = 'neutral',
  children,
}: {
  tone?: StatusChipTone
  children: ComponentChildren
}) {
  return html`<${StatusChip} tone=${tone} uppercase=${false}>${children}</${StatusChip}>`
}

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
  snapshot: externalSnapshot,
}: KeeperMemoryTierPanelProps) {
  const [usage, setUsage] = useState<MemoryKindUsageEntry[] | null>(null)
  const [internalSnapshot, setInternalSnapshot] = useState<KeeperCompositeSnapshot | null>(null)
  const snapshot = externalSnapshot ?? internalSnapshot
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<MemoryTierFilter>('all')

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError(null)

    const refresh = async () => {
      // RFC-0046 §7 #1: skip composite fetch when parent supplies it.
      // `undefined` = standalone caller (legacy fallback); `null` =
      // parent is still loading, wait rather than dual-fetch.
      const compositePromise: Promise<KeeperCompositeSnapshot | null> = externalSnapshot !== undefined
        ? Promise.resolve(externalSnapshot)
        : fetchKeeperComposite(keeperName, { signal: controller.signal })

      Promise.allSettled([
        fetchKeeperStateDiagram(keeperName, { signal: controller.signal }),
        compositePromise,
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
            setInternalSnapshot(compositeResult.value)
          } else {
            setInternalSnapshot(null)
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
    }

    refresh()
    const cleanup = setupVisibleAutoRefresh(() => refresh(), REFRESH_MS)

    return () => {
      controller.abort()
      cleanup()
    }
  }, [keeperName])

  if (loading) {
    return html`
      <div class="flex items-center justify-center gap-2 py-6 text-2xs text-[var(--color-fg-disabled)]" role="status">
        <${InlineSpinner} />
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
  const phase = snapshot?.phase ?? null
  const isCompacting = phase === 'Compacting' || phase === 'compacting'
  const compactionStage = snapshot?.compaction.stage ?? (isCompacting ? 'compacting' : 'accumulating')
  const compactionSpec = buildCompactionSpec(compactionStage, phase)

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center gap-2 text-3xs text-[var(--color-fg-disabled)]">
        <${MemoryTierBadge}>total ${totalUsed} / ${totalCap}</${MemoryTierBadge}>
        <${MemoryTierBadge}>${usage.length} kinds</${MemoryTierBadge}>
        <${MemoryTierBadge}>KMC ${compactionStage}</${MemoryTierBadge}>
        ${isCompacting ? html`
          <${MemoryTierBadge} tone="warn">compacting</${MemoryTierBadge}>
        ` : null}
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <${TextInput}
          type="search"
          value=${query}
          placeholder="kind 필터"
          ariaLabel="memory kind 필터"
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          class="min-w-30 flex-1 !px-2 !py-1 !text-2xs"
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
        <div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">
          필터 결과 없음
        </div>
      ` : null}

      <div class="flex flex-col gap-1.5">
        ${visible.map(row => {
          const pct = row.cap > 0 ? Math.min(100, Math.round((row.used / row.cap) * 100)) : 0
          const saturated = row.used >= row.cap
          const barColor = saturated
            ? 'bg-[var(--warn-fg)]'
            : pct >= 75
              ? 'bg-[var(--ok-20)]'
              : 'bg-[var(--info-fg)]'
          return html`
            <div class="flex items-center gap-2 text-2xs">
              <div class="w-24 truncate text-[var(--color-fg-primary)] font-mono" title=${row.kind}>
                ${row.kind}
              </div>
              <div class="relative flex-1 h-4 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] overflow-hidden">
                <div class=${`absolute inset-y-0 left-0 ${barColor}`} style=${`width: ${pct}%`}></div>
              </div>
              <div class="w-16 text-right text-[var(--color-fg-muted)] tabular-nums">
                ${row.used}/${row.cap}
              </div>
              <div class="w-10 text-right text-3xs text-[var(--color-fg-disabled)] tabular-nums">
                p${row.priority}
              </div>
            </div>
          `
        })}
      </div>

      <div class="mt-2">
        <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)] mb-2">
          Compaction sub-FSM (KeeperCompactionLifecycle.tla)
        </div>
        <${CytoscapeFsm} spec=${compactionSpec} height="200px" />
      </div>
    </div>
  `
}
