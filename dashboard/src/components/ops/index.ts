import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { CARD_STANDARD } from '../common/card'
import { ActionButton } from '../common/button'
import { TextInput } from '../common/input'
import { refreshRoomTruth } from '../../room-truth-store'
import { RoomTruthStrip } from '../common/room-truth-strip'
import { route } from '../../router'
import {
  operatorActionBusy,
  operatorActionLog,
  operatorDigestError,
  operatorError,
  operatorLoading,
  operatorRoomDigest,
  operatorSessionDigest,
  operatorSnapshot,
  refreshOperatorRoomDigest,
  refreshOperatorSessionDigest,
  refreshOperatorSnapshot,
} from '../../operator-store'
import {
  workflowActionLabel,
  workflowContextForRoute,
  workflowTargetLabel,
} from '../../workflow-context'
import type { OperatorReviewItem } from '../../types'
import { QuickIntervene } from './quick-intervene'
import {
  actionTypeLabel,
  actorName,
  confirmPending,
  detailDigestForItem,
  executeRecommendedAction,
  formatMessageContent,
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  hydrateOpsWorkflow,
  hydrateRecommendedAction,
  hydratedWorkflowId,
  persistActorName,
  prettyJson,
  primaryActionForReviewItem,
  relativeAge,
  reviewDecisionReason,
  runtimeJudgeLabel,
  selectedReviewItemId,
  selectedReviewTab,
  selectedSessionId,
  submitReviewDecision,
  targetTypeLabel,
  workflowTargetReady,
} from './helpers'

function severityClass(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'bad':
      return 'border-[rgba(239,68,68,0.26)] bg-[rgba(239,68,68,0.08)]'
    case 'warn':
      return 'border-[rgba(251,191,36,0.26)] bg-[rgba(251,191,36,0.08)]'
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

function renderTruth(item: OperatorReviewItem | null) {
  const snapshot = operatorSnapshot.value
  const roomDigest = operatorRoomDigest.value
  const sessionDigest = operatorSessionDigest.value
  const detailDigest = detailDigestForItem(item, roomDigest, sessionDigest)

  if (!item) {
    return html`<div class="text-[12px] text-[var(--text-muted)]">큐에서 항목을 고르면 truth를 보여줍니다.</div>`
  }

  if (item.target_type === 'room') {
    const room = detailDigest?.room ?? snapshot?.room ?? {}
    return html`
      <div class="grid grid-cols-2 gap-3 max-[880px]:grid-cols-1">
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Room</div>
          <strong>${room.current_room ?? room.room_id ?? 'default'}</strong>
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

  if (item.target_type === 'team_session') {
    const session = snapshot?.sessions.find(row => row.session_id === item.target_id) ?? null
    const detailCard = detailDigest?.session_cards[0] ?? null
    return html`
      <div class="grid grid-cols-2 gap-3 max-[880px]:grid-cols-1">
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Session</div>
          <strong>${item.target_id ?? 'unknown'}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">
            상태 ${session?.status ?? detailCard?.status ?? 'unknown'} · 진행 ${Math.round(session?.progress_pct ?? 0)}%
          </div>
        </div>
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Runtime</div>
          <strong>${detailCard?.health ?? 'unknown'}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">
            활성 ${detailCard?.active_agent_count ?? 0} · 계획 ${detailCard?.planned_worker_count ?? 0}
          </div>
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
          <div class="text-[12px] text-[var(--text-muted)]">${keeper?.status ?? 'unknown'} · ${keeper?.model ?? 'model 확인 필요'}</div>
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
  const sessionDigest = operatorSessionDigest.value
  const detailDigest = detailDigestForItem(item, roomDigest, sessionDigest)
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
                  <span> ${typeof record?.summary === 'string' ? record.summary : prettyJson(row)}</span>
                </div>
              `
            })}
          </div>
        </div>
      ` : null}
      <details class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
        <summary class="cursor-pointer text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Raw Friction</summary>
        <pre class="mt-2 text-[11px] leading-[1.45] overflow-auto">${prettyJson(item.friction)}</pre>
      </details>
    </div>
  `
}

function renderRecentReviews() {
  const roomDigest = operatorRoomDigest.value
  const recent = roomDigest?.recent_reviews ?? []
  if (recent.length === 0) {
    return html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[13px] text-[var(--text-muted)]">최근 처리 기록이 없습니다.</div>`
  }
  return html`
    <div class="grid gap-2">
      ${recent.map(item => html`
        <article key=${`${item.item_id}:${item.at}`} class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">
            <span>${item.decision}</span>
            <span>${item.target_type}${item.target_id ? ` · ${item.target_id}` : ''}</span>
            <span>${item.actor}</span>
          </div>
          <div class="mt-1 text-[13px] text-[var(--text-body)]">${item.reason}</div>
          <div class="mt-1 text-[12px] text-[var(--text-muted)]">${item.at}</div>
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
  const currentActor = actorName.value.trim() || 'dashboard'
  const workflowReady = workflowTargetReady(workflowContext, snapshot?.sessions ?? [], snapshot?.keepers ?? [])
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
    if (route.value.tab !== 'command' || route.value.params.section !== 'intervene') {
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

  useEffect(() => {
    if (selectedItem?.target_type !== 'team_session' || !selectedItem.target_id) return
    selectedSessionId.value = selectedItem.target_id ?? ''
    void refreshOperatorSessionDigest(selectedItem.target_id, { force: true })
  }, [selectedItem?.id, selectedItem?.target_type, selectedItem?.target_id])

  return html`
    <section class="flex flex-col gap-4">
      <div class="${CARD_STANDARD} flex justify-end items-center gap-4 flex-wrap">
        <div class="flex items-center gap-3 flex-wrap max-[880px]:w-full">
          <div class="flex items-center gap-1.5">
            <${TextInput}
              class="w-[140px] border-transparent bg-transparent px-1 py-0.5 text-[13px] font-semibold text-[var(--text-strong)] hover:border-[var(--white-8)]"
              value=${currentActor}
              name="operator_actor"
              ariaLabel="메시지 발신자 이름"
              onInput=${(event: Event) => { persistActorName((event.target as HTMLInputElement).value) }}
              disabled=${operatorActionBusy.value}
              autoComplete="off"
            />
          </div>
          <${ActionButton}
            variant="ghost"
            size="lg"
            onClick=${() => {
              void refreshRoomTruth({ force: true })
              void refreshOperatorSnapshot({ force: true })
              void refreshOperatorRoomDigest({ force: true })
              void refreshOperatorSessionDigest(selectedItem?.target_type === 'team_session' ? selectedItem.target_id ?? null : null, { force: true })
            }}
            disabled=${operatorLoading.value || operatorActionBusy.value}
          >
            ${operatorLoading.value ? '새로고침 중...' : '새로고침'}
          <//>
        </div>
      </div>

      ${operatorError.value ? html`<section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] error">${operatorError.value}</section>` : null}
      ${operatorDigestError.value ? html`<section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] error">${operatorDigestError.value}</section>` : null}

      <${RoomTruthStrip} />

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

      <section class="${CARD_STANDARD} grid grid-cols-4 gap-3 max-[1200px]:grid-cols-2 max-[880px]:grid-cols-1">
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Active Queue</div>
          <strong>${activeCount}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">지금 바로 사람 검토가 필요한 항목</div>
        </div>
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Deferred</div>
          <strong>${deferredCount}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">같은 fingerprint 기준으로 다시 보류 중인 항목</div>
        </div>
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Recent Reviews</div>
          <strong>${recentCount}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">최근 운영자가 처리한 review 항목</div>
        </div>
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Mode</div>
          <strong>${healthy ? 'Healthy Console' : 'Review Queue'}</strong>
          <div class="text-[12px] text-[var(--text-muted)]">${healthy ? '조용한 운영 상태' : '우선순위 검토 모드'}</div>
        </div>
      </section>

      ${healthy ? html`
        <section class="${CARD_STANDARD} grid gap-4">
          <div>
            <h2 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Healthy Console</h2>
            <p class="text-[12px] text-[var(--text-muted)] mt-1">active review queue가 비어 있습니다. 지금은 compact 상태와 최근 처리 이력만 보여줍니다.</p>
          </div>
          <${QuickIntervene} />
          <div class="grid grid-cols-2 gap-4 max-[1200px]:grid-cols-1">
            <section class="grid gap-2">
              <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">최근 Review 처리</h3>
              <${renderRecentReviews} />
            </section>
            <section class="grid gap-2">
              <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">최근 개입 로그</h3>
              ${operatorActionLog.value.length === 0
                ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[13px] text-[var(--text-muted)]">아직 실행한 개입이 없습니다.</div>`
                : html`
                    <div class="grid gap-2">
                      ${operatorActionLog.value.slice(0, 6).map(entry => html`
                        <article key=${entry.id} class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
                          <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">
                            <span>${actionTypeLabel(entry.action_type)}</span>
                            <span>${entry.target_label}</span>
                            <span>${entry.at}</span>
                          </div>
                          <div class="mt-1 text-[13px] text-[var(--text-body)]">${formatMessageContent(entry.message)}</div>
                        </article>
                      `)}
                    </div>
                  `}
            </section>
          </div>
        </section>
      ` : html`
        <div class="grid grid-cols-[280px_minmax(0,1fr)_360px] gap-4 max-[1280px]:grid-cols-1">
          <section class="${CARD_STANDARD} grid gap-3">
            <div class="flex gap-2 flex-wrap">
              <${ActionButton} variant=${tab === 'active' ? 'primary' : 'ghost'} size="lg" onClick=${() => { selectedReviewTab.value = 'active' }}>
                Active ${activeCount}
              <//>
              <${ActionButton} variant=${tab === 'deferred' ? 'primary' : 'ghost'} size="lg" onClick=${() => { selectedReviewTab.value = 'deferred' }}>
                Deferred ${deferredCount}
              <//>
              <${ActionButton} variant=${tab === 'recent' ? 'primary' : 'ghost'} size="lg" onClick=${() => { selectedReviewTab.value = 'recent' }}>
                Recent ${recentCount}
              <//>
            </div>

            ${tab === 'recent'
              ? html`<${renderRecentReviews} />`
              : currentQueue.length === 0
                ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[13px] text-[var(--text-muted)]">이 탭에는 review item이 없습니다.</div>`
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
              <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Truth</h3>
              ${renderTruth(selectedItem)}
            </div>

            <div class="grid gap-2">
              <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Friction</h3>
              ${renderFriction(selectedItem)}
            </div>

            <div class="grid gap-2">
              <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Advice</h3>
              ${renderAdvice(selectedItem)}
            </div>
          </section>

          <section class="${CARD_STANDARD} grid gap-4">
            <div>
              <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Action Workbench</h3>
              <p class="text-[12px] text-[var(--text-muted)] mt-1">가장 작은 다음 행동을 실행하거나, review 상태를 resolve/defer로 닫습니다.</p>
            </div>

            ${selectedItem == null
              ? html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[13px] text-[var(--text-muted)]">먼저 review item을 고르세요.</div>`
              : html`
                  ${primaryAction
                    ? html`
                        <article class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] grid gap-2">
                          <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">
                            <span>Primary Action</span>
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
                    : html`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[13px] text-[var(--text-muted)]">이 항목에는 자동으로 제안된 primary action이 없습니다.</div>`}

                  ${confirmToken
                    ? html`
                        <article class="p-3 rounded-xl border border-[rgba(251,191,36,0.26)] bg-[rgba(251,191,36,0.08)] grid gap-2">
                          <div class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.08em]">Pending Confirm</div>
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
                      Resolve
                    <//>
                    <${ActionButton} variant="ghost" size="lg" onClick=${() => { if (selectedItem) void submitReviewDecision(selectedItem, 'review_defer') }} disabled=${operatorActionBusy.value || !selectedItem || !reviewDecisionReason.value.trim()}>
                      Defer
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
