import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import { fetchKeeperTrajectory } from './dashboard-keeper-trajectory'

afterEach(() => {
  getMock.mockReset()
})

describe('fetchKeeperTrajectory', () => {
  it('explicitly withholds hidden thinking at the HTTP boundary', async () => {
    getMock.mockResolvedValue({ entries: [] })

    await fetchKeeperTrajectory('keeper/a', 100)

    expect(getMock).toHaveBeenCalledWith(
      '/api/v1/keepers/keeper%2Fa/trajectory?limit=100&include_thinking=false',
    )
  })
})
