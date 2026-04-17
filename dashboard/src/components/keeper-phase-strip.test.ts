import { describe, it, expect } from 'vitest'
import { toPascalPhase, eventLabel } from './keeper-phase-strip'

// ================================================================
// toPascalPhase
// ================================================================

describe('toPascalPhase', () => {
  it('converts simple lowercase to PascalCase', () => {
    expect(toPascalPhase('running')).toBe('Running')
  })

  it('converts snake_case to PascalCase', () => {
    expect(toPascalPhase('handing_off')).toBe('HandingOff')
  })

  it('converts multi-segment snake_case', () => {
    expect(toPascalPhase('a_b_c')).toBe('ABC')
  })

  it('handles already PascalCase input', () => {
    expect(toPascalPhase('Running')).toBe('Running')
  })

  it('handles empty string', () => {
    expect(toPascalPhase('')).toBe('')
  })

  it('handles mixed case', () => {
    expect(toPascalPhase('HANDING_OFF')).toBe('HandingOff')
  })

  it('handles single underscore', () => {
    expect(toPascalPhase('off_line')).toBe('OffLine')
  })

  it('handles no underscore', () => {
    expect(toPascalPhase('dead')).toBe('Dead')
  })

  it('handles overflowing', () => {
    expect(toPascalPhase('overflowed')).toBe('Overflowed')
  })
})

// ================================================================
// eventLabel
// ================================================================

describe('eventLabel', () => {
  it('returns string as-is', () => {
    expect(eventLabel('tool_call')).toBe('tool_call')
  })

  it('extracts type from object', () => {
    expect(eventLabel({ type: 'cascade_select' })).toBe('cascade_select')
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
