import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchExactLaneRuns,
  fetchFusionRuns,
  fetchVerificationRuns,
  type ExactLaneRunRecord,
  type FusionRunRecord,
  type VerificationRunRecord,
} from '../api/dashboard'
import { registerInternalAgentRefresh } from '../sse-store'
import { Btn } from './btn'
import { EmptyState, ErrorState } from './common/feedback-state'
import { StatusBadge, type StatusBadgeTone } from './common/status-badge'
import { relativeTime } from '../lib/format-time'

type Filter = 'all' | 'librarian' | 'judge' | 'verification' | 'fusion'
type Row =
  | { source: 'exact'; id: string; run: ExactLaneRunRecord }
  | { source: 'verification'; id: string; run: VerificationRunRecord }
  | { source: 'fusion'; id: string; run: FusionRunRecord }

const FILTERS: Array<{ id: Filter; label: string }> = [
  { id: 'all', label: 'All' },
  { id: 'librarian', label: 'Librarian' },
  { id: 'judge', label: 'Judge' },
  { id: 'verification', label: 'Verification' },
  { id: 'fusion', label: 'Fusion' },
]

function laneLabel(row: Row): string {
  if (row.source === 'verification') return 'Verification'
  if (row.source === 'fusion') return 'Fusion'
  switch (row.run.lane) {
    case 'librarian_exact': return 'Librarian'
    case 'hitl_auto_judge': return 'Auto Judge'
    case 'board_attention_exact': return 'Board Judge'
    case 'compaction_exact': return 'Compaction'
  }
}

function status(row: Row): string {
  return row.run.status
}

function tone(row: Row): StatusBadgeTone {
  const value = status(row)
  if (value === 'succeeded' || value === 'completed' || value === 'approved') return 'ok'
  if (value === 'running') return 'warn'
  if (value === 'rejected') return 'info'
  return 'bad'
}

function actor(row: Row): string {
  if (row.source === 'verification') return row.run.evaluatorRuntime ?? row.run.authorityActor
  if (row.source === 'fusion') return row.run.keeper
  return row.run.actor
}

function subject(row: Row): string {
  if (row.source === 'verification') return row.run.taskId
  if (row.source === 'fusion') return row.run.runId
  return row.run.subjectId
}

function startedAt(row: Row): number {
  return row.run.startedAt
}

function elapsed(row: Row): number | undefined {
  return row.source === 'fusion' ? undefined : row.run.elapsedSeconds
}

function formatElapsed(value: number | undefined): string {
  if (value == null) return '—'
  return value < 1 ? `${Math.round(value * 1000)}ms` : `${value.toFixed(1)}s`
}

function pretty(value: unknown): string {
  return JSON.stringify(value, null, 2) ?? 'null'
}

function Details({ row }: { row: Row }) {
  if (row.source === 'verification') {
    const tools = row.run.tools ?? []
    return html`
      <div class="grid gap-3 p-3 bg-[var(--color-bg-surface)] border-t border-[var(--color-border-default)]">
        <div>
          <div class="text-3xs uppercase tracking-wide text-[var(--color-fg-muted)] mb-1">Evidence path</div>
          <code class="text-xs">producer ${row.run.producer} → ${row.run.authorityKind} → ${row.run.status}</code>
        </div>
        <div>
          <div class="text-3xs uppercase tracking-wide text-[var(--color-fg-muted)] mb-1">Tools (${tools.length})</div>
          ${tools.length === 0
            ? html`<p class="text-xs text-[var(--color-fg-muted)]">No tools invoked in this verification run.</p>`
            : html`<ol class="grid gap-2">
                ${tools.map((tool, index) => html`
                  <li key=${`${row.id}-${index}`} class="rounded border border-[var(--color-border-default)] p-2">
                    <div class="flex flex-wrap items-center gap-2 text-xs">
                      <strong>${index + 1}. ${tool.toolName}</strong>
                      <code>${tool.disposition}</code>
                      <span class="text-[var(--color-fg-muted)]">${tool.durationMs.toFixed(0)}ms</span>
                    </div>
                    <div class="grid gap-2 mt-2 md:grid-cols-2">
                      <pre class="overflow-auto text-3xs whitespace-pre-wrap">${pretty(tool.input)}</pre>
                      <pre class="overflow-auto text-3xs whitespace-pre-wrap">${tool.outputExcerpt}${tool.outputTruncated ? '\n… truncated' : ''}</pre>
                    </div>
                  </li>
                `)}
              </ol>`}
        </div>
      </div>
    `
  }
  if (row.source === 'exact') {
    return html`
      <div class="grid gap-3 p-3 bg-[var(--color-bg-surface)] border-t border-[var(--color-border-default)] md:grid-cols-2">
        <div>
          <div class="text-3xs uppercase tracking-wide text-[var(--color-fg-muted)] mb-1">Input evidence</div>
          <pre class="overflow-auto text-3xs whitespace-pre-wrap">${pretty(row.run.input)}</pre>
        </div>
        <div>
          <div class="text-3xs uppercase tracking-wide text-[var(--color-fg-muted)] mb-1">Result</div>
          <pre class="overflow-auto text-3xs whitespace-pre-wrap">${pretty(row.run.output ?? { code: row.run.code, detail: row.run.detail })}</pre>
        </div>
        <p class="text-xs text-[var(--color-fg-muted)] md:col-span-2">Tools: none. This exact-output lane performs one structured model execution, not MASC tool dispatch.</p>
      </div>
    `
  }
  return html`
    <div class="p-3 bg-[var(--color-bg-surface)] border-t border-[var(--color-border-default)] text-xs">
      <p>Preset <code>${row.run.preset}</code> · status <code>${row.run.status}</code></p>
      ${row.run.error ? html`<p class="mt-1 text-[var(--color-danger)]">${row.run.failureCode}: ${row.run.error}</p>` : null}
      <p class="mt-2 text-[var(--color-fg-muted)]">Fusion participant and judge detail remains on the Fusion surface; this row uses the same run registry.</p>
    </div>
  `
}

function matches(row: Row, filter: Filter): boolean {
  if (filter === 'all') return true
  if (filter === 'verification') return row.source === 'verification'
  if (filter === 'fusion') return row.source === 'fusion'
  if (filter === 'librarian') return row.source === 'exact' && row.run.lane === 'librarian_exact'
  return row.source === 'exact'
    && (row.run.lane === 'hitl_auto_judge' || row.run.lane === 'board_attention_exact')
}

export function InternalAgentsMonitor() {
  const [rows, setRows] = useState<Row[]>([])
  const [filter, setFilter] = useState<Filter>('all')
  const [expanded, setExpanded] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [errors, setErrors] = useState<string[]>([])
  const refreshVersion = useRef(0)

  const refresh = useCallback(async () => {
    const version = ++refreshVersion.current
    setLoading(true)
    const [exact, verification, fusion] = await Promise.allSettled([
      fetchExactLaneRuns(),
      fetchVerificationRuns(),
      fetchFusionRuns(),
    ])
    const next: Row[] = []
    const failures: string[] = []
    if (exact.status === 'fulfilled') {
      next.push(...exact.value.runs.map(run => ({ source: 'exact' as const, id: `exact:${run.runId}`, run })))
    } else failures.push(`Exact lanes: ${String(exact.reason)}`)
    if (verification.status === 'fulfilled') {
      next.push(...verification.value.runs.map(run => ({ source: 'verification' as const, id: `verification:${run.verificationId}`, run })))
    } else failures.push(`Verification: ${String(verification.reason)}`)
    if (fusion.status === 'fulfilled') {
      next.push(...fusion.value.runs.map(run => ({ source: 'fusion' as const, id: `fusion:${run.runId}`, run })))
    } else failures.push(`Fusion: ${String(fusion.reason)}`)
    if (version !== refreshVersion.current) return
    next.sort((a, b) => startedAt(b) - startedAt(a))
    setRows(next)
    setErrors(failures)
    setLoading(false)
  }, [])

  useEffect(() => {
    void refresh()
    const unregister = registerInternalAgentRefresh(() => { void refresh() })
    return () => {
      unregister()
      refreshVersion.current += 1
    }
  }, [refresh])

  const visible = useMemo(() => rows.filter(row => matches(row, filter)), [rows, filter])

  return html`
    <section class="v2-monitoring-surface grid gap-3" data-testid="internal-agents-monitor">
      <div class="flex flex-wrap items-center gap-2">
        <h2 class="text-sm font-semibold text-[var(--color-fg-primary)]">Internal Agent Runs</h2>
        <span class="text-xs text-[var(--color-fg-muted)]">${rows.length} observed</span>
        <${Btn} class="v2-monitoring-action ml-auto" onClick=${() => void refresh()} disabled=${loading}>
          ${loading ? 'Loading…' : 'Refresh'}
        <//>
      </div>
      <p class="text-xs text-[var(--color-fg-muted)]">Typed run records from Librarian, Judge, Verification, Compaction, and Fusion. Updates arrive through WebSocket invalidation; HTTP snapshots remain the source of truth.</p>
      <div class="flex flex-wrap gap-1" role="group" aria-label="Internal agent filters">
        ${FILTERS.map(item => html`
          <button
            key=${item.id}
            type="button"
            class=${`rounded px-2 py-1 text-xs border ${filter === item.id ? 'border-[var(--color-accent)] text-[var(--color-fg-primary)]' : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'}`}
            aria-pressed=${filter === item.id}
            onClick=${() => setFilter(item.id)}
          >${item.label}</button>
        `)}
      </div>
      ${errors.length > 0 ? html`<${ErrorState}>${errors.join(' · ')}<//>` : null}
      ${!loading && visible.length === 0
        ? html`<${EmptyState}>No internal agent runs for this filter.<//>`
        : html`<div class="grid gap-2">
            ${visible.map(row => {
              const open = expanded === row.id
              return html`
                <article key=${row.id} class="v2-monitoring-card rounded border border-[var(--color-border-default)] overflow-hidden">
                  <button
                    type="button"
                    class="w-full grid grid-cols-[auto_1fr_auto] gap-3 items-center p-3 text-left"
                    aria-expanded=${open}
                    onClick=${() => setExpanded(open ? null : row.id)}
                  >
                    <${StatusBadge} tone=${tone(row)} label=${status(row)} />
                    <span class="min-w-0">
                      <strong class="block text-xs text-[var(--color-fg-primary)]">${laneLabel(row)}</strong>
                      <code class="block truncate text-3xs text-[var(--color-fg-muted)]" title=${subject(row)}>${subject(row)}</code>
                    </span>
                    <span class="text-right text-3xs text-[var(--color-fg-muted)]">
                      <span class="block">${actor(row)}</span>
                      <span class="block">${formatElapsed(elapsed(row))} · ${relativeTime(new Date(startedAt(row) * 1000).toISOString())}</span>
                    </span>
                  </button>
                  ${open ? html`<${Details} row=${row} />` : null}
                </article>
              `
            })}
          </div>`}
    </section>
  `
}
