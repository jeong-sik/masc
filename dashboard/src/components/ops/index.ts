import { html } from 'htm/preact'
import { JsonViewerCard } from '../common/json-viewer'
import { useEffect } from 'preact/hooks'
import { CARD_STANDARD } from '../common/card'
import { EmptyState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { CountBadge } from '../common/badge'
import { TimeAgo } from '../common/time-ago'
import { route } from '../../router'
import {
  operatorActionBusy,
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
import type { OperatorActionLogEntry, OperatorReviewDecision, OperatorReviewItem } from '../../types'
import { QuickIntervene } from './quick-intervene'
import {
  actionTypeLabel,
  confirmPending,
  detailDigestForItem,
  executeRecommendedAction,
  formatMessageContent,
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  hydrateOpsWorkflow,
  hydrateRecommendedAction,
  hydratedWorkflowId,
  
  primaryActionForReviewItem,
  relativeAge,
  reviewDecisionReason,
  runtimeJudgeLabel,
  selectedReviewItemId,
  selectedReviewTab,
  submitReviewDecision,
  targetTypeLabel,
  workflowTargetReady,
} from './helpers'
import { FlowControlPanel } from '../flow-control/flow-control-panel'
import { displayStatus } from '../../lib/status-label'

function severityClass(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'bad':
      return 'border-[var(--bad-30)] bg-[var(--bad-10)]'
    case 'warn':
      return 'border-[var(--warn-30)] bg-[var(--warn-10)]'
    default:
      return 'border-[var(--card-border)] bg-[var(--white-3)]'
  }
}

function severityLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'bad':
      return '즉시 검토'
    case 'warn':
      return '주의'
    default:
      return '정상'
  }
}

function reviewListForTab(
  tab: 'active' | 'deferred' | 'recent',
  active: OperatorReviewItem[],
  deferred: OperatorReviewItem[],
): OperatorReviewItem[] {
  return tab === 'deferred' ? deferred : active
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function pendingConfirmToken(item: OperatorReviewItem | null): string | null {
  const friction = asRecord(item?.friction)
  const pending = asRecord(friction?.pending_confirm)
  const token = pending?.confirm_token ?? pending?.token
  return typeof token === 'string' && token.trim() !== '' ? token : null
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

function renderSummaryBadges(activeCount: number, deferredCount: number, recentCount: number) {
  const roomPaused = operatorSnapshot.value?.namespace?.paused
  const roomLabel =
    typeof roomPaused === 'boolean'
      ? roomPaused ? '프로젝트 일시정지' : '프로젝트 진행 중'
      : '프로젝트 상태 확인 필요'
  const roomTone: ActivityTone =
    typeof roomPaused !== 'boolean'
      ? 'default'
      : roomPaused ? 'warn' : 'ok'

  return html`
    <section class="${CARD_STANDARD} flex flex-wrap items-center gap-2" data-testid="ops-summary-badges">
      <${CountBadge} tone=${activeCount > 0 ? 'warn' : 'ok'}>즉시 검토 ${activeCount}<//>
      <${CountBadge} tone=${deferredCount > 0 ? 'accent' : 'default'}>보류 ${deferredCount}<//>
      <${CountBadge} tone=${recentCount > 0 ? 'accent' : 'default'}>최근 처리 ${recentCount}<//>
      <${CountBadge} tone=${roomTone}>${roomLabel}<//>
    </section>
  `
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

function renderTruth(item: OperatorReviewItem | null) {
  const snapshot = operatorSnapshot.value
  const roomDigest = operatorRoomDigest.value
  const detailDigest = detailDigestForItem(item, roomDigest)

  if (!item) {
    return html`<div class="text-[12px] text-[var(--text-muted)]">큐에서 항목을 고르면 truth를 보여줍니다.</div>`
  }

  if (item.target_type === 'namespace' || item.target_type === 'room') {
    const room = detailDigest?.namespace ?? snapshot?.namespace ?? {}
    return html`
      <div class="grid grid-cols-2 gap-3 max-[880px]:grid-cols-1">
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Project</div>
          <strong>${room.project ?? 'default'}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">${room.project ?? 'project'} · ${room.cluster ?? 'cluster'}</div>
        </div>
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Gate</div>
          <strong>${room.paused ? '일시정지' : '열림'}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">${room.pause_reason ?? '추가 사유 없음'}</div>
        </div>
      </div>
    `
  }

  if (item.target_type === 'keeper') {
    const keeper = snapshot?.keepers.find(row => row.name === item.target_id) ?? null
    return html`
      <div class="grid grid-cols-2 gap-3 max-[880px]:grid-cols-1">
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Keeper</div>
          <strong>${keeper?.name ?? item.target_id ?? 'unknown'}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">${displayStatus(keeper?.status)}${keeper?.model ? ` · ${keeper.model}` : ''}</div>
        </div>
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Context</div>
          <strong>${typeof keeper?.context_ratio === 'number' ? `${Math.round(keeper.context_ratio * 100)}%` : 'unknown'}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">${relativeAge(keeper?.last_turn_ago_s)}</div>
        </div>
      </div>
    `
  }

  return html`<div class="text-[12px] text-[var(--text-muted)]">지원하지 않는 target입니다.</div>`
}

function renderAdvice(item: OperatorReviewItem | null) {
  const roomDigest = operatorRoomDigest.value
  const detailDigest = detailDigestForItem(item, roomDigest)
  const summary = detailDigest?.active_summary ?? item?.advice?.active_summary ?? null
  const guidanceLayer = detailDigest?.active_guidance_layer ?? item?.advice?.active_guidance_layer ?? null
  const runtime = detailDigest?.operator_judge_runtime ?? roomDigest?.operator_judge_runtime ?? null

  return html`
    <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
      <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">
        <span>${guidanceLayerLabel(guidanceLayer)}</span>
        <span>${runtimeJudgeLabel(runtime)}</span>
        ${summary?.fresh_until ? html`<span>${guidanceFreshnessLabel(summary)}</span>` : null}
      </div>
      <div class="mt-2 text-[13px] leading-[1.55] text-[var(--text-body)]">
        ${summary?.summary ?? '현재 이 항목에 연결된 operator guidance가 없습니다.'}
      </div>
      ${detailDigest?.operator_judge_runtime?.model_used
        ? html`<div class="mt-2 text-[12px] text-[var(--text-muted)]">${detailDigest.operator_judge_runtime.model_used}</div>`
        : null}
    </div>
  `
}

function renderFriction(item: OperatorReviewItem | null) {
  if (!item) {
    return html`<div class="text-[12px] text-[var(--text-muted)]">큐에서 항목을 고르면 friction을 보여줍니다.</div>`
  }
  const friction = asRecord(item.friction)
  const attentionItems = Array.isArray(friction?.attention_items) ? friction?.attention_items : []

  return html`
    <div class="grid gap-3">
      ${attentionItems.length > 0 ? html`
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Attention</div>
          <div class="mt-2 grid gap-2">
            ${attentionItems.slice(0, 3).map((row: unknown) => {
              const record = asRecord(row)
              return html`
                <div class="text-[13px] leading-[1.45] text-[var(--text-body)]">
                  <strong>${typeof record?.severity === 'string' ? record.severity : 'info'}</strong>
                  <span> ${typeof record?.summary === 'string' ? record.summary : (row)}</span>
                </div>
              `
            })}
          </div>
        </div>
      ` : null}
      <details class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
        <summary class="cursor-pointer text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Raw Friction</summary>
        <${JsonViewerCard} data=${item.friction} />
      </details>
    </div>
  `
}

function renderRecentReviews() {
  const roomDigest = operatorRoomDigest.value
  const recent = roomDigest?.recent_reviews ?? []
  if (recent.length === 0) {
    return html`<${EmptyState} message="최근 처리 기록이 없습니다." compact />`
  }
  return html`
    <div class="grid gap-2">
      ${recent.map(item => html`
        <article key=${`${item.item_id}:${item.at}`} class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">
            <span>${reviewDecisionLabel(item.decision)}</span>
            <span>${targetSummary(item.target_type, item.target_id)}</span>
            <span>${item.actor}</span>
          </div>
          <div class="mt-1 text-[13px] text-[var(--text-body)]">${item.reason}</div>
          <div class="mt-1 text-[12px] text-[var(--text-muted)]"><${TimeAgo} timestamp=${item.at} /></div>
        </article>
      `)}
    </div>
  `
}

export function Ops() {
  const snapshot = operatorSnapshot.value
  const workflowContext = route.value.tab === 'command' ? workflowContextForRoute(route.value) : null
  const roomDigest = operatorRoomDigest.value
  const activeQueue = roomDigest?.review_queue ?? []
  const deferredQueue = roomDigest?.deferred_queue ?? []
  const workflowReady = workflowTargetReady(workflowContext, snapshot?.keepers ?? [])
  const tab = selectedReviewTab.value
  const currentQueue = reviewListForTab(tab, activeQueue, deferredQueue)
  const selectedItem =
    tab === 'recent'
      ? null
      : currentQueue.find(item => item.id === selectedReviewItemId.value) ?? currentQueue[0] ?? null
  const primaryAction = selectedItem ? primaryActionForReviewItem(selectedItem) : null
  const activeCount = roomDigest?.review_summary?.active_count ?? activeQueue.length
  const deferredCount = roomDigest?.review_summary?.deferred_count ?? deferredQueue.length
  const recentCount = roomDigest?.review_summary?.recent_count ?? (roomDigest?.recent_reviews.length ?? 0)
  const healthy = activeCount === 0
  const confirmToken = pendingConfirmToken(selectedItem)

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

  useEffect(() => {
    if (tab === 'recent') {
      selectedReviewItemId.value = ''
      return
    }
    if (currentQueue.length === 0) {
      selectedReviewItemId.value = ''
      return
    }
    if (!currentQueue.some(item => item.id === selectedReviewItemId.value)) {
      selectedReviewItemId.value = currentQueue[0]?.id ?? ''
    }
  }, [tab, currentQueue.map(item => item.id).join('|')])

  return html`
    <section class="flex flex-col gap-4">
      ${operatorError.value ? html`<section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] error">${operatorError.value}</section>` : null}
      ${operatorDigestError.value ? html`<section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] error">${operatorDigestError.value}</section>` : null}

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

      ${renderSummaryBadges(activeCount, deferredCount, recentCount)}
      ${healthy ? html`
        <section class="grid grid-cols-[minmax(0,0.82fr)_minmax(0,1.18fr)] gap-4 max-[1200px]:grid-cols-1">
          <div class="grid gap-4 order-1 max-[1200px]:order-2">
            <${QuickIntervene} />
            <${FlowControlPanel} />
          </div>

          <section class="${CARD_STANDARD} grid gap-3 order-2 max-[1200px]:order-1">
            <div>
              <h2 class="text-sm font-semibold text-[var(--text-strong)]">최근 운영 활동</h2>
              <p class="mt-1 text-[12px] text-[var(--text-muted)]">최근 처리와 직접 개입을 시간순으로 함께 보여줍니다.</p>
            </div>
            <${renderActivityTimeline} />
          </section>
        </section>
      ` : html`
        <${FlowControlPanel} />
        <div class="grid grid-cols-[280px_minmax(0,1fr)_360px] gap-4 max-[1280px]:grid-cols-1">
          <section class="${CARD_STANDARD} grid gap-3">
            <div class="flex gap-2 flex-wrap">
              <${ActionButton} variant=${tab === 'active' ? 'primary' : 'ghost'} size="lg" onClick=${() => { selectedReviewTab.value = 'active' }}>
                즉시 검토 ${activeCount}
              <//>
              <${ActionButton} variant=${tab === 'deferred' ? 'primary' : 'ghost'} size="lg" onClick=${() => { selectedReviewTab.value = 'deferred' }}>
                보류 ${deferredCount}
              <//>
              <${ActionButton} variant=${tab === 'recent' ? 'primary' : 'ghost'} size="lg" onClick=${() => { selectedReviewTab.value = 'recent' }}>
                최근 처리 ${recentCount}
              <//>
            </div>

            ${tab === 'recent'
              ? html`<${renderRecentReviews} />`
              : currentQueue.length === 0
                ? html`<${EmptyState} message="이 탭에는 review item이 없습니다." compact />`
                : html`
                    <div class="grid gap-2">
                      ${currentQueue.map(item => html`
                        <button
                          key=${item.id}
                          type="button"
                          class="text-left p-3 rounded-xl border ${severityClass(item.severity)} ${selectedItem?.id === item.id ? 'ring-1 ring-[rgba(71,184,255,0.45)]' : ''}"
                          onClick=${() => { selectedReviewItemId.value = item.id }}
                        >
                          <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">
                            <span>${severityLabel(item.severity)}</span>
                            <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                            <span>${item.urgency}</span>
                          </div>
                          <div class="mt-1 text-[14px] font-semibold text-[var(--text-strong)]">${item.summary}</div>
                          <div class="mt-1 text-[12px] leading-[1.45] text-[var(--text-muted)]">${item.why_now}</div>
                          ${typeof item.stale_sec === 'number'
                            ? html`<div class="mt-2 text-[11px] text-[var(--text-muted)]">stale ${relativeAge(item.stale_sec)}</div>`
                            : null}
                        </button>
                      `)}
                    </div>
                  `}
          </section>

          <section class="${CARD_STANDARD} grid gap-4">
            <div class="p-3 rounded-xl border ${severityClass(selectedItem?.severity)}">
              <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">
                <span>${selectedItem?.kind ?? 'review_item'}</span>
                <span>${selectedItem ? targetTypeLabel(selectedItem.target_type) : '대상 없음'}${selectedItem?.target_id ? ` · ${selectedItem.target_id}` : ''}</span>
                <span>${selectedItem?.urgency ?? 'soon'}</span>
              </div>
              <div class="mt-1 text-[16px] font-semibold text-[var(--text-strong)]">
                ${selectedItem?.summary ?? '큐에서 항목을 고르세요'}
              </div>
              <div class="mt-2 text-[13px] leading-[1.55] text-[var(--text-body)]">
                ${selectedItem?.why_now ?? '선택한 항목의 why-now 설명이 여기에 나옵니다.'}
              </div>
            </div>

            <div class="grid gap-2">
              <h3 class="text-sm font-semibold text-[var(--text-strong)]">현재 상태</h3>
              ${renderTruth(selectedItem)}
            </div>

            <div class="grid gap-2">
              <h3 class="text-sm font-semibold text-[var(--text-strong)]">마찰 요인</h3>
              ${renderFriction(selectedItem)}
            </div>

            <div class="grid gap-2">
              <h3 class="text-sm font-semibold text-[var(--text-strong)]">운영 판단</h3>
              ${renderAdvice(selectedItem)}
            </div>
          </section>

          <section class="${CARD_STANDARD} grid gap-4">
            <div>
              <h3 class="text-sm font-semibold text-[var(--text-strong)]">실행 작업대</h3>
              <p class="text-[12px] text-[var(--text-muted)] mt-1">가장 작은 다음 행동을 실행하거나, review 상태를 resolve/defer로 닫습니다.</p>
            </div>

            ${selectedItem == null
              ? html`<${EmptyState} message="먼저 review item을 고르세요." compact />`
              : html`
                  ${primaryAction
                    ? html`
                        <article class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] grid gap-2">
                          <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">
                            <span>우선 액션</span>
                            <span>${actionTypeLabel(primaryAction.action_type)}</span>
                            <span>${targetTypeLabel(primaryAction.target_type)}${primaryAction.target_id ? ` · ${primaryAction.target_id}` : ''}</span>
                          </div>
                          <div class="text-[13px] leading-[1.55] text-[var(--text-body)]">${primaryAction.reason}</div>
                          <div class="flex gap-2 flex-wrap">
                            <${ActionButton} variant="primary" size="lg" onClick=${() => { void executeRecommendedAction(primaryAction) }} disabled=${operatorActionBusy.value}>
                              바로 실행
                            <//>
                            <${ActionButton} variant="ghost" size="lg" onClick=${() => { hydrateRecommendedAction(primaryAction) }} disabled=${operatorActionBusy.value}>
                              폼에 채우기
                            <//>
                          </div>
                        </article>
                      `
                    : html`<${EmptyState} message="이 항목에는 자동으로 제안된 primary action이 없습니다." compact />`}

                  ${confirmToken
                    ? html`
                        <article class="p-3 rounded-xl border border-[var(--warn-30)] bg-[var(--warn-10)] grid gap-2">
                          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">승인 대기</div>
                          <div class="text-[13px] text-[var(--text-body)]">${confirmToken}</div>
                          <div class="flex gap-2 flex-wrap">
                            <${ActionButton} variant="primary" size="lg" onClick=${() => { void confirmPending(confirmToken, 'confirm') }} disabled=${operatorActionBusy.value}>
                              승인 실행
                            <//>
                            <${ActionButton} variant="ghost" size="lg" onClick=${() => { void confirmPending(confirmToken, 'deny') }} disabled=${operatorActionBusy.value}>
                              거부
                            <//>
                          </div>
                        </article>
                      `
                    : null}

                  <div class="grid gap-2">
                    <label class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]" for="review-reason">처리 이유</label>
                    <textarea
                      id="review-reason"
                      class="control-textarea"
                      rows=${4}
                      placeholder="왜 resolve/defer 하는지 남깁니다"
                      value=${reviewDecisionReason.value}
                      onInput=${(event: Event) => { reviewDecisionReason.value = (event.target as HTMLTextAreaElement).value }}
                      disabled=${operatorActionBusy.value}
                    ></textarea>
                  </div>

                  <div class="flex gap-2 flex-wrap">
                    <${ActionButton} variant="primary" size="lg" onClick=${() => { if (selectedItem) void submitReviewDecision(selectedItem, 'review_resolve') }} disabled=${operatorActionBusy.value || !selectedItem || !reviewDecisionReason.value.trim()}>
                      해결 처리
                    <//>
                    <${ActionButton} variant="ghost" size="lg" onClick=${() => { if (selectedItem) void submitReviewDecision(selectedItem, 'review_defer') }} disabled=${operatorActionBusy.value || !selectedItem || !reviewDecisionReason.value.trim()}>
                      보류 처리
                    <//>
                  </div>

                  <${QuickIntervene} />
                `}
          </section>
        </div>
      `}
    </section>
  `
}
