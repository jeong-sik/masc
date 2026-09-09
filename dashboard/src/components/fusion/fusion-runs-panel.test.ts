import { describe, expect, it } from 'vitest'
import { parseFusionRunsResponse } from '../../api/dashboard'
import { fusionRunStatusText, fusionRunStatusTone } from './fusion-runs-panel'

const row = { run_id: 'r-1', keeper: 'k1', preset: 'balanced', topology: 'simple', started_at: 100, status: 'running' }
const envelope = (runs: unknown[] = [row]) => ({
  generated_at: '2026-06-20T01:00:00Z', count: runs.length, runs,
  replay: { status: 'not_replayed' }, historical_evidence: [],
})

describe('parseFusionRunsResponse', () => {
  it('preserves current rows, genuinely empty snapshots, and replay warnings', () => {
    const parsed = parseFusionRunsResponse(envelope())
    expect(parsed.runs[0]).toMatchObject({ runId: 'r-1', status: 'running', topology: 'simple', startedAt: 100 })
    expect(parseFusionRunsResponse(envelope([])).runs).toEqual([])
    const warned = parseFusionRunsResponse({ ...envelope([]),
      replay: { status: 'complete', lines_read: 68, malformed_lines: 34, dropped_running: 0 },
      historical_evidence: [{ run_id: 'old-run', post_id: 'exact-post', title: 'Old evidence', created_at: 100 }],
    })
    expect(warned.replay).toMatchObject({ malformedLines: 34 })
    expect(warned.historicalEvidence[0]).toMatchObject({ runId: 'old-run', postId: 'exact-post' })
  })

  it.each([
    null, [], {}, { ...envelope(), runs: null }, { ...envelope(), runs: {} },
    envelope([null]), envelope([{ ...row, run_id: undefined }]),
    envelope([{ ...row, run_id: '' }]), envelope([{ ...row, status: 'weird' }]),
    envelope([{ ...row, topology: 'unknown' }]), envelope([{ ...row, started_at: '100' }]),
    envelope([{ ...row, status: 'failed' }]), envelope([row, row]),
    { ...envelope(), count: 0 }, { ...envelope(), count: -1 },
    { ...envelope(), replay: { status: 'guessed' } },
    { ...envelope(), historical_evidence: {} },
  ])('rejects malformed source without inventing an outcome: %j', raw => {
    expect(() => parseFusionRunsResponse(raw)).toThrow()
  })

  it('keeps a real failed execution distinct from a decoding failure', () => {
    const parsed = parseFusionRunsResponse(envelope([{ ...row, status: 'failed', error: 'provider disconnected', failure_code: 'provider_error' }]))
    expect(parsed.runs[0]).toMatchObject({ status: 'failed', error: 'provider disconnected', failureCode: 'provider_error' })
    expect(() => parseFusionRunsResponse(envelope([{ ...row, status: 'failed', error: '', failure_code: '' }]))).not.toThrow()
  })
})

// The FusionRunsPanel component was merged into the FusionSurface master list, so
// only the pure status helpers remain here. Their SSOT mapping stays tested.
describe('fusion run status helpers', () => {
  it('maps status to the reused chip tone', () => {
    expect(fusionRunStatusTone('running')).toBe('warn')
    expect(fusionRunStatusTone('completed')).toBe('ok')
    expect(fusionRunStatusTone('failed')).toBe('bad')
  })

  it('keeps the wire label as the display text', () => {
    expect(fusionRunStatusText('running')).toBe('running')
    expect(fusionRunStatusText('completed')).toBe('completed')
    expect(fusionRunStatusText('failed')).toBe('failed')
  })
})
