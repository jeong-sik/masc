import { describe, expect, it } from 'vitest'
import { validateTokenReferences } from './validate-references'

describe('validateTokenReferences', () => {
  it('marks tokens used via var() as used', () => {
    const defined = ['color-surface', 'color-text']
    const files = [
      { path: 'a.css', content: '.btn { color: var(--color-text); }' },
    ]
    const report = validateTokenReferences(defined, files)
    expect(report.unused).toEqual(['color-surface'])
    expect(report.usageRate).toBe(0.5)
  })

  it('marks tokens used via property name as used', () => {
    const defined = ['space-4']
    const files = [
      { path: 'a.css', content: '.btn { --space-4: 16px; }' },
    ]
    const report = validateTokenReferences(defined, files)
    expect(report.unused).toEqual([])
    expect(report.usageRate).toBe(1)
  })

  it('reports all as unused when no files reference them', () => {
    const defined = ['token-a', 'token-b']
    const files = [{ path: 'a.css', content: '.btn {}' }]
    const report = validateTokenReferences(defined, files)
    expect(report.unused).toEqual(['token-a', 'token-b'])
    expect(report.usageRate).toBe(0)
  })

  it('detects hardcoded colors in source files', () => {
    const defined = ['color-primary']
    const files = [
      { path: 'a.css', content: '.btn { color: #ff0000; }' },
    ]
    const report = validateTokenReferences(defined, files)
    expect(report.hardcoded.length).toBe(1)
    expect(report.hardcoded[0].color).toBe('#ff0000')
  })

  it('returns usageRate 0 for empty token list', () => {
    const report = validateTokenReferences([], [])
    expect(report.usageRate).toBe(0)
  })

  it('does not count substring matches as token usage', () => {
    // token "color" should NOT be marked used by "--color-bg" or "--color-surface"
    const defined = ['color']
    const files = [
      { path: 'a.css', content: '.btn { color: var(--color-bg); --color-surface: red; }' },
    ]
    const report = validateTokenReferences(defined, files)
    expect(report.unused).toEqual(['color'])
    expect(report.usageRate).toBe(0)
  })

  it('correctly detects exact token match alongside longer names', () => {
    const defined = ['color', 'color-bg']
    const files = [
      { path: 'a.css', content: '.btn { color: var(--color); background: var(--color-bg); }' },
    ]
    const report = validateTokenReferences(defined, files)
    expect(report.unused).toEqual([])
    expect(report.usageRate).toBe(1)
  })
})
