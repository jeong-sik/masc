// Agent detail overlay — recent room activity + assigned task history + direct mention

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import {
  agents,
  executionContinuityBriefs,
  executionLodgeCheckins,
  keepers,
  serverStatus,
  tasks,
} from '../store'
import { fetchRoomMessages, fetchTaskHistory, sendBroadcast } from '../api'
import { missionSnapshot } from '../mission-store'
import type {
  Agent,
  DashboardExecutionContinuityBrief,
  DashboardExecutionLodgeCheckin,
  DashboardMissionAgentBrief,
  Keeper,
  Task,
} from '../types'

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

function keeperForAgent(agentName: string | null): Keeper | null {
  if (!agentName) return null
  return keepers.value.find(keeper => keeper.agent_name === agentName || keeper.name === agentName) ?? null
}

function missionAgentBrief(agentName: string | null): DashboardMissionAgentBrief | null {
  if (!agentName) return null
  const mission = missionSnapshot.value
  if (!mission) return null
  return mission.agent_briefs.find(brief => brief.agent_name === agentName) ?? null
}

function windowTopTools(keeper: Keeper | null): string[] {
  if (!keeper) return []
  const metrics = keeper.metrics_window
  const topTools = Array.isArray(metrics?.top_tools) ? metrics.top_tools : []
  return topTools
    .map(item => (typeof item === 'object' && item !== null && 'tool' in item && typeof item.tool === 'string' ? item.tool : null))
    .filter((item): item is string => item !== null)
}

function recentToolsForAgent(agentName: string | null): string[] {
  const keeper = keeperForAgent(agentName)
  if (!keeper) return []
  return keeper.recent_tool_names && keeper.recent_tool_names.length > 0 ? keeper.recent_tool_names : []
}

function continuityBriefForAgent(agentName: string | null): DashboardExecutionContinuityBrief | null {
  if (!agentName) return null
  return executionContinuityBriefs.value.find(
    brief => brief.agent_name === agentName || brief.name === agentName,
  ) ?? null
}

function latestLodgeCheckinForAgent(agentName: string | null): DashboardExecutionLodgeCheckin | null {
  if (!agentName) return null
  return executionLodgeCheckins.value.find(
    row => row.agent_name === agentName || row.worker_name === agentName,
  ) ?? null
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
  const keeper = keeperForAgent(agentName)
  const continuityBrief = continuityBriefForAgent(agentName)
  const lodgeCheckin = latestLodgeCheckinForAgent(agentName)
  const missionBrief = missionAgentBrief(agentName)
  const ownedTasks = assignedTasks(agentName)
  const lines = roomActivity.value
  const recentTools = recentToolsForAgent(agentName)
  const topTools = windowTopTools(keeper)
  const allowedTools =
    continuityBrief?.allowed_tool_names
    ?? missionBrief?.allowed_tool_names
    ?? lodgeCheckin?.allowed_tool_names
    ?? []
  const observedTools =
    continuityBrief?.latest_tool_names
    ?? missionBrief?.latest_tool_names
    ?? lodgeCheckin?.used_tool_names
    ?? []
  const toolCallCount =
    continuityBrief?.latest_tool_call_count
    ?? missionBrief?.latest_tool_call_count
    ?? lodgeCheckin?.used_tool_call_count
  const auditSource =
    continuityBrief?.tool_audit_source
    ?? missionBrief?.tool_audit_source
    ?? lodgeCheckin?.tool_audit_source
  const auditAt =
    continuityBrief?.tool_audit_at
    ?? missionBrief?.tool_audit_at
    ?? lodgeCheckin?.tool_audit_at
  const capabilities = agent?.capabilities ?? []
  const room = serverStatus.value?.room ?? 'default'
  const project = serverStatus.value?.project ?? '확인 없음'
  const cluster = serverStatus.value?.cluster ?? '확인 없음'

  return html`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
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
            ${capabilities.length > 0 ? html`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${capabilities.map((capability: string) => html`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${capability}</span>`)}
              </div>
            ` : ''}
            <div class="agent-detail-sub">
              ${agent
                ? html`
                    ${agent.current_task ? html`<span>Task: ${agent.current_task}</span>` : null}
                    ${agent.last_seen ? html`<span>Last seen: <${TimeAgo} timestamp=${agent.last_seen} /></span>` : null}
                    <span>Room: ${room}</span>
                    <span>Project: ${project}</span>
                    <span>Cluster: ${cluster}</span>
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

        <${Card} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${capabilities.length > 0
                  ? capabilities.map((capability: string) => html`<span class="pill">${capability}</span>`)
                  : html`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Allowed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${allowedTools.length > 0
                  ? allowedTools.map((tool: string) => html`<span class="pill">${tool}</span>`)
                  : html`<span class="empty-state" style="font-size:12px;">No allowlist reported</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${observedTools.length > 0
                  ? observedTools.map((tool: string) => html`<span class="pill">${tool}</span>`)
                  : html`<span class="empty-state" style="font-size:12px;">No observed tool-use evidence</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof toolCallCount === 'number' ? toolCallCount : '—'}</span>
              <span>Evidence source: ${auditSource ?? 'unreported'}</span>
              <span>
                Observed at:
                ${auditAt ? html` <${TimeAgo} timestamp=${auditAt} />` : ' unreported'}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${recentTools.length > 0
                  ? recentTools.map((tool: string) => html`<span class="pill">${tool}</span>`)
                  : html`<span class="empty-state" style="font-size:12px;">No keeper tool telemetry</span>`}
              </div>
            </div>
            ${topTools.length > 0
              ? html`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${topTools.map((tool: string) => html`<span class="pill">${tool}</span>`)}
                    </div>
                  </div>
                `
              : null}
            ${keeper
              ? html`
                  <div style="font-size:12px; color:#888;">
                    Linked keeper: <span style="color:#4ade80;">${keeper.name}</span>
                    ${keeper.skill_primary ? html` · route <span style="color:#22d3ee;">${keeper.skill_primary}</span>` : null}
                  </div>
                `
              : null}
            ${continuityBrief?.continuity_summary || continuityBrief?.skill_route_summary
              ? html`
                  <div class="agent-detail-sub">
                    ${continuityBrief?.continuity_summary ? html`<span>${continuityBrief.continuity_summary}</span>` : null}
                    ${continuityBrief?.skill_route_summary ? html`<span>Route: ${continuityBrief.skill_route_summary}</span>` : null}
                  </div>
                `
              : null}
          </div>
        <//>

        ${lodgeCheckin
          ? html`
              <${Card} title="Latest Lodge Check-in">
                <div class="agent-detail-sub">
                  <span>Outcome: ${lodgeCheckin.outcome}</span>
                  <span>Trigger: ${lodgeCheckin.trigger ?? 'unknown'}</span>
                  <span>Action: ${lodgeCheckin.action_kind ?? 'none'}</span>
                  ${lodgeCheckin.checked_at ? html`<span>Checked: <${TimeAgo} timestamp=${lodgeCheckin.checked_at} /></span>` : null}
                </div>
                ${lodgeCheckin.reason ? html`<div class="monitor-footnote">${lodgeCheckin.reason}</div>` : null}
                ${lodgeCheckin.summary && lodgeCheckin.summary !== lodgeCheckin.reason
                  ? html`<div class="monitor-footnote">${lodgeCheckin.summary}</div>`
                  : null}
                ${lodgeCheckin.failure_reason
                  ? html`<div class="monitor-footnote">Failure: ${lodgeCheckin.failure_reason}</div>`
                  : lodgeCheckin.decision_reason
                    ? html`<div class="monitor-footnote">Decision: ${lodgeCheckin.decision_reason}</div>`
                    : null}
              <//>
            `
          : null}

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
