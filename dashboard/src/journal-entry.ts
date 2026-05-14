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

export function journalSeverity(entry: JournalEntry): JournalSeverity {
  const explicit = normalizeJournalSeverity(entry.severity)
  if (explicit !== 'unknown') return explicit

  return defaultJournalSeverity(entry.eventType)
}

export function isErrorJournalEntry(entry: JournalEntry): boolean {
  return journalSeverity(entry) === 'error'
}
