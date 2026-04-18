import { describe, expect, it } from 'vitest'

import {
  doctorHeading,
  extractConfigNotes,
  extractSidecarChecks,
  severityChipClass,
  severityForExitCode,
  severityLabel,
  summaryLine,
  type DoctorEntry,
  type DoctorSummary,
} from './doctor-panel'

describe('severityForExitCode', () => {
  it('maps 0 to ok', () => {
    expect(severityForExitCode(0)).toBe('ok')
  })
  it('maps 1 to warn', () => {
    expect(severityForExitCode(1)).toBe('warn')
  })
  it('maps 2 to error', () => {
    expect(severityForExitCode(2)).toBe('error')
  })
  it('treats signal / junk exit codes as error', () => {
    expect(severityForExitCode(137)).toBe('error')
    expect(severityForExitCode(-1)).toBe('error')
  })
})

describe('severityLabel', () => {
  it('renders Korean labels', () => {
    expect(severityLabel(0)).toBe('정상')
    expect(severityLabel(1)).toBe('경고')
    expect(severityLabel(2)).toBe('오류')
  })
  it('unknown rc → 오류', () => {
    expect(severityLabel(255)).toBe('오류')
  })
})

describe('severityChipClass', () => {
  it('uses ok palette for 0', () => {
    const cls = severityChipClass(0)
    expect(cls).toContain('var(--ok')
    expect(cls).not.toContain('var(--bad')
  })
  it('uses warn palette for 1', () => {
    const cls = severityChipClass(1)
    expect(cls).toContain('var(--warn')
  })
  it('uses bad palette for error', () => {
    const cls = severityChipClass(2)
    expect(cls).toContain('var(--bad')
  })
})

describe('doctorHeading', () => {
  it('returns Config for config entries', () => {
    const entry: DoctorEntry = {
      name: 'config',
      kind: 'config',
      exit_code: 0,
      payload: {},
    }
    expect(doctorHeading(entry)).toBe('Config')
  })
  it('capitalises sidecar names', () => {
    const entry: DoctorEntry = {
      name: 'discord',
      kind: 'sidecar',
      exit_code: 2,
      payload: {},
    }
    expect(doctorHeading(entry)).toBe('Discord')
  })
  it('capitalises cli too', () => {
    const entry: DoctorEntry = {
      name: 'cli',
      kind: 'sidecar',
      exit_code: 1,
      payload: {},
    }
    expect(doctorHeading(entry)).toBe('Cli')
  })
})

describe('summaryLine', () => {
  it('formats aggregate with Korean middot separators', () => {
    const summary: DoctorSummary = { total: 6, ok: 3, warn: 2, error: 1 }
    expect(summaryLine(summary)).toBe(
      '6 Doctor · 정상 3 · 경고 2 · 오류 1',
    )
  })
  it('all-ok summary shows zeros', () => {
    const summary: DoctorSummary = { total: 6, ok: 6, warn: 0, error: 0 }
    expect(summaryLine(summary)).toBe(
      '6 Doctor · 정상 6 · 경고 0 · 오류 0',
    )
  })
})

describe('extractSidecarChecks', () => {
  it('returns empty for non-objects', () => {
    expect(extractSidecarChecks(null)).toEqual([])
    expect(extractSidecarChecks(42)).toEqual([])
    expect(extractSidecarChecks('string')).toEqual([])
  })
  it('returns empty when checks field is missing or wrong type', () => {
    expect(extractSidecarChecks({})).toEqual([])
    expect(extractSidecarChecks({ checks: 'not-array' })).toEqual([])
  })
  it('filters out entries missing name or severity', () => {
    const out = extractSidecarChecks({
      checks: [
        { name: 'a', severity: 'ok' },
        { name: 'b' }, // missing severity
        { severity: 'warn' }, // missing name
        null,
        { name: 'c', severity: 'error', message: 'boom', detail: 'x', hint: 'do X' },
      ],
    })
    expect(out).toHaveLength(2)
    expect(out[0]).toEqual({ name: 'a', severity: 'ok' })
    expect(out[1]).toEqual({
      name: 'c',
      severity: 'error',
      message: 'boom',
      detail: 'x',
      hint: 'do X',
    })
  })
  it('omits empty string optional fields', () => {
    const out = extractSidecarChecks({
      checks: [{ name: 'a', severity: 'ok', message: '', detail: '', hint: '' }],
    })
    expect(out[0]).toEqual({ name: 'a', severity: 'ok' })
  })
})

describe('extractConfigNotes', () => {
  it('returns empty for non-objects', () => {
    expect(extractConfigNotes(null)).toEqual({ warnings: [], next_actions: [] })
    expect(extractConfigNotes([])).toEqual({ warnings: [], next_actions: [] })
  })
  it('filters non-string entries', () => {
    const out = extractConfigNotes({
      warnings: ['w1', 42, 'w2', null],
      next_actions: ['a1'],
    })
    expect(out.warnings).toEqual(['w1', 'w2'])
    expect(out.next_actions).toEqual(['a1'])
  })
  it('handles missing fields', () => {
    expect(extractConfigNotes({})).toEqual({ warnings: [], next_actions: [] })
    expect(extractConfigNotes({ warnings: ['only w'] })).toEqual({
      warnings: ['only w'],
      next_actions: [],
    })
  })
})
