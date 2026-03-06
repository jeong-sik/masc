import type { Message, Task, JournalEntry, BoardPost, Keeper } from '../../types'

export interface AgentMotionSnapshot {
  activeAssignedCount: number
  lastActivityAt: string | null
  lastActivityText: string | null
}

interface AgentMotionSources {
  boardPosts?: BoardPost[]
  keepers?: Keeper[]
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

function timestampFromAgeSeconds(ageSeconds: number | null | undefined): string | null {
  if (typeof ageSeconds !== 'number' || !Number.isFinite(ageSeconds) || ageSeconds < 0) return null
  return new Date(Date.now() - ageSeconds * 1000).toISOString()
}

function keeperSignalTimestamp(keeper: Keeper): string | null {
  return keeper.last_heartbeat
    ?? timestampFromAgeSeconds(keeper.last_turn_ago_s)
    ?? timestampFromAgeSeconds(keeper.last_proactive_ago_s)
    ?? timestampFromAgeSeconds(keeper.last_handoff_ago_s)
    ?? timestampFromAgeSeconds(keeper.last_compaction_ago_s)
}

function boardPreview(post: BoardPost): string {
  const title = post.title.trim()
  if (title) return title
  return trimText(post.content)
}

function keeperPreview(keeper: Keeper): string {
  const generation = keeper.generation ?? '?'
  const ratio = typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio)
    ? `${Math.round(keeper.context_ratio * 100)}%`
    : '?'
  return keeper.last_heartbeat
    ? `Heartbeat gen=${generation} ctx=${ratio}`
    : `Keeper snapshot gen=${generation} ctx=${ratio}`
}

export function buildAgentMotion(
  agentName: string,
  tasks: Task[],
  messages: Message[],
  journal: JournalEntry[],
  sources: AgentMotionSources = {},
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
    .filter(entry => normalizeAgentKey(entry.agent) === agentKey)
    .sort((a, b) => toEpoch(b.timestamp) - toEpoch(a.timestamp))[0]

  const recentBoardPost = (sources.boardPosts ?? [])
    .filter(post => normalizeAgentKey(post.author) === agentKey)
    .sort((a, b) => toEpoch(b.updated_at || b.created_at) - toEpoch(a.updated_at || a.created_at))[0]

  const recentKeeper = (sources.keepers ?? [])
    .filter(keeper => normalizeAgentKey(keeper.name) === agentKey && keeperSignalTimestamp(keeper) !== null)
    .sort((a, b) => toEpoch(keeperSignalTimestamp(b) ?? 0) - toEpoch(keeperSignalTimestamp(a) ?? 0))[0]

  const messageTs = recentMessage ? toEpoch(recentMessage.timestamp) : 0
  const journalTs = recentJournal ? toEpoch(recentJournal.timestamp) : 0
  const boardTs = recentBoardPost ? toEpoch(recentBoardPost.updated_at || recentBoardPost.created_at) : 0
  const keeperTs = recentKeeper ? toEpoch(keeperSignalTimestamp(recentKeeper) ?? 0) : 0

  if (messageTs === 0 && journalTs === 0 && boardTs === 0 && keeperTs === 0) {
    return {
      activeAssignedCount,
      lastActivityAt: null,
      lastActivityText: activeAssignedCount > 0 ? `${activeAssignedCount} claimed tasks` : null,
    }
  }

  if (messageTs >= journalTs && recentMessage) {
    return {
      activeAssignedCount,
      lastActivityAt: recentMessage.timestamp,
      lastActivityText: trimText(recentMessage.content),
    }
  }

  if (boardTs >= journalTs && boardTs >= keeperTs && recentBoardPost) {
    return {
      activeAssignedCount,
      lastActivityAt: recentBoardPost.updated_at || recentBoardPost.created_at,
      lastActivityText: `Post: ${trimText(boardPreview(recentBoardPost))}`,
    }
  }

  if (keeperTs >= journalTs && recentKeeper) {
    return {
      activeAssignedCount,
      lastActivityAt: keeperSignalTimestamp(recentKeeper),
      lastActivityText: keeperPreview(recentKeeper),
    }
  }

  return {
    activeAssignedCount,
    lastActivityAt: recentJournal ? new Date(recentJournal.timestamp).toISOString() : null,
    lastActivityText: recentJournal ? trimText(recentJournal.text) : null,
  }
}
