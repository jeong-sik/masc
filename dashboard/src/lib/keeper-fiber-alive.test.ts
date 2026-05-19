import { describe, it, expect } from 'vitest'
import { deriveFiberAlive } from './keeper-fiber-alive'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'

const baseComposite = (
  fiberAlive: boolean | undefined,
): KeeperCompositeSnapshot | null => {
  if (fiberAlive === undefined) return null
  return {
    phase_diagnosis: {
      conditions: { fiber_alive: fiberAlive },
    },
  } as unknown as KeeperCompositeSnapshot
}

describe('deriveFiberAlive', () => {
  it('prefers composite phase_diagnosis when the boolean is present', () => {
    const r = deriveFiberAlive({
      keeper: { keepalive_running: false, presence_keepalive: false },
      composite: baseComposite(true),
      linkedState: 'offline',
    })
    expect(r).toEqual({ alive: true, source: 'composite_phase_diagnosis' })
  })

  it('reads composite false even when keepalive signals would say true', () => {
    const r = deriveFiberAlive({
      keeper: { keepalive_running: true, presence_keepalive: true },
      composite: baseComposite(false),
      linkedState: 'idle',
    })
    expect(r).toEqual({ alive: false, source: 'composite_phase_diagnosis' })
  })

  it('falls through to keepalive_running when composite is null', () => {
    const r = deriveFiberAlive({
      keeper: { keepalive_running: true, presence_keepalive: false },
      composite: null,
      linkedState: 'offline',
    })
    expect(r).toEqual({ alive: true, source: 'keepalive_running' })
  })

  it('falls through to presence_keepalive when keepalive_running is undefined', () => {
    const r = deriveFiberAlive({
      keeper: { keepalive_running: undefined, presence_keepalive: true },
      composite: null,
      linkedState: 'offline',
    })
    expect(r).toEqual({ alive: true, source: 'presence_keepalive' })
  })

  it('falls through to link-state inference when all per-keeper signals are absent', () => {
    const r1 = deriveFiberAlive({
      keeper: { keepalive_running: undefined, presence_keepalive: undefined },
      composite: null,
      linkedState: 'offline',
    })
    expect(r1).toEqual({ alive: false, source: 'link_state_inference' })

    const r2 = deriveFiberAlive({
      keeper: { keepalive_running: undefined, presence_keepalive: undefined },
      composite: null,
      linkedState: 'running',
    })
    expect(r2).toEqual({ alive: true, source: 'link_state_inference' })
  })

  it('treats explicit false from a higher-priority source as authoritative', () => {
    // Regression guard: a careless OR-chain (`?? a ?? b`) skips only
    // null/undefined — booleans must stick. The typed function preserves
    // that: an explicit `false` at keepalive_running is the authority,
    // not a signal-absence that should fall through.
    const r = deriveFiberAlive({
      keeper: { keepalive_running: false, presence_keepalive: true },
      composite: null,
      linkedState: 'running',
    })
    expect(r).toEqual({ alive: false, source: 'keepalive_running' })
  })
})
