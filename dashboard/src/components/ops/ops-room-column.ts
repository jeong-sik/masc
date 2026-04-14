// Ops — Project-scope column: broadcast, pause/resume, task inject, recommended actions, pending confirmations, shared feed

import { html } from 'htm/preact'
import { JsonViewerCard } from '../common/json-viewer'
import { signal } from '@preact/signals'
import { CARD_STANDARD } from '../common/card'
import { ActionButton } from '../common/button'
import { RichComposer } from '../common/rich-composer'
import { useRef } from 'preact/hooks'
import { EmptyState, LoadingState } from '../common/feedback-state'
import {
  operatorActionBusy,
  operatorDigestLoading,
  operatorRoomDigest,
  operatorSnapshot,
} from '../../operator-store'
import {
  actionTypeLabel,
  actorName,
  canManagePendingConfirmation,
  broadcastMessage,
  confirmPending,
  deliveryModeLabel,
  filterPendingConfirmations,
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  guidanceLayerTone,
  hydrateRecommendedAction,
  pauseReason,
  
  runtimeJudgeLabel,
  runtimeJudgeTone,
  submitBroadcast,
  submitPause,
  submitResume,
  submitTaskInject,
  targetTypeLabel,
  taskDescription,
  taskPriority,
  taskTitle,
  formatMessageContent,
  logEntryBorderClass,
  type PendingQueueFilter,
} from './helpers'
import { selectPendingConfirmState } from '../../pending-confirm'

const pendingQueueFilter = signal<PendingQueueFilter>({ kind: 'all' })

export function OpsRoomColumn() {
  const roomControlDisclosureRef = useRef<HTMLDetailsElement | null>(null)
  const snapshot = operatorSnapshot.value
  const roomDigest = operatorRoomDigest.value
  const room = snapshot?.namespace ?? {}
  const pendingState = selectPendingConfirmState(snapshot)
  const pendingConfirms = pendingState.items
  const recentMessages = snapshot?.recent_messages ?? []
  const recommendedActions = roomDigest?.recommended_actions ?? []
  const activeRecommendedActions =
    roomDigest?.active_recommended_actions?.length
      ? roomDigest.active_recommended_actions
      : recommendedActions
  const activeSummary = roomDigest?.active_summary
  const judgeRuntime = roomDigest?.operator_judge_runtime ?? snapshot?.operator_judge_runtime
  const guidanceLayer = roomDigest?.active_guidance_layer ?? 'fallback'
  const roomFeed = recentMessages.slice(0, 5)
  const currentActor = actorName.value.trim() || 'unknown'
  const actorOptions = pendingConfirms
    .map(item => item.actor?.trim() ?? '')
    .filter(Boolean)
    .filter((value, index, source) => source.indexOf(value) === index)
    .sort((a, b) => a.localeCompare(b))
  const pendingFilter = pendingQueueFilter.value
  const effectivePendingFilter =
    pendingFilter.kind === 'actor'
    && !actorOptions.includes(pendingFilter.actor)
      ? ({ kind: 'all' } as PendingQueueFilter)
      : pendingFilter
  const filteredPendingConfirms =
    filterPendingConfirmations(pendingConfirms, currentActor, effectivePendingFilter)
  const confirmActionLabels = pendingState.confirm_required_actions
    .map(item => actionTypeLabel(item.action_type))
    .filter((label, index, source) => source.indexOf(label) === index)
  const openRoomControlDisclosure = () => {
    const disclosure = roomControlDisclosureRef.current
    if (disclosure) {
      disclosure.open = true
      disclosure.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
  }

  return html`
    <div class="flex flex-col gap-4 min-w-0">
      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">추천 개입</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-2 ${guidanceLayerTone(guidanceLayer)}">
          <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
            <strong>${guidanceLayerLabel(guidanceLayer)}</strong>
            <span>${judgeRuntime?.keeper_name ?? roomDigest?.judgment_owner ?? 'judge 없음'}</span>
          </div>
          <div class="text-[var(--text-strong)] leading-[1.5]">
            ${activeSummary?.summary ?? '현재 active guidance 요약이 없습니다. fallback queue만 표시합니다.'}
          </div>
          <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
            <span>authoritative ${roomDigest?.authoritative_judgment_available ? 'yes' : 'no'}</span>
            <span>${guidanceFreshnessLabel(activeSummary)}</span>
            ${judgeRuntime?.model_used ? html`<span>${judgeRuntime.model_used}</span>` : null}
          </div>
        </article>
        ${operatorDigestLoading.value && !roomDigest ? html`
          <${LoadingState}>개입 추천을 불러오는 중입니다...<//>
        ` : activeRecommendedActions.length > 0 ? html`
          <div class="flex flex-col gap-2">
            ${activeRecommendedActions.map(item => html`
              <article key=${`${item.action_type}:${item.target_type}:${item.target_id ?? 'namespace'}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)] ${logEntryBorderClass(item.severity)}">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${actionTypeLabel(item.action_type)}</strong>
                  <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                  <span>${deliveryModeLabel(item.confirm_required)}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words max-h-[200px] overflow-auto">${item.reason}</div>
                ${item.suggested_payload ? html`
                  <div class="flex justify-between items-center gap-3 mt-3 max-[880px]:flex-col max-[880px]:items-start">
                    <${ActionButton} variant="ghost" size="lg" onClick=${() => { hydrateRecommendedAction(item); openRoomControlDisclosure() }} disabled=${operatorActionBusy.value}>
                      폼에 채우기
                    <//>
                  </div>
                ` : null}
              </article>
            `)}
          </div>
        ` : html`
          <${EmptyState} message="지금 떠 있는 추천 개입은 없습니다." compact />
        `}
      </section>

      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0 ops-pending-section">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">승인 대기</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">
          전역 승인 대기입니다. <strong>${currentActor}</strong> 이름으로 만든 항목만 실행할 수 있습니다.
        </p>
        ${confirmActionLabels.length > 0 ? html`
          <div class="text-[12px] text-[var(--text-muted)] leading-[1.45]">
            확인 후 실행 액션: ${confirmActionLabels.join(', ')}
          </div>
        ` : null}
        ${pendingConfirms.length > 0 ? html`
          <div class="flex flex-wrap gap-2">
            <${ActionButton}
              variant=${effectivePendingFilter.kind === 'all' ? 'primary' : 'ghost'}
              size="lg"
              onClick=${() => { pendingQueueFilter.value = { kind: 'all' } }}
              disabled=${operatorActionBusy.value}
            >
              전체 ${pendingConfirms.length}
            <//>
            <${ActionButton}
              variant=${effectivePendingFilter.kind === 'mine' ? 'primary' : 'ghost'}
              size="lg"
              onClick=${() => { pendingQueueFilter.value = { kind: 'mine' } }}
              disabled=${operatorActionBusy.value}
            >
              내 것 ${pendingConfirms.filter(item => canManagePendingConfirmation(item, currentActor)).length}
            <//>
            ${actorOptions
              .filter(actor => actor !== currentActor)
              .map(actor => html`
                <${ActionButton}
                  key=${actor}
                  variant=${effectivePendingFilter.kind === 'actor' && effectivePendingFilter.actor === actor ? 'primary' : 'ghost'}
                  size="lg"
                  onClick=${() => { pendingQueueFilter.value = { kind: 'actor', actor } }}
                  disabled=${operatorActionBusy.value}
                >
                  ${actor}
                <//>
              `)}
          </div>
        ` : null}
        ${filteredPendingConfirms.length > 0 ? html`
          <div class="flex flex-col gap-3 max-h-[400px] overflow-y-auto min-w-0 text-[var(--fs-sm)] text-[var(--text-muted)]">
            ${filteredPendingConfirms.map(item => {
              const canManage = canManagePendingConfirmation(item, currentActor)
              return html`
              <article key=${item.confirm_token} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)] min-w-0 flex-shrink-0">
                <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
                  <strong>${actionTypeLabel(item.action_type)}</strong>
                  <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                  ${item.delegated_tool ? html`<span>${item.delegated_tool}</span>` : null}
                  <span>owner ${item.actor ?? 'unknown'}</span>
                </div>
                ${item.preview ? html`<${JsonViewerCard} data=${item.preview} title="Preview" />` : null}
                <div class="mt-2 text-[12px] leading-[1.45] text-[var(--text-muted)]">
                  ${canManage ? '' : '읽기 전용'}
                </div>
                <div class="flex justify-between items-center gap-3 mt-3 max-[880px]:flex-col max-[880px]:items-start">
                  <${ActionButton} variant="primary" size="lg" onClick=${() => { void confirmPending(item.confirm_token) }} disabled=${operatorActionBusy.value || !canManage}>
                    실행
                  <//>
                  <${ActionButton} variant="ghost" size="lg" onClick=${() => { void confirmPending(item.confirm_token, 'deny') }} disabled=${operatorActionBusy.value || !canManage}>
                    거부
                  <//>
                  <span class="text-[var(--text-muted)] text-[var(--fs-xs)] font-mono break-all">${item.confirm_token}</span>
                </div>
              </article>
            `})}
          </div>
        ` : html`
          <${EmptyState}
            message=${pendingConfirms.length > 0
              ? '선택한 필터에는 승인 대기가 없습니다. 전체 목록으로 돌아가서 다시 확인하세요.'
              : '지금 승인 대기는 없습니다.'}
            compact
          />
        `}
      </section>

      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0 ops-lane-panel">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">프로젝트 상태</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">평소에는 추천 개입만 보면 됩니다. 프로젝트 전체에 손댈 때만 아래 고급 제어를 여세요.</p>

        <div class="grid grid-cols-2 gap-3 max-[880px]:grid-cols-1">
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1">
            <span>기본 범위</span>
            <strong>${room.namespace ?? room.namespace_id ?? 'default'}</strong>
          </div>
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1">
            <span>프로젝트</span>
            <strong>${room.project ?? '확인 없음'}</strong>
          </div>
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1">
            <span>클러스터</span>
            <strong>${room.cluster ?? '확인 없음'}</strong>
          </div>
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1 ${room.paused ? 'warn' : 'ok'}">
            <span>상태</span>
            <strong>${room.paused ? '일시정지' : '진행 중'}</strong>
          </div>
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1 ${runtimeJudgeTone(judgeRuntime)}">
            <span>운영 판정기</span>
            <strong>${runtimeJudgeLabel(judgeRuntime)}</strong>
          </div>
        </div>

        <details
          ref=${roomControlDisclosureRef}
          class="ops-control-disclosure mt-0.5 border border-[var(--white-8)] rounded-xl bg-[var(--white-2)]"
          open=${room.paused ? true : undefined}
        >
          <summary class="ops-control-summary list-none cursor-pointer grid gap-1 p-3 px-3.5">
            <span class="text-[var(--ok-20)] text-[var(--fs-2xs)] tracking-[0.08em] uppercase">고급 프로젝트 제어</span>
            <strong>${room.paused ? '지금은 프로젝트 범위가 멈춰 있어 재개 동선이 열려 있습니다.' : '전체 공지, 일시정지, 작업 주입'}</strong>
            <span>${room.paused ? '운영 점검 후 재개하거나 공지를 보내세요.' : '기본 화면은 읽기 중심이고, 실제 전체 변경은 이 안에서만 합니다.'}</span>
          </summary>

          <div class="grid gap-3 px-3.5 pb-3.5 border-t border-[var(--white-8)]">
            <label class="control-label" for="ops-broadcast">전체 공지</label>
            <div class="control-row">
              <input
                id="ops-broadcast"
                class="control-input"
                type="text"
                placeholder="@agent 또는 전체 공지"
                value=${broadcastMessage.value}
                onInput=${(event: Event) => { broadcastMessage.value = (event.target as HTMLInputElement).value }}
                onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter') void submitBroadcast() }}
                disabled=${operatorActionBusy.value}
              />
              <${ActionButton} variant="primary" size="lg" onClick=${() => { void submitBroadcast() }} disabled=${operatorActionBusy.value || broadcastMessage.value.trim() === ''}>
                보내기
              <//>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row items-stretch">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${pauseReason.value}
                onInput=${(event: Event) => { pauseReason.value = (event.target as HTMLInputElement).value }}
                disabled=${operatorActionBusy.value}
              />
              <${ActionButton} variant="ghost" size="lg" onClick=${() => { void submitPause() }} disabled=${operatorActionBusy.value}>
                일시정지
              <//>
              <${ActionButton} variant="ghost" size="lg" onClick=${() => { void submitResume() }} disabled=${operatorActionBusy.value}>
                재개
              <//>
            </div>

            <div class="mt-0.5 text-[var(--text-muted)] text-[var(--fs-xs)] tracking-[0.05em] uppercase">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${taskTitle.value}
              onInput=${(event: Event) => { taskTitle.value = (event.target as HTMLInputElement).value }}
              disabled=${operatorActionBusy.value}
            />
            <${RichComposer}
              value=${taskDescription.value}
              rows=${5}
              placeholder="작업 설명"
              disabled=${operatorActionBusy.value}
              onValueChange=${(next: string) => { taskDescription.value = next }}
              helpText="개입 화면에서도 Markdown, 코드 스니펫, URL 링크 카드를 그대로 기록할 수 있습니다."
              previewLimit=${1}
            />
            <div class="control-row items-stretch">
              <select
                class="control-input min-w-[92px]"
                value=${taskPriority.value}
                onChange=${(event: Event) => { taskPriority.value = (event.target as HTMLSelectElement).value }}
                disabled=${operatorActionBusy.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <${ActionButton} variant="primary" size="lg" onClick=${() => { void submitTaskInject() }} disabled=${operatorActionBusy.value || taskTitle.value.trim() === ''}>
                주입
              <//>
            </div>
          </div>
        </details>
      </section>

      <section class="${CARD_STANDARD} flex flex-col gap-3 min-h-0">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">최근 전체 메시지</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">전체 메시지는 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${roomFeed.length > 0 ? html`
          <div class="flex flex-col gap-3 max-h-[400px] overflow-y-auto min-w-0 text-[var(--fs-sm)] text-[var(--text-muted)]">
            ${roomFeed.map(message => html`
              <article key=${message.seq ?? message.id ?? message.timestamp} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)] min-w-0 flex-shrink-0">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${message.from}</strong>
                  <span>${message.timestamp}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words max-h-[200px] overflow-auto">${formatMessageContent(message.content)}</div>
              </article>
            `)}
          </div>
        ` : html`<${EmptyState} message="최근 전체 메시지가 없습니다." compact />`}
      </section>
    </div>
  `
}
