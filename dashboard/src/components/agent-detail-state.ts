// Agent detail shared state, selectors, data fetching, and utility functions

import { signal } from '@preact/signals'
import { selectedAgentName } from './agent-detail-selection'
import { showToast } from './common/toast'
import {
  agents,
  executionContinuityBriefs,
  executionWorkerSupportBriefs,
  tasks,
} from '../store'
import { findKeeper } from '../lib/keeper-utils'
import { currentDashboardActor, fetchWorkspaceMessages, fetchTaskHistory, sendBroadcast, fetchAgentTimeline, type AgentTimelineResponse } from '../api'
import { callMcpTool } from '../api/mcp'
import { journal } from '../sse'
import { route, navigate } from '../router'
import { missionSnapshot } from '../mission-store'
import type { JournalEntry } from '../types'
import type {
  Agent,
  DashboardExecutionContinuityBrief,
  DashboardMissionAgentBrief,
  Task,
} from '../types'

export type TaskHistoryRow = {
  taskId: string
  text: string
}

// --- Signals ---

export const loading = signal(false)
export const detailError = signal('')
export const namespaceActivity = signal<string[]>([])
export const taskHistories = signal<TaskHistoryRow[]>([])
export const agentTimeline = signal<AgentTimelineResponse | null>(null)
export const mentionText = signal('')
export const sendingMention = signal(false)

// Agent fitness
type AgentFitness = {
  completion_rate?: number
  reliability_score?: number
  speed_score?: number
  overall_fitness?: number
  [key: string]: unknown
}
export const agentFitness = signal<AgentFitness | null>(null)

// --- Selectors ---

export function selectedAgent(): Agent | null {
  const name = selectedAgentName.value
  if (!name) return null
  return agents.value.find(a => a.name === name) ?? null
}

export function assignedTasks(agentName: string | null): Task[] {
  if (!agentName) return []
  return tasks.value.filter(t => t.assignee === agentName)
}

export function missionAgentBrief(agentName: string | null): DashboardMissionAgentBrief | null {
  if (!agentName) return null
  const mission = missionSnapshot.value
  if (!mission) return null
  return mission.agent_briefs.find(brief => brief.agent_name === agentName) ?? null
}

export function continuityBriefForAgent(agentName: string | null): DashboardExecutionContinuityBrief | null {
  if (!agentName) return null
  return executionContinuityBriefs.value.find(
    brief => brief.agent_name === agentName || brief.name === agentName,
  ) ?? null
}

export function workerBriefForAgent(agentName: string | null) {
  if (!agentName) return null
  return executionWorkerSupportBriefs.value.find(w => w.name === agentName) ?? null
}

/** Collect lowercase name variants for an agent (including keeper aliases). */
function agentMatchNames(agentName: string): string[] {
  const keeper = findKeeper(agentName)
  return [agentName, keeper?.name, keeper?.agent_name]
    .filter((n): n is string => n != null && n !== '')
    .map(n => n.toLowerCase())
}

export function agentJournalEntries(agentName: string | null): JournalEntry[] {
  if (!agentName) return []
  const names = agentMatchNames(agentName)

  return journal.value
    .filter((entry: JournalEntry) => {
      const text = entry.text.toLowerCase()
      const agent = entry.agent.toLowerCase()
      return names.some(name =>
        agent === name || text.includes(name) || text.includes(`@${name}`),
      )
    })
    .slice(0, 15)
}

// --- Actions ---

// Keeper redirect — set by agent-detail.ts to avoid circular imports.
let _keeperRedirect: ((agentName: string) => boolean) | null = null

export function setKeeperRedirect(fn: (agentName: string) => boolean): void {
  _keeperRedirect = fn
}

/** Open the workspace-agent profile without attempting a keeper redirect.
 *
 * Callers use this when they already resolved the typed keeper relation and
 * found none. Keeping this entry point separate prevents display-name shapes
 * such as `keeper-*-agent` or generated nicknames from changing the selected
 * entity through the legacy name resolver. */
export function openAgentProfile(agentName: string): void {
  selectedAgentName.value = agentName
  void refreshAgentDetail()
}

export function openAgentDetail(agentName: string): void {
  if (_keeperRedirect && _keeperRedirect(agentName)) return
  const keeper = findKeeper(agentName)
  if (keeper) {
    void import('./keeper-detail')
      .then(({ openKeeperDetail }) => {
        openKeeperDetail(keeper)
      })
      .catch(err => {
        console.warn('[agent-detail] keeper redirect failed', err instanceof Error ? err.message : err)
        selectedAgentName.value = agentName
        void refreshAgentDetail()
      })
    return
  }
  openAgentProfile(agentName)
}

export function closeAgentDetail(): void {
  selectedAgentName.value = null
  detailError.value = ''
  namespaceActivity.value = []
  taskHistories.value = []
  agentTimeline.value = null
  mentionText.value = ''
  agentFitness.value = null
  if (route.value.tab === 'monitoring' && route.value.params.agent) {
    navigate('monitoring', { section: 'agents' })
  }
}

export async function refreshAgentDetail(): Promise<void> {
  const agentName = selectedAgentName.value
  if (!agentName) return

  loading.value = true
  detailError.value = ''
  namespaceActivity.value = []
  taskHistories.value = []
  agentTimeline.value = null
  agentFitness.value = null

  try {
    // Fetch namespace (workspace) messages, task histories, timeline, and fitness in parallel.
    //
    // P2 silent-failure fix: previously both .catch(() => null) calls
    // silently coerced fetch failures into null, indistinguishable from
    // "agent has no timeline / no fitness data" — operator saw blank
    // panels with no signal that the underlying fetch had failed.  Now
    // each catch logs the error so DevTools surfaces the failure even
    // though the UI still degrades gracefully (other data still shows).
    const [lines, timelineResult, fitnessResult] = await Promise.all([
      fetchWorkspaceMessages(80),
      fetchAgentTimeline(agentName, 24, 50).catch((err: unknown) => {
        console.warn('[agent-detail-state] fetchAgentTimeline failed', { agentName, err })
        return null
      }),
      callMcpTool('masc_agent_fitness', { agent_name: agentName, days: 7 })
        .then(raw => JSON.parse(raw) as AgentFitness)
        .catch((err: unknown) => {
          console.warn('[agent-detail-state] masc_agent_fitness fetch/parse failed', { agentName, err })
          return null
        }),
    ])

    const matchNames = agentMatchNames(agentName)

    namespaceActivity.value = lines
      .filter(line => {
        const lower = line.toLowerCase()
        return matchNames.some(name => lower.includes(name))
      })
      .slice(0, 20)

    agentTimeline.value = timelineResult
    agentFitness.value = fitnessResult

    const ownedTasks = assignedTasks(agentName).slice(0, 6)
    if (ownedTasks.length === 0) return

    const historyRows = await Promise.all(
      ownedTasks.map(async task => {
        try {
          const text = await fetchTaskHistory(task.id, 25)
          return { taskId: task.id, text: text.trim() }
        } catch (err) {
          const message = err instanceof Error ? err.message : 'history 로드 실패'
          return { taskId: task.id, text: `이력 로드 실패: ${message}` }
        }
      }),
    )
    taskHistories.value = historyRows
  } catch (err) {
    detailError.value = err instanceof Error ? err.message : '에이전트 상세 정보 로드 실패'
  } finally {
    loading.value = false
  }
}

export async function submitMention(): Promise<void> {
  const target = selectedAgentName.value
  const text = mentionText.value.trim()
  if (!target || !text) return

  sendingMention.value = true
  try {
    await sendBroadcast(currentDashboardActor(), `@${target} ${text}`)
    mentionText.value = ''
    showToast(`${target}에게 멘션 전송 완료`, 'success')
    void refreshAgentDetail()
  } catch (err) {
    const msg = err instanceof Error ? err.message : '멘션 전송 실패'
    showToast(msg, 'error')
  } finally {
    sendingMention.value = false
  }
}

// --- Helpers ---

export function journalKindIcon(entry: JournalEntry): string {
  if (entry.kind === 'board') return 'B'
  if (entry.kind === 'tasks') return 'T'
  if (entry.kind === 'keepers') return 'K'
  return 'S'
}
