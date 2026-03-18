import type { JournalEntry, JournalEventType } from './types'

export function classifyJournalKind(entry: JournalEntry): 'board' | 'tasks' | 'keepers' | 'system' | 'oas' {
  if (entry.kind) return entry.kind

  switch (entry.eventType) {
    case 'board_post':
    case 'board_comment':
      return 'board'
    case 'task_update':
      return 'tasks'
    case 'keeper_heartbeat':
    case 'keeper_handoff':
    case 'keeper_compaction':
    case 'keeper_guardrail':
      return 'keepers'
    default:
      return 'system'
  }
}

export function journalActor(entry: JournalEntry): string {
  return entry.author?.trim() || entry.agent?.trim() || 'system'
}

export function journalDisplayText(entry: JournalEntry): string {
  switch (entry.eventType) {
    case 'board_post':
      return entry.preview ? `Post: ${entry.preview}` : (entry.text || 'New post')
    case 'board_comment':
      return entry.preview ? `Comment: ${entry.preview}` : (entry.text || 'New comment')
    default:
      return entry.text
  }
}

export function journalEventLabel(entry: JournalEntry): JournalEventType | 'event' {
  if (!entry.eventType || entry.eventType === 'unknown') return 'event'
  return entry.eventType
}
