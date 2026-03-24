// 개입 표면 — 헤더, 우선순위 카드, 열 구성

import { html } from 'htm/preact'
import { CARD_STANDARD } from '../common/card'
import { useEffect } from 'preact/hooks'
import { refreshRoomTruth } from '../../room-truth-store'
import { RoomTruthStrip } from '../common/room-truth-strip'
import { route } from '../../router'
import {
  operatorActionBusy,
  operatorDigestError,
  operatorError,
  operatorLoading,
  operatorRoomDigest,
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
import {
  actorName,
  attentionTone,
  hydratedWorkflowId,
  hydrateOpsWorkflow,
  isKeeperAttention,
  keeperPrioritySummary,
  isSessionAttention,
  keeperPriorityTone,
  normalizeStatus,
  persistActorName,
  selectedSessionId,
  sessionPriorityTone,
  submitResume,
  workflowTargetReady,
  type OpsPriorityCardData,
  type OpsPriorityTone,
} from './helpers'
import { selectPendingConfirmState } from '../../pending-confirm'
import { OpsRoomColumn } from './ops-room-column'
import { OpsSessionColumn } from './ops-session-column'
import { OpsKeeperColumn } from './ops-keeper-column'

export function Ops() {
  const snapshot = operatorSnapshot.value
  const workflowContext = route.value.tab === 'command' ? workflowContextForRoute(route.value) : null
  const roomDigest = operatorRoomDigest.value
  const room = snapshot?.room ?? {}
  const sessions = snapshot?.sessions ?? []
  const keepers = snapshot?.keepers ?? []
  const pendingState = selectPendingConfirmState(snapshot)
  const visiblePendingCount = pendingState.visible_count
  const totalPendingCount = pendingState.total_count
  const hiddenPendingCount = pendingState.hidden_count
  const pendingActorFilter = pendingState.actor_filter
  const selectedSession = sessions.find(session => session.session_id === selectedSessionId.value) ?? sessions[0] ?? null
  const roomAttention = roomDigest?.attention_items ?? []
  const sessionAttention = roomAttention.filter(isSessionAttention)
  const keeperAttention = roomAttention.filter(isKeeperAttention)
  const flaggedSessions = sessions.filter(session => sessionPriorityTone(session) !== 'ok')
  const flaggedKeepers = keepers.filter(keeper => keeperPriorityTone(keeper) !== 'ok')
  const leadingFlaggedKeeper = flaggedKeepers[0] ?? null
  const workflowReady = workflowTargetReady(workflowContext, sessions, keepers)

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
    const sessionId = selectedSession?.session_id ?? null
    void refreshOperatorSessionDigest(sessionId)
  }, [selectedSession?.session_id])

  const priorityCards: OpsPriorityCardData[] = [
    {
      key: 'room',
      label: '방 게이트',
      value: room.paused ? '일시정지' : '열림',
      detail: room.paused
        ? `재개 전환 대기 중${room.pause_reason ? ` · ${room.pause_reason}` : ''}`
        : '지금은 새 액션과 새 작업을 바로 받을 수 있습니다',
      tone: room.paused ? 'bad' : 'ok',
    },
    {
      key: 'confirm',
      label: '확인 대기',
      value: hiddenPendingCount > 0 ? `${visiblePendingCount}/${totalPendingCount}` : visiblePendingCount,
      detail: visiblePendingCount > 0
        ? '미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다'
        : hiddenPendingCount > 0 && pendingActorFilter
          ? `현재 개입 ID(${pendingActorFilter}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${hiddenPendingCount}건이 있습니다`
          : '지금 막혀 있는 확인 대기는 없습니다',
      tone: totalPendingCount > 0 ? 'warn' : 'ok',
    },
    {
      key: 'session',
      label: '세션 리스크',
      value: sessionAttention.length > 0 ? sessionAttention.length : sessions.length,
      detail: sessionAttention.length > 0
        ? sessionAttention[0]?.summary ?? '세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다'
        : sessions.length === 0
          ? '지금 관리 중인 팀 세션이 없습니다'
          : '세션 쪽 긴급 주의 신호는 현재 없습니다',
      tone: sessionAttention.length > 0
        ? attentionTone(sessionAttention)
        : sessions.length === 0
          ? 'warn'
          : flaggedSessions.some(session => normalizeStatus(session.status) === 'paused')
            ? 'bad'
            : flaggedSessions.length > 0
              ? 'warn'
              : 'ok',
    },
    {
      key: 'keeper',
      label: '키퍼 압력',
      value: keeperAttention.length > 0 ? keeperAttention.length : flaggedKeepers.length,
      detail: keeperAttention.length > 0
        ? keeperAttention[0]?.summary ?? '직접 메시지나 상태 점검이 필요한 키퍼가 있습니다'
        : flaggedKeepers.length > 0
          ? `${leadingFlaggedKeeper?.name ?? '키퍼'} · ${leadingFlaggedKeeper ? keeperPrioritySummary(leadingFlaggedKeeper) : '점검 필요'}`
          : '지금은 키퍼 쪽이 비교적 안정적입니다',
      tone: keeperAttention.length > 0
        ? attentionTone(keeperAttention)
        : flaggedKeepers.some(keeper => keeperPriorityTone(keeper) === 'bad')
          ? 'bad'
          : flaggedKeepers.length > 0
            ? 'warn'
            : 'ok',
    },
  ]

  return html`
    <section class="flex flex-col gap-4">
      <div class="${CARD_STANDARD} flex justify-end items-center gap-4 flex-wrap">
        <div class="flex items-end gap-3 flex-wrap max-[880px]:w-full">
          <label class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.06em] font-medium" for="ops-actor">개입 ID</label>
          <input
            id="ops-actor"
            class="w-full px-3 py-2 rounded-lg bg-[var(--white-3)] border border-[var(--card-border)] text-[var(--text-body)] text-[13px] focus:border-[var(--accent)]/50 outline-none ops-actor-input min-w-[180px]"
            type="text"
            value=${actorName.value}
            onInput=${(event: Event) => persistActorName((event.target as HTMLInputElement).value)}
          />
          <button type="button"
            class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
            onClick=${() => {
              void refreshRoomTruth({ force: true })
              void refreshOperatorSnapshot({ force: true })
              void refreshOperatorRoomDigest({ force: true })
              void refreshOperatorSessionDigest(selectedSession?.session_id ?? null, { force: true })
            }}
            disabled=${operatorLoading.value || operatorActionBusy.value}
          >
            ${operatorLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
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

      ${(() => {
        const actions: Array<{ label: string; desc: string; tone: OpsPriorityTone; onClick: () => void }> = []
        if (visiblePendingCount > 0 || hiddenPendingCount > 0) {
          actions.push({
            label: hiddenPendingCount > 0
              ? `확인 대기 ${visiblePendingCount}/${totalPendingCount}건 확인`
              : `확인 대기 ${visiblePendingCount}건 처리`,
            desc: hiddenPendingCount > 0 && pendingActorFilter
              ? `현재 개입 ID(${pendingActorFilter}) 기준으로 보이는 대기열을 먼저 확인합니다`
              : '승인 또는 거부가 필요한 개입이 대기 중입니다',
            tone: visiblePendingCount > 0 ? 'bad' : 'warn',
            onClick: () => {
              const el = document.querySelector('.ops-pending-section')
              el?.scrollIntoView({ behavior: 'smooth' })
            },
          })
        }
        if (room.paused) {
          actions.push({
            label: '방 재개',
            desc: `현재 일시정지 상태${room.pause_reason ? ` (${room.pause_reason})` : ''}`,
            tone: 'warn',
            onClick: () => void submitResume(),
          })
        }
        if (flaggedKeepers.length > 0) {
          const badKeepers = flaggedKeepers.filter(k => keeperPriorityTone(k) === 'bad')
          actions.push({
            label: badKeepers.length > 0 ? `오프라인 키퍼 ${badKeepers.length}개` : `점검이 필요한 키퍼 ${flaggedKeepers.length}개`,
            desc: badKeepers.length > 0
              ? '메시지를 보내거나 상태를 확인하세요'
              : `${leadingFlaggedKeeper?.name ?? '일부 키퍼'} · ${leadingFlaggedKeeper ? keeperPrioritySummary(leadingFlaggedKeeper) : '점검 필요'}`,
            tone: badKeepers.length > 0 ? 'bad' : 'warn',
            onClick: () => {
              const el = document.querySelector('.ops-keeper-section')
              el?.scrollIntoView({ behavior: 'smooth' })
            },
          })
        }
        if (actions.length === 0) return null
        return html`
          <section class="${CARD_STANDARD}">
            <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-3">지금 할 수 있는 것</h3>
            <div class="flex flex-col gap-2">
              ${actions.slice(0, 3).map(action => html`
                <button type="button" class="ops-action-guide-item rounded-lg ${action.tone}" onClick=${action.onClick}>
                  <strong class="font-semibold">${action.label}</strong>
                  <span>${action.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `
      })()}

      <section class="${CARD_STANDARD}">
        <h2 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-1">개입 우선순위</h2>
        <p class="text-[12px] text-[var(--text-muted)] mb-4">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        <div class="ops-priority-grid grid grid-cols-4 gap-3 max-[1200px]:grid-cols-2 max-[880px]:grid-cols-1">
          ${priorityCards.map(card => html`
            <div key=${card.key} class="ops-priority-card p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] grid gap-1.5 ${card.tone}">
              <span class="text-[var(--text-muted)] text-[11px] uppercase tracking-[0.06em] font-medium">${card.label}</span>
              <strong>${card.value}</strong>
              <div class="text-[var(--text-muted)] text-[12px] leading-[1.45]">${card.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench grid gap-4 max-[1200px]:grid-cols-1">
        <${OpsRoomColumn} />
        <${OpsSessionColumn} />
        <${OpsKeeperColumn} />
      </div>
    </section>
  `
}
