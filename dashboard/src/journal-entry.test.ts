import { describe, expect, it } from 'vitest'
import {
  defaultJournalSeverity,
  isErrorJournalEntry,
  journalSeverity,
  normalizeJournalSeverity,
} from './journal-entry'
import type { JournalEntry } from './types'

function makeEntry(overrides: Partial<JournalEntry> = {}): JournalEntry {
  return {
    agent: 'keeper-a',
    text: 'test entry',
    timestamp: Date.now(),
    ...overrides,
  }
}

describe('journal severity helpers', () => {
  it('marks keeper guardrail entries as errors even without text heuristics', () => {
    expect(defaultJournalSeverity('keeper_guardrail')).toBe('error')
    expect(isErrorJournalEntry(makeEntry({ eventType: 'keeper_guardrail', text: 'stopped by guardrail' }))).toBe(true)
  })

  it('prefers explicit severity when present', () => {
    expect(normalizeJournalSeverity('warning')).toBe('warn')
    expect(normalizeJournalSeverity('fatal')).toBe('error')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', severity: 'warn' }))).toBe('warn')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', severity: 'error' }))).toBe('error')
  })

  it('falls back to conservative legacy text classification when severity is missing', () => {
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: '[ERROR] gRPC server failed: bind' }))).toBe('error')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: '[WARN] retrying stream reconnect' }))).toBe('warn')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: 'error budget update' }))).toBe('info')
  })

  it('handles case-insensitive legacy markers and empty text safely', () => {
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: '[error] timeout waiting for stream' }))).toBe('error')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: 'Retrying stream reconnect' }))).toBe('warn')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: '' }))).toBe('info')
  })
})
