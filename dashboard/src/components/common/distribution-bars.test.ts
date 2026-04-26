import { describe, it, expect } from 'vitest'
import { paletteFor } from './distribution-bars'

describe('paletteFor', () => {
  it('returns accent palette by default', () => {
    const p = paletteFor(undefined)
    expect(p.fill).toBe('var(--color-accent-fg)')
    expect(p.text).toBe('var(--color-accent-fg)')
  })

  it('returns ok palette', () => {
    const p = paletteFor('ok')
    expect(p.fill).toBe('var(--color-status-ok)')
    expect(p.text).toBe('var(--color-status-ok)')
  })

  it('returns warn palette', () => {
    const p = paletteFor('warn')
    expect(p.fill).toBe('var(--color-status-warn)')
    expect(p.chipBg).toContain('250,204,21')
  })

  it('returns bad palette', () => {
    const p = paletteFor('bad')
    expect(p.fill).toBe('var(--color-status-err)')
    expect(p.chipBg).toContain('248,113,113')
  })

  it('returns muted palette', () => {
    const p = paletteFor('muted')
    expect(p.text).toBe('var(--color-fg-muted)')
  })

  it('returns accent palette for explicit accent', () => {
    const p = paletteFor('accent')
    expect(p.fill).toBe('var(--color-accent-fg)')
    expect(p.chipBg).toContain('--accent-')
  })
})
