import type { Message, Task, JournalEntry } from '../../types'

export interface AgentMotionSnapshot {
  activeAssignedCount: number
  lastActivityAt: string | null
  lastActivityText: string | null
}

interface AgentMotionOptions {
  currentTask?: string | null
  lastSeen?: string | null
}

function normalizeAgentKey(value: string | null | undefined): string {
  return (value ?? '').trim().toLowerCase()
}

function toEpoch(value: string | number): number {
  const parsed =
    typeof value === 'number'
      ? value
      : Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function trimText(value: string, max = 88): string {
  const normalized = value.replace(/\s+/g, ' ').trim()
  if (!normalized) return normalized
  return normalized.length > max ? `${normalized.slice(0, max - 3)}...` : normalized
}

export function buildAgentMotion(
  agentName: string,
  tasks: Task[],
  messages: Message[],
  journal: JournalEntry[],
  options: AgentMotionOptions = {},
): AgentMotionSnapshot {
  const agentKey = normalizeAgentKey(agentName)
  const activeAssignedCount = tasks.filter(task =>
    normalizeAgentKey(task.assignee) === agentKey
    && (task.status === 'claimed' || task.status === 'in_progress')
  ).length

  const recentMessage = messages
    .filter(message => normalizeAgentKey(message.from) === agentKey)
    .sort((a, b) => toEpoch(b.timestamp) - toEpoch(a.timestamp))[0]

  const recentJournal = journal
    .filter(entry =>
      normalizeAgentKey(entry.agent) === agentKey
      || normalizeAgentKey(entry.author) === agentKey
    )
    .sort((a, b) => toEpoch(b.timestamp) - toEpoch(a.timestamp))[0]

  const messageTs = recentMessage ? toEpoch(recentMessage.timestamp) : 0
  const journalTs = recentJournal ? toEpoch(recentJournal.timestamp) : 0
  const lastSeenTs = options.lastSeen ? toEpoch(options.lastSeen) : 0

  const fallbackText =
    options.currentTask?.trim()
    || (activeAssignedCount > 0 ? `${activeAssignedCount} claimed tasks` : null)

  if (messageTs === 0 && journalTs === 0 && lastSeenTs === 0) {
    return {
      activeAssignedCount,
      lastActivityAt: null,
      lastActivityText: fallbackText,
    }
  }

  if (messageTs >= journalTs && recentMessage) {
    if (messageTs >= lastSeenTs) {
      return {
        activeAssignedCount,
        lastActivityAt: recentMessage.timestamp,
        lastActivityText: trimText(recentMessage.content),
      }
    }
  }

  if (journalTs >= lastSeenTs && recentJournal) {
    return {
      activeAssignedCount,
      lastActivityAt: new Date(recentJournal.timestamp).toISOString(),
      lastActivityText: trimText(recentJournal.text),
    }
  }

  return {
    activeAssignedCount,
    lastActivityAt: options.lastSeen ?? null,
    lastActivityText: fallbackText ?? 'Presence heartbeat',
  }
}
