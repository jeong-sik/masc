import { describe, it, expect } from 'vitest'
import { truncateLabel, spanStyle } from './activity-swimlane'

describe('truncateLabel', () => {
  it('returns short strings unchanged', () => {
    expect(truncateLabel('hello')).toBe('hello')
  })

  it('truncates strings exceeding max length', () => {
    const input = 'a'.repeat(25)
    expect(truncateLabel(input)).toBe('a'.repeat(18) + '..')
  })

  it('respects custom max length', () => {
    expect(truncateLabel('abcdefghij', 8)).toBe('abcdef..')
  })

  it('does not truncate at exactly max length', () => {
    const input = 'a'.repeat(20)
    expect(truncateLabel(input)).toBe(input)
  })

  it('truncates at max+1 length', () => {
    const input = 'a'.repeat(21)
    expect(truncateLabel(input)).toBe('a'.repeat(18) + '..')
  })

  it('handles empty string', () => {
    expect(truncateLabel('')).toBe('')
  })

  it('handles single character', () => {
    expect(truncateLabel('x')).toBe('x')
  })

  it('handles max=0 by slicing from -2 and appending ".."', () => {
    // slice(0, -2) on 'abc' = 'a', then + '..' = 'a..'
    expect(truncateLabel('abc', 0)).toBe('a..')
  })

  it('handles max=1', () => {
    // slice(0, -1) on 'abc' = 'ab', then + '..' = 'ab..'
    expect(truncateLabel('abc', 1)).toBe('ab..')
  })

  it('handles max=2', () => {
    expect(truncateLabel('abcdef', 2)).toBe('..')
  })
})

describe('spanStyle', () => {
  it('returns task style', () => {
    const style = spanStyle('task')
    expect(style).toEqual({ bg: 'var(--warn)', text: '#0f172a' })
  })

  it('returns operation style', () => {
    const style = spanStyle('operation')
    expect(style).toEqual({ bg: 'var(--ok)', text: '#0f172a' })
  })

  it('returns autonomy style', () => {
    const style = spanStyle('autonomy')
    expect(style).toEqual({ bg: 'var(--cyan)', text: '#0f172a' })
  })

  it('returns presence style with rgba', () => {
    const style = spanStyle('presence')
    expect(style.bg).toContain('rgba(')
    expect(style.text).toBe('#e2e8f0')
  })

  it('returns default for unknown kind', () => {
    const style = spanStyle('unknown')
    expect(style).toEqual({ bg: '#94a3b8', text: '#0f172a' })
  })

  it('returns default for empty string', () => {
    const style = spanStyle('')
    expect(style).toEqual({ bg: '#94a3b8', text: '#0f172a' })
  })

  it('each known style has bg and text keys', () => {
    for (const kind of ['task', 'operation', 'autonomy', 'presence']) {
      const style = spanStyle(kind)
      expect(style).toHaveProperty('bg')
      expect(style).toHaveProperty('text')
    }
  })
})
