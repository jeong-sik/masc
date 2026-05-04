// @vitest-environment happy-dom
import { describe, it, expect } from 'vitest'
import {
  connectorCardBorderClass,
  connectorStateLabel,
} from './connector-status'

describe('connectorCardBorderClass (pure)', () => {
  it('connected → emerald 4px left border (Portainer "running" tone)', () => {
    expect(connectorCardBorderClass('connected')).toBe(
      'border-l-4 border-l-emerald-500',
    )
  })

  it('stale → warn token 4px (intermittent / degraded)', () => {
    expect(connectorCardBorderClass('stale')).toBe(
      'border-l-4 border-l-[var(--color-warn)]',
    )
  })

  it('disconnected → rose 4px (broken)', () => {
    expect(connectorCardBorderClass('disconnected')).toBe(
      'border-l-4 border-l-rose-500',
    )
  })

  it('offline → muted 4px (not running)', () => {
    // Uses a CSS variable so the muted tone tracks the dashboard theme
    // rather than hardcoding a zinc hue that fights dark-mode tokens.
    expect(connectorCardBorderClass('offline')).toContain('border-l-4')
    expect(connectorCardBorderClass('offline')).toContain('var(--color-border-default)')
  })

  it('unknown label falls back to the offline (muted) tone', () => {
    // Regression guard: a future status vocabulary extension (e.g.
    // "reconnecting") must not accidentally render without a border —
    // the default arm keeps every card visually framed.
    expect(connectorCardBorderClass('reconnecting-someday')).toContain('border-l-4')
  })

  it('every mapping returns exactly 2 Tailwind classes (width + color)', () => {
    // Keeps the output cheap for JIT purging — any 3rd class slipping
    // in would signal the helper growing responsibilities it shouldn't.
    for (const label of ['connected', 'stale', 'disconnected', 'offline']) {
      const parts = connectorCardBorderClass(label).split(' ').filter(Boolean)
      expect(parts.length).toBe(2)
      expect(parts[0]).toBe('border-l-4')
      expect(parts[1]!.startsWith('border-l-')).toBe(true)
    }
  })
})

describe('connectorStateLabel (pure, now exported)', () => {
  // Sanity — the helper was previously internal. Exporting it makes the
  // border-class mapping verifiable end-to-end from a connector object
  // without mounting the whole gate panel.

  it('null connector → "offline"', () => {
    expect(connectorStateLabel(null)).toBe('offline')
  })

  it('advertised status (if valid) wins over flag-derived label', () => {
    const c = {
      connector_id: 'discord', status: 'stale', available: true, connected: true, stale: false,
    } as unknown as Parameters<typeof connectorStateLabel>[0]
    expect(connectorStateLabel(c)).toBe('stale')
  })

  it('flag-derived: available=false → "offline"', () => {
    const c = {
      connector_id: 'discord', available: false, connected: false, stale: false,
    } as unknown as Parameters<typeof connectorStateLabel>[0]
    expect(connectorStateLabel(c)).toBe('offline')
  })

  it('flag-derived: available + stale → "stale"', () => {
    const c = {
      connector_id: 'discord', available: true, connected: true, stale: true,
    } as unknown as Parameters<typeof connectorStateLabel>[0]
    expect(connectorStateLabel(c)).toBe('stale')
  })

  it('flag-derived: available + connected (not stale) → "connected"', () => {
    const c = {
      connector_id: 'discord', available: true, connected: true, stale: false,
    } as unknown as Parameters<typeof connectorStateLabel>[0]
    expect(connectorStateLabel(c)).toBe('connected')
  })

  it('flag-derived: available but not connected → "disconnected"', () => {
    const c = {
      connector_id: 'discord', available: true, connected: false, stale: false,
    } as unknown as Parameters<typeof connectorStateLabel>[0]
    expect(connectorStateLabel(c)).toBe('disconnected')
  })
})

describe('state → border class composition (contract)', () => {
  // End-to-end: every label that connectorStateLabel can produce must
  // map to a visible border via connectorCardBorderClass. Regression
  // guard against a future status vocabulary extension slipping through
  // without a border tone.
  const labels = ['connected', 'stale', 'disconnected', 'offline']
  for (const label of labels) {
    it(`${label} resolves to a concrete 4px border class`, () => {
      const cls = connectorCardBorderClass(label)
      expect(cls).toContain('border-l-4')
      expect(cls.length).toBeGreaterThan('border-l-4'.length)
    })
  }
})
