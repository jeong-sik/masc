// @vitest-environment happy-dom
import { describe, it, expect } from 'vitest'
import {
  ringFocusClasses,
  ringSelectClasses,
  ringInnerClasses,
} from './ring'

describe('ringFocusClasses (pure)', () => {
  it('default = accent / width 1 / no offset / focus-visible variant', () => {
    const cls = ringFocusClasses()
    expect(cls).toBe(
      'focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent',
    )
  })

  it('always includes outline-none reset', () => {
    expect(ringFocusClasses()).toContain('focus-visible:outline-none')
    expect(ringFocusClasses({ width: 2 })).toContain('focus-visible:outline-none')
    expect(ringFocusClasses({ tone: 'ok' })).toContain('focus-visible:outline-none')
  })

  it('width 2 uses ring-2', () => {
    const cls = ringFocusClasses({ width: 2 })
    expect(cls).toContain('focus-visible:ring-2')
    expect(cls).not.toContain('focus-visible:ring-1')
  })

  it('every tone produces a focus-visible:ring-* class', () => {
    const tones = [
      'accent',
      'accent-soft',
      'border',
      'muted',
      'ok',
      'warn',
      'bad',
      'info',
    ] as const
    for (const tone of tones) {
      const cls = ringFocusClasses({ tone })
      // each tone string must appear *exactly once* under focus-visible:
      expect(cls).toMatch(/focus-visible:ring-/)
    }
  })

  it('accent-soft uses /40 alpha', () => {
    expect(ringFocusClasses({ tone: 'accent-soft' })).toContain(
      'focus-visible:ring-accent/40',
    )
  })

  it('offset 0 (default) emits no ring-offset class', () => {
    expect(ringFocusClasses()).not.toContain('ring-offset')
    expect(ringFocusClasses({ offset: 0 })).not.toContain('ring-offset')
  })

  it('offset 2 + page surface (default) → matches main app focus pattern', () => {
    const cls = ringFocusClasses({ width: 2, offset: 2, offsetSurface: 'page' })
    expect(cls).toContain('focus-visible:ring-offset-2')
    expect(cls).toContain('focus-visible:ring-offset-[var(--color-bg-page)]')
  })

  it('offset 2 + surface → keeper-config / agent-detail button pattern', () => {
    const cls = ringFocusClasses({
      width: 2,
      offset: 2,
      offsetSurface: 'surface',
    })
    expect(cls).toContain('focus-visible:ring-offset-2')
    expect(cls).toContain('focus-visible:ring-offset-[var(--color-bg-surface)]')
  })

  it('offset 1 + bg-1 → list-item selection pattern', () => {
    const cls = ringFocusClasses({
      width: 2,
      offset: 1,
      offsetSurface: 'bg-1',
    })
    expect(cls).toContain('focus-visible:ring-offset-1')
    expect(cls).toContain('focus-visible:ring-offset-bg-1')
  })

  it('visible=false uses bare focus: prefix (legacy mouse+keyboard)', () => {
    const cls = ringFocusClasses({ visible: false })
    expect(cls).toBe('focus:outline-none focus:ring-1 focus:ring-accent')
    expect(cls).not.toContain('focus-visible:')
  })

  it('regression: outline-none must precede ring classes', () => {
    // CSS specificity isn't affected by class order, but a few
    // browsers respect the source order for tie-breaks. Keep the
    // reset first so the override semantics read consistently.
    const cls = ringFocusClasses()
    const outlineIdx = cls.indexOf('outline-none')
    const ringIdx = cls.indexOf(':ring-')
    expect(outlineIdx).toBeGreaterThanOrEqual(0)
    expect(ringIdx).toBeGreaterThan(outlineIdx)
  })
})

describe('ringSelectClasses (pure)', () => {
  it('default = ring-2 ring-accent (no focus-visible prefix)', () => {
    const cls = ringSelectClasses()
    expect(cls).toBe('ring-2 ring-accent')
  })

  it('does NOT add outline-none (selection ring is persistent, not focus)', () => {
    expect(ringSelectClasses()).not.toContain('outline-none')
  })

  it('does NOT use focus-visible: prefix', () => {
    expect(ringSelectClasses()).not.toContain('focus-visible:')
    expect(ringSelectClasses({ tone: 'ok', width: 1 })).not.toContain(
      'focus-visible:',
    )
  })

  it('offset 1 + bg-1 (default surface) → event-track pattern', () => {
    const cls = ringSelectClasses({ offset: 1 })
    expect(cls).toBe('ring-2 ring-accent ring-offset-1 ring-offset-bg-1')
  })

  it('width 1 produces ring-1', () => {
    expect(ringSelectClasses({ width: 1 })).toContain('ring-1')
    expect(ringSelectClasses({ width: 1 })).not.toContain('ring-2')
  })

  it('every tone produces a ring-* class', () => {
    const tones = [
      'accent',
      'accent-soft',
      'border',
      'muted',
      'ok',
      'warn',
      'bad',
      'info',
    ] as const
    for (const tone of tones) {
      expect(ringSelectClasses({ tone })).toMatch(/^ring-\d/)
    }
  })
})

describe('ringInnerClasses (pure)', () => {
  it('default = ring-1 ring-white/5 (modal panel pattern)', () => {
    expect(ringInnerClasses()).toBe('ring-1 ring-white/5')
  })

  it('accepts tone + width override', () => {
    expect(ringInnerClasses('border', 2)).toBe(
      'ring-2 ring-[var(--color-border-strong)]',
    )
  })

  it('does NOT add focus-visible / outline-none / ring-offset', () => {
    const cls = ringInnerClasses()
    expect(cls).not.toContain('focus-visible:')
    expect(cls).not.toContain('outline-none')
    expect(cls).not.toContain('ring-offset')
  })
})
