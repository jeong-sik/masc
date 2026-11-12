import { h } from 'preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import '@testing-library/jest-dom'

const { fetchKeeperRuntimeTrace, fetchKeeperComposite } = vi.hoisted(() => ({
  fetchKeeperRuntimeTrace: vi.fn(),
  fetchKeeperComposite: vi.fn(),
}))
vi.mock('../api/keeper', () => ({ fetchKeeperRuntimeTrace, fetchKeeperComposite }))

import { useKeeperRuntimeTraceEvidence } from './keeper-detail-hooks'
import { bumpKeeperRuntimeTraceRefresh } from './keeper-runtime-trace-refresh'

function Probe({ name }: { name: string }): null {
  useKeeperRuntimeTraceEvidence(name)
  return null
}

afterEach(() => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  vi.clearAllMocks()
})

beforeEach(() => {
  acceptedExecutionWorkspace.value = { epoch: 'trace-fixture', workspaceRoot: '/workspace',
    connectionGeneration: 0, observerInstanceId: 'trace-fixture' }
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
