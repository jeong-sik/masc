// MASC Dashboard — Situation Banner (Phase 1A)
// Synthesizes a one-line situation summary from mission snapshot data.
// Replaces raw number display with a human-readable sentence.

import { html } from 'htm/preact'
import { HealthBeacon } from './health-beacon'
import type {
  DashboardMissionResponse,
  DashboardMissionSessionBrief,
  DashboardMissionSessionCard,
} from '../../types'

type SituationTone = 'ok' | 'warn' | 'bad'

interface SituationResult {
  text: string
  tone: SituationTone
}

type SessionItem = DashboardMissionSessionBrief | DashboardMissionSessionCard

function synthesizeSituation(snap: DashboardMissionResponse | null): SituationResult {
  if (!snap) return { text: '데이터 로딩 중...', tone: 'ok' }

  const sessions: SessionItem[] =
    snap.sessions.length > 0 ? snap.sessions : snap.session_briefs
  const total = sessions.length
  const blocked = sessions.filter(s => s.blocker_summary).length
  const attention = snap.attention_queue.length

  if (total === 0) return { text: '진행 중인 세션 없음.', tone: 'ok' }

  if (blocked === 0 && attention === 0) {
    return { text: `${total}개 세션 순조롭게 진행 중.`, tone: 'ok' }
  }

  if (blocked > 0) {
    const suffix = attention > 0 ? ` ${attention}건 주의 필요.` : ''
    const tone: SituationTone = blocked > total / 2 ? 'bad' : 'warn'
    return { text: `${total}개 세션 중 ${blocked}개 막힘.${suffix}`, tone }
  }

  return { text: `${total}개 세션 진행 중. ${attention}건 주의 항목.`, tone: 'warn' }
}

interface SituationBannerProps {
  snap: DashboardMissionResponse | null
  roomHealth?: string | null
}

export function SituationBanner({ snap, roomHealth }: SituationBannerProps) {
  const { text, tone } = synthesizeSituation(snap)

  return html`
    <div class="situation-banner situation-banner--${tone}">
      <${HealthBeacon} health=${roomHealth ?? tone} />
      <span class="situation-banner__text">${text}</span>
    </div>
  `
}
