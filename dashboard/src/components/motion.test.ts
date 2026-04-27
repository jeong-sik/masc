import { describe, it, expect } from 'vitest'
import {
  motion,
  MOTION_HEARTBEAT_CLASS,
  MOTION_PULSE_GLOW_CLASS,
  MOTION_SHIMMER_CLASS,
  MOTION_BLINK_CLASS,
  type MotionKind,
} from './motion'

describe('motion constants', () => {
  it('MOTION_HEARTBEAT_CLASS matches SPEC anim-heartbeat', () => {
    expect(MOTION_HEARTBEAT_CLASS).toBe('anim-heartbeat')
  })

  it('MOTION_PULSE_GLOW_CLASS preserves the kebab-case SPEC name', () => {
    expect(MOTION_PULSE_GLOW_CLASS).toBe('anim-pulse-glow')
  })

  it('MOTION_SHIMMER_CLASS matches SPEC anim-shimmer', () => {
    expect(MOTION_SHIMMER_CLASS).toBe('anim-shimmer')
  })

  it('MOTION_BLINK_CLASS matches SPEC anim-blink', () => {
    expect(MOTION_BLINK_CLASS).toBe('anim-blink')
  })
})

describe('motion()', () => {
  it('maps heartbeat to anim-heartbeat', () => {
    expect(motion('heartbeat')).toBe('anim-heartbeat')
  })

  it('maps pulseGlow (camelCase) to anim-pulse-glow (kebab-case SPEC)', () => {
    expect(motion('pulseGlow')).toBe('anim-pulse-glow')
  })

  it('maps shimmer to anim-shimmer', () => {
    expect(motion('shimmer')).toBe('anim-shimmer')
  })

  it('maps blink to anim-blink', () => {
    expect(motion('blink')).toBe('anim-blink')
  })

  it('result is stable across calls', () => {
    expect(motion('heartbeat')).toBe(motion('heartbeat'))
    expect(motion('shimmer')).toBe(motion('shimmer'))
  })

  it('composes cleanly with leading classes via template literal', () => {
    const composed = `btn ${motion('pulseGlow')}`
    expect(composed).toBe('btn anim-pulse-glow')
  })

  it('all four MotionKind variants resolve to distinct classes', () => {
    const kinds: MotionKind[] = ['heartbeat', 'pulseGlow', 'shimmer', 'blink']
    const classes = kinds.map(motion)
    const unique = new Set(classes)
    expect(unique.size).toBe(kinds.length)
  })
})
