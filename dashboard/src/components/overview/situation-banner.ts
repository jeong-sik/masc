// MASC Dashboard — Situation Banner
// Synthesizes situation summary with reasons from mission snapshot data.

import { html } from 'htm/preact'
import { HealthBeacon } from './health-beacon'
import { missionError, missionLoading } from '../../mission-store'
import type {
  DashboardMissionResponse,
  DashboardMissionSessionBrief,
  DashboardMissionSessionCard,
} from '../../types'

type SituationTone = 'ok' | 'warn' | 'bad'

interface SituationReason {
  category: 'blocker' | 'attention' | 'incident'
  text: string
  severity: SituationTone
}

interface SituationResult {
  text: string
  tone: SituationTone
  reasons: SituationReason[]
}

type SessionItem = DashboardMissionSessionBrief | DashboardMissionSessionCard

function synthesizeSituation(snap: DashboardMissionResponse | null): SituationResult {
  if (!snap) {
    const error = missionError.value
    if (error) return { text: `데이터 로드 실패: ${error}`, tone: 'warn', reasons: [] }
    if (missionLoading.value) return { text: '데이터 로딩 중...', tone: 'ok', reasons: [] }
    return { text: '데이터 대기 중...', tone: 'ok', reasons: [] }
  }

  const sessions: SessionItem[] =
    snap.sessions.length > 0 ? snap.sessions : snap.session_briefs
  const total = sessions.length
  const blocked = sessions.filter(s => s.blocker_summary).length
  const attentionItems = snap.attention_queue ?? []
  const attention = attentionItems.length
  const hasAnyAgents = (snap.agent_briefs?.length ?? 0) > 0
  const hasAnyKeepers = (snap.keeper_briefs?.length ?? 0) > 0

  // Honest empty state: no sessions AND no agents/keepers means the room is idle
  if (total === 0 && !hasAnyAgents && !hasAnyKeepers) {
    return { text: '유휴 상태. 세션, 에이전트, 키퍼 모두 비활성.', tone: 'ok', reasons: [] }
  }

  const reasons: SituationReason[] = []

  // Collect blocker reasons (top 3 — full count shown in summary text)
  let blockerCount = 0
  for (const s of sessions) {
    if (s.blocker_summary) {
      blockerCount++
      if (blockerCount <= 3) {
        reasons.push({
          category: 'blocker',
          text: `${s.goal ?? s.session_id}: ${s.blocker_summary.slice(0, 80)}`,
          severity: 'bad',
        })
      }
    }
  }

  // Collect attention reasons
  for (const item of attentionItems.slice(0, 5)) {
    reasons.push({
      category: 'attention',
      text: item.summary ?? item.kind ?? '주의 항목',
      severity: item.severity === 'critical' || item.severity === 'bad' ? 'bad' : 'warn',
    })
  }

  // Collect incident reasons
  const incidents = snap.incidents ?? []
  for (const inc of incidents.slice(0, 3)) {
    reasons.push({
      category: 'incident',
      text: inc.summary ?? '인시던트',
      severity: inc.severity === 'critical' ? 'bad' : 'warn',
    })
  }

  if (total === 0) return { text: '진행 중인 세션 없음.', tone: 'ok', reasons }

  if (blocked === 0 && attention === 0) {
    return { text: `${total}개 세션 순조롭게 진행 중.`, tone: 'ok', reasons }
  }

  if (blocked > 0) {
    const suffix = attention > 0 ? ` ${attention}건 주의 필요.` : ''
    const tone: SituationTone = blocked > total / 2 ? 'bad' : 'warn'
    return { text: `${total}개 세션 중 ${blocked}개 막힘.${suffix}`, tone, reasons }
  }

  return { text: `${total}개 세션 진행 중. ${attention}건 주의 항목.`, tone: 'warn', reasons }
}

const CATEGORY_LABELS: Record<string, string> = {
  blocker: '막힘',
  attention: '주의',
  incident: '인시던트',
}

interface SituationBannerProps {
  snap: DashboardMissionResponse | null
  roomHealth?: string | null
}

export function SituationBanner({ snap, roomHealth }: SituationBannerProps) {
  const { text, tone, reasons } = synthesizeSituation(snap)
  const showReasons = tone !== 'ok' && reasons.length > 0

  return html`
    <div class="situation-banner situation-banner--${tone}">
      <${HealthBeacon} health=${roomHealth ?? tone} />
      <span class="situation-banner__text">${text}</span>
    </div>
    ${showReasons ? html`
      <details class="situation-reasons-collapse" open=${reasons.length <= 5}>
        <summary class="situation-reasons-collapse__summary">
          상세 ${reasons.length}건
        </summary>
        <div class="situation-reasons">
          ${reasons.map((r, i) => html`
            <div class="situation-reason situation-reason--${r.severity}" key=${i}>
              <span class="situation-reason__tag">${CATEGORY_LABELS[r.category] ?? r.category}</span>
              <span class="situation-reason__text">${r.text}</span>
            </div>
          `)}
        </div>
      </details>
    ` : null}
  `
}
