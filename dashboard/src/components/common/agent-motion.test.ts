import { describe, it, expect } from 'vitest'
import { normalizeAgentKey } from './agent-motion'

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
