import { describe, it, expect } from 'vitest'
import {
  runtimeBandMeta,
  summarizeKeeperMonitoring,
  summarizeMonitoringEvidence,
} from './monitoring-runtime'
import type { KeeperMonitoringSummary } from './monitoring-runtime'
import type { Keeper } from '../types'

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

describe('summarizeKeeperMonitoring', () => {
  it('ignores stale last_blocker text when no live runtime blocker is present', () => {
    const summary = summarizeKeeperMonitoring({
      name: 'keeper-a',
      status: 'idle',
      phase: 'Running',
      last_heartbeat: new Date().toISOString(),
      last_blocker: 'old blocker',
    } as Keeper)

    expect(summary.band.key).toBe('active')
    expect(summary.hint).toBeNull()
  })

  it('keeps runtime blockers as live attention signals', () => {
    const summary = summarizeKeeperMonitoring({
      name: 'keeper-a',
      status: 'idle',
      phase: 'Running',
      last_heartbeat: new Date().toISOString(),
      runtime_blocker_class: 'turn_timeout',
      runtime_blocker_summary: 'turn timed out after queue wait',
    } as Keeper)

    expect(summary.band.key).toBe('attention')
    expect(summary.hint).toBe('turn timed out after queue wait')
  })

  // RFC-0135 PR-12 — stale-vs-live blocker via composite SSOT.
  describe('composite stale-blocker conditioning', () => {
    const keeper = {
      name: 'keeper-stale',
      status: 'idle',
      phase: 'Running',
      last_heartbeat: new Date().toISOString(),
      runtime_blocker_class: 'turn_timeout',
      runtime_blocker_summary: 'turn timed out after queue wait',
    } as Keeper

    it('without composite ⇒ blocker treated as live (attention)', () => {
      const summary = summarizeKeeperMonitoring(keeper)
      expect(summary.band.key).toBe('attention')
    })

    it('composite says execution_current=false ⇒ blocker demoted, band=active', () => {
      const compositeStaleByExecutionCurrent = {
        keeper: 'keeper-stale',
        runtime_attention: {
          execution_current: false,
          stale_execution_receipt: false,
          blocked: false,
          needs_attention: false,
        },
      } as unknown as Parameters<typeof summarizeKeeperMonitoring>[1] extends infer C ? C : never
      const summary = summarizeKeeperMonitoring(keeper, compositeStaleByExecutionCurrent)
      expect(summary.band.key).toBe('active')
    })

    it('composite says stale_execution_receipt=true ⇒ blocker demoted, band=active', () => {
      const compositeStaleByReceipt = {
        keeper: 'keeper-stale',
        runtime_attention: {
          execution_current: true,
          stale_execution_receipt: true,
          blocked: false,
          needs_attention: false,
        },
      } as unknown as Parameters<typeof summarizeKeeperMonitoring>[1] extends infer C ? C : never
      const summary = summarizeKeeperMonitoring(keeper, compositeStaleByReceipt)
      expect(summary.band.key).toBe('active')
    })

    it('composite with live execution ⇒ blocker stays attention', () => {
      const compositeLive = {
        keeper: 'keeper-stale',
        runtime_attention: {
          execution_current: true,
          stale_execution_receipt: false,
          blocked: false,
          needs_attention: false,
        },
      } as unknown as Parameters<typeof summarizeKeeperMonitoring>[1] extends infer C ? C : never
      const summary = summarizeKeeperMonitoring(keeper, compositeLive)
      expect(summary.band.key).toBe('attention')
    })
  })

  it('routes heartbeat/context/social attention through the runtime projection', () => {
    const summary = summarizeKeeperMonitoring({
      name: 'keeper-organism',
      status: 'idle',
      phase: 'Running',
      last_heartbeat: '1970-01-01T00:00:00Z',
      context_ratio: 0.99,
      social_model_recognized: false,
    } as Keeper)

    expect(summary.band.key).toBe('attention')
    expect(summary.hint).toBe('오래 응답이 없어 실제 상태 확인이 필요합니다.')
  })

  it('routes current tool-contract attention through the runtime projection', () => {
    const compositeToolAttention = {
      keeper: 'keeper-tool',
      phase: 'running',
      turn_phase: 'idle',
      decision: { stage: 'idle' },
      cascade: { state: 'idle' },
      compaction: { stage: 'idle' },
      circuit_breaker: { state: 'closed' },
      is_live: false,
      execution: {
        tool_contract_result: 'missing_required_tool_use',
      },
      runtime_attention: {
        blocked: false,
        needs_attention: false,
        execution_current: true,
        stale_execution_receipt: false,
      },
    } as unknown as Parameters<typeof summarizeKeeperMonitoring>[1] extends infer C ? C : never
    const summary = summarizeKeeperMonitoring({
      name: 'keeper-tool',
      status: 'idle',
      phase: 'Running',
      last_heartbeat: new Date().toISOString(),
      keepalive_running: true,
    } as Keeper, compositeToolAttention)

    expect(summary.band.key).toBe('attention')
    expect(summary.hint).toBe('도구 계약 결과가 missing_required_tool_use입니다.')
  })
})
