// MASC Dashboard — Attention Spotlight
// Top 3 anomalies (blockers + attention). Vanishes when clean.

import { html } from 'htm/preact'
import { relativeTime, trimText } from '../mission-utils'
import type {
  DashboardMissionResponse,
  DashboardMissionSessionBrief,
  DashboardMissionSessionCard,
} from '../../types'

interface SpotlightItem {
  id: string
  severity: string
  summary: string
  relatedNames: string[]
  lastSeen: string | null
}

type SessionItem = DashboardMissionSessionBrief | DashboardMissionSessionCard

function gatherSpotlightItems(snap: DashboardMissionResponse): SpotlightItem[] {
  const items: SpotlightItem[] = []

  for (const aq of snap.attention_queue ?? []) {
    items.push({
      id: aq.id,
      severity: aq.severity,
      summary: aq.summary,
      relatedNames: [...(aq.related_agent_names ?? [])],
      lastSeen: aq.last_seen_at ?? null,
    })
  }

  const sessions: SessionItem[] = snap.sessions ?? []
  const aqIds = new Set(items.map(i => i.id))

  for (const s of sessions) {
    if (s.blocker_summary && !aqIds.has(`blocker-${s.session_id}`)) {
      items.push({
        id: `blocker-${s.session_id}`,
        severity: 'bad',
        summary: s.blocker_summary,
        relatedNames: s.member_names.slice(0, 3),
        lastSeen: s.last_event_at ?? null,
      })
    }
  }

  const severityOrder: Record<string, number> = { bad: 0, critical: 0, warn: 1, watch: 1, ok: 2, unknown: 2, info: 2 }
  items.sort((a, b) => {
    const sa = severityOrder[a.severity] ?? 2
    const sb = severityOrder[b.severity] ?? 2
    return sa - sb
  })

  return items.slice(0, 3)
}

function severityDotColor(severity: string): string {
  if (severity === 'bad' || severity === 'critical') return 'bg-[var(--bad)]'
  if (severity === 'warn' || severity === 'watch') return 'bg-[var(--warn)]'
  return 'bg-[var(--text-muted)]'
}

function severityBarColor(severity: string): string {
  if (severity === 'bad' || severity === 'critical') return 'bg-[var(--bad)]'
  if (severity === 'warn' || severity === 'watch') return 'bg-[var(--warn)]'
  return 'bg-[var(--white-10)]'
}

interface AttentionSpotlightProps {
  snap: DashboardMissionResponse | null
}

export function AttentionSpotlight({ snap }: AttentionSpotlightProps) {
  if (!snap) return null

  const items = gatherSpotlightItems(snap)
  if (items.length === 0) return null

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <span class="w-2 h-2 rounded-full bg-[var(--warn)] shrink-0"></span>
        <span class="text-xs font-semibold text-[var(--text-strong)] uppercase tracking-wider">주의 항목</span>
        <span class="text-xs text-[var(--text-muted)]">${items.length}건</span>
      </div>
      <div class="flex flex-col gap-2">
        ${items.map(item => html`
          <div class="flex rounded border border-[var(--card-border)] bg-[var(--card)] overflow-hidden" key=${item.id}>
            <div class="w-1 shrink-0 ${severityBarColor(item.severity)}" />
            <div class="flex flex-col gap-1.5 p-4 min-w-0 flex-1">
              <div class="flex items-start gap-2">
                <span class="w-2 h-2 rounded-full shrink-0 mt-1.5 ${severityDotColor(item.severity)}"></span>
                <span class="text-sm font-medium text-[var(--text-strong)] leading-snug">
                  ${trimText(item.summary, 100)}
                </span>
              </div>
              <div class="flex gap-2 flex-wrap items-center pl-4">
                ${item.relatedNames.map(name => html`
                  <span class="text-[10px] px-1.5 py-px rounded bg-[var(--white-6)] text-[var(--text-muted)] font-medium" key=${name}>${name}</span>
                `)}
                ${item.lastSeen ? html`
                  <span class="text-[10px] text-[var(--text-muted)]">${relativeTime(item.lastSeen)}</span>
                ` : null}
              </div>
            </div>
          </div>
        `)}
      </div>
    </div>
  `
}
