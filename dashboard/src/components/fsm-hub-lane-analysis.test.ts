import { describe, it, expect } from 'vitest'
import { isObservedStall } from './fsm-hub-lane-analysis'

// ================================================================
// isObservedStall
// ================================================================

// Wire format is lowercase + snake_case (phase_to_string in
// keeper_state_machine.ml:21-35). Prior fixtures asserted PascalCase
// that never reached the function in production — mock↔mock loophole.
describe('isObservedStall', () => {
  // --- phase lane ---

  it('detects failing stall at 90s', () => {
    expect(isObservedStall('phase', 'failing', 90)).toBe(true)
  })

  it('does not detect failing stall below 90s', () => {
    expect(isObservedStall('phase', 'failing', 89)).toBe(false)
  })

  it('detects overflowed stall at 60s', () => {
    expect(isObservedStall('phase', 'overflowed', 60)).toBe(true)
  })

  it('detects compacting stall at 90s', () => {
    expect(isObservedStall('phase', 'compacting', 90)).toBe(true)
  })

  it('detects handing_off stall at 60s', () => {
    expect(isObservedStall('phase', 'handing_off', 60)).toBe(true)
  })

  it('detects draining stall at 60s', () => {
    expect(isObservedStall('phase', 'draining', 60)).toBe(true)
  })

  it('does not detect running stall', () => {
    expect(isObservedStall('phase', 'running', 120)).toBe(false)
  })

  // --- turn lane ---

  it('detects prompting stall at 45s', () => {
    expect(isObservedStall('turn', 'prompting', 45)).toBe(true)
  })

  it('detects executing stall at 45s', () => {
    expect(isObservedStall('turn', 'executing', 45)).toBe(true)
  })

  it('detects compacting stall at 60s', () => {
    expect(isObservedStall('turn', 'compacting', 60)).toBe(true)
  })

  it('detects finalizing stall at 30s', () => {
    expect(isObservedStall('turn', 'finalizing', 30)).toBe(true)
  })

  it('does not detect turn stall below threshold', () => {
    expect(isObservedStall('turn', 'prompting', 44)).toBe(false)
  })

  // --- cascade lane ---

  it('detects selecting stall at 30s', () => {
    expect(isObservedStall('cascade', 'selecting', 30)).toBe(true)
  })

  it('detects trying stall at 45s', () => {
    expect(isObservedStall('cascade', 'trying', 45)).toBe(true)
  })

  it('does not detect cascade stall below threshold', () => {
    expect(isObservedStall('cascade', 'selecting', 29)).toBe(false)
  })

  // --- compaction lane ---

  it('detects compacting stall at 60s', () => {
    expect(isObservedStall('compaction', 'compacting', 60)).toBe(true)
  })

  it('does not detect compaction stall below 60s', () => {
    expect(isObservedStall('compaction', 'compacting', 59)).toBe(false)
  })

  it('does not detect compaction stall for non-compacting value', () => {
    expect(isObservedStall('compaction', 'idle', 120)).toBe(false)
  })

  // --- unknown lane ---

  it('returns false for unknown lane key', () => {
    expect(isObservedStall('unknown' as any, 'anything', 100)).toBe(false)
  })
})
