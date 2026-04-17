// @vitest-environment happy-dom
import { describe, it, expect } from 'vitest'
import {
  classifyFreshness,
  freshnessTierToneClass,
  freshnessTierAriaLabel,
} from './overview'

describe('classifyFreshness (pure)', () => {
  it('null / undefined / NaN → "unknown" (never loaded)', () => {
    // Regression guard: the freshness strip must NOT green-flash
    // during first boot before the mission snapshot arrives.
    expect(classifyFreshness(null)).toBe('unknown')
    expect(classifyFreshness(undefined)).toBe('unknown')
    expect(classifyFreshness(Number.NaN)).toBe('unknown')
  })

  it('negative age (clock skew) → "fresh" (treat as brand new)', () => {
    // Clock-skew guard: a browser tab whose OS just resynced NTP can
    // momentarily produce future-dated timestamps. That's noise, not
    // a problem — render fresh.
    expect(classifyFreshness(-5_000)).toBe('fresh')
  })

  it('0 → "fresh" (just generated)', () => {
    expect(classifyFreshness(0)).toBe('fresh')
  })

  it('sub-60s → "fresh" (green dot)', () => {
    expect(classifyFreshness(30_000)).toBe('fresh')
    expect(classifyFreshness(59_999)).toBe('fresh')
  })

  it('exactly 60s → "warn" (threshold crossing)', () => {
    // Strict < WARN, >= WARN moves up a tier. No 1-pixel dead zone.
    expect(classifyFreshness(60_000)).toBe('warn')
  })

  it('60–300s → "warn" (amber dot, card stays quiet)', () => {
    expect(classifyFreshness(120_000)).toBe('warn')
    expect(classifyFreshness(299_999)).toBe('warn')
  })

  it('exactly 300s → "stale" (triggers existing 5-min badge)', () => {
    expect(classifyFreshness(300_000)).toBe('stale')
  })

  it('≥ 300s → "stale"', () => {
    expect(classifyFreshness(600_000)).toBe('stale')
    expect(classifyFreshness(3_600_000)).toBe('stale')
  })
})

describe('freshnessTierToneClass (pure)', () => {
  it('each tier maps to a non-empty, distinct Tailwind string', () => {
    // Guards against a future refactor accidentally collapsing two
    // tiers onto the same tone (the #1 way a traffic-light indicator
    // silently stops being readable).
    const tones = new Set([
      freshnessTierToneClass('unknown'),
      freshnessTierToneClass('fresh'),
      freshnessTierToneClass('warn'),
      freshnessTierToneClass('stale'),
    ])
    expect(tones.size).toBe(4)
    for (const tone of tones) {
      expect(tone.length).toBeGreaterThan(0)
    }
  })

  it('fresh uses the ok token, stale uses the bad token', () => {
    expect(freshnessTierToneClass('fresh')).toContain('bg-ok')
    expect(freshnessTierToneClass('stale')).toContain('bg-bad')
    expect(freshnessTierToneClass('warn')).toContain('bg-warn')
  })
})

describe('freshnessTierAriaLabel (pure)', () => {
  it('every tier has a distinct Korean label (no raw enum strings leaked to AT users)', () => {
    // Regression guard: if a refactor forgets a case, TS exhaustiveness
    // will catch it — but a stringly-typed enum ("fresh") leaking to
    // a screen reader is the soft failure. Pin the labels.
    expect(freshnessTierAriaLabel('unknown')).toBe('상태 알 수 없음')
    expect(freshnessTierAriaLabel('fresh')).toBe('신선함')
    expect(freshnessTierAriaLabel('warn')).toBe('오래됨 (1분 이상)')
    expect(freshnessTierAriaLabel('stale')).toBe('stale (5분 이상)')
  })
})
