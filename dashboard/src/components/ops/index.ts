import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { CARD_STANDARD } from '../common/card'
import { EmptyState } from '../common/feedback-state'
import { CountBadge } from '../common/badge'
import { TimeAgo } from '../common/time-ago'
import { route } from '../../router'
import {
  operatorActionLog,
  operatorDigestError,
  operatorError,
  operatorRoomDigest,
  operatorSnapshot,
} from '../../operator-store'
import {
  workflowActionLabel,
  workflowContextForRoute,
  workflowTargetLabel,
} from '../../workflow-context'
import type { OperatorActionLogEntry, OperatorReviewDecision } from '../../types'
import { QuickIntervene } from './quick-intervene'
import {
  actionTypeLabel,
  formatMessageContent,
  hydrateOpsWorkflow,
  hydratedWorkflowId,
  targetTypeLabel,
  workflowTargetReady,
} from './helpers'
import { FlowControlPanel } from '../flow-control/flow-control-panel'

type ActivityTone = 'default' | 'warn' | 'ok' | 'bad' | 'accent'

export const ACTIVITY_MAX_AGE_MS = 3 * 24 * 60 * 60 * 1000

interface OpsActivityTimelineEntry {
  key: string
  kind: 'review' | 'intervention'
  at: string
  actor: string
  label: string
  target: string
  detail: string
  tone: ActivityTone
}

function parseTimestamp(value?: string | null): number {
  if (!value) return 0
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function reviewDecisionLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'resolved':
      return '검토 해결'
    case 'deferred':
      return '검토 보류'
    default:
      return value?.trim() || '검토 처리'
  }
}

function reviewDecisionTone(value?: string | null): ActivityTone {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'resolved':
      return 'ok'
    case 'deferred':
      return 'warn'
    default:
      return 'accent'
  }
}

function actionLogTone(entry: OperatorActionLogEntry): ActivityTone {
  switch (entry.outcome) {
    case 'error':
      return 'bad'
    case 'preview':
      return 'warn'
    case 'confirmed':
      return 'accent'
    default:
      return 'default'
  }
}

function targetSummary(targetType?: string | null, targetId?: string | null): string {
  return `${targetTypeLabel(targetType)}${targetId ? ` · ${targetId}` : ''}`
}

function prettyTargetLabel(label?: string | null): string {
  const value = label?.trim()
  if (!value) return '대상 없음'
  const separator = value.indexOf(':')
  if (separator < 0) return targetTypeLabel(value)
  const type = value.slice(0, separator)
  const rest = value.slice(separator + 1)
  return `${targetTypeLabel(type)} · ${rest}`
}

function timelineEntries(limit = 10): OpsActivityTimelineEntry[] {
  const reviews = (operatorRoomDigest.value?.recent_reviews ?? []).map((item: OperatorReviewDecision) => ({
    key: `review:${item.item_id}:${item.at}`,
    kind: 'review' as const,
    at: item.at,
    actor: item.actor || 'unknown',
    label: reviewDecisionLabel(item.decision),
    target: targetSummary(item.target_type, item.target_id),
    detail: item.reason || '사유 없음',
    tone: reviewDecisionTone(item.decision),
  }))

  const interventions = operatorActionLog.value.map((entry: OperatorActionLogEntry) => ({
    key: `intervention:${entry.id}`,
    kind: 'intervention' as const,
    at: entry.at,
    actor: entry.actor || 'unknown',
    label: actionTypeLabel(entry.action_type),
    target: prettyTargetLabel(entry.target_label),
    detail: formatMessageContent(entry.message) || '세부 내용 없음',
    tone: actionLogTone(entry),
  }))

  const cutoff = Date.now() - ACTIVITY_MAX_AGE_MS
  return [...reviews, ...interventions]
    .filter(entry => parseTimestamp(entry.at) >= cutoff)
    .sort((left, right) => parseTimestamp(right.at) - parseTimestamp(left.at))
    .slice(0, limit)
}

export function activityTimelineEmptyState(): { message: string; hint: string | null } {
  const root = operatorSnapshot.value?.root
  if (root?.paused) {
    const reason = root.pause_reason?.trim()
    const by = root.paused_by?.trim()
    const parts = [reason, by ? `by ${by}` : null].filter(Boolean).join(' · ')
    return {
      message: 'namespace가 일시정지 상태입니다. 재개 전까지 새 운영 활동이 기록되지 않습니다.',
      hint: parts || null,
    }
  }
  return {
    message: '최근 3일 내 운영 활동이 없습니다. 개입이 실행되거나 검토가 처리되면 자동 기록됩니다.',
    hint: null,
  }
}

function renderActivityTimeline() {
  const entries = timelineEntries()
  if (entries.length === 0) {
    const { message, hint } = activityTimelineEmptyState()
    return html`
      <div data-testid="ops-activity-timeline-empty">
        <${EmptyState} message=${message} compact />
        ${hint ? html`<div class="mt-0.5 text-center text-[11px] text-text-dim">${hint}</div>` : null}
      </div>
    `
  }

  return html`
    <div class="grid gap-2" data-testid="ops-activity-timeline">
      ${entries.map(entry => html`
        <article
          key=${entry.key}
          data-testid="ops-activity-item"
          data-activity-kind=${entry.kind}
          class="rounded border border-[var(--card-border)] bg-[var(--white-3)] p-3"
        >
          <div class="flex flex-wrap items-center gap-2 text-[11px] text-[var(--text-muted)]">
            <${CountBadge} tone=${entry.tone}>${entry.label}<//>
            <span>${entry.target}</span>
            <span>${entry.actor}</span>
            <span><${TimeAgo} timestamp=${entry.at} /></span>
          </div>
          <div class="mt-2 text-[13px] leading-[1.55] text-[var(--text-body)]">${entry.detail}</div>
        </article>
      `)}
    </div>
  `
}

export function Ops() {
  const snapshot = operatorSnapshot.value
  const workflowContext = route.value.tab === 'command' ? workflowContextForRoute(route.value) : null
  const workflowReady = workflowTargetReady(workflowContext, snapshot?.keepers ?? [])

  useEffect(() => {
    if (route.value.tab !== 'command' || route.value.params.section !== 'operations') {
      hydratedWorkflowId.value = null
      return
    }
    if (!workflowContext) {
      hydratedWorkflowId.value = null
      return
    }
    if (hydratedWorkflowId.value === workflowContext.id) return
    hydratedWorkflowId.value = workflowContext.id
    hydrateOpsWorkflow(workflowContext)
  }, [
    route.value.tab,
    route.value.params.source,
    route.value.params.action_type,
    route.value.params.target_type,
    route.value.params.target_id,
    route.value.params.focus_kind,
    workflowContext?.id,
  ])

  return html`
    <section class="flex flex-col gap-4">
      ${operatorError.value ? html`<section class="ops-banner rounded py-3 px-3.5 border border-[var(--card-border)] error">${operatorError.value}</section>` : null}
      ${operatorDigestError.value ? html`<section class="ops-banner rounded py-3 px-3.5 border border-[var(--card-border)] error">${operatorDigestError.value}</section>` : null}

      ${workflowContext ? html`
        <section class="ops-banner rounded py-3 px-3.5 border border-[var(--card-border)] ${workflowReady ? 'info' : 'warn'} grid gap-2">
          <div class="flex gap-2 flex-wrap items-center text-[var(--text-body)]">
            <strong class="font-semibold">${workflowContext.source_label}</strong>
            <span>${workflowActionLabel(workflowContext.action_type)}</span>
            <span>${workflowTargetLabel(workflowContext)}</span>
          </div>
          <div class="text-[var(--text-strong)] leading-relaxed">${workflowContext.summary}</div>
          ${workflowContext.payload_preview ? html`<div class="mt-1 p-2 rounded-lg bg-[var(--white-3)] text-[12px] font-mono">${workflowContext.payload_preview}</div>` : null}
          <div class="text-[var(--text-muted)] text-[12px]">
            ${workflowReady
              ? '추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.'
              : '대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다.'}
          </div>
        </section>
      ` : null}

      <${FlowControlPanel} />
      <section class="grid grid-cols-2 gap-4 max-[1200px]:grid-cols-1">
        <div class="grid gap-4 order-1 max-[1200px]:order-2">
          <${QuickIntervene} />
        </div>

        <section class="${CARD_STANDARD} grid gap-3 order-2 max-[1200px]:order-1">
          <div>
            <h2 class="text-sm font-semibold text-[var(--text-strong)]">최근 운영 활동</h2>
            <p class="mt-1 text-[12px] text-[var(--text-muted)]">최근 처리와 직접 개입을 시간순으로 함께 보여줍니다. 검토 큐와 Live Judge 판단은 거버넌스 페이지에서 처리합니다.</p>
          </div>
          <${renderActivityTimeline} />
        </section>
      </section>
    </section>
  `
}
