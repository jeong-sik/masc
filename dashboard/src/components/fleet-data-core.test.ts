import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  __resetFleetDataCoreForTests,
  refreshSharedTelemetrySummary,
  refreshSharedToolQuality,
  sharedTelemetrySummary,
  sharedTelemetrySummaryError,
  sharedTelemetrySummaryLoading,
  sharedToolQuality,
  sharedToolQualityError,
  sharedToolQualityLoading,
} from './fleet-data-core'

const toolQualityPayload = {
  total: 22,
  success: 21,
  failure: 1,
  success_rate: 95.5,
  by_tool: [],
  by_keeper: [],
  failure_categories: [],
  hourly_trend: [],
}

const telemetrySummaryPayload = {
  generated_at: '2026-04-14T00:00:00Z',
  sources: [],
  total_entries: 0,
}

function okJson<T>(body: T) {
  return {
    ok: true,
    status: 200,
    json: async () => body,
  }
}

describe('fleet-data-core', () => {
  beforeEach(() => {
    __resetFleetDataCoreForTests()
    vi.unstubAllGlobals()
  })

  afterEach(() => {
    __resetFleetDataCoreForTests()
    vi.unstubAllGlobals()
  })

  describe('refreshSharedToolQuality', () => {
    it('populates sharedToolQuality signal from fetch response', async () => {
      const fetchMock = vi.fn().mockResolvedValue(okJson(toolQualityPayload))
      vi.stubGlobal('fetch', fetchMock)

      await refreshSharedToolQuality()

      expect(fetchMock).toHaveBeenCalledTimes(1)
      expect(sharedToolQuality.value?.success_rate).toBe(95.5)
      expect(sharedToolQualityLoading.value).toBe(false)
      expect(sharedToolQualityError.value).toBeNull()
    })

    it('formats timeout errors into friendly "request timeout (Xs)" text', async () => {
      const fetchMock = vi.fn().mockRejectedValue(new Error('GET /foo: timeout after 35000ms'))
      vi.stubGlobal('fetch', fetchMock)

      await refreshSharedToolQuality()

      expect(sharedToolQualityError.value).toBe('request timeout (35s)')
    })

    it('silently ignores AbortError without populating the error signal', async () => {
      // fetchWithTimeout re-throws AbortError (not a timeout wrap) only when the
      // upstream signal is explicitly aborted. Emulate that path by pre-aborting
      // the signal passed into refreshSharedToolQuality.
      const fetchMock = vi.fn().mockImplementation((_url: string, init?: { signal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          const signal = init?.signal
          if (signal?.aborted) {
            reject(new DOMException('aborted', 'AbortError'))
            return
          }
          signal?.addEventListener('abort', () => {
            reject(new DOMException('aborted', 'AbortError'))
          }, { once: true })
        }))
      vi.stubGlobal('fetch', fetchMock)

      const upstreamController = new AbortController()
      upstreamController.abort()
      await refreshSharedToolQuality({ signal: upstreamController.signal })

      expect(sharedToolQualityError.value).toBeNull()
    })

    it('newer refresh supersedes an in-flight request (dedup by requestId)', async () => {
      let resolveFirst: (value: unknown) => void = () => {}
      const firstPromise = new Promise(resolve => {
        resolveFirst = resolve
      })
      const fetchMock = vi
        .fn<(input: unknown, init?: { signal?: AbortSignal }) => Promise<unknown>>()
        .mockImplementationOnce((_url, init) => new Promise((_resolve, reject) => {
          const signal = init?.signal
          signal?.addEventListener('abort', () => {
            reject(new DOMException('superseded', 'AbortError'))
          })
          // This resolves only if not aborted — simulates a stale response.
          void firstPromise.then(() => resolveFirst)
        }))
        .mockResolvedValueOnce(okJson({ ...toolQualityPayload, success_rate: 99.9 }))
      vi.stubGlobal('fetch', fetchMock)

      const first = refreshSharedToolQuality()
      const second = refreshSharedToolQuality()
      resolveFirst(okJson(toolQualityPayload))

      await Promise.all([first, second])

      expect(sharedToolQuality.value?.success_rate).toBe(99.9)
    })
  })

  describe('refreshSharedTelemetrySummary', () => {
    it('populates sharedTelemetrySummary signal', async () => {
      const fetchMock = vi.fn().mockResolvedValue(okJson(telemetrySummaryPayload))
      vi.stubGlobal('fetch', fetchMock)

      await refreshSharedTelemetrySummary()

      expect(sharedTelemetrySummary.value?.generated_at).toBe('2026-04-14T00:00:00Z')
      expect(sharedTelemetrySummaryLoading.value).toBe(false)
      expect(sharedTelemetrySummaryError.value).toBeNull()
    })

    it('formats timeout errors with the shared helper', async () => {
      const fetchMock = vi.fn().mockRejectedValue(new Error('GET /foo: timeout after 15000ms'))
      vi.stubGlobal('fetch', fetchMock)

      await refreshSharedTelemetrySummary()

      expect(sharedTelemetrySummaryError.value).toBe('request timeout (15s)')
    })
  })

  describe('consumer contract', () => {
    it('two concurrent refresh calls share a single resolved signal update', async () => {
      const fetchMock = vi.fn().mockResolvedValue(okJson(toolQualityPayload))
      vi.stubGlobal('fetch', fetchMock)

      // Simulates two panels both calling refresh on mount in the same tick.
      await Promise.all([refreshSharedToolQuality(), refreshSharedToolQuality()])

      // The first fetch is aborted by the second (requestId supersedes), so
      // only one response actually writes the signal. Both calls observe the
      // final state.
      expect(sharedToolQuality.value?.success_rate).toBe(95.5)
    })
  })
})
