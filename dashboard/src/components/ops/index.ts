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
  operatorDigestErrorStatus,
  operatorError,
  operatorErrorStatus,
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

const OPERATOR_ROUTE_MISSING_PATTERN = /\b(?:404|410)\s+Not\s+Found\b/i
const OPERATOR_ROUTE_MISSING_STATUSES = new Set<number>([404, 410])

export function operatorErrorHint(message: string, status: number | null): string | null {
  const routeMissing = status != null
    ? OPERATOR_ROUTE_MISSING_STATUSES.has(status)
    : OPERATOR_ROUTE_MISSING_PATTERN.test(message)
  if (routeMissing) {
    return '서버 바이너리가 최신 API 라우트를 포함하지 않을 수 있습니다. 우측 상단 빌드 배지에서 커밋을 확인하고 필요하면 서버를 재시작하세요.'
  }
  return null
}

function OperatorErrorBanner({ message, status }: { message: string; status: number | null }) {
  const hint = operatorErrorHint(message, status)
  return html`
    <section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] error" data-testid="operator-error-banner">
      <div class="leading-relaxed">${message}</div>
      ${hint ? html`<div class="mt-1.5 text-[12px] opacity-85" data-testid="operator-error-hint">${hint}</div>` : null}
    </section>
  `
}

type ActivityTone = 'default' | 'warn' | 'ok' | 'bad' | 'accent'

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

  return [...reviews, ...interventions]
    .sort((left, right) => parseTimestamp(right.at) - parseTimestamp(left.at))
    .slice(0, limit)
}

function renderActivityTimeline() {
  const entries = timelineEntries()
  if (entries.length === 0) {
    return html`<${EmptyState} message="아직 기록된 운영 활동이 없습니다." compact />`
  }

  return html`
    <div class="grid gap-2" data-testid="ops-activity-timeline">
      ${entries.map(entry => html`
        <article
          key=${entry.key}
          data-testid="ops-activity-item"
          data-activity-kind=${entry.kind}
          class="rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] p-3"
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
      ${operatorError.value ? html`<${OperatorErrorBanner} message=${operatorError.value} status=${operatorErrorStatus.value} />` : null}
      ${operatorDigestError.value ? html`<${OperatorErrorBanner} message=${operatorDigestError.value} status=${operatorDigestErrorStatus.value} />` : null}

      ${workflowContext ? html`
        <section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] ${workflowReady ? 'info' : 'warn'} grid gap-2">
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
