// @vitest-environment happy-dom
import { describe, it, expect } from 'vitest'
import {
  opHubTileIsActive,
  opHubTileNumberClass,
  opHubTileBorderClass,
} from './overview'

describe('opHubTileIsActive (pure)', () => {
  it('0 → inactive (the operator has nothing to do here right now)', () => {
    expect(opHubTileIsActive(0)).toBe(false)
  })

  it('positive count → active', () => {
    expect(opHubTileIsActive(1)).toBe(true)
    expect(opHubTileIsActive(42)).toBe(true)
  })

  it('negative count → inactive (defensive — backend should never send this, but never surface it)', () => {
    // If an upstream bug produces -1, dimming is the correct fail-safe:
    // the operator sees "nothing to do" rather than a bright attention-
    // grabbing anomaly tile they can't actually act on.
    expect(opHubTileIsActive(-1)).toBe(false)
  })

  it('NaN / Infinity → inactive (never light up on garbage input)', () => {
    expect(opHubTileIsActive(Number.NaN)).toBe(false)
    expect(opHubTileIsActive(Number.POSITIVE_INFINITY)).toBe(false)
  })
})

describe('opHubTileNumberClass (pure)', () => {
  it('active uses strong text, inactive uses dim text', () => {
    // Regression guard: if a future refactor makes zero tiles as bold
    // as active ones, the operator loses the \"one of these is not
    // like the others\" scan. Stripe $0 cards and Linear zero counters
    // both rely on this contrast drop.
    expect(opHubTileNumberClass(0)).toContain('text-[var(--text-dim)]')
    expect(opHubTileNumberClass(1)).toContain('text-[var(--text-strong)]')
  })

  it('both variants keep the same size + weight (layout invariant)', () => {
    // The 24px bold glyph is the visual anchor — only the color
    // changes between tiers, never the size.
    for (const count of [0, 1, 99]) {
      expect(opHubTileNumberClass(count)).toContain('text-[24px]')
      expect(opHubTileNumberClass(count)).toContain('font-bold')
    }
  })
})

describe('opHubTileBorderClass (pure)', () => {
  it('active gets an accent-tinted border; inactive keeps the card-border default', () => {
    expect(opHubTileBorderClass(0)).toContain('border-card-border')
    expect(opHubTileBorderClass(1)).toContain('border-accent')
  })

  it('both variants keep the same p-3 padding + rounded (layout invariant)', () => {
    for (const count of [0, 1]) {
      expect(opHubTileBorderClass(count)).toContain('rounded')
      expect(opHubTileBorderClass(count)).toContain('p-3')
    }
  })
})
