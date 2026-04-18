import { describe, it, expect } from 'vitest'
import { intensityColor, canvasWidth, canvasHeight, hitTest } from './activity-heatmap'

describe('intensityColor', () => {
  const COLORS = ['#1e293b', '#0e4a5c', '#0e6e7e', '#14919b', 'var(--cyan)']

  it('returns first color for zero count', () => {
    expect(intensityColor(0, 100)).toBe(COLORS[0])
  })

  it('returns first color when max is zero', () => {
    expect(intensityColor(5, 0)).toBe(COLORS[0])
  })

  it('returns first color when both are zero', () => {
    expect(intensityColor(0, 0)).toBe(COLORS[0])
  })

  it('returns level 1 for ratio up to 0.25', () => {
    expect(intensityColor(1, 100)).toBe(COLORS[1])
    expect(intensityColor(25, 100)).toBe(COLORS[1])
  })

  it('returns level 2 for ratio 0.26 to 0.50', () => {
    expect(intensityColor(26, 100)).toBe(COLORS[2])
    expect(intensityColor(50, 100)).toBe(COLORS[2])
  })

  it('returns level 3 for ratio 0.51 to 0.75', () => {
    expect(intensityColor(51, 100)).toBe(COLORS[3])
    expect(intensityColor(75, 100)).toBe(COLORS[3])
  })

  it('returns level 4 for ratio above 0.75', () => {
    expect(intensityColor(76, 100)).toBe(COLORS[4])
    expect(intensityColor(100, 100)).toBe(COLORS[4])
  })

  it('handles count equal to max', () => {
    expect(intensityColor(50, 50)).toBe(COLORS[4])
  })

  it('handles small max values', () => {
    expect(intensityColor(1, 4)).toBe(COLORS[1]) // 0.25 ratio → level 1
    expect(intensityColor(1, 10)).toBe(COLORS[1])
  })
})

describe('canvasWidth', () => {
  it('returns a positive number', () => {
    const w = canvasWidth()
    expect(w).toBeGreaterThan(0)
  })

  it('is deterministic', () => {
    expect(canvasWidth()).toBe(canvasWidth())
  })

  it('is based on 24 cells + left margin', () => {
    // LEFT_MARGIN=28 + 24*(20+2) - 2 = 28 + 528 - 2 = 554
    expect(canvasWidth()).toBe(554)
  })
})

describe('canvasHeight', () => {
  it('returns a positive number', () => {
    const h = canvasHeight()
    expect(h).toBeGreaterThan(0)
  })

  it('is deterministic', () => {
    expect(canvasHeight()).toBe(canvasHeight())
  })

  it('is based on 7 rows + top pad + legend', () => {
    // TOP_PAD=20 + 7*(20+2) - 2 + 32 = 20 + 154 - 2 + 32 = 204
    expect(canvasHeight()).toBe(204)
  })
})

describe('hitTest', () => {
  it('returns null for coordinates outside grid', () => {
    expect(hitTest(0, 0)).toBeNull()
    expect(hitTest(500, 500)).toBeNull()
    expect(hitTest(-10, -10)).toBeNull()
  })

  it('returns a cell for coordinates inside grid', () => {
    // First cell: day=0, hour=0 at x=LEFT_MARGIN, y=TOP_PAD
    // LEFT_MARGIN=28, TOP_PAD=20, CELL=20
    const cell = hitTest(30, 25)
    expect(cell).not.toBeNull()
    expect(cell!.day).toBe(0)
    expect(cell!.hour).toBe(0)
    expect(cell!.count).toBe(0)
  })

  it('returns correct day and hour for mid-grid cell', () => {
    // day=3: y = 20 + 3*(20+2) = 86 → test y=90
    // hour=12: x = 28 + 12*(20+2) = 292 → test x=300
    const cell = hitTest(300, 90)
    expect(cell).not.toBeNull()
    expect(cell!.day).toBe(3)
    expect(cell!.hour).toBe(12)
  })

  it('returns null in left margin area', () => {
    expect(hitTest(5, 25)).toBeNull()
  })

  it('returns null in top padding area', () => {
    expect(hitTest(50, 5)).toBeNull()
  })

  it('covers all 7 days', () => {
    for (let day = 0; day < 7; day++) {
      const y = 20 + day * 22 + 5
      const cell = hitTest(50, y)
      expect(cell, `day ${day} should be detected`).not.toBeNull()
      expect(cell!.day).toBe(day)
    }
  })

  it('covers last hour (hour 23)', () => {
    // hour=23: x = 28 + 23*22 = 534 → test x=540
    const cell = hitTest(540, 25)
    expect(cell).not.toBeNull()
    expect(cell!.hour).toBe(23)
  })
})
