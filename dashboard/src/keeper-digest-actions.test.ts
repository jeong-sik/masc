import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { fetchKeeperCatchupDigest } = vi.hoisted(() => ({ fetchKeeperCatchupDigest: vi.fn() }))
vi.mock('./api/keeper', () => ({ fetchKeeperCatchupDigest }))

import { refreshKeeperCatchupDigest, _resetKeeperDigestForTests } from './keeper-digest-actions'
import {
  keeperCatchupDigests,
  keeperDigestError,
  keeperDigestLoading,
} from './keeper-digest-signals'
import type { KeeperCatchupDigest } from './api/schemas/keeper-catchup-digest'

function makeDigest(sinceUnix: number): KeeperCatchupDigest {
  return {
    keeper: 'garnet',
    since_unix: sinceUnix,
    generated_at_unix: sinceUnix + 100,
    chat: { new_messages: 3, first_new_ts: sinceUnix + 1, transport_failures: 0 },
    turns: { completed: 5, failed: 0, crashes: 0 },
    tasks: { claimed: 0, done: 1, released: 0, cancelled: 0, items: [] },
    board: { posted: 0, commented: 0, voted: 0 },
    lifecycle: { paused_now: false, pause_events: 0, resume_events: 0, items: [] },
    coverage: {
      chat: { lower_bound: false, reason: null },
      turns: { lower_bound: false, reason: null },
      tasks: { lower_bound: false, reason: null },
      board: { lower_bound: false, reason: null },
      lifecycle: { lower_bound: false, reason: null },
    },
    read_errors: [],
  }
}

describe('refreshKeeperCatchupDigest', () => {
  beforeEach(() => {
    _resetKeeperDigestForTests()
    fetchKeeperCatchupDigest.mockReset()
  })

  afterEach(() => {
    _resetKeeperDigestForTests()
  })

  it('stores the fetched digest on the per-keeper signal', async () => {
    fetchKeeperCatchupDigest.mockResolvedValue(makeDigest(1000))

    await refreshKeeperCatchupDigest('garnet', 1000)

    expect(fetchKeeperCatchupDigest).toHaveBeenCalledTimes(1)
    expect(fetchKeeperCatchupDigest).toHaveBeenCalledWith('garnet', 1000)
    expect(keeperCatchupDigests.value.garnet?.since_unix).toBe(1000)
    expect(keeperDigestLoading.value.garnet).toBe(false)
    expect(keeperDigestError.value.garnet ?? null).toBeNull()
  })

  it('dedups two concurrent refreshes into a single fetch', async () => {
    let resolveFetch: (digest: KeeperCatchupDigest) => void = () => {}
    fetchKeeperCatchupDigest.mockImplementation(
      () => new Promise<KeeperCatchupDigest>((resolve) => { resolveFetch = resolve }),
    )

    const first = refreshKeeperCatchupDigest('garnet', 1000)
    const second = refreshKeeperCatchupDigest('garnet', 1000)
    resolveFetch(makeDigest(1000))
    await Promise.all([first, second])

    expect(fetchKeeperCatchupDigest).toHaveBeenCalledTimes(1)
    expect(keeperCatchupDigests.value.garnet?.since_unix).toBe(1000)
  })

  it('does not let an older in-flight baseline overwrite a newer one', async () => {
    const resolvers = new Map<number, (digest: KeeperCatchupDigest) => void>()
    fetchKeeperCatchupDigest.mockImplementation(
      (_keeper: string, sinceUnix: number) => new Promise<KeeperCatchupDigest>((resolve) => {
        resolvers.set(sinceUnix, resolve)
      }),
    )

    const older = refreshKeeperCatchupDigest('garnet', 1000)
    const newer = refreshKeeperCatchupDigest('garnet', 2000)
    resolvers.get(2000)?.(makeDigest(2000))
    await newer
    resolvers.get(1000)?.(makeDigest(1000))
    await older

    expect(fetchKeeperCatchupDigest).toHaveBeenCalledTimes(2)
    expect(fetchKeeperCatchupDigest).toHaveBeenNthCalledWith(1, 'garnet', 1000)
    expect(fetchKeeperCatchupDigest).toHaveBeenNthCalledWith(2, 'garnet', 2000)
    expect(keeperCatchupDigests.value.garnet?.since_unix).toBe(2000)
    expect(keeperDigestLoading.value.garnet).toBe(false)
  })

  it('surfaces fetch errors on keeperDigestError without throwing', async () => {
    fetchKeeperCatchupDigest.mockRejectedValue(new Error('boom'))

    await expect(refreshKeeperCatchupDigest('garnet', 1000)).resolves.toBeUndefined()

    expect(keeperDigestError.value.garnet).toContain('boom')
    expect(keeperDigestLoading.value.garnet).toBe(false)
    expect(keeperCatchupDigests.value.garnet ?? null).toBeNull()
  })

  it('ignores blank keeper names and non-finite since values', async () => {
    await refreshKeeperCatchupDigest('   ', 1000)
    await refreshKeeperCatchupDigest('garnet', Number.NaN)
    expect(fetchKeeperCatchupDigest).not.toHaveBeenCalled()
  })
})
