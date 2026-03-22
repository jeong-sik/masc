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
    (snap.sessions ?? []).length > 0 ? snap.sessions : (snap.session_briefs ?? [])
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
    <div class="flex items-center gap-3 py-3.5 px-[18px] bg-[var(--color-ff-panel)] border border-[var(--border-subtle,var(--ff-gold-15))] border-l-[3px] border-l-[var(--ok)] text-[length:var(--fs-md)] font-medium text-[color:var(--text-strong)] leading-[1.4] rounded-md situation-banner--${tone}">
      <${HealthBeacon} health=${roomHealth ?? tone} />
      <span class="flex-1 min-w-0">${text}</span>
      <span class="inline-flex items-center shrink-0">
      </span>
    </div>
    ${showReasons ? html`
      <details class="mb-2" open=${reasons.length <= 5}>
        <summary class="cursor-pointer text-[length:var(--fs-xs)] text-[color:var(--text-muted,var(--text-slate))] py-1 px-[var(--space-md,16px)] tracking-[0.04em] hover:text-[color:var(--text-strong)]">
          상세 ${reasons.length}건
        </summary>
        <div class="flex flex-col gap-1 py-1.5 px-[var(--space-md,16px)] border-l-2 border-l-[var(--color-ff-border)]">
          ${reasons.map((r, i) => html`
            <div class="flex items-center gap-[var(--space-sm,8px)] text-[length:var(--fs-sm)] ${r.severity === 'bad' ? 'text-[rgba(239,68,68,0.9)]' : r.severity === 'warn' ? 'text-[color:var(--ff-gold)]' : 'text-[color:var(--white-55)]'}" key=${i}>
              <span class="text-[9px] py-px px-1.5 rounded-sm bg-[rgba(212,169,75,0.08)] border border-[var(--ff-border-subtle)] whitespace-nowrap uppercase tracking-[0.5px] font-semibold">${CATEGORY_LABELS[r.category] ?? r.category}</span>
              <span class="overflow-hidden text-ellipsis whitespace-nowrap">${r.text}</span>
            </div>
          `)}
        </div>
      </details>
    ` : null}
  `
}
