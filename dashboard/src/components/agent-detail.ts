// Agent detail overlay — recent room activity + assigned task history + direct mention

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { agents, tasks } from '../store'
import { fetchRoomMessages, fetchTaskHistory, sendBroadcast } from '../api'
import type { Agent, Task } from '../types'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

type TaskHistoryRow = {
  taskId: string
  text: string
}

export const selectedAgentName = signal<string | null>(null)
const loading = signal(false)
const detailError = signal('')
const roomActivity = signal<string[]>([])
const taskHistories = signal<TaskHistoryRow[]>([])
const mentionText = signal('')
const sendingMention = signal(false)

export function openAgentDetail(agentName: string): void {
  selectedAgentName.value = agentName
  void refreshAgentDetail()
}

export function closeAgentDetail(): void {
  selectedAgentName.value = null
  detailError.value = ''
  roomActivity.value = []
  taskHistories.value = []
  mentionText.value = ''
}

function selectedAgent(): Agent | null {
  const name = selectedAgentName.value
  if (!name) return null
  return agents.value.find(a => a.name === name) ?? null
}

function assignedTasks(agentName: string | null): Task[] {
  if (!agentName) return []
  return tasks.value.filter(t => t.assignee === agentName)
}

async function refreshAgentDetail(): Promise<void> {
  const agentName = selectedAgentName.value
  if (!agentName) return

  loading.value = true
  detailError.value = ''
  roomActivity.value = []
  taskHistories.value = []

  try {
    const lines = await fetchRoomMessages(80)
    roomActivity.value = lines
      .filter(line => line.includes(agentName))
      .slice(0, 20)

    const ownedTasks = assignedTasks(agentName).slice(0, 6)
    if (ownedTasks.length === 0) return

    const historyRows = await Promise.all(
      ownedTasks.map(async task => {
        try {
          const text = await fetchTaskHistory(task.id, 25)
          return { taskId: task.id, text: text.trim() }
        } catch (err) {
          const message = err instanceof Error ? err.message : 'history load failed'
          return { taskId: task.id, text: `Failed to load history: ${message}` }
        }
      }),
    )
    taskHistories.value = historyRows
  } catch (err) {
    detailError.value = err instanceof Error ? err.message : 'Failed to load agent detail'
  } finally {
    loading.value = false
  }
}

async function submitMention(): Promise<void> {
  const target = selectedAgentName.value
  const text = mentionText.value.trim()
  if (!target || !text) return

  const sender = localStorage.getItem(AGENT_NAME_KEY)?.trim() || 'dashboard'

  sendingMention.value = true
  try {
    await sendBroadcast(sender, `@${target} ${text}`)
    mentionText.value = ''
    showToast(`Mention sent to ${target}`, 'success')
    void refreshAgentDetail()
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to send mention'
    showToast(msg, 'error')
  } finally {
    sendingMention.value = false
  }
}

function TaskSummary({ task }: { task: Task }) {
  return html`
    <div class="agent-detail-task">
      <span class="pill">${task.id}</span>
      <span class="agent-detail-task-title">${task.title}</span>
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function TaskHistoryPanel({ row }: { row: TaskHistoryRow }) {
  return html`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${row.taskId}</span>
      </div>
      <pre class="agent-history-pre">${row.text || 'No task history yet'}</pre>
    </div>
  `
}

export function AgentDetailOverlay() {
  const agentName = selectedAgentName.value
  if (!agentName) return null

  const agent = selectedAgent()
  const ownedTasks = assignedTasks(agentName)
  const lines = roomActivity.value

  return html`
    <div
      class="agent-detail-overlay"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('agent-detail-overlay')) closeAgentDetail()
      }}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${agent?.emoji ? html`<span style="font-size:2rem">${agent.emoji}</span>` : ''}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${agentName}
                  ${agent?.koreanName ? html`<span style="font-size:0.75em;color:#888">(${agent.koreanName})</span>` : ''}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${agent
                    ? html`
                        <${StatusBadge} status=${agent.status} />
                        ${agent.model ? html`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${agent.model}</span>` : ''}
                        ${agent.primaryValue ? html`<span style="font-size:0.75rem;color:#a78bfa">${agent.primaryValue}</span>` : ''}
                      `
                    : html`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${agent?.activityLevel != null ? html`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(agent.activityLevel * 10, 100)}%;height:100%;background:${agent.activityLevel >= 8 ? '#22c55e' : agent.activityLevel >= 5 ? '#f59e0b' : '#666'};border-radius:3px"></div>
                </div>
                <span style="color:#888">${agent.activityLevel}/10</span>
              </div>
            ` : ''}
            ${(agent?.traits?.length ?? 0) > 0 ? html`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${agent?.traits?.map((t: string) => html`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${t}</span>`)}
              </div>
            ` : ''}
            ${(agent?.interests?.length ?? 0) > 0 ? html`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${agent?.interests?.map((t: string) => html`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${t}</span>`)}
              </div>
            ` : ''}
            <div class="agent-detail-sub">
              ${agent
                ? html`
                    ${agent.current_task ? html`<span>Task: ${agent.current_task}</span>` : null}
                    ${agent.last_seen ? html`<span>Last seen: <${TimeAgo} timestamp=${agent.last_seen} /></span>` : null}
                  `
                : null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${() => { void refreshAgentDetail() }} disabled=${loading.value}>
              ${loading.value ? 'Refreshing...' : 'Refresh'}
            </button>
            <button class="control-btn ghost" onClick=${closeAgentDetail}>Close</button>
          </div>
        </div>

        ${detailError.value ? html`<div class="council-error">${detailError.value}</div>` : null}

        <div class="agent-detail-grid">
          <${Card} title="Assigned Tasks">
            ${ownedTasks.length === 0
              ? html`<div class="empty-state">No assigned tasks</div>`
              : html`<div class="agent-detail-task-list">${ownedTasks.map(t => html`<${TaskSummary} key=${t.id} task=${t} />`)}</div>`}
          <//>

          <${Card} title="Recent Activity">
            ${lines.length === 0
              ? html`<div class="empty-state">No recent room activity match</div>`
              : html`<div class="agent-activity-list">${lines.map((line, idx) => html`<div key=${idx} class="agent-activity-line">${line}</div>`)}</div>`}
          <//>
        </div>

        <${Card} title="Task History">
          ${taskHistories.value.length === 0
            ? html`<div class="empty-state">No task history loaded</div>`
            : html`<div class="agent-history-list">${taskHistories.value.map(row => html`<${TaskHistoryPanel} key=${row.taskId} row=${row} />`)}</div>`}
        <//>

        <${Card} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${mentionText.value}
              onInput=${(e: Event) => { mentionText.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitMention() }}
              disabled=${sendingMention.value}
            />
            <button
              class="control-btn"
              onClick=${() => { void submitMention() }}
              disabled=${sendingMention.value || mentionText.value.trim() === ''}
            >
              ${sendingMention.value ? 'Sending...' : 'Send'}
            </button>
          </div>
        <//>
      </div>
    </div>
  `
}
