// MASC Dashboard — Session Strip (horizontal scrolling active sessions)

import { html } from 'htm/preact'
import { navigate } from '../../router'
import type {
  DashboardMissionSessionBrief,
  DashboardMissionSessionCard,
} from '../../types'
import { formatElapsedCompact } from '../../lib/format-time'

type SessionItem = DashboardMissionSessionBrief | DashboardMissionSessionCard

interface SessionStripProps {
  sessions: SessionItem[]
}

function sessionHealthClass(session: SessionItem): string {
  const h = session.health?.toLowerCase()
  if (h === 'ok' || h === 'healthy' || h === 'green') return 'ok'
  if (h === 'warn' || h === 'degraded' || h === 'yellow') return 'warn'
  if (h === 'bad' || h === 'critical' || h === 'red') return 'bad'
  return ''
}

export function SessionStrip({ sessions }: SessionStripProps) {
  if (sessions.length === 0) {
    return html`
      <div class="session-strip">
        <div class="session-card-mini" style="opacity: 0.5; cursor: default;">
          <span class="session-card-mini__goal">활성 세션 없음</span>
        </div>
      </div>
    `
  }

  return html`
    <div class="session-strip">
      ${sessions.map(session => html`
        <div
          class="session-card-mini ${sessionHealthClass(session)}"
          key=${session.session_id}
          onClick=${() => navigate('mission', { session_id: session.session_id })}
        >
          <span class="session-card-mini__goal">${session.goal ?? session.session_id}</span>
          <div class="session-card-mini__meta">
            ${session.status ? html`<span>${session.status}</span>` : null}
            ${session.member_names?.length ? html`<span>${session.member_names.length}명</span>` : null}
            ${session.elapsed_sec ? html`<span>${formatElapsedCompact(session.elapsed_sec)}</span>` : null}
          </div>
        </div>
      `)}
    </div>
  `
}
