import { describe, it, expect } from 'vitest'
import {
  runtimeBandMeta,
  summarizeKeeperMonitoring,
  summarizeMonitoringEvidence,
  isTransientPhase,
} from './monitoring-runtime'
import type { KeeperMonitoringSummary } from './monitoring-runtime'
import type { Keeper, PipelineStage } from '../types'

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
    expect(meta.description).toContain('재개')
    expect(meta.description).not.toContain('운영자')
  })

  it('returns offline meta', () => {
    const meta = runtimeBandMeta('offline')
    expect(meta.key).toBe('offline')
    expect(meta.label).toContain('오프라인')
    expect(meta.description).toContain('기동')
  })

  // RFC-0295 §5.1 — transient band metadata. The 5th value activates the
  // busy rail; meta must agree with the prototype's FL_TONE_LABEL.busy gloss.
  it('returns transient meta', () => {
    const meta = runtimeBandMeta('transient')
    expect(meta.key).toBe('transient')
    expect(meta.label).toBe('전이')
    expect(meta.description).toContain('전이')
  })
})

// ================================================================
// isTransientPhase
// ================================================================

describe('isTransientPhase', () => {
  // Both KeeperPhase (PascalCase SSOT) and PipelineStage (lowercase wire)
  // spellings must resolve to true. Either spelling may arrive through
  // projection.opState.phase or keeper.pipeline_stage, so the helper
  // bridges both formats at one location.
  it.each([
    ['Compacting', 'PascalCase KeeperPhase'],
    ['HandingOff', 'PascalCase KeeperPhase'],
    ['Draining', 'PascalCase KeeperPhase'],
    ['Restarting', 'PascalCase KeeperPhase'],
    ['compacting', 'lowercase PipelineStage'],
    ['handoff', 'lowercase PipelineStage'],
    ['draining', 'lowercase PipelineStage'],
    ['restarting', 'lowercase PipelineStage'],
  ])('returns true for transient phase %s (%s)', (phase) => {
    expect(isTransientPhase(phase)).toBe(true)
  })

  it.each([
    ['Running'],
    ['Paused'],
    ['Offline'],
    ['Failing'],
    ['idle'],
    ['offline'],
    ['paused'],
    ['unknown'],
  ])('returns false for non-transient phase %s', (phase) => {
    expect(isTransientPhase(phase)).toBe(false)
  })

  it('returns false for null and undefined', () => {
    expect(isTransientPhase(null)).toBe(false)
    expect(isTransientPhase(undefined)).toBe(false)
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
  it('describes paused keepers as resume-waiting instead of operator-only', () => {
    const summary = summarizeKeeperMonitoring({
      name: 'keeper-paused',
      status: 'paused',
      phase: 'Paused',
      pipeline_stage: 'paused',
      paused: true,
    } as Keeper)

    expect(summary.band.key).toBe('paused')
    expect(summary.hint).toContain('재개 대기')
    expect(summary.hint).not.toContain('운영자')
  })

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

  // RFC-0295 §6 verification: each of the four transient FSM phases must
  // route to the new `transient` band regardless of which spelling arrives.
  // Driven via composite.phase (open string wire, `KeeperCompositePhaseSchema`)
  // and keeper.phase (PascalCase SSOT) to cover both projection paths.
  //
  // Wire spelling notes: composite.phase uses snake_case for `handing_off`
  // but single-word lowercase for the rest (`compacting`/`draining`/
  // `restarting`) — see `keeper-store-normalize.ts:110` `BACKEND_PHASE_LOWERCASE_MAP`.
  // `handoff` is the PipelineStage spelling (types/core.ts:945) used for
  // `keeper.pipeline_stage`; it does not appear in the composite wire.
  describe('transient band routing (RFC-0295 §5.2)', () => {
    const transientPhases: ReadonlyArray<[string, string]> = [
      ['compacting', 'lowercase composite.phase'],
      ['draining', 'lowercase composite.phase'],
      ['handing_off', 'snake_case composite.phase (lowercase map SSOT)'],
      ['restarting', 'lowercase composite.phase'],
    ]

    it.each(transientPhases)(
      'routes %s (%s) to the transient band',
      (phase, _label) => {
        const summary = summarizeKeeperMonitoring(
          {
            name: 'keeper-transient',
            status: 'busy',
            phase: 'Running',
            pipeline_stage: phase === 'handing_off' ? 'handoff' : phase,
          } as Keeper,
          { keeper: 'keeper-transient', phase } as unknown as Parameters<
            typeof summarizeKeeperMonitoring
          >[1],
        )
        expect(summary.band.key).toBe('transient')
        expect(summary.band.label).toBe('전이')
      },
    )

    it.each([
      ['Compacting', 'PascalCase keeper.phase'],
      ['Draining', 'PascalCase keeper.phase'],
      ['HandingOff', 'PascalCase keeper.phase'],
      ['Restarting', 'PascalCase keeper.phase'],
    ] as const)(
      'routes %s (%s) to the transient band',
      (phase, _label) => {
        const summary = summarizeKeeperMonitoring({
          name: 'keeper-transient-pascal',
          status: 'busy',
          phase,
          pipeline_stage: phase === 'HandingOff' ? 'handoff' : (phase.toLowerCase() as PipelineStage),
        } as Keeper)
        expect(summary.band.key).toBe('transient')
      },
    )

    // Order matters in `keeperBand`: transient must beat attention so a
    // mid-compaction blocker check does not repaint the row as red.
    it('transient beats attention when a live blocker signal fires mid-compaction', () => {
      const summary = summarizeKeeperMonitoring(
        {
          name: 'keeper-transient-blocked',
          status: 'busy',
          phase: 'Running',
          pipeline_stage: 'compacting',
          runtime_blocker_class: 'turn_timeout',
          runtime_blocker_summary: 'turn timed out after queue wait',
        } as Keeper,
        { keeper: 'keeper-transient-blocked', phase: 'compacting' } as unknown as Parameters<
          typeof summarizeKeeperMonitoring
        >[1],
      )
      expect(summary.band.key).toBe('transient')
    })

    // Offband priority: paused/offline remain sticky over transient so a
    // paused keeper mid-restart does not silently flip to busy.
    it('offline beats transient when both apply', () => {
      const summary = summarizeKeeperMonitoring(
        {
          name: 'keeper-offline-restarting',
          status: 'offline',
          phase: 'Restarting',
          pipeline_stage: 'restarting',
        } as Keeper,
        { keeper: 'keeper-offline-restarting', phase: 'restarting' } as unknown as Parameters<
          typeof summarizeKeeperMonitoring
        >[1],
      )
      expect(summary.band.key).toBe('offline')
    })
  })
})
