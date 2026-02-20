// Control dock — broadcast + quick task creation (legacy lobby parity)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  addTaskFromDashboard,
  joinDashboardAgent,
  leaveDashboardAgent,
  sendAgentHeartbeat,
  sendBroadcast,
} from '../api'
import { showToast } from './common/toast'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

function defaultAgentName(): string {
  const q = new URLSearchParams(window.location.search)
  const fromQuery = q.get('agent') ?? q.get('agent_name')
  const fromStorage = localStorage.getItem(AGENT_NAME_KEY)
  return fromQuery ?? fromStorage ?? 'dashboard'
}

const agentName = signal(defaultAgentName())
const message = signal('')
const taskTitle = signal('')
const taskDesc = signal('')
const sending = signal(false)
const creatingTask = signal(false)
const joining = signal(false)
const leaving = signal(false)
const pinging = signal(false)
const joined = signal(false)

function persistAgentName(value: string): void {
  const v = value.trim()
  agentName.value = v
  if (v) localStorage.setItem(AGENT_NAME_KEY, v)
}

function parseJoinedAgentName(text: string): string | null {
  const line = text.split('\n').find(l => l.includes(' joined')) ?? text
  const m = line.match(/✅\s+(\S+)\s+joined/i)
  return m?.[1] ?? null
}

async function joinRoom() {
  const agent = agentName.value.trim()
  if (!agent) return
  joining.value = true
  try {
    const resText = await joinDashboardAgent(agent)
    const joinedName = parseJoinedAgentName(resText)
    if (joinedName) persistAgentName(joinedName)
    joined.value = true
    showToast(`Joined as ${joinedName ?? agent}`, 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to join room'
    showToast(msg, 'error')
  } finally {
    joining.value = false
  }
}

async function leaveRoom() {
  const agent = agentName.value.trim()
  if (!agent) return
  leaving.value = true
  try {
    await leaveDashboardAgent(agent)
    joined.value = false
    showToast(`Left room (${agent})`, 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to leave room'
    showToast(msg, 'error')
  } finally {
    leaving.value = false
  }
}

async function resetIdentity() {
  const prev = agentName.value.trim()
  if (prev) {
    try {
      await leaveDashboardAgent(prev)
    } catch {
      // Ignore leave failure while resetting identity.
    }
  }

  localStorage.removeItem(AGENT_NAME_KEY)
  persistAgentName('dashboard')
  joined.value = false
  await joinRoom()
}

async function pingHeartbeat() {
  const agent = agentName.value.trim()
  if (!agent) return
  pinging.value = true
  try {
    await sendAgentHeartbeat(agent)
    showToast('Heartbeat sent', 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to send heartbeat'
    showToast(msg, 'error')
  } finally {
    pinging.value = false
  }
}

async function submitBroadcast() {
  const agent = agentName.value.trim()
  const text = message.value.trim()
  if (!agent || !text) return
  sending.value = true
  try {
    await sendBroadcast(agent, text)
    message.value = ''
    showToast('Broadcast sent', 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to send broadcast'
    showToast(msg, 'error')
  } finally {
    sending.value = false
  }
}

async function submitTask() {
  const title = taskTitle.value.trim()
  const desc = taskDesc.value.trim() || 'Created from dashboard'
  if (!title) return
  creatingTask.value = true
  try {
    await addTaskFromDashboard(title, desc, 1)
    taskTitle.value = ''
    taskDesc.value = ''
    showToast('Task created', 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to create task'
    showToast(msg, 'error')
  } finally {
    creatingTask.value = false
  }
}

export function ControlDock() {
  useEffect(() => {
    void joinRoom()
  }, [])

  return html`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${agentName.value}
        onInput=${(e: Event) => persistAgentName((e.target as HTMLInputElement).value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${message.value}
          onInput=${(e: Event) => { message.value = (e.target as HTMLInputElement).value }}
          onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') submitBroadcast() }}
          disabled=${sending.value}
        />
        <button
          class="control-btn"
          onClick=${submitBroadcast}
          disabled=${sending.value || message.value.trim() === '' || agentName.value.trim() === ''}
        >
          ${sending.value ? 'Sending...' : 'Send'}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${() => { void joinRoom() }}
          disabled=${joining.value || agentName.value.trim() === ''}
        >
          ${joining.value ? 'Joining...' : joined.value ? 'Rejoin' : 'Join'}
        </button>
        <button
          class="control-btn ghost"
          onClick=${() => { void leaveRoom() }}
          disabled=${leaving.value || agentName.value.trim() === ''}
        >
          ${leaving.value ? 'Leaving...' : 'Leave'}
        </button>
        <button
          class="control-btn ghost"
          onClick=${() => { void resetIdentity() }}
          disabled=${joining.value || leaving.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${() => { void pingHeartbeat() }}
          disabled=${pinging.value || agentName.value.trim() === ''}
        >
          ${pinging.value ? 'Pinging...' : 'Heartbeat'}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${taskTitle.value}
        onInput=${(e: Event) => { taskTitle.value = (e.target as HTMLInputElement).value }}
        disabled=${creatingTask.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${taskDesc.value}
        onInput=${(e: Event) => { taskDesc.value = (e.target as HTMLTextAreaElement).value }}
        disabled=${creatingTask.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${submitTask}
        disabled=${creatingTask.value || taskTitle.value.trim() === ''}
      >
        ${creatingTask.value ? 'Creating...' : 'Create Task'}
      </button>
    </section>
  `
}
