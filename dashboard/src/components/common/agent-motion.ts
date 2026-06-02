import { formatPct } from '../../lib/format-number'
import type { Message, Task, JournalEntry, BoardPost, Keeper } from '../../types'
import { trimText as trimTextBase } from '../../lib/truncate'

export interface AgentMotionSnapshot {
  activeAssignedCount: number
  lastActivityAt: string | null
  lastActivityText: string | null
}

interface AgentMotionOptions {
  currentTask?: string | null
  lastSeen?: string | null
  boardPosts?: BoardPost[]
  keepers?: Keeper[]
}

export function normalizeAgentKey(value: string | null | undefined): string {
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
  return trimTextBase(value, max) ?? ''
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
  const ratio = formatPct(keeper.context_ratio, '?')
  return keeper.last_heartbeat
    ? `Heartbeat gen=${generation} ctx=${ratio}`
    : `Keeper snapshot gen=${generation} ctx=${ratio}`
}

export function buildAgentMotion(
  tasks: Task[],
  messages: Message[],
  journal: JournalEntry[],
  options: AgentMotionOptions = {},
): AgentMotionSnapshot {
  // Callers should pre-filter arrays by agent key before calling.
  // This function only sorts and picks the most recent entries.
  const activeAssignedCount = tasks.filter(task =>
    task.status === 'claimed' || task.status === 'in_progress'
  ).length

  const recentMessage = messages
    .slice().sort((a, b) => toEpoch(b.timestamp ?? '') - toEpoch(a.timestamp ?? ''))[0]

  const recentJournal = journal
    .slice().sort((a, b) => toEpoch(b.timestamp) - toEpoch(a.timestamp))[0]

  const recentBoardPost = (options.boardPosts ?? [])
    .slice().sort((a, b) => toEpoch(b.updated_at || b.created_at) - toEpoch(a.updated_at || a.created_at))[0]

  const recentKeeper = (options.keepers ?? [])
    .filter(keeper => keeperSignalTimestamp(keeper) !== null)
    .sort((a, b) => toEpoch(keeperSignalTimestamp(b) ?? 0) - toEpoch(keeperSignalTimestamp(a) ?? 0))[0]

  const messageTs = recentMessage ? toEpoch(recentMessage.timestamp ?? '') : 0
  const journalTs = recentJournal ? toEpoch(recentJournal.timestamp) : 0
  const boardTs = recentBoardPost ? toEpoch(recentBoardPost.updated_at || recentBoardPost.created_at) : 0
  const keeperTs = recentKeeper ? toEpoch(keeperSignalTimestamp(recentKeeper) ?? 0) : 0
  const lastSeenTs = options.lastSeen ? toEpoch(options.lastSeen) : 0

  const fallbackText =
    options.currentTask?.trim()
    || (activeAssignedCount > 0 ? `${activeAssignedCount} claimed tasks` : null)

  if (messageTs === 0 && journalTs === 0 && boardTs === 0 && keeperTs === 0 && lastSeenTs === 0) {
    return {
      activeAssignedCount,
      lastActivityAt: null,
      lastActivityText: fallbackText,
    }
  }

  const candidates = [
    recentMessage
      ? {
          timestamp: recentMessage.timestamp,
          ts: messageTs,
          text: trimText(recentMessage.content),
        }
      : null,
    recentBoardPost
      ? {
          timestamp: recentBoardPost.updated_at || recentBoardPost.created_at,
          ts: boardTs,
          text: `Post: ${trimText(boardPreview(recentBoardPost))}`,
        }
      : null,
    recentKeeper
      ? {
          timestamp: keeperSignalTimestamp(recentKeeper),
          ts: keeperTs,
          text: keeperPreview(recentKeeper),
        }
      : null,
    recentJournal
      ? {
          timestamp: new Date(recentJournal.timestamp).toISOString(),
          ts: journalTs,
          text: trimText(recentJournal.text),
        }
      : null,
  ]
    .filter((candidate): candidate is { timestamp: string | null; ts: number; text: string } => candidate !== null)
    .sort((a, b) => b.ts - a.ts)

  const latest = candidates[0]
  if (latest && latest.ts >= lastSeenTs) {
    return {
      activeAssignedCount,
      lastActivityAt: latest.timestamp,
      lastActivityText: latest.text,
    }
  }

  return {
    activeAssignedCount,
    lastActivityAt: options.lastSeen ?? null,
    lastActivityText: fallbackText ?? '프레즌스 하트비트',
  }
}
