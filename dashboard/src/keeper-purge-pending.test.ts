import { describe, it, expect, beforeEach, vi } from 'vitest'
import * as lifecycle from './api/keeper-lifecycle'
import { keeperPurgePending, keeperDeletionInventory, keeperDeletionError,
  markKeeperPurgePending, refreshKeeperDeletions } from './store'

describe('durable Keeper deletion observation', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    keeperPurgePending.value = new Set()
    keeperDeletionInventory.value = null
    keeperDeletionError.value = null
  })

  it('restores a deletion after reload without any Keeper roster row', async () => {
    vi.spyOn(lifecycle, 'fetchKeeperDeletions').mockResolvedValue({ operations: [{
      kind: 'runtime_shutdown', source: null, keeperName: 'removed-owner', operationId: 'durable-operation', completed: false,
      canRetry: true, phase: 'finalized', description: 'artifact cleanup failed',
    }], errors: [], configurationErrors: [] })
    await refreshKeeperDeletions()
    expect([...keeperPurgePending.value]).toEqual(['removed-owner'])
    expect(keeperDeletionInventory.value?.operations[0]?.operationId).toBe('durable-operation')
  })

  it('clears acceptance only when the durable inventory confirms completion', async () => {
    markKeeperPurgePending('removed-owner')
    vi.spyOn(lifecycle, 'fetchKeeperDeletions').mockResolvedValue({ operations: [{
      kind: 'runtime_shutdown', source: null, keeperName: 'removed-owner', operationId: 'durable-operation', completed: true,
      canRetry: false, phase: 'finalized', description: 'completed',
    }], errors: [], configurationErrors: [] })
    await refreshKeeperDeletions()
    expect(keeperPurgePending.value.size).toBe(0)
    expect(keeperDeletionInventory.value?.operations[0]?.completed).toBe(true)
  })

  it('keeps unresolved acceptance and exposes a failed observation', async () => {
    markKeeperPurgePending('removed-owner')
    vi.spyOn(lifecycle, 'fetchKeeperDeletions').mockRejectedValue(new Error('store unavailable'))
    await refreshKeeperDeletions()
    expect(keeperPurgePending.value.has('removed-owner')).toBe(true)
    expect(keeperDeletionError.value).toBe('store unavailable')
  })
})
