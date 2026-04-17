import { describe, it, expect } from 'vitest'
import { isObservedStall } from './fsm-hub-lane-analysis'

// ================================================================
// isObservedStall
// ================================================================

describe('isObservedStall', () => {
  // --- phase lane ---

  it('detects Failing stall at 90s', () => {
    expect(isObservedStall('phase', 'Failing', 90)).toBe(true)
  })

  it('does not detect Failing stall below 90s', () => {
    expect(isObservedStall('phase', 'Failing', 89)).toBe(false)
  })

  it('detects Overflowed stall at 60s', () => {
    expect(isObservedStall('phase', 'Overflowed', 60)).toBe(true)
  })

  it('detects Compacting stall at 90s', () => {
    expect(isObservedStall('phase', 'Compacting', 90)).toBe(true)
  })

  it('detects HandingOff stall at 60s', () => {
    expect(isObservedStall('phase', 'HandingOff', 60)).toBe(true)
  })

  it('detects Draining stall at 60s', () => {
    expect(isObservedStall('phase', 'Draining', 60)).toBe(true)
  })

  it('does not detect Running stall', () => {
    expect(isObservedStall('phase', 'Running', 120)).toBe(false)
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
