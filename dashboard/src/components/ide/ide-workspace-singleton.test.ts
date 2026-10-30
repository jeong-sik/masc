import { afterEach, describe, expect, it, vi } from 'vitest'
import type { IdeDataWorkspaceStore } from './ide-data-workspace-store'

// Mock the store factory so the singleton's own lifecycle (construct-once,
// return-same, reset-disposes) is tested in isolation — without firing the
// real store's repository/tree network fetches or importing sse-store/router.
const dispose = vi.fn()
let constructCount = 0

vi.mock('./ide-data-workspace-store', () => ({
  createIdeDataWorkspaceStore: (): IdeDataWorkspaceStore => {
    constructCount += 1
    return { dispose } as unknown as IdeDataWorkspaceStore
  },
}))

import {
  getIdeDataWorkspaceStore,
  resetIdeDataWorkspaceStoreForTest,
} from './ide-workspace-singleton'

describe('ide workspace store singleton', () => {
  afterEach(() => {
    resetIdeDataWorkspaceStoreForTest()
    dispose.mockClear()
    constructCount = 0
  })

  it('does not construct the store until first access', () => {
    expect(constructCount).toBe(0)
    getIdeDataWorkspaceStore()
    expect(constructCount).toBe(1)
  })

  it('returns the same instance across calls (survives IdeShell remounts)', () => {
    const first = getIdeDataWorkspaceStore()
    const second = getIdeDataWorkspaceStore()
    expect(first).toBe(second)
    expect(constructCount).toBe(1)
  })

  it('resetForTest disposes the instance and the next access builds a fresh one', () => {
    const first = getIdeDataWorkspaceStore()
    resetIdeDataWorkspaceStoreForTest()
    expect(dispose).toHaveBeenCalledTimes(1)
    const second = getIdeDataWorkspaceStore()
    expect(second).not.toBe(first)
    expect(constructCount).toBe(2)
  })

  it('resetForTest is a no-op when no instance exists', () => {
    resetIdeDataWorkspaceStoreForTest()
    expect(dispose).not.toHaveBeenCalled()
  })
})
