import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  boardLatencyMetrics,
  recordBoardLatency,
  resetBoardLatencyMetrics,
  timeBoardRequest,
} from './board-metrics'

afterEach(() => {
  vi.restoreAllMocks()
  resetBoardLatencyMetrics()
})

describe('board latency metrics', () => {
  it('records successful request latency by operation', () => {
    vi.spyOn(performance, 'now').mockReturnValue(37.4)

    recordBoardLatency('list', 10, true)

    expect(boardLatencyMetrics.value.list).toMatchObject({
      last_latency_ms: 27,
      last_ok: true,
      sample_count: 1,
      failure_count: 0,
      last_error: null,
    })
  })

  it('records failures without erasing other operation buckets', async () => {
    vi.spyOn(performance, 'now')
      .mockReturnValueOnce(100)
      .mockReturnValueOnce(145)

    await expect(timeBoardRequest('reaction_toggle', async () => {
      throw new Error('network down')
    })).rejects.toThrow('network down')

    expect(boardLatencyMetrics.value.reaction_toggle).toMatchObject({
      last_latency_ms: 45,
      last_ok: false,
      sample_count: 1,
      failure_count: 1,
      last_error: 'network down',
    })
    expect(boardLatencyMetrics.value.list.sample_count).toBe(0)
  })
})
