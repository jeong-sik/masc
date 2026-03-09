import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { showToast } from './common/toast'
import type { OperatorAttentionItem, OperatorKeeperSnapshot, OperatorSessionSnapshot } from '../types'
import {
  confirmOperatorPendingAction,
  dispatchOperatorAction,
  operatorActionBusy,
  operatorDigestError,
  operatorDigestLoading,
  operatorActionLog,
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
const pauseReason = signal('Operator pause')
const taskTitle = signal('')
const taskDescription = signal('')
const taskPriority = signal('2')
const selectedSessionId = signal('')
const teamTurnKind = signal<'note' | 'broadcast' | 'task' | 'checkpoint'>('note')
const teamMessage = signal('')
const teamTaskTitle = signal('')
const teamTaskDescription = signal('')
const teamTaskPriority = signal('2')
const teamStopReason = signal('Operator stop request')
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
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return 'n/a'
  if (seconds < 60) return `${Math.round(seconds)}s ago`
  if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`
  return `${Math.round(seconds / 3600)}h ago`
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

async function executeAction(input: {
  action_type: 'broadcast' | 'room_pause' | 'room_resume' | 'team_turn' | 'team_stop' | 'keeper_msg' | 'task_inject'
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
      showToast('Confirmation queued', 'warning')
    } else {
      showToast(input.successMessage, 'success')
    }
    return result
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Operator action failed'
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
    successMessage: 'Broadcast sent',
  })
  if (result) broadcastMessage.value = ''
}

async function submitPause() {
  await executeAction({
    action_type: 'room_pause',
    target_type: 'room',
    payload: { reason: pauseReason.value.trim() || 'Operator pause' },
    successMessage: 'Pause request sent',
  })
}

async function submitResume() {
  await executeAction({
    action_type: 'room_resume',
    target_type: 'room',
    payload: {},
    successMessage: 'Room resumed',
  })
}

async function submitTaskInject() {
  const title = taskTitle.value.trim()
  if (!title) return
  const result = await executeAction({
    action_type: 'task_inject',
    target_type: 'room',
    payload: {
      title,
      description: taskDescription.value.trim() || 'Injected from Ops tab',
      priority: Number.parseInt(taskPriority.value, 10) || 2,
    },
    successMessage: 'Task injection submitted',
  })
  if (result) {
    taskTitle.value = ''
    taskDescription.value = ''
  }
}

async function submitTeamTurn() {
  const snapshot = operatorSnapshot.value
  const sessionId = selectedSessionId.value || snapshot?.sessions[0]?.session_id || ''
  if (!sessionId) {
    showToast('Select a team session first', 'warning')
    return
  }
  const payload: Record<string, unknown> = {
    turn_kind: teamTurnKind.value,
  }
  const message = teamMessage.value.trim()
  if (message) payload.message = message
  if (teamTurnKind.value === 'task') {
    payload.task_title = teamTaskTitle.value.trim() || 'Operator injected task'
    payload.task_description = teamTaskDescription.value.trim() || 'Injected from Ops tab'
    payload.task_priority = Number.parseInt(teamTaskPriority.value, 10) || 2
  }
  const result = await executeAction({
    action_type: 'team_turn',
    target_type: 'team_session',
    target_id: sessionId,
    payload,
    successMessage: 'Team session updated',
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
    showToast('Select a team session first', 'warning')
    return
  }
  await executeAction({
    action_type: 'team_stop',
    target_type: 'team_session',
    target_id: sessionId,
    payload: { reason: teamStopReason.value.trim() || 'Operator stop request' },
    successMessage: 'Team stop requested',
  })
}

async function submitKeeperMessage() {
  const snapshot = operatorSnapshot.value
  const keeperName = selectedKeeperName.value || snapshot?.keepers[0]?.name || ''
  const message = keeperMessage.value.trim()
  if (!keeperName) {
    showToast('Select a keeper first', 'warning')
    return
  }
  if (!message) return
  const result = await executeAction({
    action_type: 'keeper_msg',
    target_type: 'keeper',
    target_id: keeperName,
    payload: { message },
    successMessage: `Message sent to ${keeperName}`,
  })
  if (result) keeperMessage.value = ''
}

async function confirmPending(confirmToken: string) {
  const actor = actorName.value.trim() || 'dashboard'
  try {
    await confirmOperatorPendingAction(actor, confirmToken)
    showToast('Confirmation executed', 'success')
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Confirmation failed'
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
      label: 'Room Gate',
      value: room.paused ? 'Paused' : 'Open',
      detail: room.paused
        ? `Resume gate armed${room.pause_reason ? ` · ${room.pause_reason}` : ''}`
        : 'Commands are live and the room is accepting new work',
      tone: room.paused ? 'bad' : 'ok',
    },
    {
      key: 'confirm',
      label: 'Pending Confirm',
      value: pendingConfirms.length,
      detail: pendingConfirms.length > 0
        ? 'Previewed operator actions are waiting for confirmation'
        : 'No confirm gates are currently blocking execution',
      tone: pendingConfirms.length > 0 ? 'warn' : 'ok',
    },
    {
      key: 'session',
      label: 'Session Risk',
      value: sessionAttention.length > 0 ? sessionAttention.length : sessions.length,
      detail: sessionAttention.length > 0
        ? sessionAttention[0]?.summary ?? 'Team sessions need steering, stop, or checkpoint attention'
        : sessions.length === 0
          ? 'No supervised team session is active right now'
          : 'No session-level attention items are currently active',
      tone: sessionAttention.length > 0 ? attentionTone(sessionAttention) : sessions.length === 0 ? 'warn' : flaggedSessions.some(session => normalizeStatus(session.status) === 'paused') ? 'bad' : flaggedSessions.length > 0 ? 'warn' : 'ok',
    },
    {
      key: 'keeper',
      label: 'Keeper Pressure',
      value: keeperAttention.length > 0 ? keeperAttention.length : flaggedKeepers.length,
      detail: keeperAttention.length > 0
        ? keeperAttention[0]?.summary ?? 'At least one keeper needs direct intervention'
        : flaggedKeepers.length > 0
          ? 'At least one keeper is stale, offline, or missing telemetry'
          : 'Keepers are available for direct intervention',
      tone: keeperAttention.length > 0 ? attentionTone(keeperAttention) : flaggedKeepers.some(keeper => keeperPriorityTone(keeper) === 'bad') ? 'bad' : flaggedKeepers.length > 0 ? 'warn' : 'ok',
    },
  ]

  return html`
    <section class="ops-view">
      <div class="ops-header card">
      <div>
          <div class="card-title">Intervene</div>
          <h2 class="ops-heading">room, session, keeper를 위한 개입 워크스페이스</h2>
          <p class="ops-subheading">
            즉시 실행 가능한 액션만 모읍니다. 위험한 변경은 confirmation token 뒤에 둡니다.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">Actor</label>
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
            ${operatorLoading.value ? 'Refreshing...' : 'Refresh'}
          </button>
        </div>
      </div>

      ${operatorError.value ? html`
        <section class="ops-banner error">${operatorError.value}</section>
      ` : null}
      ${operatorDigestError.value ? html`
        <section class="ops-banner error">${operatorDigestError.value}</section>
      ` : null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <p class="monitor-subheadline">지금 어디를 먼저 손대야 하는지, 그리고 어떤 표면으로 내려가야 하는지를 여기서 먼저 판단합니다.</p>
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

      <section class="card ops-panel">
        <div class="card-title">Recommended Actions</div>
        <p class="ops-context-note">Digest-backed recommendations are the smallest next interventions the backend currently suggests.</p>
        ${operatorDigestLoading.value && !roomDigest ? html`
          <div class="ops-empty">Loading operator digest…</div>
        ` : roomDigest && roomDigest.recommended_actions.length > 0 ? html`
          <div class="ops-log-list">
            ${roomDigest.recommended_actions.map(item => html`
              <article key=${`${item.action_type}:${item.target_type}:${item.target_id ?? 'room'}`} class="ops-log-entry ${item.severity}">
                <div class="ops-log-head">
                  <strong>${item.action_type}</strong>
                  <span>${item.target_type}${item.target_id ? `:${item.target_id}` : ''}</span>
                  <span>${item.confirm_required ? 'confirm' : 'direct'}</span>
                </div>
                <div class="ops-log-body">${item.reason}</div>
              </article>
            `)}
          </div>
        ` : html`
          <div class="ops-empty">No digest recommendations are active right now.</div>
        `}
      </section>

      ${pendingConfirms.length > 0 ? html`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${pendingConfirms.map(item => html`
              <article key=${item.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${item.action_type ?? 'unknown'}</strong>
                  <span>${item.target_type ?? 'target'}${item.target_id ? `:${item.target_id}` : ''}</span>
                  <span>${item.delegated_tool ?? 'delegated tool pending'}</span>
                </div>
                ${item.preview ? html`<pre class="ops-code-block">${prettyJson(item.preview)}</pre>` : null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${() => { void confirmPending(item.confirm_token) }} disabled=${operatorActionBusy.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${item.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        </section>
      ` : null}

      <div class="ops-workbench">
        <div class="ops-column">
          <section class="card ops-panel">
            <div class="card-title">Priority Queue</div>
            ${pendingConfirms.length > 0 ? html`
              <div class="ops-confirmation-list">
                ${pendingConfirms.map(item => html`
                  <article key=${item.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${item.action_type ?? 'unknown'}</strong>
                      <span>${item.target_type ?? 'target'}${item.target_id ? `:${item.target_id}` : ''}</span>
                      <span>${item.delegated_tool ?? 'delegated tool pending'}</span>
                    </div>
                    ${item.preview ? html`<pre class="ops-code-block compact">${prettyJson(item.preview)}</pre>` : null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${() => { void confirmPending(item.confirm_token) }} disabled=${operatorActionBusy.value}>
                        Confirm
                      </button>
                      <span class="ops-token">${item.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            ` : html`<div class="ops-empty">No pending confirmations.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title">Operator Log</div>
            <div class="ops-log-list">
              ${operatorActionLog.value.length === 0 ? html`
                <div class="ops-empty">No operator actions in this session yet.</div>
              ` : operatorActionLog.value.map(entry => html`
                <article key=${entry.id} class="ops-log-entry ${entry.outcome}">
                  <div class="ops-log-head">
                    <strong>${entry.action_type}</strong>
                    <span>${entry.target_label}</span>
                    <span>${entry.at}</span>
                  </div>
                  <div class="ops-log-body">${entry.message}</div>
                </article>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Room Feed</div>
            <p class="ops-context-note">Recent chatter stays available for operator context, but it is secondary to the intervention queue.</p>
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
            ` : html`<div class="ops-empty">No recent room messages.</div>`}
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel">
            <div class="card-title">Session Queue</div>
            <p class="ops-context-note">Select the session that needs steering. This queue should answer which run is hot, paused, or drifting.</p>
            <div class="ops-entity-list">
              ${sessions.length === 0 ? html`<div class="ops-empty">No team sessions available.</div>` : sessions.map(session => html`
                <button
                  key=${session.session_id}
                  class="ops-entity-card ${selectedSession?.session_id === session.session_id ? 'active' : ''}"
                  onClick=${() => { selectedSessionId.value = session.session_id }}
                >
                  <div class="ops-entity-title-row">
                    <strong>${session.session_id}</strong>
                    <span class="status-badge ${session.status ?? 'idle'}">${session.status ?? 'unknown'}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(session.progress_pct ?? 0)}%</span>
                    <span>${session.done_delta_total ?? 0} done</span>
                    <span>${session.team_health?.status ? String(session.team_health.status) : 'health n/a'}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Session Digest</div>
            <p class="ops-context-note">Worker cards and attention items come from operator digest, not the lighter snapshot.</p>
            ${selectedSession && sessionDigest ? html`
              <div class="ops-log-list">
                ${sessionDigest.attention_items.length > 0 ? sessionDigest.attention_items.map(item => html`
                  <article key=${`${item.kind}:${item.target_id ?? 'session'}`} class="ops-log-entry ${item.severity}">
                    <div class="ops-log-head">
                      <strong>${item.kind}</strong>
                      <span>${item.target_type}${item.target_id ? `:${item.target_id}` : ''}</span>
                    </div>
                    <div class="ops-log-body">${item.summary}</div>
                  </article>
                `) : html`<div class="ops-empty">No session-specific attention items.</div>`}
                ${sessionDigest.worker_cards.length > 0 ? sessionDigest.worker_cards.map(card => html`
                  <article key=${`${card.actor ?? card.spawn_role ?? 'worker'}:${card.spawn_agent ?? 'runtime'}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${card.actor ?? card.spawn_role ?? 'worker'}</strong>
                      <span>${card.status}</span>
                      <span>${card.spawn_agent ?? card.runtime_pool ?? 'runtime n/a'}</span>
                    </div>
                    <div class="ops-log-body">
                      ${(card.worker_class ?? 'worker')}${card.lane_id ? ` · ${card.lane_id}` : ''}${card.routing_reason ? ` · ${card.routing_reason}` : ''}
                    </div>
                  </article>
                `) : null}
              </div>
            ` : html`
              <div class="ops-empty">Select a team session to load digest-backed worker cards.</div>
            `}
          </section>

          <section class="card ops-panel">
            <div class="card-title">Keeper Queue</div>
            <p class="ops-context-note">Keepers are long-lived operators. Pick one when you need recovery, course correction, or a direct probe.</p>
            <div class="ops-entity-list">
              ${keepers.length === 0 ? html`<div class="ops-empty">No keepers available.</div>` : keepers.map(keeper => html`
                <button
                  key=${keeper.name}
                  class="ops-entity-card ${selectedKeeper?.name === keeper.name ? 'active' : ''}"
                  onClick=${() => { selectedKeeperName.value = keeper.name }}
                >
                  <div class="ops-entity-title-row">
                    <strong>${keeper.name}</strong>
                    <span class="status-badge ${keeper.status ?? 'idle'}">${keeper.status ?? 'unknown'}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${keeper.model ?? 'model n/a'}</span>
                    <span>${typeof keeper.context_ratio === 'number' ? `${Math.round(keeper.context_ratio * 100)}% ctx` : 'ctx n/a'}</span>
                    <span>${relativeAge(keeper.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Available Actions</div>
            <p class="ops-context-note">These are the actions the backend currently advertises, even if they are not all wired into inline controls yet.</p>
            <div class="ops-log-list">
              ${snapshot?.available_actions?.length
                ? snapshot.available_actions.map(action => html`
                    <article key=${`${action.action_type}:${action.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${action.action_type}</strong>
                        <span>${action.target_type}</span>
                        <span>${action.confirm_required ? 'confirm' : 'direct'}</span>
                      </div>
                      <div class="ops-log-body">${action.description ?? 'No description'}</div>
                    </article>
                  `)
                : html`<div class="ops-empty">No available action descriptors.</div>`}
            </div>
          </section>
        </div>

        <div class="ops-column ops-studio-column">
          <section class="card ops-panel ops-studio-panel">
            <div class="card-title">Action Studio</div>
            <p class="ops-context-note">All write controls are centralized here. Room actions stay global; session and keeper actions always target the currently selected entity.</p>

            <div class="ops-studio-group">
              <div class="ops-section-head">Room Gate</div>
              <div class="ops-stat-grid">
                <div class="ops-stat">
                  <span>Room</span>
                  <strong>${room.current_room ?? room.room_id ?? 'default'}</strong>
                </div>
                <div class="ops-stat">
                  <span>Project</span>
                  <strong>${room.project ?? 'n/a'}</strong>
                </div>
                <div class="ops-stat">
                  <span>Cluster</span>
                  <strong>${room.cluster ?? 'n/a'}</strong>
                </div>
                <div class="ops-stat ${room.paused ? 'warn' : 'ok'}">
                  <span>Status</span>
                  <strong>${room.paused ? 'Paused' : 'Running'}</strong>
                </div>
              </div>

              <label class="control-label" for="ops-broadcast">Room Broadcast</label>
              <div class="control-row">
                <input
                  id="ops-broadcast"
                  class="control-input"
                  type="text"
                  placeholder="@agent or room-wide operator update"
                  value=${broadcastMessage.value}
                  onInput=${(event: Event) => { broadcastMessage.value = (event.target as HTMLInputElement).value }}
                  onKeyDown=${(event: KeyboardEvent) => { if (event.key === 'Enter') void submitBroadcast() }}
                  disabled=${operatorActionBusy.value}
                />
                <button class="control-btn" onClick=${() => { void submitBroadcast() }} disabled=${operatorActionBusy.value || broadcastMessage.value.trim() === ''}>
                  Send
                </button>
              </div>

              <label class="control-label" for="ops-pause-reason">Pause or Resume</label>
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
                  Pause
                </button>
                <button class="control-btn ghost" onClick=${() => { void submitResume() }} disabled=${operatorActionBusy.value}>
                  Resume
                </button>
              </div>

              <div class="ops-section-head">Inject Work</div>
              <input
                class="control-input"
                type="text"
                placeholder="Task title"
                value=${taskTitle.value}
                onInput=${(event: Event) => { taskTitle.value = (event.target as HTMLInputElement).value }}
                disabled=${operatorActionBusy.value}
              />
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Task description"
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
                  Inject
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Session</div>
              ${selectedSession ? html`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${selectedSession.session_id}</div>
                  <div class="ops-detail-meta">
                    <span>Status: ${selectedSession.status ?? 'unknown'}</span>
                    <span>Elapsed: ${selectedSession.elapsed_sec ?? 0}s</span>
                    <span>Remaining: ${selectedSession.remaining_sec ?? 0}s</span>
                  </div>
                  ${selectedSession.recent_events && selectedSession.recent_events.length > 0 ? html`
                    <pre class="ops-code-block compact">${prettyJson(selectedSession.recent_events.slice(-3))}</pre>
                  ` : null}
                </div>
              ` : html`<div class="ops-empty">Select a team session to edit notes, inject tasks, or stop the run.</div>`}

              <label class="control-label" for="ops-turn-kind">Session Action</label>
              <div class="control-row ops-split-row">
                <select
                  id="ops-turn-kind"
                  class="control-input ops-select"
                  value=${teamTurnKind.value}
                  onChange=${(event: Event) => { teamTurnKind.value = (event.target as HTMLSelectElement).value as typeof teamTurnKind.value }}
                  disabled=${operatorActionBusy.value || !selectedSession}
                >
                  <option value="note">Note</option>
                  <option value="broadcast">Broadcast</option>
                  <option value="task">Task</option>
                  <option value="checkpoint">Checkpoint</option>
                </select>
                <button class="control-btn" onClick=${() => { void submitTeamTurn() }} disabled=${operatorActionBusy.value || !selectedSession}>
                  Apply
                </button>
              </div>
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Session message"
                value=${teamMessage.value}
                onInput=${(event: Event) => { teamMessage.value = (event.target as HTMLTextAreaElement).value }}
                disabled=${operatorActionBusy.value || !selectedSession}
              ></textarea>
              ${teamTurnKind.value === 'task' ? html`
                <input
                  class="control-input"
                  type="text"
                  placeholder="Injected task title"
                  value=${teamTaskTitle.value}
                  onInput=${(event: Event) => { teamTaskTitle.value = (event.target as HTMLInputElement).value }}
                  disabled=${operatorActionBusy.value || !selectedSession}
                />
                <textarea
                  class="control-textarea"
                  rows=${2}
                  placeholder="Injected task description"
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
                  Stop
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Keeper</div>
              ${selectedKeeper ? html`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${selectedKeeper.name}</div>
                  <div class="ops-detail-meta">
                    <span>Autonomy: ${selectedKeeper.autonomy_level ?? 'n/a'}</span>
                    <span>Generation: ${selectedKeeper.generation ?? 0}</span>
                    <span>Goals: ${selectedKeeper.active_goal_ids?.length ?? 0}</span>
                  </div>
                </div>
              ` : html`<div class="ops-empty">Select a keeper to send a direct intervention.</div>`}

              <label class="control-label" for="ops-keeper-message">Keeper Message</label>
              <textarea
                id="ops-keeper-message"
                class="control-textarea"
                rows=${6}
                placeholder="Send a structured intervention or course correction"
                value=${keeperMessage.value}
                onInput=${(event: Event) => { keeperMessage.value = (event.target as HTMLTextAreaElement).value }}
                disabled=${operatorActionBusy.value || !selectedKeeper}
              ></textarea>
              <div class="control-row">
                <button class="control-btn" onClick=${() => { void submitKeeperMessage() }} disabled=${operatorActionBusy.value || !selectedKeeper || keeperMessage.value.trim() === ''}>
                  Send Keeper Message
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </section>
  `
}
