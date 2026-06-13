import { describe, it, expect } from 'vitest'
import { eventLabel } from './keeper-phase-strip'

// `toPascalPhase` was sunset 2026-05-28 — the same lowercase→PascalCase
// normalization is now handled by `toKeeperPhase` (keeper-store-normalize),
// which `getPhaseStyle` calls internally. Coverage for that path lives in
// keeper-store-normalize.test.ts (closed-set parsing with compile-time
// coverage check). The strip no longer ships a generic regex normalizer.

// ================================================================
// eventLabel
// ================================================================

describe('eventLabel', () => {
  it('returns string as-is', () => {
    expect(eventLabel('tool_call')).toBe('tool_call')
  })

  it('extracts type from object', () => {
    expect(eventLabel({ type: 'runtime_select' })).toBe('runtime_select')
  })

  it('extracts type as string from number', () => {
    expect(eventLabel({ type: 42 })).toBe('42')
  })

  it('returns ? for null', () => {
    expect(eventLabel(null)).toBe('?')
  })

  it('returns ? for undefined', () => {
    expect(eventLabel(undefined)).toBe('?')
  })

  it('returns ? for object without type', () => {
    expect(eventLabel({ name: 'test' })).toBe('?')
  })

  it('returns ? for object with null type', () => {
    expect(eventLabel({ type: null })).toBe('?')
  })

  it('returns ? for object with undefined type', () => {
    expect(eventLabel({ type: undefined })).toBe('?')
  })

  it('returns ? for number', () => {
    expect(eventLabel(123)).toBe('?')
  })

  it('returns ? for empty object', () => {
    expect(eventLabel({})).toBe('?')
  })

  it('returns ? for array', () => {
    expect(eventLabel([1, 2, 3])).toBe('?')
  })
})
