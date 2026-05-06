import { describe, expect, it } from 'vitest'
import {
  deriveCorpusBlocker,
  normalizeGoalLoopStatus,
  verifyEvidenceLabel,
  verifyEvidenceState,
} from './goal-loop-status'

function criticalPayload() {
  return {
    schema_version: 1,
    generated_at: '2026-05-06T00:00:00Z',
    loop_iteration: '#fixture',
    overall_status: 'critical',
    dashboard_source: {
      kind: 'runtime_status_json',
      path: '/tmp/goal-loop-status.json',
    },
    phases: {
      observe: { status: 'critical', summary: { critical_matches: 75 } },
      orient: {
        status: 'critical',
        summary: {
          critical_present: 3,
          audit_catalog: {
            status: 'INCOMPLETE',
            expected_findings_total: 206,
            itemized_findings_total: 19,
            missing_itemized_findings: 187,
            strict_row_corpus_validated: false,
          },
        },
      },
      decide: { status: 'critical', summary: { decisions_total: 5, p0_count: 2 } },
      act: { status: 'ok', summary: { act_linked_count: 5, act_missing_count: 0 } },
      verify: {
        status: 'critical',
        summary: {
          verify_status: 'FAIL',
          violations: 1,
          post_act_verify: false,
        },
      },
    },
    next_action: {
      decision_id: 'D-EMERGENCY-2',
      priority: 'P0',
      owner: 'provider',
      action: 'Run bootstrap provider health checks',
    },
    system_health_signals: {},
  }
}

describe('goal-loop-status contract', () => {
  it('normalizes all five phases and dashboard source metadata', () => {
    const status = normalizeGoalLoopStatus(criticalPayload())

    expect(status.overallStatus).toBe('critical')
    expect(status.loopIteration).toBe('#fixture')
    expect(status.dashboardSource.kind).toBe('runtime_status_json')
    expect(status.dashboardSource.path).toBe('/tmp/goal-loop-status.json')
    expect(status.phases.observe.status).toBe('critical')
    expect(status.phases.verify.summary.verify_status).toBe('FAIL')
  })

  it('derives the strict corpus blocker from audit catalog completeness', () => {
    const status = normalizeGoalLoopStatus(criticalPayload())
    const blocker = deriveCorpusBlocker(status)

    expect(blocker?.id).toBe('strict_row_level_catalog_complete')
    expect(blocker?.status).toBe('BLOCKED')
    expect(blocker?.expectedFindingsTotal).toBe(206)
    expect(blocker?.itemizedFindingsTotal).toBe(19)
    expect(blocker?.missingItemizedFindings).toBe(187)
    expect(blocker?.strictRowCorpusValidated).toBe(false)
  })

  it('distinguishes startup fixture failure from post-ACT live evidence', () => {
    const startup = normalizeGoalLoopStatus(criticalPayload())
    expect(verifyEvidenceState(startup)).toBe('startup-fixture-failure')
    expect(verifyEvidenceLabel(verifyEvidenceState(startup))).toBe('Startup fixture failure')

    const livePayload = criticalPayload() as ReturnType<typeof criticalPayload> & {
      phases: { verify: { summary: Record<string, unknown> } }
    }
    livePayload.phases.verify.summary = {
      verify_status: 'PASS',
      violations: 0,
      post_act_verify: true,
      evidence_kind: 'live_runtime_logs',
      evidence_source: '/tmp/goal-loop-post-act.log',
    }
    const live = normalizeGoalLoopStatus(livePayload)
    expect(verifyEvidenceState(live)).toBe('post-act-live')
    expect(verifyEvidenceLabel(verifyEvidenceState(live))).toBe('Post-ACT live Verify evidence')
  })
})
