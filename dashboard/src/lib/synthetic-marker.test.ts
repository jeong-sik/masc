import { describe, it, expect } from 'vitest'
import {
  SYNTHETIC_PREFIX,
  SYNTHETIC_SCOPE_LABEL,
  SYNTHETIC_TOOLTIP,
  hasSyntheticMarker,
  stripSyntheticMarker,
} from './synthetic-marker'

describe('stripSyntheticMarker', () => {
  it('detects the [SYNTHETIC] prefix and strips it', () => {
    const result = stripSyntheticMarker('[SYNTHETIC] Last output: tool: keeper_task_done')
    expect(result.synthesized).toBe(true)
    expect(result.stripped).toBe('Last output: tool: keeper_task_done')
  })

  it('handles leading whitespace around the prefix', () => {
    const result = stripSyntheticMarker('   [SYNTHETIC]   Decisions: pause')
    expect(result.synthesized).toBe(true)
    expect(result.stripped).toBe('Decisions: pause')
  })

  it('returns synthesized=false for plain text', () => {
    const result = stripSyntheticMarker('Last output: model native')
    expect(result.synthesized).toBe(false)
    expect(result.stripped).toBe('Last output: model native')
  })

  it('treats mid-string [SYNTHETIC] mentions as plain text', () => {
    // Could be a quoted message from another keeper — only the
    // prefix form is the wire contract.
    const result = stripSyntheticMarker('keeper@bob said: "[SYNTHETIC] is rare"')
    expect(result.synthesized).toBe(false)
    expect(result.stripped).toBe('keeper@bob said: "[SYNTHETIC] is rare"')
  })

  it('handles null / undefined / empty input', () => {
    expect(stripSyntheticMarker(null)).toEqual({ stripped: '', synthesized: false })
    expect(stripSyntheticMarker(undefined)).toEqual({ stripped: '', synthesized: false })
    expect(stripSyntheticMarker('')).toEqual({ stripped: '', synthesized: false })
    expect(stripSyntheticMarker('   ')).toEqual({ stripped: '', synthesized: false })
  })

  it('preserves trailing/internal whitespace in the stripped body', () => {
    const result = stripSyntheticMarker('[SYNTHETIC] line1\nline2')
    expect(result.synthesized).toBe(true)
    expect(result.stripped).toBe('line1\nline2')
  })
})

describe('hasSyntheticMarker', () => {
  it('returns true only when the prefix is present', () => {
    expect(hasSyntheticMarker('[SYNTHETIC] x')).toBe(true)
    expect(hasSyntheticMarker('x [SYNTHETIC]')).toBe(false)
    expect(hasSyntheticMarker(null)).toBe(false)
  })
})

describe('exported constants', () => {
  it('SYNTHETIC_PREFIX matches the backend literal', () => {
    expect(SYNTHETIC_PREFIX).toBe('[SYNTHETIC]')
  })

  it('operator-facing strings are non-empty', () => {
    expect(SYNTHETIC_SCOPE_LABEL.length).toBeGreaterThan(0)
    expect(SYNTHETIC_TOOLTIP.length).toBeGreaterThan(0)
    expect(SYNTHETIC_TOOLTIP).toContain('TTL')
  })
})
