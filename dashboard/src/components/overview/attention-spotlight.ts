// MASC Dashboard — Attention Spotlight (Phase 1B)
// Highlights top 3 anomalies (blockers + attention queue items).
// Renders only when there are items that need attention; vanishes when clean.

import { html } from 'htm/preact'
import { toneClass, relativeTime, trimText } from '../mission-utils'
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

  // 1. Attention queue items
  for (const aq of snap.attention_queue) {
    items.push({
      id: aq.id,
      severity: aq.severity,
      summary: aq.summary,
      relatedNames: [...aq.related_agent_names],
      lastSeen: aq.last_seen_at ?? null,
    })
  }

  // 2. Sessions with blockers (that aren't already captured in attention queue)
  const sessions: SessionItem[] =
    (snap.sessions ?? []).length > 0 ? snap.sessions : (snap.session_briefs ?? [])
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

  // Sort by severity (bad > warn > ok) then by recency
  const severityOrder: Record<string, number> = { bad: 0, critical: 0, warn: 1, watch: 1, ok: 2 }
  items.sort((a, b) => {
    const sa = severityOrder[a.severity] ?? 1
    const sb = severityOrder[b.severity] ?? 1
    return sa - sb
  })

  return items.slice(0, 3)
}

interface AttentionSpotlightProps {
  snap: DashboardMissionResponse | null
}

export function AttentionSpotlight({ snap }: AttentionSpotlightProps) {
  if (!snap) return null

  const items = gatherSpotlightItems(snap)
  if (items.length === 0) return null

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-start justify-between mb-1 gap-3">
        <div>
          <span class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">주의 항목</span>
          <div class="mt-1 text-[13px] text-[var(--text-muted)] leading-[1.45]">지금 바로 확인할 blocker와 attention 신호만 상단에 압축합니다.</div>
        </div>
      </div>
      ${items.map(item => html`
        <div class="attention-spotlight__card ${toneClass(item.severity)} rounded-xl border border-[var(--card-border)] bg-[var(--card)] flex overflow-hidden" key=${item.id}>
          <div class="w-1 shrink-0 attention-spotlight__bar" />
          <div class="grid gap-1.5 p-4 min-w-0">
            <span class="text-sm font-medium text-[var(--text-strong)] leading-[1.4]">
              ${trimText(item.summary, 100)}
            </span>
            <div class="flex gap-1.5 flex-wrap items-center">
              ${item.relatedNames.map(name => html`
                <span class="status-badge" key=${name}>${name}</span>
              `)}
              ${item.lastSeen ? html`
                <span class="text-xs text-[var(--text-muted)]">${relativeTime(item.lastSeen)}</span>
              ` : null}
            </div>
          </div>
        </div>
      `)}
    </div>
  `
}
