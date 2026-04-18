// MASC Dashboard — Situation Banner
// Clean alert bar: icon + text hierarchy + severity indicator.

import { html } from 'htm/preact'
import { AlertCircle, AlertTriangle, CheckCircle2 } from 'lucide-preact'
import { missionError, missionLoading } from '../../mission-store'
import { namespaceTruthError } from '../../namespace-truth-store'
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

export function synthesizeSituation(snap: DashboardMissionResponse | null): SituationResult {
  const loadErrors = [
    missionError.value?.trim(),
    namespaceTruthError.value?.trim(),
  ].filter((value): value is string => Boolean(value))

  if (!snap) {
    if (loadErrors.length > 0) {
      return {
        text: `데이터 로드 실패: ${loadErrors[0]}`,
        tone: 'bad',
        reasons: loadErrors.map(text => ({
          category: 'incident',
          text,
          severity: 'bad',
        })),
      }
    }
    if (missionLoading.value) return { text: '데이터 로딩 중...', tone: 'ok', reasons: [] }
    return { text: '데이터 대기 중...', tone: 'ok', reasons: [] }
  }

  const sessions: SessionItem[] = snap.sessions ?? []
  const total = sessions.length
  const blocked = sessions.filter(s => s.blocker_summary).length
  const attentionItems = snap.attention_queue ?? []
  const attention = attentionItems.length
  const hasAnyAgents = (snap.agent_briefs?.length ?? 0) > 0
  const hasAnyKeepers = (snap.keeper_briefs?.length ?? 0) > 0

  if (total === 0 && !hasAnyAgents && !hasAnyKeepers) {
    return { text: '유휴 상태. 세션, 에이전트, 키퍼 모두 비활성.', tone: 'ok', reasons: [] }
  }

  const reasons: SituationReason[] = []

  for (const error of loadErrors) {
    reasons.push({
      category: 'incident',
      text: `최근 데이터 갱신 실패: ${error}`,
      severity: 'bad',
    })
  }

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

  for (const item of attentionItems.slice(0, 5)) {
    reasons.push({
      category: 'attention',
      text: item.summary ?? item.kind ?? '주의 항목',
      severity: item.severity === 'critical' || item.severity === 'bad' ? 'bad' : 'warn',
    })
  }

  const incidents = snap.incidents ?? []
  for (const inc of incidents.slice(0, 3)) {
    reasons.push({
      category: 'incident',
      text: inc.summary ?? '인시던트',
      severity: inc.severity === 'critical' ? 'bad' : 'warn',
    })
  }

  if (total === 0) {
    if (loadErrors.length > 0) {
      return {
        text: '데이터 일부 갱신 실패. 진행 중인 세션 없음.',
        tone: 'bad',
        reasons,
      }
    }
    return { text: '진행 중인 세션 없음.', tone: 'ok', reasons }
  }

  if (blocked === 0 && attention === 0) {
    if (loadErrors.length > 0) {
      return {
        text: `데이터 일부 갱신 실패. ${total}개 세션은 기존 스냅샷 기준으로 표시 중.`,
        tone: 'bad',
        reasons,
      }
    }
    return { text: `${total}개 세션 순조롭게 진행 중.`, tone: 'ok', reasons }
  }

  if (blocked > 0) {
    const suffix = attention > 0 ? ` ${attention}건 주의 필요.` : ''
    const tone: SituationTone = loadErrors.length > 0 || blocked > total / 2 ? 'bad' : 'warn'
    const prefix = loadErrors.length > 0 ? '데이터 일부 갱신 실패. ' : ''
    return { text: `${prefix}${total}개 세션 중 ${blocked}개 막힘.${suffix}`, tone, reasons }
  }

  if (loadErrors.length > 0) {
    return {
      text: `데이터 일부 갱신 실패. ${total}개 세션 진행 중. ${attention}건 주의 항목.`,
      tone: 'bad',
      reasons,
    }
  }

  return { text: `${total}개 세션 진행 중. ${attention}건 주의 항목.`, tone: 'warn', reasons }
}

const CATEGORY_LABELS: Record<string, string> = {
  blocker: '막힘',
  attention: '주의',
  incident: '인시던트',
}

function toneIcon(tone: SituationTone) {
  if (tone === 'bad') return html`<${AlertCircle} size=${20} />`
  if (tone === 'warn') return html`<${AlertTriangle} size=${20} />`
  return html`<${CheckCircle2} size=${20} />`
}

function toneBorderClass(tone: SituationTone): string {
  if (tone === 'bad') return 'border-l-[var(--bad)]'
  if (tone === 'warn') return 'border-l-[var(--warn)]'
  return 'border-l-[var(--ok)]'
}

function toneBgClass(tone: SituationTone): string {
  if (tone === 'bad') return 'bg-[rgba(239,68,68,0.06)]'
  if (tone === 'warn') return 'bg-[var(--warn-10)]'
  return 'bg-[var(--white-3)]'
}

function toneTextClass(tone: SituationTone): string {
  if (tone === 'bad') return 'text-[var(--bad)]'
  if (tone === 'warn') return 'text-[var(--warn)]'
  return 'text-[var(--ok)]'
}

interface SituationBannerProps {
  snap: DashboardMissionResponse | null
  roomHealth?: string | null
}

export function SituationBanner({ snap }: SituationBannerProps) {
  const { text, tone, reasons } = synthesizeSituation(snap)
  const showReasons = tone !== 'ok' && reasons.length > 0

  return html`
    <div class="flex flex-col gap-0">
      <div class="flex items-center gap-3 px-4 py-3 rounded border border-[var(--card-border)] border-l-[3px] ${toneBorderClass(tone)} ${toneBgClass(tone)}">
        <span class="shrink-0 w-5 h-5 flex items-center justify-center text-sm ${toneTextClass(tone)}">${toneIcon(tone)}</span>
        <span class="flex-1 min-w-0 text-sm font-medium text-[var(--text-strong)] leading-snug">${text}</span>
      </div>
      ${showReasons ? html`
        <div class="flex flex-col gap-1 px-4 py-2 border-l-[3px] ${toneBorderClass(tone)} ml-0">
          ${reasons.map((r, i) => html`
            <div class="flex items-center gap-2 text-xs" key=${i}>
              <span class="shrink-0 px-1.5 py-px rounded text-[10px] font-semibold uppercase tracking-wide ${r.severity === 'bad' ? 'bg-[var(--bad-8)] text-[var(--bad-light)]' : 'bg-[var(--warn-12)] text-[var(--warn)]'}">${CATEGORY_LABELS[r.category] ?? r.category}</span>
              <span class="truncate text-[var(--text-muted)]">${r.text}</span>
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}
