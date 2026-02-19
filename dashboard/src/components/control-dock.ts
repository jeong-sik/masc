// Control dock — broadcast + quick task creation (legacy lobby parity)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { addTaskFromDashboard, sendBroadcast } from '../api'
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

function persistAgentName(value: string): void {
  const v = value.trim()
  agentName.value = v
  if (v) localStorage.setItem(AGENT_NAME_KEY, v)
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
