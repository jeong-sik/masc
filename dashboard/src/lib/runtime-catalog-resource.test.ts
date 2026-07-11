import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DashboardRuntimeProviderSnapshot } from '../api/dashboard'

const apiMock = vi.hoisted(() => ({
  fetchRuntimeProviders: vi.fn(),
}))

vi.mock('../api/dashboard', () => ({
  fetchRuntimeProviders: apiMock.fetchRuntimeProviders,
}))

import {
  reloadRuntimeCatalog,
  resolveRuntimeCatalogEntry,
  resetRuntimeCatalog,
  runtimeCatalogState,
} from './runtime-catalog-resource'
import { failed, idle, loaded, loading } from './async-state'

function provider(runtimeId: string): DashboardRuntimeProviderSnapshot {
  return {
    provider: runtimeId,
    runtime_id: runtimeId,
    models: [],
  } as DashboardRuntimeProviderSnapshot
}

describe('runtime catalog resource', () => {
  afterEach(() => {
    apiMock.fetchRuntimeProviders.mockReset()
    resetRuntimeCatalog()
  })

  it('awaits a forced catalog reload before resolving', async () => {
    apiMock.fetchRuntimeProviders.mockResolvedValueOnce({
      providers: [provider('rt-a')],
    })

    await reloadRuntimeCatalog()

    expect(apiMock.fetchRuntimeProviders).toHaveBeenCalledTimes(1)
    expect(runtimeCatalogState.value).toEqual({
      status: 'loaded',
      data: [provider('rt-a')],
    })
  })

  it('rejects a forced catalog reload while publishing the error state', async () => {
    apiMock.fetchRuntimeProviders.mockRejectedValueOnce(new Error('catalog unavailable'))

    await expect(reloadRuntimeCatalog()).rejects.toThrow('catalog unavailable')
    expect(runtimeCatalogState.value).toEqual({
      status: 'error',
      message: 'catalog unavailable',
    })
  })

  it('keeps loading, error, missing, and ready entry states distinct', () => {
    const entry = provider('rt-a')

    expect(resolveRuntimeCatalogEntry(idle, 'rt-a')).toEqual({ status: 'loading' })
    expect(resolveRuntimeCatalogEntry(loading, 'rt-a')).toEqual({ status: 'loading' })
    expect(resolveRuntimeCatalogEntry(failed('catalog unavailable'), 'rt-a')).toEqual({
      status: 'error',
      message: 'catalog unavailable',
    })
    expect(resolveRuntimeCatalogEntry(loaded([]), 'rt-a')).toEqual({ status: 'missing' })
    expect(resolveRuntimeCatalogEntry(loaded([entry]), 'rt-a')).toEqual({
      status: 'ready',
      entry,
    })
  })
})
