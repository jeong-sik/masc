import { describe, it, expect } from 'vitest'
import { paletteForAgent, templateForAgent, PIXEL_TEMPLATES } from './avatar-palettes'

// ================================================================
// paletteForAgent
// ================================================================

describe('paletteForAgent', () => {
  it('returns a palette with all color keys', () => {
    const palette = paletteForAgent('janitor')
    expect(palette).toHaveProperty('skin')
    expect(palette).toHaveProperty('hair')
    expect(palette).toHaveProperty('point')
    expect(palette).toHaveProperty('highlight')
    expect(typeof palette.skin).toBe('string')
  })

  it('returns deterministic palette for same name', () => {
    expect(paletteForAgent('janitor')).toEqual(paletteForAgent('janitor'))
  })

  it('returns valid palettes for different names', () => {
    const p1 = paletteForAgent('janitor')
    const p2 = paletteForAgent('alice')
    expect(typeof p1.skin).toBe('string')
    expect(typeof p2.skin).toBe('string')
  })

  it('is case-insensitive', () => {
    expect(paletteForAgent('Janitor')).toEqual(paletteForAgent('janitor'))
    expect(paletteForAgent('JANITOR')).toEqual(paletteForAgent('janitor'))
  })

  it('returns a palette with required keys', () => {
    const palette = paletteForAgent('test')
    expect(palette).toHaveProperty('skin')
    expect(palette).toHaveProperty('hair')
    expect(palette).toHaveProperty('point')
    expect(palette).toHaveProperty('highlight')
  })
})

// ================================================================
// templateForAgent
// ================================================================

describe('templateForAgent', () => {
  it('returns a valid template type', () => {
    const template = templateForAgent('janitor')
    expect(['humanoid', 'robot', 'animal', 'abstract']).toContain(template)
  })

  it('returns a deterministic template', () => {
    expect(templateForAgent('janitor')).toBe(templateForAgent('janitor'))
  })
})

// ================================================================
// PIXEL_TEMPLATES
// ================================================================

describe('PIXEL_TEMPLATES', () => {
  it('has all four templates', () => {
    expect(Object.keys(PIXEL_TEMPLATES)).toEqual(['humanoid', 'robot', 'animal', 'abstract'])
  })

  it('each template has 64 pixels (8x8)', () => {
    for (const grid of Object.values(PIXEL_TEMPLATES)) {
      expect(grid).toHaveLength(64)
    }
  })

  it('each pixel is 0-4', () => {
    for (const grid of Object.values(PIXEL_TEMPLATES)) {
      for (const pixel of grid) {
        expect(pixel).toBeGreaterThanOrEqual(0)
        expect(pixel).toBeLessThanOrEqual(4)
      }
    }
  })
})
