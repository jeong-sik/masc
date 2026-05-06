import { html } from 'htm/preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { GoalLoopPanel } from './goal-loop-panel'
import { normalizeGoalLoopStatus } from '../goal-loop-status'

function blockedStatus() {
  return normalizeGoalLoopStatus({
    schema_version: 1,
    generated_at: '2026-05-06T00:00:00Z',
    loop_iteration: '#fixture',
    overall_status: 'critical',
    dashboard_source: {
      kind: 'runtime_status_json',
      path: '/tmp/goal-loop-status.json',
    },
    phases: {
      observe: {
        status: 'critical',
        summary: { critical_matches: 75, warning_matches: 4, matched_lines: 79 },
      },
      orient: {
        status: 'critical',
        summary: {
          critical_present: 3,
          evidence_present: 5,
          findings_total: 10,
          audit_catalog: {
            status: 'INCOMPLETE',
            expected_findings_total: 206,
            itemized_findings_total: 19,
            missing_itemized_findings: 187,
            strict_row_corpus_validated: false,
          },
        },
      },
      decide: {
        status: 'critical',
        summary: { decisions_total: 5, p0_count: 2, act_missing_count: 0 },
      },
      act: {
        status: 'ok',
        summary: { act_linked_count: 5, act_missing_count: 0, decisions_total: 5 },
      },
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
  })
}

describe('GoalLoopPanel', () => {
  afterEach(() => {
    cleanup()
  })

  it('renders phase status, next action, and the strict corpus blocker', () => {
    render(html`<${GoalLoopPanel} initialStatus=${blockedStatus()} />`)

    expect(screen.getByTestId('goal-loop-panel')).toBeTruthy()
    expect(screen.getByTestId('goal-loop-phase-observe').textContent).toContain('critical')
    expect(screen.getByTestId('goal-loop-phase-verify').textContent).toContain('FAIL')
    expect(screen.getByTestId('goal-loop-audit-catalog').textContent).toContain('INCOMPLETE')
    expect(screen.getByTestId('goal-loop-corpus-missing').textContent).toContain('187')
    expect(screen.getByTestId('goal-loop-next-action').textContent).toContain('D-EMERGENCY-2')
  })

  it('renders startup fixture Verify evidence as distinct from live post-ACT evidence', () => {
    const status = blockedStatus()
    render(html`<${GoalLoopPanel} initialStatus=${status} />`)

    expect(screen.getByTestId('goal-loop-verify-evidence').textContent).toContain('Startup fixture failure')
  })

  it('renders post-ACT live Verify evidence when the status JSON carries it', () => {
    const status = blockedStatus()
    status.phases.verify = {
      status: 'ok',
      summary: {
        verify_status: 'PASS',
        violations: 0,
        post_act_verify: true,
        evidence_kind: 'live_runtime_logs',
        evidence_source: '/tmp/goal-loop-post-act.log',
      },
    }
    render(html`<${GoalLoopPanel} initialStatus=${status} />`)

    expect(screen.getByTestId('goal-loop-verify-evidence').textContent).toContain('Post-ACT live Verify evidence')
    expect(screen.getByTestId('goal-loop-verify-evidence').textContent).toContain('/tmp/goal-loop-post-act.log')
  })
})
