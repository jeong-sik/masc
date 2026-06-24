import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { GoalLoopPanel } from './goal-loop-panel'
import { normalizeGoalLoopStatus } from '../goal-loop-status'
import { goalLoopStatusData } from '../goal-loop-state'

const mocks = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  fetchGoalLoopStatus: vi.fn(),
  fetchDashboardGoalsTree: vi.fn(),
  hydrateGoalTreeSnapshot: vi.fn(),
  navigate: vi.fn(),
}))

vi.mock('../api/mcp', () => ({
  callMcpTool: mocks.callMcpTool,
}))

vi.mock('../api/goal-loop', () => ({
  fetchGoalLoopStatus: mocks.fetchGoalLoopStatus,
}))

vi.mock('../api/dashboard', () => ({
  fetchDashboardGoalsTree: mocks.fetchDashboardGoalsTree,
}))

vi.mock('../goal-tree-state', () => ({
  hydrateGoalTreeSnapshot: mocks.hydrateGoalTreeSnapshot,
}))

vi.mock('../router', () => ({
  navigate: mocks.navigate,
}))

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
    mocks.callMcpTool.mockReset()
    mocks.fetchGoalLoopStatus.mockReset()
    mocks.fetchDashboardGoalsTree.mockReset()
    mocks.hydrateGoalTreeSnapshot.mockReset()
    mocks.navigate.mockReset()
    // RFC-0284: the panel now reads a module-global signal; reset it so a
    // pushed/refreshed status in one test cannot leak into the next.
    goalLoopStatusData.value = null
  })

  it('renders a pushed goal-loop snapshot from the store without a mount fetch', () => {
    // RFC-0284 §6 FE: a snapshot already in the store renders with no
    // initialStatus prop and triggers no HTTP fetch (push, not poll).
    goalLoopStatusData.value = blockedStatus()

    render(html`<${GoalLoopPanel} />`)

    expect(screen.getByTestId('goal-loop-panel')).toBeTruthy()
    expect(screen.getByTestId('goal-loop-next-action').textContent).toContain('D-EMERGENCY-2')
    expect(mocks.fetchGoalLoopStatus).not.toHaveBeenCalled()
  })

  it('re-renders when the store signal is written after mount (push reactivity)', async () => {
    // RFC-0284 §6 FE: the panel reads goalLoopStatusData.value in its render
    // body, which subscribes it to the signal. A post-mount write (the SSE
    // push path) must drive a re-render with no fetch and no re-mount. Moving
    // the read into a useCallback/useMemo closure would break the subscription
    // and turn this test red — that is the regression this pins.
    goalLoopStatusData.value = blockedStatus()
    render(html`<${GoalLoopPanel} />`)
    expect(screen.getByTestId('goal-loop-next-action').textContent).toContain('D-EMERGENCY-2')

    const pushed = blockedStatus()
    pushed.nextAction = { ...(pushed.nextAction ?? {}), decision_id: 'D-PUSHED-7' }
    goalLoopStatusData.value = pushed

    await waitFor(() => {
      expect(screen.getByTestId('goal-loop-next-action').textContent).toContain('D-PUSHED-7')
    })
    expect(mocks.fetchGoalLoopStatus).not.toHaveBeenCalled()
  })

  it('renders phase table, audit, and next action', () => {
    const { container } = render(html`<${GoalLoopPanel} initialStatus=${blockedStatus()} />`)

    expect(screen.getByTestId('goal-loop-panel')).toBeTruthy()
    expect(container.querySelector('.v2-workspace-surface')).not.toBeNull()
    expect(screen.getByRole('grid', { name: /goal loop phases/i })).toBeTruthy()
    expect(screen.getByTestId('goal-loop-audit-catalog').textContent).toContain('INCOMPLETE')
    expect(screen.getByTestId('goal-loop-corpus-missing').textContent).toContain('187')
    expect(screen.getByTestId('goal-loop-next-action').textContent).toContain('D-EMERGENCY-2')
  })

  it('renders audit catalog values even when the catalog is not blocked', () => {
    const status = blockedStatus()
    status.phases.orient.summary.audit_catalog = {
      status: 'COMPLETE',
      expected_findings_total: 206,
      itemized_findings_total: 206,
      missing_itemized_findings: 0,
    }

    render(html`<${GoalLoopPanel} initialStatus=${status} />`)

    const audit = screen.getByTestId('goal-loop-audit-catalog')
    expect(audit.textContent).toContain('COMPLETE')
    expect(audit.textContent).toContain('206')
    expect(screen.getByTestId('goal-loop-corpus-missing').textContent).toContain('0')
  })

  it('renders an explicit missing audit catalog state', () => {
    const status = blockedStatus()
    delete status.phases.orient.summary.audit_catalog

    render(html`<${GoalLoopPanel} initialStatus=${status} />`)

    const audit = screen.getByTestId('goal-loop-audit-catalog')
    expect(audit.textContent).toContain('missing')
    expect(screen.getByTestId('goal-loop-corpus-missing').textContent).toContain('n/a')
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

  it('creates a goal through the goal store tool and refreshes the loop status', async () => {
    mocks.callMcpTool.mockResolvedValue('{"ok":true}')
    mocks.fetchGoalLoopStatus.mockResolvedValue(blockedStatus())
    mocks.fetchDashboardGoalsTree.mockResolvedValue({ tree: [], summary: {} })

    render(html`<${GoalLoopPanel} initialStatus=${blockedStatus()} />`)

    fireEvent.input(screen.getByLabelText('Goal title'), {
      target: { value: 'Stabilize runtime truth' },
    })
    fireEvent.change(screen.getByLabelText('Priority'), {
      target: { value: '2' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Create goal' }))

    await waitFor(() => {
      expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_goal_upsert', {
        title: 'Stabilize runtime truth',
        priority: 2,
      })
    })
    await waitFor(() => {
      expect(mocks.fetchGoalLoopStatus).toHaveBeenCalledTimes(1)
    })
    expect(screen.getByTestId('goal-loop-create-goal').textContent)
      .toContain('created Stabilize runtime truth')
  })

  it('surfaces the created goal id, refreshes the goal tree cache, and routes to goal manager', async () => {
    const treePayload = { tree: [], summary: {} }
    mocks.callMcpTool.mockResolvedValue(JSON.stringify({
      ok: true,
      goal_id: 'goal-runtime-truth',
      task_link_field: 'goal_id',
    }))
    mocks.fetchGoalLoopStatus.mockResolvedValue(blockedStatus())
    mocks.fetchDashboardGoalsTree.mockResolvedValue(treePayload)

    render(html`<${GoalLoopPanel} initialStatus=${blockedStatus()} />`)

    fireEvent.input(screen.getByLabelText('Goal title'), {
      target: { value: 'Stabilize runtime truth' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Create goal' }))

    await waitFor(() => {
      expect(screen.getByTestId('goal-loop-created-goal-id').textContent)
        .toContain('goal goal-runtime-truth')
    })
    expect(screen.getByTestId('goal-loop-created-goal-id').textContent)
      .toContain('task link goal_id')
    await waitFor(() => {
      expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    })
    expect(mocks.hydrateGoalTreeSnapshot).toHaveBeenCalledWith(treePayload)

    fireEvent.click(screen.getByRole('button', {
      name: 'Open Stabilize runtime truth in Goal Manager',
    }))

    expect(mocks.navigate).toHaveBeenCalledWith('workspace', {
      section: 'planning',
      goal: 'goal-runtime-truth',
    })
  })
})
