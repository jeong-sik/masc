import { describe, expect, it } from 'vitest'
import {
  defaultJournalSeverity,
  isErrorJournalEntry,
  journalSeverity,
  normalizeJournalSeverity,
  normalizeJournalSource,
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

  it('does not infer severity by parsing journal text', () => {
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: '[ERROR] gRPC server failed: bind' }))).toBe('info')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: '[WARN] retrying stream reconnect' }))).toBe('info')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: 'error budget update' }))).toBe('info')
    expect(journalSeverity(makeEntry({ eventType: 'broadcast', text: '' }))).toBe('info')
  })
})

describe('normalizeJournalSource', () => {
  it('maps each recognized source string to its first-class variant', () => {
    expect(normalizeJournalSource('structured')).toBe('structured')
    expect(normalizeJournalSource('legacy_stderr')).toBe('legacy_stderr')
    expect(normalizeJournalSource('legacy_traceln')).toBe('legacy_traceln')
    expect(normalizeJournalSource('sse')).toBe('sse')
  })

  it('is case-insensitive and trims whitespace', () => {
    expect(normalizeJournalSource('  Structured ')).toBe('structured')
    expect(normalizeJournalSource('SSE')).toBe('sse')
  })

  it("returns 'unknown' for unrecognized strings instead of silently coercing to 'sse'", () => {
    // Anti-pattern §2 escape: the previous default arm classified every
    // unrecognized source as a normal SSE event, so a malformed wire
    // record looked indistinguishable from a real SSE entry downstream.
    // The 'unknown' variant surfaces the parse failure explicitly.
    expect(normalizeJournalSource(null)).toBe('unknown')
    expect(normalizeJournalSource(undefined)).toBe('unknown')
    expect(normalizeJournalSource('')).toBe('unknown')
    expect(normalizeJournalSource('garbled')).toBe('unknown')
    expect(normalizeJournalSource('streamed')).toBe('unknown')
  })
})
