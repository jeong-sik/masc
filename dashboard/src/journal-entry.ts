import type { JournalEntry, JournalEventType, JournalSeverity, JournalSource } from './types'

export function normalizeJournalSeverity(value: string | null | undefined): JournalSeverity {
  const normalized = (value ?? '').trim().toLowerCase()
  switch (normalized) {
    case 'debug':
      return 'debug'
    case 'info':
      return 'info'
    case 'warn':
    case 'warning':
    case 'degraded':
      return 'warn'
    case 'error':
    case 'fatal':
    case 'critical':
    case 'failed':
      return 'error'
    default:
      return 'unknown'
  }
}

export function normalizeJournalSource(value: string | null | undefined): JournalSource {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'structured':
      return 'structured'
    case 'legacy_stderr':
      return 'legacy_stderr'
    case 'legacy_traceln':
      return 'legacy_traceln'
    default:
      return 'sse'
  }
}

export function defaultJournalSeverity(eventType: JournalEventType | undefined): JournalSeverity {
  switch (eventType) {
    case 'keeper_guardrail':
      return 'error'
    case 'unknown':
      return 'unknown'
    default:
      return 'info'
  }
}

function legacyJournalSeverityFromText(text: string | undefined): JournalSeverity {
  const normalized = (text ?? '').trim().toLowerCase()
  if (!normalized) return 'unknown'
  if (
    normalized.startsWith('[error]')
    || normalized.startsWith('[fatal]')
    || /\b(failed|failure|fatal|exception|timed out|timeout|crash(?:ed)?)\b/.test(normalized)
  ) {
    return 'error'
  }
  if (
    normalized.startsWith('[warn]')
    || normalized.startsWith('[warning]')
    || /\b(warn(?:ing)?|degraded|retry(?:ing)?)\b/.test(normalized)
  ) {
    return 'warn'
  }
  return 'unknown'
}

export function journalSeverity(entry: JournalEntry): JournalSeverity {
  const explicit = normalizeJournalSeverity(entry.severity)
  if (explicit !== 'unknown') return explicit

  const fallback = defaultJournalSeverity(entry.eventType)
  if (fallback === 'error' || fallback === 'warn') return fallback

  const legacy = legacyJournalSeverityFromText(entry.text)
  return legacy === 'unknown' ? fallback : legacy
}

export function isErrorJournalEntry(entry: JournalEntry): boolean {
  return journalSeverity(entry) === 'error'
}

export function classifyJournalKind(entry: JournalEntry): 'board' | 'tasks' | 'keepers' | 'system' | 'oas' {
  if (entry.kind) return entry.kind

  switch (entry.eventType) {
    case 'board_post':
    case 'board_comment':
    case 'board_delete':
    case 'board_vote':
      return 'board'
    case 'task_update':
      return 'tasks'
    case 'keeper_heartbeat':
    case 'keeper_handoff':
    case 'keeper_compaction':
    case 'keeper_guardrail':
    case 'keeper_phase_changed':
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
    case 'board_vote':
      return entry.text || 'Vote'
    default:
      return entry.text
  }
}

export function journalEventLabel(entry: JournalEntry): JournalEventType | 'event' {
  if (!entry.eventType || entry.eventType === 'unknown') return 'event'
  return entry.eventType
}
