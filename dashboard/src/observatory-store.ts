// Agent Observatory — computed signals that join agents, workers, sessions, continuity
// into session-grouped views for the observatory surface.

import { computed, type ReadonlySignal } from '@preact/signals'
import {
  agents,
  executionWorkerSupportBriefs,
  executionSessionBriefs,
  executionContinuityBriefs,
} from './store'
import type {
  Agent,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionSessionBrief,
  DashboardExecutionContinuityBrief,
} from './types'

// --- Types ---

type ObservatoryAgentState = 'working' | 'watching' | 'quiet' | 'offline'

export interface ObservatoryAgent {
  name: string
  koreanName: string | null
  emoji: string | null
  model: string | null
  status: string
  state: ObservatoryAgentState
  focus: string | null
  currentTask: string | null
  recentTools: string[]
  recentOutputPreview: string | null
  contextRatio: number | null
  lastSignalAt: string | null
  lastSignalAgeSec: number | null
  signalTruth: string | null
  relatedSessionId: string | null
}

interface ObservatoryGroup {
  sessionId: string | null
  goal: string | null
  status: string | null
  health: string | null
  memberCount: number
  agents: ObservatoryAgent[]
}

// --- Helpers ---

function deriveAgentState(
  agent: Agent | null,
  worker: DashboardExecutionWorkerSupportBrief | null,
): ObservatoryAgentState {
  // WorkerState: 'working' | 'watching' | 'quiet' | 'offline'
  const workerState = worker?.state
  if (workerState === 'working') return 'working'
  if (workerState === 'watching') return 'watching'
  if (workerState === 'quiet') return 'quiet'
  if (workerState === 'offline') return 'offline'

  // Fallback to agent status if no worker state
  const agentStatus = agent?.status ?? (worker?.status as string | undefined)
  if (agentStatus === 'active' || agentStatus === 'busy') return 'working'
  if (agentStatus === 'listening' || agentStatus === 'idle') return 'watching'
  if (agentStatus === 'offline' || agentStatus === 'inactive') return 'offline'

  return 'quiet'
}

const STATE_ORDER: Record<ObservatoryAgentState, number> = {
  working: 0,
  watching: 1,
  quiet: 2,
  offline: 3,
}

function buildObservatoryAgent(
  agent: Agent | null,
  worker: DashboardExecutionWorkerSupportBrief | null,
  continuity: DashboardExecutionContinuityBrief | null,
): ObservatoryAgent {
  const name = agent?.name ?? worker?.name ?? continuity?.name ?? 'unknown'

  return {
    name,
    koreanName: agent?.koreanName ?? worker?.korean_name ?? continuity?.korean_name ?? null,
    emoji: agent?.emoji ?? worker?.emoji ?? continuity?.emoji ?? null,
    model: agent?.model ?? worker?.model ?? continuity?.model ?? null,
    status: (agent?.status ?? worker?.status ?? continuity?.status ?? 'unknown') as string,
    state: deriveAgentState(agent, worker),
    focus: worker?.focus ?? continuity?.focus ?? null,
    currentTask: agent?.current_task ?? null,
    recentTools: continuity?.recent_tool_names ?? continuity?.latest_tool_names ?? [],
    recentOutputPreview: worker?.recent_output_preview ?? continuity?.recent_output_preview ?? null,
    contextRatio: continuity?.context_ratio ?? null,
    lastSignalAt: worker?.last_signal_at ?? continuity?.last_signal_at ?? null,
    lastSignalAgeSec: worker?.last_signal_age_sec ?? null,
    signalTruth: worker?.signal_truth ?? null,
    relatedSessionId: worker?.related_session_id ?? continuity?.related_session_id ?? null,
  }
}

// --- Computed signal ---

const observatoryGroups: ReadonlySignal<ObservatoryGroup[]> = computed(() => {
  const agentList = agents.value
  const workers = executionWorkerSupportBriefs.value
  const sessions = executionSessionBriefs.value
  const continuities = executionContinuityBriefs.value

  // Build lookup maps
  const agentMap = new Map<string, Agent>()
  for (const a of agentList) agentMap.set(a.name, a)

  const workerMap = new Map<string, DashboardExecutionWorkerSupportBrief>()
  for (const w of workers) workerMap.set(w.name, w)

  const continuityMap = new Map<string, DashboardExecutionContinuityBrief>()
  for (const c of continuities) continuityMap.set(c.agent_name ?? c.name, c)

  const sessionMap = new Map<string, DashboardExecutionSessionBrief>()
  for (const s of sessions) sessionMap.set(s.session_id, s)

  // Collect all known agent names
  const allNames = new Set<string>()
  for (const a of agentList) allNames.add(a.name)
  for (const w of workers) allNames.add(w.name)
  for (const c of continuities) allNames.add(c.agent_name ?? c.name)

  // Build reverse lookup: agent name → session ID from member_names
  // Covers agents whose relatedSessionId is missing but are still session members
  const membershipLookup = new Map<string, string>()
  for (const s of sessions) {
    for (const memberName of (s.member_names ?? [])) {
      membershipLookup.set(memberName, s.session_id)
    }
  }

  // Build ObservatoryAgent for each, grouped by session
  const grouped = new Map<string | null, ObservatoryAgent[]>()

  for (const name of allNames) {
    const agent = agentMap.get(name) ?? null
    const worker = workerMap.get(name) ?? null
    const continuity = continuityMap.get(name) ?? null

    const obsAgent = buildObservatoryAgent(agent, worker, continuity)
    // Primary: relatedSessionId from worker/continuity briefs
    // Fallback: reverse lookup from session member_names
    const sessionId = obsAgent.relatedSessionId ?? membershipLookup.get(name) ?? null

    const list = grouped.get(sessionId) ?? []
    list.push(obsAgent)
    grouped.set(sessionId, list)
  }

  // Sort agents within each group: working > watching > quiet > offline, then name
  for (const [, list] of grouped) {
    list.sort((a, b) => {
      const stateA = STATE_ORDER[a.state]
      const stateB = STATE_ORDER[b.state]
      if (stateA !== stateB) return stateA - stateB
      return a.name.localeCompare(b.name)
    })
  }

  // Build groups with session metadata
  const groups: ObservatoryGroup[] = []

  // Sessions with agents first (sorted: active sessions before completed)
  const sessionIds = [...grouped.keys()].filter((k): k is string => k !== null)
  sessionIds.sort((a, b) => {
    const sa = sessionMap.get(a)
    const sb = sessionMap.get(b)
    const healthOrder = (h?: string) => {
      if (h === 'critical' || h === 'bad') return 0
      if (h === 'degraded') return 1
      if (h === 'ok' || h === 'healthy') return 2
      return 3
    }
    const ha = healthOrder(sa?.health)
    const hb = healthOrder(sb?.health)
    if (ha !== hb) return ha - hb
    return a.localeCompare(b)
  })

  for (const sessionId of sessionIds) {
    const session = sessionMap.get(sessionId)
    const agentsList = grouped.get(sessionId) ?? []
    groups.push({
      sessionId,
      goal: session?.goal ?? null,
      status: session?.status ?? null,
      health: session?.health ?? null,
      memberCount: session?.member_names?.length ?? agentsList.length,
      agents: agentsList,
    })
  }

  // Unassigned bucket
  const unassigned = grouped.get(null)
  if (unassigned && unassigned.length > 0) {
    groups.push({
      sessionId: null,
      goal: null,
      status: null,
      health: null,
      memberCount: unassigned.length,
      agents: unassigned,
    })
  }

  return groups
})

/** Top active agents (working/watching first), capped at `limit`. Used by Home AgentPulse. */
export const topActiveAgents: ReadonlySignal<ObservatoryAgent[]> = computed(() => {
  const allAgents = observatoryGroups.value.flatMap(g => g.agents)
  return allAgents
    .sort((a, b) => STATE_ORDER[a.state] - STATE_ORDER[b.state] || a.name.localeCompare(b.name))
    .slice(0, 12)
})
