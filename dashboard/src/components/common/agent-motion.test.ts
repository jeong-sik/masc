import { describe, it, expect } from 'vitest'
import { normalizeAgentKey, toEpoch, boardPreview } from './agent-motion'
import type { BoardPost } from '../../types'

describe('normalizeAgentKey', () => {
  it('returns lowercase trimmed string', () => {
    expect(normalizeAgentKey('  Hello World  ')).toBe('hello world')
  })

  it('returns empty string for null', () => {
    expect(normalizeAgentKey(null)).toBe('')
  })

  it('returns empty string for undefined', () => {
    expect(normalizeAgentKey(undefined)).toBe('')
  })

  it('returns empty string for empty string', () => {
    expect(normalizeAgentKey('')).toBe('')
  })

  it('lowercases and trims', () => {
    expect(normalizeAgentKey('  Keeper-A  ')).toBe('keeper-a')
  })
})

describe('toEpoch', () => {
  it('returns number unchanged if valid', () => {
    expect(toEpoch(1711440000000)).toBe(1711440000000)
  })

  it('parses ISO string to epoch ms', () => {
    const result = toEpoch('2024-03-26T00:00:00.000Z')
    expect(result).toBeGreaterThan(0)
    expect(typeof result).toBe('number')
  })

  it('returns 0 for invalid date string', () => {
    expect(toEpoch('not-a-date')).toBe(0)
  })

  it('returns 0 for NaN input', () => {
    expect(toEpoch(Number.NaN)).toBe(0)
  })

  it('handles zero', () => {
    expect(toEpoch(0)).toBe(0)
  })
})

describe('boardPreview', () => {
  function makePost(overrides: Partial<BoardPost> = {}): BoardPost {
    return {
      id: 'post-1',
      title: '',
      content: '',
      body: '',
      author: 'agent-a',
      tags: [],
      votes: 0,
      comment_count: 0,
      created_at: '2024-03-26T00:00:00Z',
      updated_at: '2024-03-26T00:00:00Z',
      ...overrides,
    }
  }

  it('returns trimmed title when present', () => {
    expect(boardPreview(makePost({ title: '  Hello  ', content: 'world' }))).toBe('Hello')
  })

  it('returns trimmed content when title is empty', () => {
    expect(boardPreview(makePost({ title: '', content: 'some content here' }))).toBe('some content here')
  })

  it('returns trimmed content when title is whitespace', () => {
    expect(boardPreview(makePost({ title: '   ', content: 'fallback' }))).toBe('fallback')
  })
})
