// @ts-nocheck
import { describe, expect, it } from 'vitest'
import {
  normalizeBranch,
  unwrapRepository,
  branchRows,
  normalizeRepoStatus,
  formatDate,
} from './repo-detail-panel'
import type { BranchInfo } from './repo-detail-panel'

describe('normalizeBranch', () => {
  it('returns null for null input', () => {
    expect(normalizeBranch(null)).toBeNull()
  })

  it('returns null for non-object input', () => {
    expect(normalizeBranch('string')).toBeNull()
    expect(normalizeBranch(42)).toBeNull()
    expect(normalizeBranch(undefined)).toBeNull()
  })

  it('returns null when name is missing or empty', () => {
    expect(normalizeBranch({})).toBeNull()
    expect(normalizeBranch({ name: '' })).toBeNull()
    expect(normalizeBranch({ name: 123 })).toBeNull()
  })

  it('returns BranchInfo for a fully populated object', () => {
    const raw = {
      name: 'main',
      is_default: true,
      is_remote: false,
      last_commit_at: '2024-01-15T10:30:00Z',
    }
    expect(normalizeBranch(raw)).toEqual({
      name: 'main',
      is_default: true,
      is_remote: false,
      last_commit_at: '2024-01-15T10:30:00Z',
    })
  })

  it('defaults booleans to false and last_commit_at to null when absent', () => {
    const raw = { name: 'feature-x' }
    expect(normalizeBranch(raw)).toEqual({
      name: 'feature-x',
      is_default: false,
      is_remote: false,
      last_commit_at: null,
    })
  })

  it('treats truthy non-boolean as false for boolean fields', () => {
    const raw = {
      name: 'dev',
      is_default: 'yes',
      is_remote: 1,
      last_commit_at: null,
    }
    expect(normalizeBranch(raw)).toEqual({
      name: 'dev',
      is_default: false,
      is_remote: false,
      last_commit_at: null,
    })
  })
})

describe('unwrapRepository', () => {
  it('throws for null input', () => {
    expect(() => unwrapRepository(null)).toThrow('Invalid repository response')
  })

  it('throws for non-object input', () => {
    expect(() => unwrapRepository('text')).toThrow('Invalid repository response')
    expect(() => unwrapRepository(42)).toThrow('Invalid repository response')
  })

  it('unwraps { ok: true, data: {...} } wrapper', () => {
    const inner = { id: 'r1', name: 'repo' }
    expect(unwrapRepository({ ok: true, data: inner })).toEqual(inner)
  })

  it('returns the record directly when not wrapped', () => {
    const record = { id: 'r2', name: 'direct' }
    expect(unwrapRepository(record)).toEqual(record)
  })

  it('returns record when ok is not true', () => {
    const record = { ok: false, data: { id: 'r3' } }
    expect(unwrapRepository(record)).toEqual(record)
  })
})

describe('branchRows', () => {
  it('returns the array directly when input is an array', () => {
    const arr = [{ name: 'a' }, { name: 'b' }]
    expect(branchRows(arr)).toEqual(arr)
  })

  it('extracts .branches when input is an object with branches array', () => {
    const branches = [{ name: 'a' }]
    expect(branchRows({ branches })).toEqual(branches)
  })

  it('extracts .data when input is { ok: true, data: [...] }', () => {
    const data = [{ name: 'c' }]
    expect(branchRows({ ok: true, data })).toEqual(data)
  })

  it('returns empty array for null', () => {
    expect(branchRows(null)).toEqual([])
  })

  it('returns empty array for non-object, non-array input', () => {
    expect(branchRows('text')).toEqual([])
    expect(branchRows(42)).toEqual([])
  })

  it('returns empty array when object has no known array property', () => {
    expect(branchRows({ other: [] })).toEqual([])
  })
})

describe('normalizeRepoStatus', () => {
  it.each([
    ['active', 'active'],
    ['ACTIVE', 'active'],
    ['Active', 'active'],
    ['paused', 'paused'],
    ['PAUSED', 'paused'],
    ['Paused', 'paused'],
    ['cloning', 'active'],
    ['CLONING', 'active'],
    ['error', 'error'],
    ['ERROR', 'error'],
    ['Error', 'error'],
  ] as const)('normalizeRepoStatus(%s) → %s', (input, expected) => {
    expect(normalizeRepoStatus(input)).toBe(expected)
  })

  it('defaults to active for unknown or undefined input', () => {
    expect(normalizeRepoStatus(undefined)).toBe('active')
    expect(normalizeRepoStatus('unknown')).toBe('active')
    expect(normalizeRepoStatus('')).toBe('active')
  })
})

describe('formatDate', () => {
  it('returns -- for null', () => {
    expect(formatDate(null)).toBe('--')
  })

  it('returns -- for empty string', () => {
    expect(formatDate('')).toBe('--')
  })

  it('formats an ISO date string', () => {
    const result = formatDate('2024-01-15T10:30:00Z')
    expect(result).toContain('2024')
    expect(result).toContain('01')
    expect(result).toContain('15')
  })

  it('formats a numeric Unix timestamp', () => {
    const ts = 1705315800 // 2024-01-15T10:30:00Z
    const result = formatDate(ts)
    expect(result).toContain('2024')
    expect(result).toContain('01')
    expect(result).toContain('15')
  })

  it('returns the raw value for invalid date string', () => {
    expect(formatDate('not-a-date')).toBe('not-a-date')
  })

  it('returns the raw value for invalid numeric timestamp', () => {
    expect(formatDate(Number.NaN)).toBe('NaN')
  })
})
