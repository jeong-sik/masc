/**
 * KeeperLifecycleTimeline — operator panel showing keeper lifecycle events.
 *
 * Surfaces the /api/v1/keepers/{name}/lifecycle ring buffer so operators
 * can see when a keeper was Started, Restarted (via liveness recovery or
 * normal restart), Paused, Auto-resumed, Dead-cleaned, etc. with timestamps
 * and detail strings.
 *
 * #12798: Dashboard Gaps — gives operators observability into Dead → Recovery
 * transitions that were previously only visible in server logs.
 */

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchKeeperLifecycle,
  type KeeperLifecycleEvent,
  type KeeperLifecycleTimelineResponse,
} from '../api/keeper'
import { TimeAgo } from './common/time-ago'
import { PanelCard } from './common/panel-card'
import { SectionHeader } from './common/section-header'
import { StatusChip } from './common/status-chip'

// ── Tone mapping ───────────────────────────────────────────────────────

type EventTone = 'ok' | 'warn' | 'err' | 'info' | 'neutral'

function toneForEvent(event: string): EventTone {
  switch (event) {
    case 'started':
    case 'reconciled':
    case 'auto_resumed':
      return 'ok'
    case 'restarted':
      return 'info'
    case 'crashed':
    case 'dead':
      return 'err'
    case 'dead_cleaned':
    case 'paused_pruned':
      return 'warn'
    case 'self_preservation':
      return 'warn'
    case 'stopped':
      return 'neutral'
    default:
      return 'neutral'
  }
}

function isLivenessRecovery(ev: KeeperLifecycleEvent): boolean {
  return ev.event === 'restarted' && ev.detail.includes('liveness recovery')
}

// ── Subcomponents ─────────────────────────────────────────────────────

function EventRow({ ev }: { ev: KeeperLifecycleEvent }) {
  const tone = toneForEvent(ev.event)
  const liveness = isLivenessRecovery(ev)

  const livenessBadge = liveness
    ? html`<${StatusChip} tone="accent" uppercase=${false} class="text-xs">liveness recovery</${StatusChip}>`
    : null

  return html`
    <div class="flex gap-3 items-start py-2 border-b border-[var(--color-border-subtle)] last:border-0">
      <${StatusChip} tone=${tone === 'neutral' ? 'muted' : tone} uppercase=${false}>
        ${ev.event}
      </${StatusChip}>
      ${livenessBadge}
      <div class="flex-1 min-w-0">
        <div class="t-body text-[var(--color-fg-default)] truncate">
          ${ev.detail || html`<span class="t-dim">—</span>`}
        </div>
        ${ev.phase ? html`<div class="t-caption t-dim">phase: ${ev.phase}</div>` : null}
      </div>
      <div class="t-caption t-dim whitespace-nowrap">
        <${TimeAgo} ts=${ev.ts} />
      </div>
    </div>
  `
}

// ── Main panel ────────────────────────────────────────────────────────

export function KeeperLifecycleTimelinePanel({ keeperName }: { keeperName: string }) {
  const [data, setData] = useState<KeeperLifecycleTimelineResponse | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    if (!keeperName) return
    const ctrl = new AbortController()
    setLoading(true)
    setError(null)

    fetchKeeperLifecycle(keeperName, 50, { signal: ctrl.signal })
      .then(resp => {
        setData(resp)
        setLoading(false)
      })
      .catch(err => {
        if (err?.name === 'AbortError') return
        setError(err instanceof Error ? err.message : String(err))
        setLoading(false)
      })

    return () => ctrl.abort()
  }, [keeperName])

  const events = data?.events ?? []
  const livenessCount = events.filter(isLivenessRecovery).length

  return html`
    <${PanelCard}>
      <${SectionHeader}>Lifecycle Timeline</${SectionHeader}>
      ${loading ? html`<div class="t-dim t-caption px-1 py-2">Loading…</div>` : null}
      ${error ? html`<div class="t-err t-caption px-1 py-2">Error: ${error}</div>` : null}
      ${!loading && !error && events.length === 0
        ? html`<div class="t-dim t-caption px-1 py-2">No lifecycle events recorded yet.</div>`
        : null}
      ${livenessCount > 0
        ? html`
          <div class="t-caption t-warn px-1 py-1 mb-2">
            ${livenessCount} liveness recovery attempt${livenessCount !== 1 ? 's' : ''} visible
          </div>`
        : null}
      <div>
        ${events.map((ev: KeeperLifecycleEvent) => html`<${EventRow} ev=${ev} />`)}
      </div>
    </${PanelCard}>
  `
}

// ── Pure helpers (exported for tests) ─────────────────────────────────

export { isLivenessRecovery, toneForEvent }
export type { EventTone }
