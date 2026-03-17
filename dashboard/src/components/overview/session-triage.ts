// MASC Dashboard — Session Triage (Phase 4)
// Replaces flat SessionStrip with a 3-tier hierarchical display:
//   Tier 1 (Critical): sessions with blockers or bad attention
//   Tier 2 (Watch):    sessions with attention items or degraded health
//   Tier 3 (Running):  healthy sessions, collapsed by default

import { html } from 'htm/preact'
import { navigate } from '../../router'
import { trimText, formatDuration } from '../mission-utils'
import type {
  DashboardMissionSessionBrief,
  DashboardMissionSessionCard,
} from '../../types'

type SessionItem = DashboardMissionSessionBrief | DashboardMissionSessionCard

interface SessionTriageProps {
  sessions: SessionItem[]
}

interface TriageResult {
  critical: SessionItem[]
  watch: SessionItem[]
  running: SessionItem[]
}

function handleKeyActivate(fn: () => void) {
  return (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      fn()
    }
  }
}

function triageSessions(sessions: SessionItem[]): TriageResult {
  const critical: SessionItem[] = []
  const watch: SessionItem[] = []
  const running: SessionItem[] = []

  for (const s of sessions) {
    const isCritical =
      s.blocker_summary ||
      (s.top_attention && (s.top_attention.severity === 'bad' || s.top_attention.severity === 'critical'))

    const isWatch =
      !isCritical && (
        s.related_attention_count > 0 ||
        s.health === 'warn' ||
        s.health === 'degraded' ||
        s.health === 'yellow'
      )

    if (isCritical) critical.push(s)
    else if (isWatch) watch.push(s)
    else running.push(s)
  }

  return { critical, watch, running }
}

function CriticalCard({ session }: { session: SessionItem }) {
  const go = () => navigate('mission', { session_id: session.session_id })
  return html`
    <div
      class="triage-card triage-card--critical"
      role="button"
      tabindex="0"
      onClick=${go}
      onKeyDown=${handleKeyActivate(go)}
    >
      <div class="triage-card__header">
        <strong class="triage-card__goal">${session.goal ?? session.session_id}</strong>
      </div>
      ${session.blocker_summary ? html`
        <div class="triage-card__blocker">
          ${trimText(session.blocker_summary, 120)}
        </div>
      ` : null}
      <div class="triage-card__meta">
        ${session.member_names?.length ? html`
          <span class="triage-card__members">
            ${session.member_names.slice(0, 4).join(', ')}
            ${session.member_names.length > 4 ? ` +${session.member_names.length - 4}` : ''}
          </span>
        ` : null}
        ${session.elapsed_sec ? html`
          <span>${formatDuration(session.elapsed_sec)}</span>
        ` : null}
      </div>
    </div>
  `
}

function WatchCard({ session }: { session: SessionItem }) {
  const go = () => navigate('mission', { session_id: session.session_id })
  return html`
    <div
      class="triage-card triage-card--watch"
      role="button"
      tabindex="0"
      onClick=${go}
      onKeyDown=${handleKeyActivate(go)}
    >
      <strong class="triage-card__goal">${session.goal ?? session.session_id}</strong>
      <div class="triage-card__meta">
        ${session.related_attention_count > 0 ? html`
          <span>주의 ${session.related_attention_count}건</span>
        ` : null}
        ${session.elapsed_sec ? html`
          <span>${formatDuration(session.elapsed_sec)}</span>
        ` : null}
        ${session.member_names?.length ? html`
          <span>${session.member_names.length}명</span>
        ` : null}
      </div>
    </div>
  `
}

function RunningRow({ session }: { session: SessionItem }) {
  const go = () => navigate('mission', { session_id: session.session_id })
  return html`
    <div
      class="triage-row"
      role="button"
      tabindex="0"
      onClick=${go}
      onKeyDown=${handleKeyActivate(go)}
    >
      <span class="triage-row__goal">${trimText(session.goal, 60) ?? session.session_id}</span>
      <span class="triage-row__meta">
        ${session.elapsed_sec ? formatDuration(session.elapsed_sec) : ''}
        ${session.member_names?.length ? ` / ${session.member_names.length}명` : ''}
      </span>
    </div>
  `
}

export function SessionTriage({ sessions }: SessionTriageProps) {
  if (sessions.length === 0) {
    return html`<div class="session-triage" style="color: var(--text-muted)">활성 세션 없음</div>`
  }

  const { critical, watch, running } = triageSessions(sessions)

  return html`
    <div class="session-triage">
      ${critical.length > 0 ? html`
        <div class="triage-tier triage-tier--critical">
          ${critical.map(s => html`<${CriticalCard} session=${s} key=${s.session_id} />`)}
        </div>
      ` : null}

      ${watch.length > 0 ? html`
        <div class="triage-tier triage-tier--watch">
          ${watch.map(s => html`<${WatchCard} session=${s} key=${s.session_id} />`)}
        </div>
      ` : null}

      ${running.length > 0 ? html`
        <details class="triage-tier triage-tier--running">
          <summary class="triage-running-label">순조로운 세션 ${running.length}개</summary>
          <div class="triage-running-list">
            ${running.map(s => html`<${RunningRow} session=${s} key=${s.session_id} />`)}
          </div>
        </details>
      ` : null}
    </div>
  `
}
