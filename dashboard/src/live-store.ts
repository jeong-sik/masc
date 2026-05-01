// Live Monitor tab — derived signals and filter state

import { signal, computed, type ReadonlySignal } from '@preact/signals'
import { isOfflineStatus } from './lib/status-utils'
import type { JournalEntry } from './types'
import type { PipelineStage } from './types/core'
import type { AuditEntry } from './api/dashboard'
import { journal } from './sse'
import { agents, agentMotionMap, keepers, staleKeepers } from './store'
import { contextThresholds } from './config/context-thresholds'
import type { AgentMotionSnapshot } from './components/common/agent-motion'

// --- Filter toggles ---

export type LiveFilterKind = 'broadcast' | 'tasks' | 'keepers' | 'system'

export const liveFilters = signal<Set<LiveFilterKind>>(
  new Set(['broadcast', 'tasks', 'keepers', 'system']),
)

export function toggleLiveFilter(kind: LiveFilterKind): void {
  const next = new Set(liveFilters.value)
  if (next.has(kind)) {
    next.delete(kind)
  } else {
    next.add(kind)
  }
  liveFilters.value = next
}

// --- Selected agent for focus sidebar highlight ---

export const selectedAgent = signal<string | null>(null)

// --- Map journal kind to filter kind ---

function journalKindToFilter(entry: JournalEntry): LiveFilterKind {
  if (entry.kind === 'board') return 'broadcast'
  if (entry.kind === 'tasks') return 'tasks'
  if (entry.kind === 'keepers') return 'keepers'
  return 'system'
}

// --- Filtered journal entries ---

export const filteredJournal: ReadonlySignal<JournalEntry[]> = computed(() => {
  const filters = liveFilters.value
  return journal.value.filter(entry => filters.has(journalKindToFilter(entry)))
})

// --- Agent pulse data ---

export type PulseState = 'working' | 'idle' | 'stale'

const STALE_THRESHOLD_MS = 120_000

export interface AgentPulse {
  name: string
  emoji: string
  koreanName: string | null
  state: PulseState
  currentTask: string | null
  motion: AgentMotionSnapshot | null
}

export const agentPulses: ReadonlySignal<AgentPulse[]> = computed(() => {
  const motionMap = agentMotionMap.value
  const now = Date.now()

  return agents.value.map(agent => {
    const key = agent.name.trim().toLowerCase()
    const motion = motionMap.get(key) ?? null

    let state: PulseState = 'idle'
    if (agent.status === 'active' || agent.status === 'busy') {
      const lastAt = motion?.lastActivityAt
      if (lastAt) {
        const elapsed = now - new Date(lastAt).getTime()
        state = elapsed > STALE_THRESHOLD_MS ? 'stale' : 'working'
      } else {
        state = 'working'
      }
    } else if (isOfflineStatus(agent.status)) {
      state = 'stale'
    }

    return {
      name: agent.name,
      emoji: agent.emoji ?? '',
      koreanName: agent.koreanName ?? null,
      state,
      currentTask: agent.current_task,
      motion,
    }
  })
})

// --- Focus sidebar data ---

interface FocusAgent {
  name: string
  emoji: string
  koreanName: string | null
  currentTask: string | null
  lastActivityAt: string | null
  lastActivityText: string | null
  assignedCount: number
  pressure: 'calm' | 'normal' | 'hot'
}

export const focusAgents: ReadonlySignal<FocusAgent[]> = computed(() => {
  const motionMap = agentMotionMap.value

  return agents.value
    .filter(a =>
      a.status === 'active'
      || a.status === 'busy'
      || a.status === 'listening'
      || a.status === 'idle',
    )
    .map(agent => {
      const key = agent.name.trim().toLowerCase()
      const motion = motionMap.get(key)
      const assignedCount = motion?.activeAssignedCount ?? 0

      let pressure: 'calm' | 'normal' | 'hot' = 'calm'
      if (assignedCount >= 3) pressure = 'hot'
      else if (assignedCount >= 1) pressure = 'normal'

      return {
        name: agent.name,
        emoji: agent.emoji ?? '',
        koreanName: agent.koreanName ?? null,
        currentTask: agent.current_task,
        lastActivityAt: motion?.lastActivityAt ?? null,
        lastActivityText: motion?.lastActivityText ?? null,
        assignedCount,
        pressure,
      }
    })
    .sort((a, b) => {
      const pressureOrder = { hot: 0, normal: 1, calm: 2 }
      return pressureOrder[a.pressure] - pressureOrder[b.pressure]
    })
})

// --- Keeper health summary for Live Monitor ---

export interface KeeperPressure {
  name: string
  ratio: number
  stage: PipelineStage
}

export interface KeeperHealthSummary {
  activeCount: number
  totalCount: number
  warningCount: number
  criticalCount: number
  staleCount: number
  pressures: KeeperPressure[]
}

export const keeperHealthSummary: ReadonlySignal<KeeperHealthSummary> = computed(() => {
  const all = keepers.value
  const active = all.filter(k => k.keepalive_running === true)
  const stale = staleKeepers.value

  let warningCount = 0
  let criticalCount = 0

  const thresholds = contextThresholds.value
  const pressures: KeeperPressure[] = active.map(k => {
    const ratio = k.context_ratio ?? 0
    if (ratio > thresholds.critical) criticalCount++
    else if (ratio > thresholds.warn || stale.has(k.name)) warningCount++
    return { name: k.name, ratio, stage: (k.pipeline_stage ?? 'idle') as PipelineStage }
  }).sort((a, b) => b.ratio - a.ratio)

  return {
    activeCount: active.length,
    totalCount: all.length,
    warningCount,
    criticalCount,
    staleCount: stale.size,
    pressures,
  }
})

// --- Event type color mapping ---

export function eventKindColor(entry: JournalEntry): string {
  if (entry.kind === 'board') return 'live-event-broadcast'
  if (entry.kind === 'tasks') return 'live-event-task'
  if (entry.kind === 'keepers') return 'live-event-keeper'
  return 'live-event-system'
}

export function eventKindLabel(entry: JournalEntry): string {
  const type = entry.eventType
  if (type === 'broadcast') return 'broadcast'
  if (type === 'agent_joined') return 'joined'
  if (type === 'agent_left') return 'left'
  if (type === 'task_update') return 'task'
  if (type === 'board_post') return 'post'
  if (type === 'board_comment') return 'comment'
  if (type === 'board_delete') return 'deleted'
  if (type === 'keeper_heartbeat') return 'heartbeat'
  if (type === 'keeper_handoff') return 'handoff'
  if (type === 'keeper_compaction') return 'compact'
  if (type === 'keeper_guardrail') return 'guardrail'
  if (type === 'keeper_phase_changed') return 'phase'
  if (entry.kind === 'board') return 'board'
  if (entry.kind === 'tasks') return 'task'
  if (entry.kind === 'keepers') return 'keeper'
  return 'system'
}

// --- Global audit ledger (O2 Phase 2) ---

const AUDIT_MAX_ENTRIES = 500

/** Append-only ring buffer of live audit entries pushed via SSE. */
export const auditEntries = signal<AuditEntry[]>([])

/** Append a single audit entry from an SSE event.  Trims to the
 *  most recent AUDIT_MAX_ENTRIES to keep memory bounded. */
export function appendAuditEntry(entry: AuditEntry): void {
  const next = [...auditEntries.value, entry]
  auditEntries.value =
    next.length > AUDIT_MAX_ENTRIES
      ? next.slice(next.length - AUDIT_MAX_ENTRIES)
      : next
}
