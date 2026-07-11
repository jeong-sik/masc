import { beforeEach, describe, expect, it, vi } from 'vitest'

const refreshMock = vi.hoisted(() => ({
  refreshKeeperRuntimeStatus: vi.fn<() => Promise<void>>(async () => {}),
  reloadRuntimeCatalog: vi.fn<() => Promise<void>>(async () => {}),
  reloadRuntimeResolved: vi.fn<() => Promise<void>>(async () => {}),
}))

vi.mock('../store', () => ({
  refreshKeeperRuntimeStatus: refreshMock.refreshKeeperRuntimeStatus,
}))

vi.mock('./runtime-catalog-resource', () => ({
  reloadRuntimeCatalog: refreshMock.reloadRuntimeCatalog,
}))

vi.mock('./runtime-resolved-resource', () => ({
  reloadRuntimeResolved: refreshMock.reloadRuntimeResolved,
}))

import { refreshRuntimeConfigConsumers } from './runtime-config-refresh'

describe('refreshRuntimeConfigConsumers', () => {
  beforeEach(() => {
    refreshMock.refreshKeeperRuntimeStatus.mockClear()
    refreshMock.reloadRuntimeCatalog.mockClear()
    refreshMock.reloadRuntimeResolved.mockClear()
  })

  it('waits for both the shared catalog and keeper runtime projection', async () => {
    let resolveCatalog!: () => void
    refreshMock.reloadRuntimeCatalog.mockReturnValueOnce(new Promise<void>(resolve => {
      resolveCatalog = resolve
    }))

    const refresh = refreshRuntimeConfigConsumers()
    let settled = false
    void refresh.then(() => {
      settled = true
    })

    await Promise.resolve()
    expect(settled).toBe(false)
    expect(refreshMock.refreshKeeperRuntimeStatus).toHaveBeenCalledWith({ force: true })
    expect(refreshMock.reloadRuntimeResolved).toHaveBeenCalledTimes(1)

    resolveCatalog()
    await refresh
    expect(settled).toBe(true)
  })

  it('surfaces catalog refresh failures to settings save callers', async () => {
    refreshMock.reloadRuntimeCatalog.mockRejectedValueOnce(new Error('catalog unavailable'))

    await expect(refreshRuntimeConfigConsumers()).rejects.toThrow('catalog unavailable')
    expect(refreshMock.refreshKeeperRuntimeStatus).toHaveBeenCalledWith({ force: true })
  })
})
