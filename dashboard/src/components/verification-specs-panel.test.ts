import { describe, it, expect } from 'vitest'
import {
  categoryLabel,
  categoryTone,
  cfgCoverage,
  shortMtime,
} from './verification-specs-panel'
import type { TlaSpecEntry } from '../api/dashboard'

function makeEntry(overrides: Partial<TlaSpecEntry> = {}): TlaSpecEntry {
  return {
    name: 'TestSpec',
    path: '/specs/test',
    category: 'boundary',
    has_clean_cfg: true,
    has_buggy_cfg: true,
    mtime_iso: '2026-04-16T12:00:00Z',
    ...overrides,
  }
}

describe('categoryLabel', () => {
  it('returns Korean label for boundary', () => {
    expect(categoryLabel('boundary')).toBe('경계')
  })

  it('returns Korean label for bug-models', () => {
    expect(categoryLabel('bug-models')).toBe('버그 모델')
  })

  it('returns fallback for other', () => {
    expect(categoryLabel('other')).toBe('기타')
  })
})

describe('categoryTone', () => {
  it('returns ok for boundary', () => {
    expect(categoryTone('boundary')).toBe('ok')
  })

  it('returns warn for bug-models', () => {
    expect(categoryTone('bug-models')).toBe('warn')
  })

  it('returns neutral for other', () => {
    expect(categoryTone('other')).toBe('neutral')
  })
})

describe('cfgCoverage', () => {
  it('returns ok tone when both clean and buggy cfg exist', () => {
    const result = cfgCoverage(makeEntry({ has_clean_cfg: true, has_buggy_cfg: true }))
    expect(result.label).toBe('clean + buggy')
    expect(result.tone).toBe('ok')
  })

  it('returns warn tone when only clean cfg exists', () => {
    const result = cfgCoverage(makeEntry({ has_clean_cfg: true, has_buggy_cfg: false }))
    expect(result.label).toBe('clean only')
    expect(result.tone).toBe('warn')
  })

  it('returns warn tone when only buggy cfg exists', () => {
    const result = cfgCoverage(makeEntry({ has_clean_cfg: false, has_buggy_cfg: true }))
    expect(result.label).toBe('buggy only')
    expect(result.tone).toBe('warn')
  })

  it('returns err tone when no cfg exists', () => {
    const result = cfgCoverage(makeEntry({ has_clean_cfg: false, has_buggy_cfg: false }))
    expect(result.label).toBe('no cfg')
    expect(result.tone).toBe('err')
  })
})

describe('shortMtime', () => {
  it('extracts date portion from ISO string', () => {
    expect(shortMtime('2026-04-16T12:34:56Z')).toBe('2026-04-16')
  })

  it('handles already-short string', () => {
    expect(shortMtime('2026-04-16')).toBe('2026-04-16')
  })

  it('handles empty string', () => {
    expect(shortMtime('')).toBe('')
  })

  it('handles short string gracefully', () => {
    expect(shortMtime('2026')).toBe('2026')
  })
})
