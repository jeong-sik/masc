import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { showToast } from './common/toast'
import type { OperatorKeeperSnapshot, OperatorSessionSnapshot } from '../types'
import {
  confirmOperatorPendingAction,
  dispatchOperatorAction,
  operatorActionBusy,
  operatorActionLog,
  operatorError,
  operatorLoading,
  operatorSnapshot,
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
  const health = normalizeStatus(session.team_health?.status)
  if (health && health !== 'ok' && health !== 'healthy' && health !== 'green') return 'warn'
  if (status && status !== 'active' && status !== 'running' && status !== 'ended') return 'warn'
  return 'ok'
}

function keeperPriorityTone(keeper: OperatorKeeperSnapshot): OpsPriorityTone {
  const status = normalizeStatus(keeper.status)
  if (status === 'offline' || status === 'inactive' || status === 'error') return 'bad'
  if ((keeper.context_ratio ?? 0) >= 0.8) return 'warn'
  if ((keeper.last_turn_ago_s ?? 0) >= 3600) return 'warn'
  return 'ok'
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
  useEffect(() => {
    void refreshOperatorSnapshot()
  }, [])

  const snapshot = operatorSnapshot.value
  const room = snapshot?.room ?? {}
  const sessions = snapshot?.sessions ?? []
  const keepers = snapshot?.keepers ?? []
  const pendingConfirms = snapshot?.pending_confirms ?? []
  const recentMessages = snapshot?.recent_messages ?? []
  const selectedSession = sessions.find(session => session.session_id === selectedSessionId.value) ?? sessions[0] ?? null
  const selectedKeeper = keepers.find(keeper => keeper.name === selectedKeeperName.value) ?? keepers[0] ?? null
  const flaggedSessions = sessions.filter(session => sessionPriorityTone(session) !== 'ok')
  const flaggedKeepers = keepers.filter(keeper => keeperPriorityTone(keeper) !== 'ok')
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
      value: flaggedSessions.length,
      detail: flaggedSessions.length > 0
        ? 'Team sessions need steering, stop, or checkpoint attention'
        : 'Team sessions look healthy from the operator snapshot',
      tone: flaggedSessions.some(session => normalizeStatus(session.status) === 'paused') ? 'bad' : flaggedSessions.length > 0 ? 'warn' : 'ok',
    },
    {
      key: 'keeper',
      label: 'Keeper Pressure',
      value: flaggedKeepers.length,
      detail: flaggedKeepers.length > 0
        ? 'At least one keeper is stale, offline, or running hot'
        : 'Keepers are available for direct intervention',
      tone: flaggedKeepers.some(keeper => keeperPriorityTone(keeper) === 'bad') ? 'bad' : flaggedKeepers.length > 0 ? 'warn' : 'ok',
    },
  ]

  return html`
    <section class="ops-view">
      <div class="ops-header card">
        <div>
          <div class="card-title">Operator Control</div>
          <h2 class="ops-heading">Guided control for room, sessions, and keepers</h2>
          <p class="ops-subheading">
            Structured actions only. Destructive changes remain behind confirmation tokens.
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
          <button class="control-btn ghost" onClick=${() => { void refreshOperatorSnapshot() }} disabled=${operatorLoading.value || operatorActionBusy.value}>
            ${operatorLoading.value ? 'Refreshing...' : 'Refresh'}
          </button>
        </div>
      </div>

      ${operatorError.value ? html`
        <section class="ops-banner error">${operatorError.value}</section>
      ` : null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
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

      <div class="ops-grid">
        <section class="card ops-panel">
          <div class="card-title">Room Control</div>
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

          <label class="control-label" for="ops-broadcast">Broadcast</label>
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

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
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

          <div class="ops-section-head">Task Inject</div>
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

          ${recentMessages.length > 0 ? html`
            <div class="ops-section-head">Context Tail</div>
            <div class="ops-context-note">Recent room chatter stays available for context, but command work remains the primary focus of this tab.</div>
            <div class="ops-feed-list">
              ${recentMessages.slice(0, 6).map(message => html`
                <article key=${message.seq ?? message.id ?? message.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${message.from}</strong>
                    <span>${message.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${message.content}</div>
                </article>
              `)}
            </div>
          ` : null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
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
          ` : null}

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

          <div class="ops-section-head">Stop Session</div>
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
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
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

          ${selectedKeeper ? html`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${selectedKeeper.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${selectedKeeper.autonomy_level ?? 'n/a'}</span>
                <span>Generation: ${selectedKeeper.generation ?? 0}</span>
                <span>Goals: ${selectedKeeper.active_goal_ids?.length ?? 0}</span>
              </div>
            </div>
          ` : null}

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
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
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
    </section>
  `
}
