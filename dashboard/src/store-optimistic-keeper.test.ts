import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  applyOptimisticKeeperDirective,
  applyOptimisticKeeperDirectives,
  keepers,
} from './store'
import { phasePulse, phaseTone } from './components/v2/keeper-fsm'
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
    // The roster status dot renders lifecycle_phase, not phase — patch it so
    // the left-list dot flips on the same click (see patchForDirective).
    expect(after.lifecycle_phase).toBe('Paused')
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
    expect(after.lifecycle_phase).toBe('Running')

    revert()
    expect(keepers.value[0]).toEqual(original)
  })

  it('wakeup behaves like resume (paused → running) for the optimistic patch', () => {
    keepers.value = [baseKeeper({ name: 'rondo', paused: true, phase: 'Paused' })]
    applyOptimisticKeeperDirective('rondo', 'wakeup')
    expect(keepers.value[0]!.paused).toBe(false)
    expect(keepers.value[0]!.phase).toBe('Running')
    expect(keepers.value[0]!.lifecycle_phase).toBe('Running')
  })

  it('patches lifecycle_phase so the roster status dot tone flips immediately', () => {
    keepers.value = [
      baseKeeper({ name: 'rondo', paused: true, phase: 'Paused', lifecycle_phase: 'Paused' }),
    ]
    // Before: the dot reads the paused tone from lifecycle_phase.
    expect(phaseTone(keepers.value[0]!.lifecycle_phase)).toBe('warn')

    applyOptimisticKeeperDirective('rondo', 'resume')

    // After the optimistic resume, the dot tone is the running tone with no
    // server round-trip. This is the field keeper-workspace-roster renders.
    expect(phaseTone(keepers.value[0]!.lifecycle_phase)).toBe('ok')
    expect(phasePulse(keepers.value[0]!.lifecycle_phase)).toBe(true)
  })

  it('reverts lifecycle_phase to the original on failure (no stale Running dot)', () => {
    // Failure rollback: runKeeperAction calls the returned revert thunk on a
    // non-ok response and on throw (keeper-action-panel.ts:96-117). Since the
    // dot reads lifecycle_phase, the revert must restore it — otherwise a
    // failed resume would leave the dot stuck on a stale 'Running' (a silent
    // UI lie). Locks the rollback of the field this change introduced.
    keepers.value = [
      baseKeeper({ name: 'rondo', paused: true, phase: 'Paused', lifecycle_phase: 'Paused' }),
    ]
    const revert = applyOptimisticKeeperDirective('rondo', 'resume')
    expect(phaseTone(keepers.value[0]!.lifecycle_phase)).toBe('ok')

    revert()

    expect(keepers.value[0]!.lifecycle_phase).toBe('Paused')
    expect(phaseTone(keepers.value[0]!.lifecycle_phase)).toBe('warn')
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
