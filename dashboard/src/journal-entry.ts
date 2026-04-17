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
