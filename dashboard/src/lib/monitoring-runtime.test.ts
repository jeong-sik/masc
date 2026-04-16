import { describe, it, expect } from 'vitest'
import {
  runtimeBandMeta,
  summarizeMonitoringEvidence,
} from './monitoring-runtime'
import type { KeeperMonitoringSummary } from './monitoring-runtime'

function makeSummary(overrides: Partial<KeeperMonitoringSummary> = {}): KeeperMonitoringSummary {
  return {
    band: { key: 'active', label: '가동중', description: '정상' },
    phase: { key: 'Running', label: '실행중', description: '정상 실행' },
    stage: { key: 'idle', label: '활동 없음', description: '없음' },
    hint: null,
    ...overrides,
  }
}

// ================================================================
// runtimeBandMeta
// ================================================================

describe('runtimeBandMeta', () => {
  it('returns active meta', () => {
    const meta = runtimeBandMeta('active')
    expect(meta.key).toBe('active')
    expect(meta.label).toBeTruthy()
  })

  it('returns attention meta', () => {
    const meta = runtimeBandMeta('attention')
    expect(meta.key).toBe('attention')
    expect(meta.label).toContain('주의')
  })

  it('returns paused meta', () => {
    const meta = runtimeBandMeta('paused')
    expect(meta.key).toBe('paused')
    expect(meta.label).toContain('일시정지')
  })

  it('returns offline meta', () => {
    const meta = runtimeBandMeta('offline')
    expect(meta.key).toBe('offline')
    expect(meta.label).toContain('오프라인')
  })
})

// ================================================================
// summarizeMonitoringEvidence
// ================================================================

describe('summarizeMonitoringEvidence', () => {
  it('suppresses Running phase as null', () => {
    const evidence = summarizeMonitoringEvidence(makeSummary())
    expect(evidence.phase).toBeNull()
  })

  it('suppresses idle stage as null', () => {
    const evidence = summarizeMonitoringEvidence(makeSummary())
    expect(evidence.stage).toBeNull()
  })

  it('suppresses offline stage as null', () => {
    const evidence = summarizeMonitoringEvidence(makeSummary({
      stage: { key: 'offline', label: '오프라인', description: 'offline' },
    }))
    expect(evidence.stage).toBeNull()
  })

  it('exposes attention phase', () => {
    const evidence = summarizeMonitoringEvidence(makeSummary({
      phase: { key: 'Failing', label: '오류중', description: '오류 감지' },
    }))
    expect(evidence.phase).not.toBeNull()
    expect(evidence.phase!.key).toBe('Failing')
  })

  it('exposes non-idle stage when not matching phase', () => {
    const evidence = summarizeMonitoringEvidence(makeSummary({
      stage: { key: 'thinking', label: '사고', description: 'thinking' },
    }))
    expect(evidence.stage).not.toBeNull()
    expect(evidence.stage!.key).toBe('thinking')
  })

  it('suppresses stage when it matches phase equivalent', () => {
    const evidence = summarizeMonitoringEvidence(makeSummary({
      phase: { key: 'Compacting', label: '압축중', description: 'compressing' },
      stage: { key: 'compacting', label: '압축', description: 'compressing stage' },
    }))
    expect(evidence.stage).toBeNull()
  })

  it('suppresses paused stage in paused band', () => {
    const evidence = summarizeMonitoringEvidence(makeSummary({
      band: { key: 'paused', label: '일시정지', description: 'paused' },
      stage: { key: 'paused', label: '일시정지', description: 'paused stage' },
    }))
    expect(evidence.stage).toBeNull()
  })

  it('suppresses unknown phase as null when default for band', () => {
    const evidence = summarizeMonitoringEvidence(makeSummary({
      band: { key: 'active', label: '가동중', description: 'active' },
      phase: { key: 'unknown', label: '확인 필요', description: 'unknown' },
    }))
    expect(evidence.phase).toBeNull()
  })
})
