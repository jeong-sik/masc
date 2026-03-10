import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { showToast } from './common/toast'
import { PanelSemanticDetails, SurfaceSemanticIntro } from './common/semantic-layer'
import type { OperatorAttentionItem, OperatorKeeperSnapshot, OperatorSessionSnapshot } from '../types'
import { addTaskFromDashboard } from '../api'
import {
  confirmOperatorPendingAction,
  dispatchOperatorAction,
  operatorActionBusy,
  operatorActionLog,
  operatorDigestError,
  operatorDigestLoading,
  operatorError,
  operatorLoading,
  operatorRoomDigest,
  operatorSessionDigest,
  operatorSnapshot,
  refreshOperatorRoomDigest,
  refreshOperatorSessionDigest,
  refreshOperatorSnapshot,
} from '../operator-store'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

function initialActorName(): string {
  const params = new URLSearchParams(window.location.search)
  return (
    params.get('agent')?.trim()
    || params.get('agent_name')?.trim()
    || localStorage.getItem(AGENT_NAME_KEY)?.trim()
    || 'dashboard'
  )
}

const actorName = signal(initialActorName())
const broadcastMessage = signal('')
const pauseReason = signal('운영 점검')
const taskTitle = signal('')
const taskDescription = signal('')
const taskPriority = signal('2')
const selectedSessionId = signal('')
const teamTurnKind = signal<'note' | 'broadcast' | 'task'>('note')
const teamMessage = signal('')
const teamTaskTitle = signal('')
const teamTaskDescription = signal('')
const teamTaskPriority = signal('2')
const teamStopReason = signal('운영자 중지 요청')
const selectedKeeperName = signal('')
const keeperMessage = signal('')

function persistActorName(value: string): void {
  const trimmed = value.trim() || 'dashboard'
  actorName.value = trimmed
  localStorage.setItem(AGENT_NAME_KEY, trimmed)
}

function prettyJson(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function relativeAge(seconds?: number): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return '확인 없음'
  if (seconds < 60) return `${Math.round(seconds)}초 전`
  if (seconds < 3600) return `${Math.round(seconds / 60)}분 전`
  return `${Math.round(seconds / 3600)}시간 전`
}

type OpsPriorityTone = 'ok' | 'warn' | 'bad'

interface OpsPriorityCardData {
  key: string
  label: string
  value: string | number
  detail: string
  tone: OpsPriorityTone
}

function normalizeStatus(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

function sessionPriorityTone(session: OperatorSessionSnapshot): OpsPriorityTone {
  const status = normalizeStatus(session.status)
  if (status === 'paused') return 'bad'
  if (status === '' || status === 'unknown') return 'warn'
  const health = normalizeStatus(session.team_health?.status)
  if (health && health !== 'ok' && health !== 'healthy' && health !== 'green') return 'warn'
  if (status && status !== 'active' && status !== 'running' && status !== 'ended') return 'warn'
  return 'ok'
}

function keeperPriorityTone(keeper: OperatorKeeperSnapshot): OpsPriorityTone {
  const status = normalizeStatus(keeper.status)
  if (status === 'offline' || status === 'inactive' || status === 'error') return 'bad'
  if (status === '' || status === 'unknown') return 'warn'
  if ((keeper.context_ratio ?? 0) >= 0.8) return 'warn'
  if (keeper.context_ratio == null) return 'warn'
  if (keeper.last_turn_ago_s == null) return 'warn'
  if ((keeper.last_turn_ago_s ?? 0) >= 3600) return 'warn'
  return 'ok'
}

function attentionTone(items: OperatorAttentionItem[]): OpsPriorityTone {
  if (items.some(item => normalizeStatus(item.severity) === 'bad')) return 'bad'
  if (items.length > 0) return 'warn'
  return 'ok'
}

function isSessionAttention(item: OperatorAttentionItem): boolean {
  return item.target_type === 'team_session'
}

function isKeeperAttention(item: OperatorAttentionItem): boolean {
  return item.target_type === 'keeper'
}

function actionTypeLabel(value?: string | null): string {
  switch (value) {
    case 'broadcast':
      return '방송'
    case 'room_pause':
      return 'room 일시정지'
    case 'room_resume':
      return 'room 재개'
    case 'team_note':
      return '세션 노트'
    case 'team_broadcast':
      return '세션 방송'
    case 'team_task_inject':
      return '세션 작업 주입'
    case 'team_stop':
      return '세션 중지'
    case 'keeper_message':
      return 'keeper 메시지'
    default:
      return value?.trim() || '액션'
  }
}

function targetTypeLabel(value?: string | null): string {
  switch (value) {
    case 'room':
      return 'room'
    case 'team_session':
      return 'session'
    case 'keeper':
      return 'keeper'
    default:
      return value?.trim() || 'target'
  }
}

function displayStatus(value?: string | null): string {
  const normalized = normalizeStatus(value)
  switch (normalized) {
    case 'running':
    case 'active':
      return '진행 중'
    case 'paused':
      return '일시정지'
    case 'ended':
    case 'done':
      return '종료'
    case 'offline':
      return '오프라인'
    case 'idle':
      return '대기'
    case 'unknown':
    case '':
      return '확인 필요'
    default:
      return value?.trim() || '확인 필요'
  }
}

function deliveryModeLabel(confirmRequired?: boolean): string {
  return confirmRequired ? '확인 후 실행' : '즉시 실행'
}

function sessionActionLabel(value: typeof teamTurnKind.value): string {
  switch (value) {
    case 'note':
      return '노트'
    case 'broadcast':
      return '방송'
    case 'task':
      return '작업'
    default:
      return value
  }
}

async function executeAction(input: {
  action_type: 'broadcast' | 'room_pause' | 'room_resume' | 'team_note' | 'team_broadcast' | 'team_task_inject' | 'team_stop' | 'keeper_message'
  target_type: 'room' | 'team_session' | 'keeper'
  target_id?: string
  payload: Record<string, unknown>
  successMessage: string
}) {
  const actor = actorName.value.trim() || 'dashboard'
  try {
    const result = await dispatchOperatorAction({
      actor,
      action_type: input.action_type,
      target_type: input.target_type,
      target_id: input.target_id,
      payload: input.payload,
    })
    if (result.confirm_required) {
      showToast('확인 대기열에 올렸습니다', 'warning')
    } else {
      showToast(input.successMessage, 'success')
    }
    return result
  } catch (err) {
    const message = err instanceof Error ? err.message : '개입 실행에 실패했습니다'
    showToast(message, 'error')
    return null
  }
}

async function submitBroadcast() {
  const message = broadcastMessage.value.trim()
  if (!message) return
  const result = await executeAction({
    action_type: 'broadcast',
    target_type: 'room',
    payload: { message },
    successMessage: '방송을 보냈습니다',
  })
  if (result) broadcastMessage.value = ''
}

async function submitPause() {
  await executeAction({
    action_type: 'room_pause',
    target_type: 'room',
    payload: { reason: pauseReason.value.trim() || '운영 점검' },
    successMessage: 'room 일시정지를 요청했습니다',
  })
}

async function submitResume() {
  await executeAction({
    action_type: 'room_resume',
    target_type: 'room',
    payload: {},
    successMessage: 'room 재개를 요청했습니다',
  })
}

async function submitTaskInject() {
  const title = taskTitle.value.trim()
  if (!title) return
  try {
    await addTaskFromDashboard(
      title,
      taskDescription.value.trim() || 'Intervene 화면에서 주입',
      Number.parseInt(taskPriority.value, 10) || 2,
    )
    showToast('작업을 backlog에 추가했습니다', 'success')
    taskTitle.value = ''
    taskDescription.value = ''
  } catch (err) {
    const message = err instanceof Error ? err.message : '작업 추가에 실패했습니다'
    showToast(message, 'error')
  }
}

async function submitTeamTurn() {
  const snapshot = operatorSnapshot.value
  const sessionId = selectedSessionId.value || snapshot?.sessions[0]?.session_id || ''
  if (!sessionId) {
    showToast('먼저 세션을 고르세요', 'warning')
    return
  }
  const payload: Record<string, unknown> = {}
  const message = teamMessage.value.trim()
  if (message) payload.message = message
  let actionType: 'team_note' | 'team_broadcast' | 'team_task_inject' = 'team_note'
  if (teamTurnKind.value === 'broadcast') {
    actionType = 'team_broadcast'
  } else if (teamTurnKind.value === 'task') {
    actionType = 'team_task_inject'
  }
  if (teamTurnKind.value === 'task') {
    payload.task_title = teamTaskTitle.value.trim() || '운영자 주입 작업'
    payload.task_description = teamTaskDescription.value.trim() || 'Intervene 화면에서 주입'
    payload.task_priority = Number.parseInt(teamTaskPriority.value, 10) || 2
  }
  const result = await executeAction({
    action_type: actionType,
    target_type: 'team_session',
    target_id: sessionId,
    payload,
    successMessage: '세션 액션을 적용했습니다',
  })
  if (result) {
    teamMessage.value = ''
    if (teamTurnKind.value === 'task') {
      teamTaskTitle.value = ''
      teamTaskDescription.value = ''
    }
  }
}

async function submitTeamStop() {
  const snapshot = operatorSnapshot.value
  const sessionId = selectedSessionId.value || snapshot?.sessions[0]?.session_id || ''
  if (!sessionId) {
    showToast('먼저 세션을 고르세요', 'warning')
    return
  }
  await executeAction({
    action_type: 'team_stop',
    target_type: 'team_session',
    target_id: sessionId,
    payload: { reason: teamStopReason.value.trim() || '운영자 중지 요청' },
    successMessage: '세션 중지를 요청했습니다',
  })
}

async function submitKeeperMessage() {
  const snapshot = operatorSnapshot.value
  const keeperName = selectedKeeperName.value || snapshot?.keepers[0]?.name || ''
  const message = keeperMessage.value.trim()
  if (!keeperName) {
    showToast('먼저 keeper를 고르세요', 'warning')
    return
  }
  if (!message) return
  const result = await executeAction({
    action_type: 'keeper_message',
    target_type: 'keeper',
    target_id: keeperName,
    payload: { message },
    successMessage: `${keeperName}에게 메시지를 보냈습니다`,
  })
  if (result) keeperMessage.value = ''
}

async function confirmPending(confirmToken: string) {
  const actor = actorName.value.trim() || 'dashboard'
  try {
    await confirmOperatorPendingAction(actor, confirmToken)
    showToast('확인 실행을 완료했습니다', 'success')
  } catch (err) {
    const message = err instanceof Error ? err.message : '확인 실행에 실패했습니다'
    showToast(message, 'error')
  }
}

export function Ops() {
  const snapshot = operatorSnapshot.value
  const roomDigest = operatorRoomDigest.value
  const sessionDigest = operatorSessionDigest.value
  const room = snapshot?.room ?? {}
  const sessions = snapshot?.sessions ?? []
  const keepers = snapshot?.keepers ?? []
  const pendingConfirms = snapshot?.pending_confirms ?? []
  const recentMessages = snapshot?.recent_messages ?? []
  const recommendedActions = roomDigest?.recommended_actions ?? []
  const availableActions = snapshot?.available_actions ?? []
  const selectedSession = sessions.find(session => session.session_id === selectedSessionId.value) ?? sessions[0] ?? null
  const selectedKeeper = keepers.find(keeper => keeper.name === selectedKeeperName.value) ?? keepers[0] ?? null
  const roomAttention = roomDigest?.attention_items ?? []
  const sessionAttention = roomAttention.filter(isSessionAttention)
  const keeperAttention = roomAttention.filter(isKeeperAttention)
  const flaggedSessions = sessions.filter(session => sessionPriorityTone(session) !== 'ok')
  const flaggedKeepers = keepers.filter(keeper => keeperPriorityTone(keeper) !== 'ok')
  const roomFeed = recentMessages.slice(0, 5)

  useEffect(() => {
    void refreshOperatorRoomDigest()
  }, [])

  useEffect(() => {
    const sessionId = selectedSession?.session_id ?? null
    void refreshOperatorSessionDigest(sessionId)
  }, [selectedSession?.session_id])

  const priorityCards: OpsPriorityCardData[] = [
    {
      key: 'room',
      label: 'Room 게이트',
      value: room.paused ? '일시정지' : '열림',
      detail: room.paused
        ? `재개 전환 대기 중${room.pause_reason ? ` · ${room.pause_reason}` : ''}`
        : '지금은 새 액션과 새 작업을 바로 받을 수 있습니다',
      tone: room.paused ? 'bad' : 'ok',
    },
    {
      key: 'confirm',
      label: '확인 대기',
      value: pendingConfirms.length,
      detail: pendingConfirms.length > 0
        ? '미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다'
        : '지금 막혀 있는 확인 대기는 없습니다',
      tone: pendingConfirms.length > 0 ? 'warn' : 'ok',
    },
    {
      key: 'session',
      label: '세션 리스크',
      value: sessionAttention.length > 0 ? sessionAttention.length : sessions.length,
      detail: sessionAttention.length > 0
        ? sessionAttention[0]?.summary ?? '세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다'
        : sessions.length === 0
          ? '지금 관리 중인 team session이 없습니다'
          : '세션 쪽 긴급 attention은 현재 없습니다',
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
      label: 'Keeper 압력',
      value: keeperAttention.length > 0 ? keeperAttention.length : flaggedKeepers.length,
      detail: keeperAttention.length > 0
        ? keeperAttention[0]?.summary ?? '직접 메시지나 상태 점검이 필요한 keeper가 있습니다'
        : flaggedKeepers.length > 0
          ? 'stale, offline, telemetry 누락 keeper가 보입니다'
          : '지금은 keeper 쪽이 비교적 안정적입니다',
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
      <${SurfaceSemanticIntro} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
          </div>
          <h2 class="ops-heading">room, session, keeper에 바로 손대는 개입 화면</h2>
          <p class="ops-subheading">
            읽는 화면이 아니라 행동하는 화면입니다. room, session, keeper를 나눠서 보고 바로 개입합니다.
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

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${PanelSemanticDetails} panelId="intervene.priority_cards" compact=${true} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
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
        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Room 개입</div>
              <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
            </div>
            <p class="ops-context-note">전체 room에 영향 주는 액션입니다. 방송, 정지/재개, 작업 주입을 여기서 처리합니다.</p>

            <div class="ops-stat-grid">
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
            </div>

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
            <div class="control-row ops-split-row">
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

            <div class="ops-section-head">작업 주입</div>
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
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
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
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">추천 개입</div>
              <${PanelSemanticDetails} panelId="intervene.recommended_actions" compact=${true} />
            </div>
            <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
            ${operatorDigestLoading.value && !roomDigest ? html`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            ` : recommendedActions.length > 0 ? html`
              <div class="ops-log-list">
                ${recommendedActions.map(item => html`
                  <article key=${`${item.action_type}:${item.target_type}:${item.target_id ?? 'room'}`} class="ops-log-entry ${item.severity}">
                    <div class="ops-log-head">
                      <strong>${actionTypeLabel(item.action_type)}</strong>
                      <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                      <span>${deliveryModeLabel(item.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${item.reason}</div>
                  </article>
                `)}
              </div>
            ` : html`
              <div class="ops-empty">지금 떠 있는 추천 개입은 없습니다.</div>
            `}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">승인 대기</div>
              <${PanelSemanticDetails} panelId="intervene.pending_confirmations" compact=${true} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${pendingConfirms.length > 0 ? html`
              <div class="ops-confirmation-list">
                ${pendingConfirms.map(item => html`
                  <article key=${item.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${actionTypeLabel(item.action_type)}</strong>
                      <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                      <span>${item.delegated_tool ?? '위임 도구 확인 필요'}</span>
                    </div>
                    ${item.preview ? html`<pre class="ops-code-block compact">${prettyJson(item.preview)}</pre>` : null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${() => { void confirmPending(item.confirm_token) }} disabled=${operatorActionBusy.value}>
                        실행
                      </button>
                      <span class="ops-token">${item.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            ` : html`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 Room 메시지</div>
              <${PanelSemanticDetails} panelId="intervene.recommended_actions" compact=${true} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${roomFeed.length > 0 ? html`
              <div class="ops-feed-list">
                ${roomFeed.map(message => html`
                  <article key=${message.seq ?? message.id ?? message.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${message.from}</strong>
                      <span>${message.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${message.content}</div>
                  </article>
                `)}
              </div>
            ` : html`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Session 개입</div>
              <${PanelSemanticDetails} panelId="intervene.session_queue" compact=${true} />
            </div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${sessions.length === 0 ? html`<div class="ops-empty">지금 활성 team session이 없습니다.</div>` : sessions.map(session => html`
                <button
                  key=${session.session_id}
                  class="ops-entity-card ${selectedSession?.session_id === session.session_id ? 'active' : ''}"
                  onClick=${() => { selectedSessionId.value = session.session_id }}
                >
                  <div class="ops-entity-title-row">
                    <strong>${session.session_id}</strong>
                    <span class="status-badge ${session.status ?? 'idle'}">${displayStatus(session.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(session.progress_pct ?? 0)}%</span>
                    <span>${session.done_delta_total ?? 0}건 완료</span>
                    <span>${session.team_health?.status ? displayStatus(String(session.team_health.status)) : '상태 확인 필요'}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 요약</div>
              <${PanelSemanticDetails} panelId="intervene.session_digest" compact=${true} />
            </div>
            <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
            ${selectedSession && sessionDigest ? html`
              <div class="ops-log-list">
                ${sessionDigest.attention_items.length > 0 ? sessionDigest.attention_items.map(item => html`
                  <article key=${`${item.kind}:${item.target_id ?? 'session'}`} class="ops-log-entry ${item.severity}">
                    <div class="ops-log-head">
                      <strong>${item.kind}</strong>
                      <span>${targetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
                    </div>
                    <div class="ops-log-body">${item.summary}</div>
                  </article>
                `) : html`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${sessionDigest.worker_cards.length > 0 ? sessionDigest.worker_cards.map(card => html`
                  <article key=${`${card.actor ?? card.spawn_role ?? 'worker'}:${card.spawn_agent ?? card.runtime_pool ?? 'runtime'}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${card.actor ?? card.spawn_role ?? 'worker'}</strong>
                      <span>${displayStatus(card.status)}</span>
                      <span>${card.spawn_agent ?? card.runtime_pool ?? 'runtime 확인 필요'}</span>
                    </div>
                    <div class="ops-log-body">
                      ${(card.worker_class ?? 'worker')}${card.lane_id ? ` · ${card.lane_id}` : ''}${card.routing_reason ? ` · ${card.routing_reason}` : ''}
                    </div>
                  </article>
                `) : null}
              </div>
            ` : html`
              <div class="ops-empty">세션을 고르면 세부 요약을 불러옵니다.</div>
            `}
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 액션</div>
              <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${selectedSession ? html`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${selectedSession.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${displayStatus(selectedSession.status)}</span>
                  <span>경과: ${selectedSession.elapsed_sec ?? 0}초</span>
                  <span>남은 시간: ${selectedSession.remaining_sec ?? 0}초</span>
                </div>
                ${selectedSession.recent_events && selectedSession.recent_events.length > 0 ? html`
                  <pre class="ops-code-block compact">${prettyJson(selectedSession.recent_events.slice(-3))}</pre>
                ` : null}
              </div>
            ` : html`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${teamTurnKind.value}
                onChange=${(event: Event) => { teamTurnKind.value = (event.target as HTMLSelectElement).value as typeof teamTurnKind.value }}
                disabled=${operatorActionBusy.value || !selectedSession}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${() => { void submitTeamTurn() }} disabled=${operatorActionBusy.value || !selectedSession}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${sessionActionLabel(teamTurnKind.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${teamMessage.value}
              onInput=${(event: Event) => { teamMessage.value = (event.target as HTMLTextAreaElement).value }}
              disabled=${operatorActionBusy.value || !selectedSession}
            ></textarea>

            ${teamTurnKind.value === 'task' ? html`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${teamTaskTitle.value}
                onInput=${(event: Event) => { teamTaskTitle.value = (event.target as HTMLInputElement).value }}
                disabled=${operatorActionBusy.value || !selectedSession}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${teamTaskDescription.value}
                onInput=${(event: Event) => { teamTaskDescription.value = (event.target as HTMLTextAreaElement).value }}
                disabled=${operatorActionBusy.value || !selectedSession}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${teamTaskPriority.value}
                onChange=${(event: Event) => { teamTaskPriority.value = (event.target as HTMLSelectElement).value }}
                disabled=${operatorActionBusy.value || !selectedSession}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
            ` : null}

            <div class="control-row ops-split-row">
              <input
                class="control-input"
                type="text"
                value=${teamStopReason.value}
                onInput=${(event: Event) => { teamStopReason.value = (event.target as HTMLInputElement).value }}
                disabled=${operatorActionBusy.value || !selectedSession}
              />
              <button class="control-btn ghost" onClick=${() => { void submitTeamStop() }} disabled=${operatorActionBusy.value || !selectedSession}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Keeper 개입</div>
              <${PanelSemanticDetails} panelId="intervene.keeper_queue" compact=${true} />
            </div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${keepers.length === 0 ? html`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>` : keepers.map(keeper => html`
                <button
                  key=${keeper.name}
                  class="ops-entity-card ${selectedKeeper?.name === keeper.name ? 'active' : ''}"
                  onClick=${() => { selectedKeeperName.value = keeper.name }}
                >
                  <div class="ops-entity-title-row">
                    <strong>${keeper.name}</strong>
                    <span class="status-badge ${keeper.status ?? 'idle'}">${displayStatus(keeper.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${keeper.model ?? 'model 확인 필요'}</span>
                    <span>${typeof keeper.context_ratio === 'number' ? `${Math.round(keeper.context_ratio * 100)}% ctx` : 'ctx 확인 필요'}</span>
                    <span>${relativeAge(keeper.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Keeper 액션</div>
              <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
            </div>
            <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

            ${selectedKeeper ? html`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${selectedKeeper.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${selectedKeeper.autonomy_level ?? '확인 없음'}</span>
                  <span>세대: ${selectedKeeper.generation ?? 0}</span>
                  <span>활성 목표: ${selectedKeeper.active_goal_ids?.length ?? 0}</span>
                </div>
              </div>
            ` : html`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${keeperMessage.value}
              onInput=${(event: Event) => { keeperMessage.value = (event.target as HTMLTextAreaElement).value }}
              disabled=${operatorActionBusy.value || !selectedKeeper}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${() => { void submitKeeperMessage() }} disabled=${operatorActionBusy.value || !selectedKeeper || keeperMessage.value.trim() === ''}>
                keeper에 보내기
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">가능한 액션 목록</div>
              <${PanelSemanticDetails} panelId="intervene.action_studio" compact=${true} />
            </div>
            <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
            <div class="ops-log-list">
              ${availableActions.length
                ? availableActions.map(action => html`
                    <article key=${`${action.action_type}:${action.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${actionTypeLabel(action.action_type)}</strong>
                        <span>${targetTypeLabel(action.target_type)}</span>
                        <span>${deliveryModeLabel(action.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${action.description ?? '설명이 아직 없습니다.'}</div>
                    </article>
                  `)
                : html`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${PanelSemanticDetails} panelId="intervene.recommended_actions" compact=${true} />
            </div>
            <div class="ops-log-list">
              ${operatorActionLog.value.length === 0 ? html`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              ` : operatorActionLog.value.map(entry => html`
                <article key=${entry.id} class="ops-log-entry ${entry.outcome}">
                  <div class="ops-log-head">
                    <strong>${actionTypeLabel(entry.action_type)}</strong>
                    <span>${entry.target_label}</span>
                    <span>${entry.at}</span>
                  </div>
                  <div class="ops-log-body">${entry.message}</div>
                </article>
              `)}
            </div>
          </section>
        </div>
      </div>
    </section>
  `
}
