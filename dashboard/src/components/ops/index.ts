// 개입 표면 — 헤더, 우선순위 카드, 열 구성

import { html } from 'htm/preact'
import { CARD_STANDARD } from '../common/card'
import { ActionButton } from '../common/button'
import { TextInput } from '../common/input'
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
  workflowTargetReady,
  type OpsPriorityCardData,
} from './helpers'
import { selectPendingConfirmState } from '../../pending-confirm'
import { OpsRoomColumn } from './ops-room-column'
import { OpsSessionColumn } from './ops-session-column'
import { OpsKeeperColumn } from './ops-keeper-column'
import { QuickIntervene } from './quick-intervene'

export function Ops() {
  const snapshot = operatorSnapshot.value
  const workflowContext = route.value.tab === 'command' ? workflowContextForRoute(route.value) : null
  const roomDigest = operatorRoomDigest.value
  const room = snapshot?.room ?? {}
  const sessions = snapshot?.sessions ?? []
  const keepers = snapshot?.keepers ?? []
  const pendingState = selectPendingConfirmState(snapshot)
  const totalPendingCount = pendingState.total_count
  const selectedSession = sessions.find(session => session.session_id === selectedSessionId.value) ?? sessions[0] ?? null
  const currentActor = actorName.value.trim() || 'dashboard'
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
      value: totalPendingCount,
      detail: totalPendingCount > 0
        ? '전역 승인 대기열에 사람 확인이 필요한 개입이 남아 있습니다'
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
              void refreshOperatorSessionDigest(selectedSession?.session_id ?? null, { force: true })
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

      <${QuickIntervene} />

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
