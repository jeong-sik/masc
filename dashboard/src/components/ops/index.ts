// 개입 표면 — 헤더, 우선순위 카드, 열 구성

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { refreshRoomTruth } from '../../room-truth-store'
import { RoomTruthStrip } from '../common/room-truth-strip'
import { PanelSemanticDetails } from '../common/semantic-layer'
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
  const workflowContext = route.value.tab === 'control' ? workflowContextForRoute(route.value) : null
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
  const workflowReady = workflowTargetReady(workflowContext, sessions, keepers)

  useEffect(() => {
    void refreshOperatorRoomDigest()
  }, [])

  useEffect(() => {
    if (route.value.tab !== 'control') {
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
          ? '오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다'
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
    <section class="ops-view">
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">개입</div>
            <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
          </div>
          <h2 class="ops-heading">방, 세션, 키퍼를 바로 조정하는 화면</h2>
          <p class="ops-subheading">
            읽는 화면이 아니라 행동하는 화면입니다. 방, 세션, 키퍼를 나눠 보고 바로 개입합니다.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">개입 ID</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${actorName.value}
            onInput=${(event: Event) => persistActorName((event.target as HTMLInputElement).value)}
          />
            <button
              class="control-btn ghost"
              onClick=${() => {
                void refreshRoomTruth()
                void refreshOperatorSnapshot()
                void refreshOperatorRoomDigest()
                void refreshOperatorSessionDigest(selectedSession?.session_id ?? null)
            }}
            disabled=${operatorLoading.value || operatorActionBusy.value}
          >
            ${operatorLoading.value ? '새로고침 중...' : '새로고침'}
          </button>
        </div>
      </div>

      ${operatorError.value ? html`<section class="ops-banner error">${operatorError.value}</section>` : null}
      ${operatorDigestError.value ? html`<section class="ops-banner error">${operatorDigestError.value}</section>` : null}
      <${RoomTruthStrip} />
      ${workflowContext ? html`
        <section class="ops-banner ${workflowReady ? 'info' : 'warn'} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${workflowContext.source_label}</strong>
            <span>${workflowActionLabel(workflowContext.action_type)}</span>
            <span>${workflowTargetLabel(workflowContext)}</span>
          </div>
          <div class="ops-handoff-body">${workflowContext.summary}</div>
          ${workflowContext.payload_preview ? html`<div class="ops-handoff-preview">${workflowContext.payload_preview}</div>` : null}
          <div class="ops-handoff-meta">
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
            desc: badKeepers.length > 0 ? '메시지를 보내거나 상태를 확인하세요' : '오래됐거나 텔레메트리가 비어 있습니다',
            tone: badKeepers.length > 0 ? 'bad' : 'warn',
            onClick: () => {
              const el = document.querySelector('.ops-keeper-section')
              el?.scrollIntoView({ behavior: 'smooth' })
            },
          })
        }
        if (actions.length === 0) return null
        return html`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${actions.slice(0, 3).map(action => html`
                <button class="ops-action-guide-item ${action.tone}" onClick=${action.onClick}>
                  <strong>${action.label}</strong>
                  <span>${action.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `
      })()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${PanelSemanticDetails} panelId="intervene.priority_cards" compact=${true} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${priorityCards.map(card => html`
            <div key=${card.key} class="ops-priority-card ${card.tone}">
              <span class="ops-priority-label">${card.label}</span>
              <strong>${card.value}</strong>
              <div class="ops-priority-detail">${card.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${OpsRoomColumn} />
        <${OpsSessionColumn} />
        <${OpsKeeperColumn} />
      </div>
    </section>
  `
}
