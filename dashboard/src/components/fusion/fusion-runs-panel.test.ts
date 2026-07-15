import { describe, expect, it } from 'vitest'
import { parseFusionRunsResponse } from '../../api/dashboard'
import { fusionRunStatusText, fusionRunStatusTone } from './fusion-runs-panel'

describe('parseFusionRunsResponse', () => {
  it('maps snake_case rows to FusionRunRecord and falls back count to length', () => {
    const parsed = parseFusionRunsResponse({
      generated_at: '2026-06-20T01:00:00Z',
      runs: [
        { run_id: 'r-1', keeper: 'k1', preset: 'balanced', started_at: 100, status: 'running' },
        { run_id: 'r-2', keeper: 'k2', preset: 'deep', started_at: 200, status: 'completed' },
      ],
    })
    expect(parsed.generatedAt).toBe('2026-06-20T01:00:00Z')
    expect(parsed.count).toBe(2)
    expect(parsed.runs[0]).toEqual({
      runId: 'r-1',
      keeper: 'k1',
      preset: 'balanced',
      startedAt: 100,
      status: 'running',
    })
  })

  it('fails loudly on an unrecognized status', () => {
    expect(() => parseFusionRunsResponse({
      runs: [{ run_id: 'r-unknown', keeper: 'k', preset: 'p', started_at: 1, status: 'weird' }],
    })).toThrow('unknown fusion run status: weird')
  })

  it('returns an empty, well-formed response for a non-object payload', () => {
    const parsed = parseFusionRunsResponse(null)
    expect(parsed.runs).toEqual([])
    expect(parsed.count).toBe(0)
    expect(parsed.generatedAt).toBeNull()
  })

  it('carries the additive error / failure_code fields on a failed row', () => {
    const parsed = parseFusionRunsResponse({
      runs: [
        {
          run_id: 'r-fail',
          keeper: 'k',
          preset: 'deep',
          started_at: 1,
          status: 'failed',
          error: 'judge timed out after 30s',
          failure_code: 'timeout',
        },
        { run_id: 'r-run', keeper: 'k', preset: 'p', started_at: 2, status: 'running' },
      ],
    })
    expect(parsed.runs[0]).toMatchObject({
      runId: 'r-fail',
      status: 'failed',
      error: 'judge timed out after 30s',
      failureCode: 'timeout',
    })
    // running rows carry no failure attribution
    expect(parsed.runs[1]?.error).toBeUndefined()
    expect(parsed.runs[1]?.failureCode).toBeUndefined()
  })
})

// The FusionRunsPanel component was merged into the FusionSurface master list, so
// only the pure status helpers remain here. Their SSOT mapping stays tested.
describe('fusion run status helpers', () => {
  it('maps status to the reused chip tone', () => {
    expect(fusionRunStatusTone('running')).toBe('warn')
    expect(fusionRunStatusTone('recovery_required')).toBe('bad')
    expect(fusionRunStatusTone('completed')).toBe('ok')
    expect(fusionRunStatusTone('failed')).toBe('bad')
  })

  it('keeps the wire label as the display text', () => {
    expect(fusionRunStatusText('running')).toBe('running')
    expect(fusionRunStatusText('recovery_required')).toBe('recovery required')
    expect(fusionRunStatusText('completed')).toBe('completed')
    expect(fusionRunStatusText('failed')).toBe('failed')
  })
})
