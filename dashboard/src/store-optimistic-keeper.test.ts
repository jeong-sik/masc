import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  applyOptimisticKeeperDirective,
  applyOptimisticKeeperDirectives,
  keepers,
} from './store'
import type { Keeper } from './types'

const baseKeeper = (overrides: Partial<Keeper> & { name: string }): Keeper => ({
  status: 'idle',
  ...overrides,
})

describe('applyOptimisticKeeperDirective', () => {
  beforeEach(() => {
    keepers.value = [
      baseKeeper({ name: 'rondo', paused: false, phase: 'Running', pipeline_stage: 'idle', status: 'idle' }),
      baseKeeper({ name: 'qa-king', paused: false, phase: 'Running', pipeline_stage: 'idle', status: 'idle' }),
    ]
  })

  afterEach(() => {
    keepers.value = []
  })

  it('flips paused/phase locally on pause and reverts on failure', () => {
    const revert = applyOptimisticKeeperDirective('rondo', 'pause')

    const after = keepers.value.find(k => k.name === 'rondo')!
    expect(after.paused).toBe(true)
    expect(after.phase).toBe('Paused')
    expect(after.pipeline_stage).toBe('paused')
    // Other keepers untouched.
    expect(keepers.value.find(k => k.name === 'qa-king')!.paused).toBe(false)

    revert()
    const reverted = keepers.value.find(k => k.name === 'rondo')!
    expect(reverted.paused).toBe(false)
    expect(reverted.phase).toBe('Running')
    expect(reverted.pipeline_stage).toBe('idle')
  })

  it('flips paused/phase locally on resume and reverts on failure', () => {
    keepers.value = [
      baseKeeper({ name: 'rondo', paused: true, phase: 'Paused', pipeline_stage: 'paused', status: 'paused' }),
    ]
    const original = keepers.value[0]!

    const revert = applyOptimisticKeeperDirective('rondo', 'resume')
    const after = keepers.value[0]!
    expect(after.paused).toBe(false)
    expect(after.phase).toBe('Running')

    revert()
    expect(keepers.value[0]).toEqual(original)
  })

  it('wakeup behaves like resume (paused → running) for the optimistic patch', () => {
    keepers.value = [baseKeeper({ name: 'rondo', paused: true, phase: 'Paused' })]
    applyOptimisticKeeperDirective('rondo', 'wakeup')
    expect(keepers.value[0]!.paused).toBe(false)
    expect(keepers.value[0]!.phase).toBe('Running')
  })

  it('returns a no-op revert when the keeper is not in the local list', () => {
    const before = keepers.value
    const revert = applyOptimisticKeeperDirective('ghost', 'pause')
    expect(keepers.value).toBe(before)
    revert()
    expect(keepers.value).toBe(before)
  })

  it('revert is keyed by name so a subsequent unrelated mutation is preserved', () => {
    const revert = applyOptimisticKeeperDirective('rondo', 'pause')
    // Simulate an unrelated update arriving from the snapshot stream
    // (e.g. qa-king's status field changes).
    keepers.value = keepers.value.map(k =>
      k.name === 'qa-king' ? { ...k, status: 'busy' } : k,
    )
    revert()
    expect(keepers.value.find(k => k.name === 'rondo')!.paused).toBe(false)
    expect(keepers.value.find(k => k.name === 'qa-king')!.status).toBe('busy')
  })
})

describe('applyOptimisticKeeperDirectives (bulk)', () => {
  beforeEach(() => {
    keepers.value = [
      baseKeeper({ name: 'a', paused: false, phase: 'Running' }),
      baseKeeper({ name: 'b', paused: false, phase: 'Running' }),
      baseKeeper({ name: 'c', paused: false, phase: 'Running' }),
    ]
  })

  it('applies the patch to every requested name and returns per-name reverts', () => {
    const reverts = applyOptimisticKeeperDirectives(['a', 'b'], 'pause')
    expect(reverts.size).toBe(2)
    expect(keepers.value.find(k => k.name === 'a')!.paused).toBe(true)
    expect(keepers.value.find(k => k.name === 'b')!.paused).toBe(true)
    expect(keepers.value.find(k => k.name === 'c')!.paused).toBe(false)
  })

  it('reverting only one entry leaves the others optimistically patched', () => {
    const reverts = applyOptimisticKeeperDirectives(['a', 'b'], 'pause')
    reverts.get('a')!()
    expect(keepers.value.find(k => k.name === 'a')!.paused).toBe(false)
    expect(keepers.value.find(k => k.name === 'b')!.paused).toBe(true)
  })
})
