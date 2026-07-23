import { h } from 'preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

const { fetchKeeperRuntimeTrace, fetchKeeperComposite } = vi.hoisted(() => ({
  fetchKeeperRuntimeTrace: vi.fn(),
  fetchKeeperComposite: vi.fn(),
}))
vi.mock('../api/keeper', () => ({ fetchKeeperRuntimeTrace, fetchKeeperComposite }))
// Silence the visible-auto-refresh timer so only explicit (initial + nonce) fetches occur.
vi.mock('../lib/auto-refresh', () => ({
  DEFAULT_PANEL_REFRESH_MS: 30_000,
  setupVisibleAutoRefresh: () => () => {},
}))

import { useKeeperRuntimeTraceEvidence } from './keeper-detail-hooks'
import { bumpKeeperRuntimeTraceRefresh } from './keeper-runtime-trace-refresh'

function Probe({ name }: { name: string }): null {
  useKeeperRuntimeTraceEvidence(name)
  return null
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('useKeeperRuntimeTraceEvidence refresh nonce', () => {
  it('re-fetches the runtime trace when the refresh nonce is bumped', async () => {
    fetchKeeperRuntimeTrace.mockResolvedValue({ keeper_name: 'runtime-sync-keeper', lines: [] } as never)

    render(h(Probe, { name: 'runtime-sync-keeper' }))
    await waitFor(() => expect(fetchKeeperRuntimeTrace).toHaveBeenCalledTimes(1))

    // A config save bumps the nonce; the effect (deps include the nonce) re-runs.
    // Counterfactual: with deps [keeperName] only, this stays at 1 and the test fails.
    bumpKeeperRuntimeTraceRefresh()
    await waitFor(() => expect(fetchKeeperRuntimeTrace).toHaveBeenCalledTimes(2))
  })
})
