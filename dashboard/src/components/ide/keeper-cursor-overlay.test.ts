// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { getKeeperColor } from './keeper-cursor-overlay'

describe('getKeeperColor', () => {
  it('maps explicit indexes to design-system keeper token slots', () => {
    expect(getKeeperColor('alpha', 0)).toMatchObject({
      slot: 1,
      cursor: 'var(--color-keeper-1)',
      glow: 'var(--color-keeper-1-glow)',
      selection: 'rgb(var(--color-keeper-1-glow) / 0.22)',
      text: 'var(--color-bg-page)',
    })
    expect(getKeeperColor('alpha', 11).cursor).toBe('var(--color-keeper-12)')
    expect(getKeeperColor('alpha', 12).cursor).toBe('var(--color-keeper-1)')
  })

  it('uses token references for hashed keeper ids instead of raw colors', () => {
    const color = getKeeperColor('nick0cave')
    expect(color.slot).toBeGreaterThanOrEqual(1)
    expect(color.slot).toBeLessThanOrEqual(12)
    expect(color.cursor).toMatch(/^var\(--color-keeper-\d+\)$/)
    expect(color.selection).toMatch(/^rgb\(var\(--color-keeper-\d+-glow\) \/ 0\.22\)$/)
    expect(`${color.cursor} ${color.selection} ${color.shadow}`).not.toMatch(/#[0-9a-fA-F]{3,8}|rgba\(/)
  })
})
