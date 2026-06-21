import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationRequest,
} from '../../api'

const mocks = vi.hoisted(() => ({
  resolveScheduleApproval: vi.fn(),
  showToast: vi.fn(),
}))

vi.mock('../../api', () => ({
  resolveScheduleApproval: mocks.resolveScheduleApproval,
}))

vi.mock('../common/toast', () => ({
  showToast: mocks.showToast,
}))

import { ScheduledAutomationPanel, selectWakeSignals } from './scheduled-automation-panel'

function request(
  overrides: Partial<DashboardScheduledAutomationRequest> & { schedule_id: string },
): DashboardScheduledAutomationRequest {
  return {
    status: 'scheduled',
    risk_class: 'read_only',
    approval_required: false,
    source: 'schedule_store',
    ...overrides,
  }
}

function automation(
  requests: DashboardScheduledAutomationRequest[],
): DashboardScheduledAutomation {
  return {
    schema: 'masc.dashboard.scheduled_automation.v1',
    source: 'schedule_store',
    generated_at: '2026-06-21T00:00:00Z',
    request_count: requests.length,
    request_limit: 50,
    truncated: false,
    counts: {},
    derived_counts: {
      due_effective: 0,
      blocked_approval: 0,
      due_execution_ready: 0,
      expired_effective: 0,
    },
    fsm: { state: 'idle', active_count: requests.length, terminal_count: 0 },
    requests,
  }
}

function approvalAutomationFixture(): DashboardScheduledAutomation {
  return {
    schema: 'masc.dashboard.scheduled_automation.v1',
    source: 'schedule_store',
    generated_at: '2026-06-21T00:00:00Z',
    request_count: 1,
    request_limit: 20,
    truncated: false,
    counts: { pending_approval: 1 },
    derived_counts: {
      due_effective: 0,
      blocked_approval: 1,
      due_execution_ready: 0,
      expired_effective: 0,
    },
    fsm: {
      state: 'blocked_approval',
      active_count: 1,
      terminal_count: 0,
      next_due_at: '2026-06-21T01:00:00Z',
    },
    requests: [
      {
        schedule_id: 'sched-1',
        status: 'pending_approval',
        effective_status: 'blocked_approval',
        execution_readiness: 'blocked_approval',
        operator_action: 'approve_or_reject',
        keeper_next_tool: 'masc_schedule_get',
        keeper_next_action:
          'Inspect details, then wait for the dashboard operator approval or rejection action to resolve this schedule.',
        risk_class: 'workspace_write',
        approval_required: true,
        source: 'operator_request',
        recurrence: { kind: 'one_shot' },
        recurrence_kind: 'one_shot',
        payload_kind: 'masc.board_post',
        due_at_iso: '2026-06-21T01:00:00Z',
        approval_policy: 'separate_human_grant_required',
      },
    ],
  }
}

async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

describe('selectWakeSignals', () => {
  it('returns an empty list for missing automation', () => {
    expect(selectWakeSignals(null)).toEqual([])
    expect(selectWakeSignals(undefined)).toEqual([])
  })

  it('orders upcoming wakes soonest-first and reads id/at/kind/risk verbatim', () => {
    const signals = selectWakeSignals(
      automation([
        request({
          schedule_id: 's-late',
          next_due_at: 2000,
          next_due_at_iso: '2026-06-21T02:00:00Z',
          payload_kind: 'masc.board_post',
          risk_class: 'side_effecting',
          execution_readiness: 'scheduled',
        }),
        request({
          schedule_id: 's-soon',
          next_due_at: 1000,
          payload_kind: 'masc.keeper_nudge',
          risk_class: 'read_only',
          execution_readiness: 'ready',
        }),
      ]),
    )

    expect(signals.map(s => s.id)).toEqual(['s-soon', 's-late'])
    expect(signals[0]).toMatchObject({
      id: 's-soon',
      at: 1000,
      kind: 'masc.keeper_nudge',
      risk: 'read_only',
      readiness: 'ready',
    })
    expect(signals[1]?.risk).toBe('side_effecting')
  })

  it('falls back to due_at when next_due_at is absent', () => {
    const signals = selectWakeSignals(
      automation([request({ schedule_id: 's', due_at: 1500, execution_readiness: 'scheduled' })]),
    )
    expect(signals).toHaveLength(1)
    expect(signals[0]?.at).toBe(1500)
  })

  it('drops rows with no concrete wake time', () => {
    const signals = selectWakeSignals(
      automation([request({ schedule_id: 's-nodue', execution_readiness: 'scheduled' })]),
    )
    expect(signals).toEqual([])
  })

  it('excludes terminal/expired readiness and terminal statuses', () => {
    const signals = selectWakeSignals(
      automation([
        request({ schedule_id: 's-term', next_due_at: 100, execution_readiness: 'terminal' }),
        request({ schedule_id: 's-exp', next_due_at: 200, execution_readiness: 'expired' }),
        request({
          schedule_id: 's-cancelled',
          next_due_at: 300,
          status: 'cancelled',
          effective_status: 'cancelled',
        }),
        request({ schedule_id: 's-live', next_due_at: 400, execution_readiness: 'scheduled' }),
      ]),
    )
    expect(signals.map(s => s.id)).toEqual(['s-live'])
  })

  it('excludes running rows because they already woke', () => {
    const signals = selectWakeSignals(
      automation([
        request({
          schedule_id: 's-running',
          next_due_at: 100,
          status: 'running',
          effective_status: 'running',
          execution_readiness: 'running',
        }),
        request({ schedule_id: 's-live', next_due_at: 200, execution_readiness: 'scheduled' }),
      ]),
    )
    expect(signals.map(s => s.id)).toEqual(['s-live'])
  })

  it('keeps due-but-blocked rows because they are still pending wakes', () => {
    const signals = selectWakeSignals(
      automation([
        request({
          schedule_id: 's-blocked',
          next_due_at: 100,
          execution_readiness: 'blocked_approval',
          status: 'pending_approval',
        }),
      ]),
    )
    expect(signals.map(s => s.id)).toEqual(['s-blocked'])
    expect(signals[0]?.readiness).toBe('blocked_approval')
  })

  it('uses the recurrence label as kind when payload_kind is absent', () => {
    const signals = selectWakeSignals(
      automation([
        request({
          schedule_id: 's-recur',
          next_due_at: 100,
          recurrence: { kind: 'interval', interval_sec: 60 },
          execution_readiness: 'scheduled',
        }),
      ]),
    )
    expect(signals[0]?.kind).toBe('every 60s')
  })
})

describe('ScheduledAutomationPanel wake-signal feed', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the .sch-signals feed with the soonest signal first', () => {
    render(
      html`<${ScheduledAutomationPanel}
        automation=${automation([
          request({
            schedule_id: 's-soon',
            next_due_at: 1000,
            payload_kind: 'masc.keeper_nudge',
            execution_readiness: 'ready',
          }),
          request({
            schedule_id: 's-late',
            next_due_at: 2000,
            payload_kind: 'masc.board_post',
            execution_readiness: 'scheduled',
          }),
        ])}
      />`,
      container,
    )

    const feed = container.querySelector('[data-testid="sch-signals"]')
    expect(feed).not.toBeNull()
    const items = container.querySelectorAll('[data-testid="sch-signal"]')
    expect(items).toHaveLength(2)
    expect(items[0]?.textContent).toContain('s-soon')
    expect(items[0]?.textContent).toContain('masc.keeper_nudge')
    expect(items[0]?.textContent).toContain('risk')
  })

  it('renders an explicit empty state when there are no upcoming wakes', () => {
    render(
      html`<${ScheduledAutomationPanel}
        automation=${automation([
          request({ schedule_id: 's-term', next_due_at: 1000, execution_readiness: 'terminal' }),
        ])}
      />`,
      container,
    )

    expect(container.querySelector('[data-testid="sch-signals-empty"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="sch-signals"]')).toBeNull()
  })
})

describe('ScheduledAutomationPanel approval actions', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.resolveScheduleApproval.mockReset()
    mocks.showToast.mockReset()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('resolves pending schedule approval through the dashboard-only API', async () => {
    mocks.resolveScheduleApproval.mockResolvedValue({
      ok: true,
      schedule_id: 'sched-1',
      decision: 'approve',
    })
    const onResolved = vi.fn()

    render(
      html`<${ScheduledAutomationPanel}
        automation=${approvalAutomationFixture()}
        onResolved=${onResolved}
      />`,
      container,
    )

    const approve = container.querySelector(
      '[data-testid="schedule-approve-sched-1"]',
    ) as HTMLButtonElement | null
    const reject = container.querySelector(
      '[data-testid="schedule-reject-sched-1"]',
    ) as HTMLButtonElement | null
    expect(approve).not.toBeNull()
    expect(reject).not.toBeNull()

    approve?.click()
    await flush()

    expect(mocks.resolveScheduleApproval).toHaveBeenCalledWith('sched-1', 'approve', undefined)
    expect(onResolved).toHaveBeenCalledTimes(1)
    expect(mocks.showToast).toHaveBeenCalledWith('sched-1 approved', 'success')
  })
})
