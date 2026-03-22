// Ops — Room column: broadcast, pause/resume, task inject, recommended actions, pending confirmations, room feed

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import {
  operatorActionBusy,
  operatorDigestLoading,
  operatorRoomDigest,
  operatorSnapshot,
} from '../../operator-store'
import {
  actionTypeLabel,
  broadcastMessage,
  confirmPending,
  deliveryModeLabel,
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  guidanceLayerTone,
  hydrateRecommendedAction,
  pauseReason,
  prettyJson,
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
} from './helpers'
import { selectPendingConfirmState } from '../../pending-confirm'

export function OpsRoomColumn() {
  const roomControlDisclosureRef = useRef<HTMLDetailsElement | null>(null)
  const snapshot = operatorSnapshot.value
  const roomDigest = operatorRoomDigest.value
  const room = snapshot?.room ?? {}
  const pendingState = selectPendingConfirmState(snapshot)
  const pendingConfirms = pendingState.items
  const confirmRequiredActions = pendingState.confirm_required_actions
  const actorFilter = pendingState.actor_filter
  const hiddenCount = pendingState.hidden_count
  const hiddenActors = pendingState.hidden_actors
  const recentMessages = snapshot?.recent_messages ?? []
  const recommendedActions = roomDigest?.recommended_actions ?? []
  const activeRecommendedActions =
    roomDigest?.active_recommended_actions?.length
      ? roomDigest.active_recommended_actions
      : recommendedActions
  const activeSummary = roomDigest?.active_summary
  const residentRuntime = roomDigest?.resident_judge_runtime ?? snapshot?.resident_judge_runtime
  const guidanceLayer = roomDigest?.active_guidance_layer ?? 'fallback'
  const roomFeed = recentMessages.slice(0, 5)
  const openRoomControlDisclosure = () => {
    const disclosure = roomControlDisclosureRef.current
    if (disclosure) {
      disclosure.open = true
      disclosure.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
  }

  return html`
    <div class="flex flex-col gap-4 min-w-0">
      <section class="card flex flex-col gap-3 min-h-0">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
        </div>
        <p class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45]">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${guidanceLayerTone(guidanceLayer)}">
          <div class="flex flex-wrap gap-2 text-text-muted text-[var(--fs-xs)]">
            <strong>${guidanceLayerLabel(guidanceLayer)}</strong>
            <span>${residentRuntime?.keeper_name ?? roomDigest?.judgment_owner ?? 'judge 없음'}</span>
          </div>
          <div class="text-text-strong leading-[1.5]">
            ${activeSummary?.summary ?? '현재 active guidance 요약이 없습니다. fallback queue만 표시합니다.'}
          </div>
          <div class="flex flex-wrap gap-2 text-text-muted text-[var(--fs-xs)]">
            <span>authoritative ${roomDigest?.authoritative_judgment_available ? 'yes' : 'no'}</span>
            <span>${guidanceFreshnessLabel(activeSummary)}</span>
            ${residentRuntime?.model_used ? html`<span>${residentRuntime.model_used}</span>` : null}
          </div>
        </article>
        ${operatorDigestLoading.value && !roomDigest ? html`
          <div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">개입 추천을 불러오는 중입니다...</div>
        ` : activeRecommendedActions.length > 0 ? html`
          <div class="flex flex-col gap-2">
            ${activeRecommendedActions.map(item => html`
              <article key=${`${item.action_type}:${item.target_type}:${item.target_id ?? 'room'}`} class="ops-log-entry ${item.severity}">
                <div class="text-[var(--fs-xs)] text-text-muted mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${actionTypeLabel(item.action_type)}</strong>
                  <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                  <span>${deliveryModeLabel(item.confirm_required)}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${item.reason}</div>
                ${item.suggested_payload ? html`
                  <div class="flex justify-between items-center gap-3 mt-2.5 max-[880px]:flex-col max-[880px]:items-start">
                    <button class="control-btn ghost" onClick=${() => { hydrateRecommendedAction(item); openRoomControlDisclosure() }} disabled=${operatorActionBusy.value}>
                      폼에 채우기
                    </button>
                  </div>
                ` : null}
              </article>
            `)}
          </div>
        ` : html`
          <div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">지금 떠 있는 추천 개입은 없습니다.</div>
        `}
      </section>

      <section class="card flex flex-col gap-3 min-h-0 ops-pending-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
        </div>
        <p class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45]">
          ${actorFilter
            ? `현재 actor ${actorFilter} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`
            : '승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.'}
        </p>
        ${confirmRequiredActions.length > 0 ? html`
          <div class="flex flex-col gap-2">
            ${confirmRequiredActions.map(item => html`
              <article key=${`${item.action_type}:${item.target_type}`} class="ops-log-entry">
                <div class="text-[var(--fs-xs)] text-text-muted mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${actionTypeLabel(item.action_type)}</strong>
                  <span>${targetTypeLabel(item.target_type)}</span>
                  <span>${deliveryModeLabel(item.confirm_required)}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${item.description ?? '설명 확인 필요'}</div>
              </article>
            `)}
          </div>
        ` : null}
        ${pendingConfirms.length > 0 ? html`
          <div class="flex items-center justify-between gap-2.5 text-[var(--fs-sm)] text-text-muted">
            ${pendingConfirms.map(item => html`
              <article key=${item.confirm_token} class="p-3 rounded-[10px] bg-[var(--white-3)] border border-solid border-[var(--white-8)]">
                <div class="flex flex-wrap gap-2 text-text-muted text-[var(--fs-xs)]">
                  <strong>${actionTypeLabel(item.action_type)}</strong>
                  <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                  <span>${item.delegated_tool ?? '위임 도구 확인 필요'}</span>
                </div>
                ${item.preview ? html`<pre class="ops-code-block compact">${prettyJson(item.preview)}</pre>` : null}
                <div class="flex justify-between items-center gap-3 mt-2.5 max-[880px]:flex-col max-[880px]:items-start">
                  <button class="control-btn" onClick=${() => { void confirmPending(item.confirm_token) }} disabled=${operatorActionBusy.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${() => { void confirmPending(item.confirm_token, 'deny') }} disabled=${operatorActionBusy.value}>
                    거부
                  </button>
                  <span class="text-text-muted text-[var(--fs-xs)] font-mono break-all">${item.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        ` : html`
          <div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">
            ${hiddenCount > 0 && actorFilter
              ? `현재 선택한 actor(${actorFilter}) 기준 승인 대기는 0건입니다. 다른 actor 대기 ${hiddenCount}건${hiddenActors.length > 0 ? ` · ${hiddenActors.join(', ')}` : ''}`
              : '지금 승인 대기는 없습니다. 위 목록의 preview-confirm 액션을 먼저 만들어야 여기에 쌓입니다.'}
          </div>
        `}
      </section>

      <section class="card flex flex-col gap-3 min-h-0 ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 상태</div>
        </div>
        <p class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45]">평소에는 추천 개입만 보면 됩니다. room 전체를 건드릴 때만 아래 고급 제어를 여세요.</p>

        <div class="grid grid-cols-2 gap-2.5 max-[880px]:grid-cols-1">
          <div class="ops-stat">
            <span>Room</span>
            <strong>${room.current_room ?? room.room_id ?? 'default'}</strong>
          </div>
          <div class="ops-stat">
            <span>프로젝트</span>
            <strong>${room.project ?? '확인 없음'}</strong>
          </div>
          <div class="ops-stat">
            <span>클러스터</span>
            <strong>${room.cluster ?? '확인 없음'}</strong>
          </div>
          <div class="ops-stat ${room.paused ? 'warn' : 'ok'}">
            <span>상태</span>
            <strong>${room.paused ? '일시정지' : '진행 중'}</strong>
          </div>
          <div class="ops-stat ${runtimeJudgeTone(residentRuntime)}">
            <span>Resident Judge</span>
            <strong>${runtimeJudgeLabel(residentRuntime)}</strong>
          </div>
        </div>

        <details
          ref=${roomControlDisclosureRef}
          class="ops-control-disclosure"
          open=${room.paused ? true : undefined}
        >
          <summary class="ops-control-summary">
            <span class="text-[#9fe6b5] text-[var(--fs-2xs)] tracking-[0.08em] uppercase">고급 room 제어</span>
            <strong>${room.paused ? '지금은 room이 멈춰 있어 재개 동선이 열려 있습니다.' : '방송 · 일시정지/재개 · 작업 주입'}</strong>
            <span>${room.paused ? '운영 점검 후 재개하거나 공지를 보내세요.' : 'room 전체에 영향 주는 액션만 이 안에 넣었습니다.'}</span>
          </summary>

          <div class="ops-control-body">
            <label class="control-label" for="ops-broadcast">Room 방송</label>
            <div class="control-row">
              <input
                id="ops-broadcast"
                class="control-input"
                type="text"
                placeholder="@agent 또는 room 전체 공지"
                value=${broadcastMessage.value}
                onInput=${(event: Event) => { broadcastMessage.value = (event.target as HTMLInputElement).value }}
                onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter') void submitBroadcast() }}
                disabled=${operatorActionBusy.value}
              />
              <button class="control-btn" onClick=${() => { void submitBroadcast() }} disabled=${operatorActionBusy.value || broadcastMessage.value.trim() === ''}>
                보내기
              </button>
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
              <button class="control-btn ghost" onClick=${() => { void submitPause() }} disabled=${operatorActionBusy.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${() => { void submitResume() }} disabled=${operatorActionBusy.value}>
                재개
              </button>
            </div>

            <div class="mt-0.5 text-text-muted text-[var(--fs-xs)] tracking-[0.05em] uppercase">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${taskTitle.value}
              onInput=${(event: Event) => { taskTitle.value = (event.target as HTMLInputElement).value }}
              disabled=${operatorActionBusy.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${taskDescription.value}
              onInput=${(event: Event) => { taskDescription.value = (event.target as HTMLTextAreaElement).value }}
              disabled=${operatorActionBusy.value}
            ></textarea>
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
              <button class="control-btn" onClick=${() => { void submitTaskInject() }} disabled=${operatorActionBusy.value || taskTitle.value.trim() === ''}>
                주입
              </button>
            </div>
          </div>
        </details>
      </section>

      <section class="card flex flex-col gap-3 min-h-0">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
        </div>
        <p class="-mt-0.5 text-text-muted text-[var(--fs-sm)] leading-[1.45]">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${roomFeed.length > 0 ? html`
          <div class="flex items-center justify-between gap-2.5 text-[var(--fs-sm)] text-text-muted">
            ${roomFeed.map(message => html`
              <article key=${message.seq ?? message.id ?? message.timestamp} class="p-3 rounded-[10px] bg-[var(--white-3)] border border-solid border-[var(--white-8)]">
                <div class="text-[var(--fs-xs)] text-text-muted mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${message.from}</strong>
                  <span>${message.timestamp}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${formatMessageContent(message.content)}</div>
              </article>
            `)}
          </div>
        ` : html`<div class="p-3 rounded-[10px] border border-dashed border-[var(--white-12)] text-text-muted text-[var(--fs-base)]">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `
}
