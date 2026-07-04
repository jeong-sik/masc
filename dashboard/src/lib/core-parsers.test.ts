import { describe, expect, it } from 'vitest'
import {
  EVIDENCE_SOURCE_VALUES,
  EXECUTION_TONE_VALUES,
  SIGNAL_TRUTH_VALUES,
  TASK_STATUS_VALUES,
  parseEvidenceSource,
  parseExecutionTone,
  parseSignalTruth,
  parseTaskStatus,
} from './core-parsers'

describe('parseTaskStatus (trim + lowercase + inprogress alias)', () => {
  it('accepts every canonical value', () => {
    for (const v of TASK_STATUS_VALUES) expect(parseTaskStatus(v)).toBe(v)
  })
  it('trims and lowercases', () => {
    expect(parseTaskStatus('  DONE ')).toBe('done')
    expect(parseTaskStatus('In_Progress')).toBe('in_progress')
  })
  it('maps the legacy inprogress alias', () => {
    expect(parseTaskStatus('inprogress')).toBe('in_progress')
    expect(parseTaskStatus('InProgress')).toBe('in_progress')
  })
  it('returns undefined for unknown / non-string', () => {
    expect(parseTaskStatus('bogus')).toBeUndefined()
    expect(parseTaskStatus(42)).toBeUndefined()
    expect(parseTaskStatus(undefined)).toBeUndefined()
  })
})

describe('parseExecutionTone (lowercase, NO trim)', () => {
  it('accepts every canonical value', () => {
    for (const v of EXECUTION_TONE_VALUES) expect(parseExecutionTone(v)).toBe(v)
  })
  it('lowercases', () => {
    expect(parseExecutionTone('OK')).toBe('ok')
  })
  it('does NOT trim (preserves original callsite behavior)', () => {
    expect(parseExecutionTone(' ok ')).toBeUndefined()
  })
  it('returns undefined for unknown', () => {
    expect(parseExecutionTone('info')).toBeUndefined()
    expect(parseExecutionTone(null)).toBeUndefined()
  })
})

describe('parseSignalTruth (case-sensitive)', () => {
  it('accepts every canonical value', () => {
    for (const v of SIGNAL_TRUTH_VALUES) expect(parseSignalTruth(v)).toBe(v)
  })
  it('is case-sensitive', () => {
    expect(parseSignalTruth('LIVE')).toBeUndefined()
  })
  it('returns undefined for undefined / unknown', () => {
    expect(parseSignalTruth(undefined)).toBeUndefined()
    expect(parseSignalTruth('archived')).toBeUndefined()
  })
})

describe('parseEvidenceSource (case-sensitive)', () => {
  it('accepts every canonical value', () => {
    for (const v of EVIDENCE_SOURCE_VALUES) expect(parseEvidenceSource(v)).toBe(v)
  })
  it('is case-sensitive', () => {
    expect(parseEvidenceSource('MESSAGE')).toBeUndefined()
  })
  it('returns undefined for undefined / unknown', () => {
    expect(parseEvidenceSource(undefined)).toBeUndefined()
    expect(parseEvidenceSource('session')).toBeUndefined()
  })
})
