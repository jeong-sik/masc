import { describe, it, expect, vi, beforeEach } from 'vitest'
import {
  refreshCommandPlaneSummary,
  setCommandPlaneSurface,
  pauseCommandPlaneOperation
} from './command-actions'
import * as api from './api'
import { commandPlaneSummary, commandPlaneLoading, commandPlaneSurface } from './command-signals'

vi.mock('./api', () => ({
  fetchCommandPlaneSummary: vi.fn(),
  fetchCommandPlaneSnapshot: vi.fn(),
  fetchChainSummary: vi.fn(),
  fetchChainRun: vi.fn(),
  fetchCommandPlaneHelp: vi.fn(),
  runCommandPlaneAction: vi.fn(),
}))

vi.mock('./command-normalizers-swarm', () => ({
  normalizeSnapshot: vi.fn(x => x),
  normalizeSummarySnapshot: vi.fn(x => x),
  normalizeChainSummary: vi.fn(x => x),
  normalizeChainRunResponse: vi.fn(x => x),
  normalizeHelp: vi.fn(x => x),
}))

describe('command-actions', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    commandPlaneSummary.value = null
    commandPlaneLoading.value = false
    commandPlaneSurface.value = 'default' as any
  })

  it('refreshCommandPlaneSummary updates summary on success', async () => {
    const mockSummary = { status: 'ok' } as any
    vi.mocked(api.fetchCommandPlaneSummary).mockResolvedValue(mockSummary)

    const promise = refreshCommandPlaneSummary({ force: true })
    expect(commandPlaneLoading.value).toBe(true)
    await promise
    
    expect(commandPlaneLoading.value).toBe(false)
    expect(api.fetchCommandPlaneSummary).toHaveBeenCalled()
    expect(commandPlaneSummary.value).toEqual(mockSummary)
  })

  it('setCommandPlaneSurface updates surface', () => {
    setCommandPlaneSurface('operations')
    expect(commandPlaneSurface.value).toBe('operations')
  })

  it('pauseCommandPlaneOperation calls api and refreshes', async () => {
    vi.mocked(api.runCommandPlaneAction).mockResolvedValue({} as any)
    
    await pauseCommandPlaneOperation('op-123')
    
    expect(api.runCommandPlaneAction).toHaveBeenCalledWith('/api/v1/command-plane/operations/pause', {
      operation_id: 'op-123'
    })
  })
})
