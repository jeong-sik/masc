import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationRequest,
  DashboardScheduledAutomationSignal,
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

import { ScheduleAside, ScheduledAutomationPanel, scheduledPendingApprovalCount, selectWakeSignals, filterMatches } from './scheduled-automation-panel'

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

function signal(
  overrides: Partial<DashboardScheduledAutomationSignal> & { signal_id: string; schedule_id: string },
): DashboardScheduledAutomationSignal {
  const { signal_id, schedule_id, ...rest } = overrides
  return {
    signal_id,
    kind: 'schedule.due_candidate',
    schedule_id,
    emitted_at_iso: '2026-06-21T00:00:00Z',
    due_at_iso: '2026-06-21T00:10:00Z',
    risk_class: 'read_only',
    ...rest,
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

  it('excludes payload-blocked rows from upcoming wake signals', () => {
    const signals = selectWakeSignals(
      automation([
        request({
          schedule_id: 's-supported',
          next_due_at: 100,
          execution_readiness: 'scheduled',
          payload_kind: 'keeper.smoke',
          payload_support: 'supported',
        }),
        request({
          schedule_id: 's-unsupported',
          next_due_at: 200,
          execution_readiness: 'scheduled',
          payload_kind: 'orphan_auto_release',
          payload_support: 'unsupported',
        }),
        request({
          schedule_id: 's-unknown',
          next_due_at: 300,
          execution_readiness: 'scheduled',
          payload_kind: 'keeper.future',
          payload_support: 'unknown',
        }),
      ]),
    )

    expect(signals.map(s => s.id)).toEqual(['s-supported'])
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

    // one_shot schedule: no standing button, plain approve carries no scope
    expect(
      container.querySelector('[data-testid="schedule-approve-standing-sched-1"]'),
    ).toBeNull()

    approve?.click()
    await flush()

    expect(mocks.resolveScheduleApproval).toHaveBeenCalledWith(
      'sched-1',
      'approve',
      undefined,
      undefined,
    )
    expect(onResolved).toHaveBeenCalledTimes(1)
    expect(mocks.showToast).toHaveBeenCalledWith('sched-1 approved', 'success')
  })

  it('offers a standing approval for recurring schedules and sends the scope', async () => {
    mocks.resolveScheduleApproval.mockResolvedValue({
      ok: true,
      schedule_id: 'sched-1',
      decision: 'approve',
    })
    const onResolved = vi.fn()
    const automation = approvalAutomationFixture()
    const first = automation.requests[0]
    if (first == null) throw new Error('fixture has no requests')
    first.recurrence = { kind: 'interval', interval_sec: 60 }
    first.recurrence_kind = 'interval'

    render(
      html`<${ScheduledAutomationPanel}
        automation=${automation}
        onResolved=${onResolved}
      />`,
      container,
    )

    const once = container.querySelector(
      '[data-testid="schedule-approve-sched-1"]',
    ) as HTMLButtonElement | null
    const standing = container.querySelector(
      '[data-testid="schedule-approve-standing-sched-1"]',
    ) as HTMLButtonElement | null
    expect(once?.textContent).toContain('Approve once')
    expect(standing).not.toBeNull()

    standing?.click()
    await flush()

    expect(mocks.resolveScheduleApproval).toHaveBeenCalledWith(
      'sched-1',
      'approve',
      undefined,
      'standing',
    )
    expect(onResolved).toHaveBeenCalledTimes(1)
  })
})

function sampleAutomation(): DashboardScheduledAutomation {
  return {
    schema: 'masc.dashboard.scheduled_automation.v1',
    source: 'schedule_store',
    generated_at: '2026-06-21T00:00:00Z',
    request_count: 2,
    request_limit: 20,
    truncated: false,
    counts: { pending_approval: 1, due: 1 },
    derived_counts: {
      due_effective: 2,
      blocked_approval: 1,
      due_execution_ready: 1,
      expired_effective: 0,
    },
    payload_support: {
      supported_kinds: ['keeper.review', 'keeper.smoke'],
      unsupported_request_count: 0,
      unsupported_kinds: [],
      unknown_request_count: 0,
    },
    fsm: {
      state: 'blocked_approval',
      active_count: 2,
      terminal_count: 0,
      next_due_at: '2026-06-21T01:00:00Z',
    },
    requests: [
      {
        schedule_id: 'sched-keeper-review',
        status: 'pending_approval',
        effective_status: 'blocked_approval',
        execution_readiness: 'blocked_approval',
        operator_action: 'approve_or_reject',
        keeper_next_tool: 'masc_schedule_get',
        keeper_next_action: 'Inspect schedule details and wait for explicit human approval.',
        risk_class: 'workspace_write',
        approval_required: true,
        approval_policy: 'human_required',
        requires_separate_human_grant: true,
        source: 'operator_request',
        requested_by: { id: 'operator', kind: 'human_operator', display_name: 'Operator' },
        scheduled_by: { id: 'scheduler-agent', kind: 'automated_actor', display_name: 'Scheduler Agent' },
        recurrence: { kind: 'cron', expression: '0 9 * * 1-5', timezone: 'Asia/Seoul' },
        recurrence_kind: 'cron',
        payload_kind: 'keeper.review',
        payload_target: 'workspace/yousleepwhen/masc',
        payload_summary: 'Run a keeper review sweep.',
        payload_digest: 'sha256:abc123',
        requested_at_iso: '2026-06-21T00:00:00Z',
        due_at_iso: '2026-06-21T01:00:00Z',
        expires_at_iso: '2026-06-21T02:00:00Z',
        last_execution: {
          execution_id: 'exec-1',
          schedule_id: 'sched-keeper-review',
          started_at_iso: '2026-06-21T00:30:00Z',
          finished_at_iso: '2026-06-21T00:31:00Z',
          status: 'succeeded',
          detail: {
            kind: 'test.done',
            summary: 'Completed keeper review sweep.',
            stats: { scanned: 3 },
            artifacts: ['receipt', 'log'],
          },
        },
      },
      {
        schedule_id: 'sched-run-smoke',
        status: 'due',
        effective_status: 'due',
        execution_readiness: 'execution_ready',
        operator_action: 'run_when_due',
        keeper_next_tool: 'masc_schedule_run_due',
        keeper_next_action: 'Run the due smoke check.',
        risk_class: 'read_only',
        approval_required: false,
        source: 'operator_request',
        requested_by: { id: 'operator', kind: 'human_operator', display_name: null },
        scheduled_by: { id: 'executor', kind: 'automated_actor', display_name: null },
        recurrence: { kind: 'one_shot' },
        recurrence_kind: 'one_shot',
        payload_kind: 'keeper.smoke',
        payload_summary: 'Run a read-only smoke check.',
        due_at_iso: '2026-06-21T00:45:00Z',
      },
    ],
  }
}

function payloadSupportAutomation(): DashboardScheduledAutomation {
  const auto = sampleAutomation()
  auto.request_count = 3
  auto.counts = { failed: 1, scheduled: 1, expired: 1 }
  auto.derived_counts = {
    due_effective: 0,
    blocked_approval: 0,
    due_execution_ready: 0,
    expired_effective: 1,
    unsupported_payload_kind: 2,
    unknown_payload_kind: 1,
  }
  auto.payload_support = {
    supported_kinds: ['keeper.smoke'],
    unsupported_request_count: 2,
    unsupported_kinds: [
      { kind: 'backlog_depletion_check', count: 1 },
      { kind: 'orphan_auto_release', count: 1 },
    ],
    unknown_request_count: 1,
  }
  auto.requests = [
    {
      ...auto.requests[0]!,
      schedule_id: 'sched-unsupported-failed',
      status: 'failed',
      effective_status: 'failed',
      execution_readiness: 'terminal',
      operator_action: null,
      approval_required: false,
      payload_kind: 'backlog_depletion_check',
      payload_support: 'unsupported',
      payload_summary: 'Backlog depletion check cannot be executed by the current payload catalog.',
      last_execution: {
        execution_id: 'exec-unsupported',
        schedule_id: 'sched-unsupported-failed',
        status: 'failed',
        error: 'unsupported payload kind',
      },
    },
    {
      ...auto.requests[1]!,
      schedule_id: 'sched-unsupported-expired',
      status: 'expired',
      effective_status: 'expired',
      execution_readiness: 'expired',
      payload_kind: 'orphan_auto_release',
      payload_support: 'unsupported',
      payload_summary: 'Orphan auto release payload is not registered.',
    },
    {
      ...auto.requests[1]!,
      schedule_id: 'sched-unknown-scheduled',
      status: 'scheduled',
      effective_status: 'scheduled',
      execution_readiness: 'scheduled',
      payload_kind: 'keeper.future',
      payload_support: 'unknown',
      payload_summary: 'Payload catalog has not classified this kind yet.',
    },
  ]
  return auto
}

describe('ScheduledAutomationPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders scheduled requests as read-only cards with a wake signal feed', () => {
    render(html`<${ScheduledAutomationPanel} automation=${sampleAutomation()} />`, container)

    expect(container.querySelector('[data-schedule-id="sched-keeper-review"]')).not.toBeNull()
    expect(container.textContent).toContain('wake signal feed')
    expect(container.textContent).toContain('키퍼 다음 단계')
    expect(container.textContent).toContain('선택한 예약')
    expect(container.textContent).toContain('approve or reject')
    expect(container.textContent).toContain('human required')
    expect(container.textContent).toContain('별도 human grant 필요')
    expect(container.textContent).toContain('masc_schedule_get')
    expect(container.textContent).toContain('keeper.review')
    expect(container.textContent).toContain('sha256:abc123')
    expect(container.textContent).toContain('Operator (operator, human operator)')
    expect(container.textContent).toContain('Scheduler Agent (scheduler-agent, automated actor)')
    expect(container.textContent).toContain('test.done')
    expect(container.textContent).toContain('Completed keeper review sweep.')
    expect(container.textContent).toContain('{1 field}')
    expect(container.textContent).toContain('[2 items]')
    expect(container.querySelector('[data-execution-detail-row="kind"]')).not.toBeNull()
    expect(container.textContent).not.toContain('"kind":"test.done"')
    expect(container.querySelector('[data-schedule-filter="all"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-filter="pending"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-detail-panel="sched-keeper-review"]')).not.toBeNull()
    expect(container.textContent).toContain('실행 준비')
    expect(container.textContent).toContain('운영자 조치')
    expect(container.textContent).toContain('위험도')
    expect(container.textContent).toContain('승인 정책')
    expect(container.textContent).toContain('페이로드')
  })

  it('renders keeper wake dispatch receipts as queue proof in diagnostics and v2', async () => {
    const auto = automation([
      request({
        schedule_id: 'sched-keeper-wake',
        status: 'succeeded',
        effective_status: 'succeeded',
        execution_readiness: 'terminal',
        operator_action: null,
        approval_required: false,
        risk_class: 'workspace_write',
        payload_kind: 'masc.keeper_wake',
        payload_support: 'supported',
        payload_target: 'keeper:schedule-keeper',
        payload_summary: 'Scheduled lane wake',
        last_execution: {
          execution_id: 'exec-keeper-wake',
          schedule_id: 'sched-keeper-wake',
          status: 'succeeded',
          detail: {
            kind: 'masc.keeper_wake.enqueued',
            queue: 'keeper_event_queue',
            stimulus: 'schedule_due',
            stimulus_id: 'stimulus:keeper-wake-digest',
            keeper_name: 'schedule-keeper',
            schedule_id: 'sched-keeper-wake',
            urgency: 'immediate',
            post_id: 'schedule-due:sched-keeper-wake',
          },
        },
        dispatch_receipt: {
          projection_status: 'recognized',
          kind: 'masc.keeper_wake.enqueued',
          queue: 'keeper_event_queue',
          stimulus: 'schedule_due',
          stimulus_id: 'stimulus:keeper-wake-digest',
          keeper_name: 'schedule-keeper',
          schedule_id: 'sched-keeper-wake',
          urgency: 'immediate',
          post_id: 'schedule-due:sched-keeper-wake',
        },
        keeper_queue_evidence: {
          projection_status: 'matched_pending',
          source: 'durable_event_queue_snapshot',
          queue: 'keeper_event_queue',
          stimulus: 'schedule_due',
          keeper_name: 'schedule-keeper',
          schedule_id: 'sched-keeper-wake',
          post_id: 'schedule-due:sched-keeper-wake',
          pending_count: 1,
          inflight_count: 0,
          matched_bucket: 'pending',
          matched_post_id: 'schedule-due:sched-keeper-wake',
          matched_schedule_id: 'sched-keeper-wake',
          matched_payload_kind: 'schedule_due',
          matched_arrived_at: 201,
          matched_arrived_at_iso: '2026-06-21T00:03:21Z',
          matched_age_seconds: 0,
          read_errors: [],
        },
        keeper_reaction_evidence: {
          projection_status: 'matched_stimulus',
          source: 'keeper_reaction_ledger',
          keeper_name: 'schedule-keeper',
          schedule_id: 'sched-keeper-wake',
          post_id: 'schedule-due:sched-keeper-wake',
          stimulus: 'schedule_due',
          stimulus_id: 'stimulus:keeper-wake-digest',
          stimulus_kind: 'schedule_due',
          reaction_kind: 'turn_started',
          stimulus_seen: true,
          turn_started_seen: false,
          matched_record_count: 1,
          stimulus_recorded_at: 201,
          stimulus_recorded_at_iso: '2026-06-21T00:03:21Z',
          latest_recorded_at: 201,
          latest_recorded_at_iso: '2026-06-21T00:03:21Z',
        },
      }),
    ])

    render(html`<${ScheduledAutomationPanel} automation=${auto} />`, container)

    const receipt = container.querySelector('[data-schedule-dispatch-receipt="recognized"]')
    expect(receipt).not.toBeNull()
    expect(receipt?.getAttribute('data-schedule-dispatch-receipt-kind')).toBe('masc.keeper_wake.enqueued')
    expect(container.querySelector('[data-dispatch-receipt-row="queue"]')?.textContent).toContain('keeper_event_queue')
    expect(container.querySelector('[data-dispatch-receipt-row="stimulus"]')?.textContent).toContain('schedule_due')
    expect(container.querySelector('[data-dispatch-receipt-row="stimulus_id"]')?.textContent).toContain('stimulus:keeper-wake-digest')
    expect(container.querySelector('[data-dispatch-receipt-row="keeper"]')?.textContent).toContain('schedule-keeper')
    expect(container.querySelector('[data-dispatch-receipt-row="post_id"]')?.textContent).toContain('schedule-due:sched-keeper-wake')
    const queueEvidence = container.querySelector('[data-schedule-keeper-queue-evidence="matched_pending"]')
    expect(queueEvidence).not.toBeNull()
    expect(queueEvidence?.getAttribute('data-schedule-keeper-queue-evidence-source')).toBe('durable_event_queue_snapshot')
    expect(container.querySelector('[data-keeper-queue-evidence-row="matched_bucket"]')?.textContent).toContain('pending')
    expect(container.querySelector('[data-keeper-queue-evidence-row="pending_count"]')?.textContent).toContain('1')
    expect(container.querySelector('[data-keeper-queue-evidence-row="matched_payload_kind"]')?.textContent).toContain('schedule_due')
    const reactionEvidence = container.querySelector('[data-schedule-keeper-reaction-evidence="matched_stimulus"]')
    expect(reactionEvidence).not.toBeNull()
    expect(reactionEvidence?.getAttribute('data-schedule-keeper-reaction-evidence-source')).toBe('keeper_reaction_ledger')
    expect(container.querySelector('[data-keeper-reaction-evidence-row="stimulus_id"]')?.textContent).toContain('stimulus:keeper-wake-digest')
    expect(container.querySelector('[data-keeper-reaction-evidence-row="turn_started_seen"]')?.textContent).toContain('false')

    render(null, container)
    render(html`<${ScheduledAutomationPanel} automation=${auto} variant="v2" />`, container)

    const doneFilter = container.querySelector('[data-schedule-filter="done"]') as HTMLButtonElement
    doneFilter.click()
    await Promise.resolve()

    const cardWakeSummary = container.querySelector('[data-schedule-wake-evidence-summary="sched-keeper-wake"]')
    expect(cardWakeSummary).not.toBeNull()
    expect(cardWakeSummary?.getAttribute('data-schedule-wake-evidence-receipt')).toBe('recognized')
    expect(cardWakeSummary?.getAttribute('data-schedule-wake-evidence-queue')).toBe('matched_pending')
    expect(cardWakeSummary?.getAttribute('data-schedule-wake-evidence-reaction')).toBe('matched_stimulus')
    expect(cardWakeSummary?.textContent).toContain('wake evidence')
    expect(cardWakeSummary?.textContent).toContain('receipt recognized')
    expect(cardWakeSummary?.textContent).toContain('queue matched pending')
    expect(cardWakeSummary?.textContent).toContain('reaction matched stimulus')
    expect(cardWakeSummary?.textContent).toContain('post schedule-due:sched-keeper-wake')

    const openDetail = container.querySelector('[data-schedule-detail="sched-keeper-wake"]') as HTMLButtonElement
    openDetail.click()
    await Promise.resolve()

    const v2Receipt = container.querySelector('[data-schedule-dispatch-receipt="recognized"]')
    expect(v2Receipt).not.toBeNull()
    expect(v2Receipt?.textContent).toContain('keeper_event_queue')
    expect(v2Receipt?.textContent).toContain('schedule_due')
    expect(v2Receipt?.textContent).toContain('schedule-due:sched-keeper-wake')
    const v2QueueEvidence = container.querySelector('[data-schedule-keeper-queue-evidence="matched_pending"]')
    expect(v2QueueEvidence).not.toBeNull()
    expect(v2QueueEvidence?.textContent).toContain('durable_event_queue_snapshot')
    expect(v2QueueEvidence?.textContent).toContain('matched pending')
    expect(v2QueueEvidence?.textContent).toContain('schedule_due')
    const v2ReactionEvidence = container.querySelector('[data-schedule-keeper-reaction-evidence="matched_stimulus"]')
    expect(v2ReactionEvidence).not.toBeNull()
    expect(v2ReactionEvidence?.textContent).toContain('keeper_reaction_ledger')
    expect(v2ReactionEvidence?.textContent).toContain('matched stimulus')

    const wakeRequest = auto.requests[0]!
    const inflightAuto = automation([
      {
        ...wakeRequest,
        schedule_id: 'sched-keeper-wake',
        keeper_queue_evidence: {
          ...wakeRequest.keeper_queue_evidence!,
          projection_status: 'matched_inflight',
          pending_count: 0,
          inflight_count: 1,
          matched_bucket: 'inflight',
        },
        keeper_reaction_evidence: {
          ...wakeRequest.keeper_reaction_evidence!,
          projection_status: 'matched_turn_started',
          turn_started_seen: true,
          matched_record_count: 2,
          turn_started_recorded_at: 202,
          turn_started_recorded_at_iso: '2026-06-21T00:03:22Z',
          latest_recorded_at: 202,
          latest_recorded_at_iso: '2026-06-21T00:03:22Z',
        },
      },
    ])

    render(null, container)
    render(html`<${ScheduledAutomationPanel} automation=${inflightAuto} variant="v2" />`, container)

    const inflightDoneFilter = container.querySelector('[data-schedule-filter="done"]') as HTMLButtonElement
    inflightDoneFilter.click()
    await Promise.resolve()

    const openInflightDetail = container.querySelector('[data-schedule-detail="sched-keeper-wake"]') as HTMLButtonElement
    openInflightDetail.click()
    await Promise.resolve()

    const inflightQueueEvidence = container.querySelector('[data-schedule-keeper-queue-evidence="matched_inflight"]')
    expect(inflightQueueEvidence).not.toBeNull()
    expect(inflightQueueEvidence?.textContent).toContain('matched inflight')
    expect(inflightQueueEvidence?.textContent).toContain('inflight_count')
    expect(inflightQueueEvidence?.textContent).toContain('1')
    expect(inflightQueueEvidence?.textContent).toContain('inflight')
    const turnReactionEvidence = container.querySelector('[data-schedule-keeper-reaction-evidence="matched_turn_started"]')
    expect(turnReactionEvidence).not.toBeNull()
    expect(turnReactionEvidence?.textContent).toContain('matched turn started')
    expect(turnReactionEvidence?.textContent).toContain('turn_started')
    expect(turnReactionEvidence?.textContent).toContain('true')

    const ackedAuto = automation([
      {
        ...wakeRequest,
        schedule_id: 'sched-keeper-wake',
        keeper_queue_evidence: {
          ...wakeRequest.keeper_queue_evidence!,
          projection_status: 'not_found',
          pending_count: 0,
          inflight_count: 0,
          matched_bucket: undefined,
          matched_post_id: undefined,
          matched_schedule_id: undefined,
          matched_payload_kind: undefined,
          matched_arrived_at: undefined,
          matched_arrived_at_iso: undefined,
          matched_age_seconds: undefined,
        },
        keeper_reaction_evidence: {
          ...wakeRequest.keeper_reaction_evidence!,
          projection_status: 'matched_consumed_ack',
          turn_started_seen: true,
          event_queue_ack_seen: true,
          matched_record_count: 3,
          turn_started_recorded_at: 202,
          turn_started_recorded_at_iso: '2026-06-21T00:03:22Z',
          event_queue_ack_recorded_at: 203,
          event_queue_ack_recorded_at_iso: '2026-06-21T00:03:23Z',
          latest_recorded_at: 203,
          latest_recorded_at_iso: '2026-06-21T00:03:23Z',
        },
      },
    ])

    render(null, container)
    render(html`<${ScheduledAutomationPanel} automation=${ackedAuto} variant="v2" />`, container)

    const ackDoneFilter = container.querySelector('[data-schedule-filter="done"]') as HTMLButtonElement
    ackDoneFilter.click()
    await Promise.resolve()

    const openAckDetail = container.querySelector('[data-schedule-detail="sched-keeper-wake"]') as HTMLButtonElement
    openAckDetail.click()
    await Promise.resolve()

    const ackQueueEvidence = container.querySelector('[data-schedule-keeper-queue-evidence="not_found"]')
    expect(ackQueueEvidence).not.toBeNull()
    expect(ackQueueEvidence?.textContent).toContain('not found')
    expect(ackQueueEvidence?.textContent).toContain('pending_count')
    expect(ackQueueEvidence?.textContent).toContain('0')
    const ackReactionEvidence = container.querySelector('[data-schedule-keeper-reaction-evidence="matched_consumed_ack"]')
    expect(ackReactionEvidence).not.toBeNull()
    expect(ackReactionEvidence?.textContent).toContain('matched consumed ack')
    expect(ackReactionEvidence?.textContent).toContain('event_queue_ack_seen')
    expect(ackReactionEvidence?.textContent).toContain('true')
    expect(ackReactionEvidence?.textContent).toContain('event_queue_ack_recorded_at')
  })

  it('shows missing wake evidence explicitly for keeper wake cards', async () => {
    const auto = automation([
      request({
        schedule_id: 'sched-keeper-wake-missing',
        status: 'scheduled',
        effective_status: 'scheduled',
        execution_readiness: 'scheduled',
        approval_required: false,
        payload_kind: 'masc.keeper_wake',
        payload_support: 'supported',
        payload_target: 'keeper:schedule-keeper',
        payload_summary: 'Scheduled wake without projection evidence yet',
      }),
    ])

    render(html`<${ScheduledAutomationPanel} automation=${auto} variant="v2" />`, container)

    const scheduledFilter = container.querySelector('[data-schedule-filter="scheduled"]') as HTMLButtonElement
    scheduledFilter.click()
    await Promise.resolve()

    const summary = container.querySelector('[data-schedule-wake-evidence-summary="sched-keeper-wake-missing"]')
    expect(summary).not.toBeNull()
    expect(summary?.getAttribute('data-schedule-wake-evidence-receipt')).toBe('missing')
    expect(summary?.getAttribute('data-schedule-wake-evidence-queue')).toBe('missing')
    expect(summary?.getAttribute('data-schedule-wake-evidence-reaction')).toBe('missing')
    expect(summary?.textContent).toContain('receipt missing')
    expect(summary?.textContent).toContain('queue missing')
    expect(summary?.textContent).toContain('reaction missing')
  })

  it('surfaces cadence counts and filters exact recurrence kinds in v2', async () => {
    const auto = automation([
      request({
        schedule_id: 'sched-poll-live',
        status: 'scheduled',
        effective_status: 'scheduled',
        execution_readiness: 'scheduled',
        recurrence: { kind: 'interval', interval_sec: 60 },
        recurrence_kind: 'interval',
        payload_kind: 'keeper.poll',
        payload_summary: 'Poll live queue',
        due_at_iso: '2026-06-21T00:01:00Z',
      }),
      request({
        schedule_id: 'sched-poll-terminal',
        status: 'succeeded',
        effective_status: 'succeeded',
        execution_readiness: 'terminal',
        recurrence: { kind: 'interval', interval_sec: 300 },
        recurrence_kind: 'interval',
        payload_kind: 'keeper.poll',
        payload_summary: 'Terminal poll history',
      }),
      request({
        schedule_id: 'sched-daily',
        status: 'scheduled',
        effective_status: 'scheduled',
        execution_readiness: 'scheduled',
        recurrence: { kind: 'daily', hour: 9, minute: 0, timezone: 'Asia/Seoul' },
        recurrence_kind: 'daily',
        payload_kind: 'keeper.daily',
        payload_summary: 'Daily keeper check',
      }),
      request({
        schedule_id: 'sched-one-shot',
        status: 'scheduled',
        effective_status: 'scheduled',
        execution_readiness: 'scheduled',
        recurrence: { kind: 'one_shot' },
        recurrence_kind: 'one_shot',
        payload_kind: 'keeper.once',
        payload_summary: 'One shot keeper check',
      }),
      request({
        schedule_id: 'sched-cron',
        status: 'scheduled',
        effective_status: 'scheduled',
        execution_readiness: 'scheduled',
        recurrence: { kind: 'cron', expression: '0 9 * * 1-5', timezone: 'Asia/Seoul' },
        recurrence_kind: 'cron',
        payload_kind: 'keeper.cron',
        payload_summary: 'Cron keeper check',
      }),
      request({
        schedule_id: 'sched-unknown-cadence',
        status: 'scheduled',
        effective_status: 'scheduled',
        execution_readiness: 'scheduled',
        payload_kind: 'keeper.unknown',
        payload_summary: 'Missing recurrence projection',
      }),
    ])

    render(html`<${ScheduledAutomationPanel} automation=${auto} variant="v2" />`, container)

    const summary = container.querySelector('[data-schedule-cadence-summary]')
    expect(summary).not.toBeNull()
    expect(container.querySelector('[data-schedule-cadence-filter="interval"]')?.getAttribute('data-schedule-cadence-count')).toBe('2')
    expect(container.querySelector('[data-schedule-cadence-filter="daily"]')?.getAttribute('data-schedule-cadence-count')).toBe('1')
    expect(container.querySelector('[data-schedule-cadence-filter="oneshot"]')?.getAttribute('data-schedule-cadence-count')).toBe('1')
    expect(container.querySelector('[data-schedule-cadence-filter="cron"]')?.getAttribute('data-schedule-cadence-count')).toBe('1')
    expect(container.querySelector('[data-schedule-cadence-filter="unknown"]')?.getAttribute('data-schedule-cadence-count')).toBe('1')
    expect(container.querySelector('[data-schedule-polling-strip]')?.getAttribute('data-schedule-polling-count')).toBe('1')
    expect(container.querySelector('[data-schedule-polling-card="sched-poll-live"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-polling-card="sched-poll-terminal"]')).toBeNull()

    const scheduledFilter = container.querySelector('[data-schedule-filter="scheduled"]') as HTMLButtonElement
    scheduledFilter.click()
    await flush()

    const intervalFilter = container.querySelector('[data-schedule-cadence-filter="interval"]') as HTMLButtonElement
    intervalFilter.click()
    await flush()

    expect(container.querySelector('[data-schedule-id="sched-poll-live"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-daily"]')).toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-one-shot"]')).toBeNull()
    expect(container.querySelector('[data-schedule-cadence-card="sched-poll-live"]')?.getAttribute('data-schedule-cadence')).toBe('interval')

    const dailyFilter = container.querySelector('[data-schedule-cadence-filter="daily"]') as HTMLButtonElement
    dailyFilter.click()
    await flush()

    expect(container.querySelector('[data-schedule-polling-strip]')).toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-daily"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-poll-live"]')).toBeNull()

    const unknownFilter = container.querySelector('[data-schedule-cadence-filter="unknown"]') as HTMLButtonElement
    unknownFilter.click()
    await flush()

    expect(container.querySelector('[data-schedule-id="sched-unknown-cadence"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-cadence-card="sched-unknown-cadence"]')?.getAttribute('data-schedule-cadence')).toBe('unknown')
  })

  it('filters schedule cards without filtering the wake signal feed', async () => {
    render(html`<${ScheduledAutomationPanel} automation=${sampleAutomation()} />`, container)

    const pendingFilter = container.querySelector('[data-schedule-filter="pending"]') as HTMLButtonElement
    pendingFilter.click()
    await Promise.resolve()

    expect(container.querySelector('[data-schedule-id="sched-keeper-review"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-run-smoke"]')).toBeNull()
    expect(container.textContent).toContain('sched-run-smoke')
  })

  it('keeps payload-blocked rows out of every request-derived wake feed', () => {
    const auto = automation([
      request({
        schedule_id: 'sched-supported',
        next_due_at: 100,
        next_due_at_iso: '2026-06-21T00:10:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'keeper.smoke',
        payload_support: 'supported',
      }),
      request({
        schedule_id: 'sched-unsupported',
        next_due_at: 200,
        next_due_at_iso: '2026-06-21T00:20:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'orphan_auto_release',
        payload_support: 'unsupported',
      }),
      request({
        schedule_id: 'sched-unknown',
        next_due_at: 300,
        next_due_at_iso: '2026-06-21T00:30:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'keeper.future',
        payload_support: 'unknown',
      }),
    ])

    render(html`<${ScheduledAutomationPanel} automation=${auto} />`, container)

    expect(container.querySelector('[data-schedule-id="sched-unsupported"]')).not.toBeNull()
    const wakeSignalFeed = container.querySelector('[data-testid="sch-signals"]')
    expect(wakeSignalFeed?.textContent).toContain('sched-supported')
    expect(wakeSignalFeed?.textContent).not.toContain('sched-unsupported')
    expect(wakeSignalFeed?.textContent).not.toContain('sched-unknown')
    expect(container.querySelector('[data-schedule-signal-schedule="sched-supported"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-signal-schedule="sched-unsupported"]')).toBeNull()
    expect(container.querySelector('[data-schedule-signal-schedule="sched-unknown"]')).toBeNull()
  })

  it('keeps payload-blocked rows out of every durable wake signal feed', () => {
    const auto = automation([
      request({
        schedule_id: 'sched-supported',
        next_due_at: 100,
        next_due_at_iso: '2026-06-21T00:10:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'keeper.smoke',
        payload_support: 'supported',
      }),
      request({
        schedule_id: 'sched-unsupported',
        next_due_at: 200,
        next_due_at_iso: '2026-06-21T00:20:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'orphan_auto_release',
        payload_support: 'unsupported',
      }),
      request({
        schedule_id: 'sched-unknown',
        next_due_at: 300,
        next_due_at_iso: '2026-06-21T00:30:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'keeper.future',
        payload_support: 'unknown',
      }),
    ])
    auto.signal_source = 'schedule_runner_signals'
    auto.signal_count = 3
    auto.signals = [
      signal({
        signal_id: 'sig-supported',
        schedule_id: 'sched-supported',
        payload_kind: 'keeper.smoke',
      }),
      signal({
        signal_id: 'sig-unsupported',
        schedule_id: 'sched-unsupported',
        payload_kind: 'orphan_auto_release',
      }),
      signal({
        signal_id: 'sig-unknown',
        schedule_id: 'sched-unknown',
        payload_kind: 'keeper.future',
      }),
    ]

    for (const variant of [undefined, 'v2'] as const) {
      render(null, container)
      render(html`<${ScheduledAutomationPanel} automation=${auto} variant=${variant} />`, container)

      if (variant === 'v2') {
        expect(container.querySelector('[data-schedule-payload-support-row="sched-unsupported"]')).not.toBeNull()
        expect(container.querySelector('[data-schedule-payload-support-row="sched-unknown"]')).not.toBeNull()
      } else {
        expect(container.querySelector('[data-schedule-id="sched-unsupported"]')).not.toBeNull()
        expect(container.querySelector('[data-schedule-id="sched-unknown"]')).not.toBeNull()
      }
      expect(container.querySelector('[data-schedule-signal-id="sig-supported"]')).not.toBeNull()
      expect(container.querySelector('[data-schedule-signal-id="sig-unsupported"]')).toBeNull()
      expect(container.querySelector('[data-schedule-signal-id="sig-unknown"]')).toBeNull()
      expect(container.querySelector('[data-schedule-signal-schedule="sched-supported"]')).not.toBeNull()
      expect(container.querySelector('[data-schedule-signal-schedule="sched-unsupported"]')).toBeNull()
      expect(container.querySelector('[data-schedule-signal-schedule="sched-unknown"]')).toBeNull()
    }
  })

  it('keeps unsupported durable wake signals hidden when the request row is absent', () => {
    const auto = automation([
      request({
        schedule_id: 'sched-supported',
        next_due_at: 100,
        next_due_at_iso: '2026-06-21T00:10:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'keeper.smoke',
        payload_support: 'supported',
      }),
    ])
    auto.payload_support = {
      supported_kinds: ['keeper.smoke'],
      unsupported_request_count: 1,
      unsupported_kinds: [{ kind: 'orphan_auto_release', count: 1 }],
      unknown_request_count: 1,
    }
    auto.signal_source = 'schedule_runner_signals'
    auto.signal_count = 3
    auto.signals = [
      signal({
        signal_id: 'sig-supported',
        schedule_id: 'sched-supported',
        payload_kind: 'keeper.smoke',
      }),
      signal({
        signal_id: 'sig-unsupported-missing-row',
        schedule_id: 'sched-unsupported-missing-row',
        payload_kind: 'orphan_auto_release',
      }),
      signal({
        signal_id: 'sig-unknown-missing-row',
        schedule_id: 'sched-unknown-missing-row',
      }),
    ]

    for (const variant of [undefined, 'v2'] as const) {
      render(null, container)
      render(html`<${ScheduledAutomationPanel} automation=${auto} variant=${variant} />`, container)

      const contract = container.querySelector('[data-schedule-durable-signal-contract="payload_support"]')
      expect(contract?.getAttribute('data-schedule-durable-signal-raw')).toBe('3')
      expect(contract?.getAttribute('data-schedule-durable-signal-visible')).toBe('1')
      expect(contract?.getAttribute('data-schedule-durable-signal-hidden')).toBe('2')
      expect(container.querySelector('[data-schedule-signal-id="sig-supported"]')).not.toBeNull()
      expect(container.querySelector('[data-schedule-signal-id="sig-unsupported-missing-row"]')).toBeNull()
      expect(container.querySelector('[data-schedule-signal-id="sig-unknown-missing-row"]')).toBeNull()
      expect(container.querySelector('[data-schedule-signal-schedule="sched-supported"]')).not.toBeNull()
      expect(container.querySelector('[data-schedule-signal-schedule="sched-unsupported-missing-row"]')).toBeNull()
      expect(container.querySelector('[data-schedule-signal-schedule="sched-unknown-missing-row"]')).toBeNull()
    }
  })

  it('marks request-derived fallback when all durable runner signals are hidden by payload support', () => {
    const auto = automation([
      request({
        schedule_id: 'sched-supported-request',
        next_due_at: 100,
        next_due_at_iso: '2026-06-21T00:10:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'keeper.smoke',
        payload_support: 'supported',
      }),
    ])
    auto.payload_support = {
      supported_kinds: ['keeper.smoke'],
      unsupported_request_count: 1,
      unsupported_kinds: [{ kind: 'orphan_auto_release', count: 1 }],
      unknown_request_count: 1,
    }
    auto.signal_source = 'schedule_runner_signals'
    auto.signal_count = 2
    auto.signals = [
      signal({
        signal_id: 'sig-unsupported-only',
        schedule_id: 'sched-unsupported-only',
        payload_kind: 'orphan_auto_release',
      }),
      signal({
        signal_id: 'sig-unknown-only',
        schedule_id: 'sched-unknown-only',
      }),
    ]

    render(html`<${ScheduledAutomationPanel} automation=${auto} />`, container)

    const contract = container.querySelector('[data-schedule-durable-signal-contract="payload_support"]')
    expect(contract?.getAttribute('data-schedule-durable-signal-raw')).toBe('2')
    expect(contract?.getAttribute('data-schedule-durable-signal-visible')).toBe('0')
    expect(contract?.getAttribute('data-schedule-durable-signal-hidden')).toBe('2')
    expect(contract?.textContent).toContain('payload support로 2 durable runner signal 숨김')
    expect(contract?.textContent).toContain('request rows에서 파생했습니다')
    expect(container.querySelector('[data-schedule-signal-id="sig-unsupported-only"]')).toBeNull()
    expect(container.querySelector('[data-schedule-signal-id="sig-unknown-only"]')).toBeNull()
    expect(container.querySelector('[data-schedule-signal-schedule="sched-supported-request"]')).not.toBeNull()

    render(null, container)
    render(html`<${ScheduledAutomationPanel} automation=${auto} variant="v2" />`, container)

    const v2Contract = container.querySelector('[data-schedule-durable-signal-contract="payload_support"]')
    expect(v2Contract?.getAttribute('data-schedule-durable-signal-raw')).toBe('2')
    expect(v2Contract?.getAttribute('data-schedule-durable-signal-visible')).toBe('0')
    expect(v2Contract?.getAttribute('data-schedule-durable-signal-hidden')).toBe('2')
    expect(v2Contract?.textContent).toContain('payload support로 2 durable wake signal 숨김')
    expect(container.querySelector('[data-schedule-signal-id="sig-unsupported-only"]')).toBeNull()
    expect(container.querySelector('[data-schedule-signal-id="sig-unknown-only"]')).toBeNull()
  })

  it('renders explicit live supported non-terminal evidence absence', () => {
    const auto = payloadSupportAutomation()
    auto.live_supported_non_terminal_evidence = {
      schema: 'masc.dashboard.scheduled_automation.live_supported_non_terminal_evidence.v1',
      source: 'schedule_store',
      projection_status: 'no_supported_payload_rows',
      criteria: 'payload_support=supported && execution_readiness not in {terminal,expired}',
      reason: 'current live schedule_store has no rows with a supported payload kind',
      request_count: 3,
      supported_request_count: 0,
      supported_non_terminal_count: 0,
      supported_live_count: 0,
      supported_terminal_or_expired_count: 0,
      unsupported_request_count: 2,
      unknown_request_count: 1,
      terminal_or_expired_count: 2,
      matched_schedule_ids: [],
      matched_schedule_id_limit: 8,
    }

    for (const variant of [undefined, 'v2'] as const) {
      render(null, container)
      render(html`<${ScheduledAutomationPanel} automation=${auto} variant=${variant} />`, container)

      const evidence = container.querySelector('[data-schedule-live-supported-evidence="no_supported_payload_rows"]')
      expect(evidence).not.toBeNull()
      expect(evidence?.getAttribute('data-schedule-live-supported-count')).toBe('0')
      expect(evidence?.getAttribute('data-schedule-live-supported-source')).toBe('schedule_store')
      expect(evidence?.textContent).toContain('no supported payload rows')
      expect(evidence?.textContent).toContain('payload_support=supported')
      expect(evidence?.textContent).toContain('unsupported/unknown')
      expect(evidence?.textContent).toContain('3')
    }
  })

  it('renders an explicit contract gap when live supported evidence is absent', () => {
    const auto = { ...payloadSupportAutomation() }
    delete auto.live_supported_non_terminal_evidence

    for (const variant of [undefined, 'v2'] as const) {
      render(null, container)
      render(html`<${ScheduledAutomationPanel} automation=${auto} variant=${variant} />`, container)

      const evidence = container.querySelector('[data-schedule-live-supported-evidence="projection_contract_missing"]')
      expect(evidence).not.toBeNull()
      expect(evidence?.getAttribute('data-schedule-live-supported-count')).toBe('0')
      expect(evidence?.getAttribute('data-schedule-live-supported-source')).toBe('schedule_store')
      expect(evidence?.getAttribute('data-schedule-live-supported-schema')).toBe('missing')
      expect(evidence?.textContent).toContain('projection contract missing')
      expect(evidence?.textContent).toContain('live_supported_non_terminal_evidence')
      expect(evidence?.textContent).toContain('matched_supported_non_terminal')
      expect(evidence?.textContent).toContain('unproven')
      expect(evidence?.textContent).toContain('3')
    }
  })

  it('renders matched live supported non-terminal evidence and opens matched rows', async () => {
    const auto = automation([
      request({
        schedule_id: 'sched-supported-live',
        next_due_at: 100,
        next_due_at_iso: '2026-06-21T00:10:00Z',
        execution_readiness: 'scheduled',
        payload_kind: 'masc.keeper_wake',
        payload_support: 'supported',
      }),
    ])
    auto.live_supported_non_terminal_evidence = {
      schema: 'masc.dashboard.scheduled_automation.live_supported_non_terminal_evidence.v1',
      source: 'schedule_store',
      projection_status: 'matched_supported_non_terminal',
      criteria: 'payload_support=supported && execution_readiness not in {terminal,expired}',
      reason: 'live schedule_store contains supported rows whose readiness is not terminal or expired',
      request_count: 1,
      supported_request_count: 1,
      supported_non_terminal_count: 1,
      supported_live_count: 1,
      supported_terminal_or_expired_count: 0,
      unsupported_request_count: 0,
      unknown_request_count: 0,
      terminal_or_expired_count: 0,
      matched_schedule_ids: ['sched-supported-live'],
      matched_schedule_id_limit: 8,
    }

    render(html`<${ScheduledAutomationPanel} automation=${auto} variant="v2" />`, container)

    const evidence = container.querySelector('[data-schedule-live-supported-evidence="matched_supported_non_terminal"]')
    expect(evidence).not.toBeNull()
    expect(evidence?.getAttribute('data-schedule-live-supported-count')).toBe('1')
    expect(evidence?.textContent).toContain('matched supported non-terminal')
    const integrity = container.querySelector('[data-schedule-live-supported-row-integrity="matched_rows_verified"]')
    expect(integrity).not.toBeNull()
    expect(integrity?.getAttribute('data-schedule-live-supported-row-integrity-count')).toBe('1')
    const open = container.querySelector('[data-schedule-live-supported-open="sched-supported-live"]') as HTMLButtonElement
    expect(open).not.toBeNull()
    open.click()
    await Promise.resolve()
    expect(container.querySelector('[data-schedule-detail-panel="sched-supported-live"]')).not.toBeNull()
  })

  it('renders a mismatch when matched live evidence contradicts response rows', () => {
    const auto = automation([
      request({
        schedule_id: 'sched-unsupported-row',
        execution_readiness: 'scheduled',
        payload_kind: 'orphan_auto_release',
        payload_support: 'unsupported',
      }),
      request({
        schedule_id: 'sched-terminal-row',
        execution_readiness: 'terminal',
        payload_kind: 'masc.keeper_wake',
        payload_support: 'supported',
      }),
    ])
    auto.live_supported_non_terminal_evidence = {
      schema: 'masc.dashboard.scheduled_automation.live_supported_non_terminal_evidence.v1',
      source: 'schedule_store',
      projection_status: 'matched_supported_non_terminal',
      criteria: 'payload_support=supported && execution_readiness not in {terminal,expired}',
      reason: 'live schedule_store contains supported rows whose readiness is not terminal or expired',
      request_count: 2,
      supported_request_count: 1,
      supported_non_terminal_count: 1,
      supported_live_count: 1,
      supported_terminal_or_expired_count: 1,
      unsupported_request_count: 1,
      unknown_request_count: 0,
      terminal_or_expired_count: 1,
      matched_schedule_ids: ['sched-unsupported-row', 'sched-terminal-row', 'sched-missing-row'],
      matched_schedule_id_limit: 8,
    }

    render(html`<${ScheduledAutomationPanel} automation=${auto} variant="v2" />`, container)

    const mismatch = container.querySelector('[data-schedule-live-supported-row-integrity="matched_row_mismatch"]')
    expect(mismatch).not.toBeNull()
    expect(mismatch?.getAttribute('data-schedule-live-supported-row-integrity-count')).toBe('3')
    expect(mismatch?.textContent).toContain('sched-unsupported-row:payload_support_not_supported')
    expect(mismatch?.textContent).toContain('sched-terminal-row:execution_readiness_terminal_or_expired')
    expect(mismatch?.textContent).toContain('sched-missing-row:missing_request_row')
    expect(container.querySelector('[data-schedule-live-supported-row-integrity="matched_rows_verified"]')).toBeNull()
  })

  it('uses explicit ready and terminal status matching', async () => {
    const automation = sampleAutomation()
    automation.requests = [
      ...automation.requests,
      {
        ...automation.requests[1]!,
        schedule_id: 'sched-not-ready',
        status: 'scheduled',
        effective_status: 'scheduled',
        execution_readiness: 'not_ready',
      },
      {
        ...automation.requests[1]!,
        schedule_id: 'sched-canceled',
        status: 'canceled',
        effective_status: 'canceled',
        execution_readiness: 'blocked_approval',
      },
    ]
    render(html`<${ScheduledAutomationPanel} automation=${automation} />`, container)

    const readyFilter = container.querySelector('[data-schedule-filter="ready"]') as HTMLButtonElement
    readyFilter.click()
    await Promise.resolve()

    expect(container.querySelector('[data-schedule-id="sched-run-smoke"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-not-ready"]')).toBeNull()

    const terminalFilter = container.querySelector('[data-schedule-filter="terminal"]') as HTMLButtonElement
    terminalFilter.click()
    await Promise.resolve()

    expect(container.querySelector('[data-schedule-id="sched-canceled"]')).not.toBeNull()
  })

  it('prefers durable schedule runner signals when present', async () => {
    const automation = sampleAutomation()
    automation.signal_source = 'schedule_runner_signals'
    automation.signal_count = 1
    automation.signal_limit = 20
    automation.signals = [
      {
        signal_id: 'sig-due-1',
        kind: 'schedule.due_candidate',
        event_type: 'schedule.due_candidate',
        schedule_id: 'sched-run-smoke',
        emitted_at_iso: '2026-06-21T00:46:00Z',
        due_at_iso: '2026-06-21T00:45:00Z',
        risk_class: 'read_only',
        payload_digest: 'sha256:def456',
        payload_kind: 'keeper.smoke',
      },
    ]

    render(html`<${ScheduledAutomationPanel} automation=${automation} />`, container)

    expect(container.textContent).toContain('durable wake signal feed')
    expect(container.textContent).toContain('출처 schedule_runner_signals')
    expect(container.textContent).toContain('schedule.due candidate')
    expect(container.textContent).toContain('keeper.smoke')
    expect(container.textContent).toContain('sha256:def456')
    expect(container.querySelector('[data-schedule-signal-id="sig-due-1"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-signal-kind="schedule.due_candidate"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-signal-risk="sig-due-1"]')?.textContent).toContain('read only')
    expect(container.querySelector('[data-schedule-signal-at="sig-due-1"]')?.textContent).toMatch(/^\d{2}:\d{2}$/)

    const signalScheduleButton = container.querySelector('[data-schedule-signal-schedule="sched-run-smoke"]') as HTMLButtonElement
    signalScheduleButton.click()
    await Promise.resolve()

    expect(container.querySelector('[data-schedule-detail-panel="sched-run-smoke"]')).not.toBeNull()
  })

  it('does not render prototype action buttons without a backend action callback', () => {
    render(html`<${ScheduledAutomationPanel} automation=${sampleAutomation()} />`, container)

    expect(container.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)
    expect(container.textContent).not.toContain('승인 — grant 발급')
    expect(container.textContent).not.toContain('거부')
    expect(container.textContent).not.toContain('취소')
  })

  it('surfaces v2 payload support failures from the scheduler projection', async () => {
    render(
      html`<${ScheduledAutomationPanel} automation=${payloadSupportAutomation()} variant="v2" />`,
      container,
    )

    const alert = container.querySelector('[data-testid="schedule-payload-support-alert"]')
    expect(alert).not.toBeNull()
    expect(alert?.textContent).toContain('2 unsupported')
    expect(alert?.textContent).toContain('1 unknown')
    expect(alert?.textContent).toContain('backlog_depletion_check')
    expect(alert?.textContent).toContain('orphan_auto_release')
    expect(container.querySelector('[data-schedule-payload-support-row="sched-unsupported-failed"]')).not.toBeNull()

    const alertRow = container.querySelector(
      '[data-schedule-payload-support-row="sched-unsupported-failed"]',
    ) as HTMLButtonElement
    alertRow.click()
    await flush()

    const detail = container.querySelector('[data-schedule-detail-panel="sched-unsupported-failed"]')
    expect(detail).not.toBeNull()
    expect(detail?.textContent).toContain('payload unsupported')
    expect(detail?.textContent).toContain('backlog_depletion_check')
    expect(detail?.textContent).toContain('"support": "unsupported"')
    expect(container.querySelector('[data-payload-support="unsupported"]')).not.toBeNull()

    const doneFilter = container.querySelector('[data-schedule-filter="done"]') as HTMLButtonElement
    doneFilter.click()
    await flush()

    expect(container.querySelector('[data-schedule-id="sched-unsupported-failed"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-unsupported-expired"]')).not.toBeNull()
  })
})

describe('filterMatches', () => {
  it('matches each ScheduleFilterKey against the right request shape', () => {
    expect(filterMatches('all', request({ schedule_id: 'a' }))).toBe(true)
    expect(filterMatches('ready', request({ schedule_id: 'r', execution_readiness: 'ready' }))).toBe(true)
    expect(filterMatches('ready', request({ schedule_id: 'r2', execution_readiness: 'scheduled' }))).toBe(false)
    expect(filterMatches('scheduled', request({ schedule_id: 's', status: 'scheduled' }))).toBe(true)
    expect(filterMatches('terminal', request({ schedule_id: 't', status: 'succeeded' }))).toBe(true)
    expect(filterMatches('terminal', request({ schedule_id: 't2', status: 'scheduled' }))).toBe(false)
    expect(filterMatches('pending', request({ schedule_id: 'p', status: 'pending_approval' }))).toBe(true)
    expect(filterMatches('due', request({ schedule_id: 'd', effective_status: 'due' }))).toBe(true)
  })

  it('throws on an out-of-union filter key instead of silently showing all', () => {
    // Simulates a future ScheduleFilterKey added to the type/UI but missing a
    // switch case: the assertNever default must surface the gap (Error) rather
    // than fall through to `return true`. `as never` stands in for that bypass.
    expect(() => filterMatches('archived' as never, request({ schedule_id: 'x' }))).toThrow()
  })
})

describe('scheduledPendingApprovalCount', () => {
  it('returns 0 for a missing projection', () => {
    expect(scheduledPendingApprovalCount(null)).toBe(0)
    expect(scheduledPendingApprovalCount(undefined)).toBe(0)
  })

  it('counts pending-family requests when sparse counts are absent', () => {
    const auto = automation([
      request({ schedule_id: 'a', status: 'pending_approval' }),
      request({ schedule_id: 'b', status: 'awaiting_approval' }),
      request({ schedule_id: 'c', status: 'scheduled' }),
    ])
    expect(scheduledPendingApprovalCount(auto)).toBe(2)
  })

  it('takes the larger of sparse counts vs materialized requests', () => {
    const auto = automation([request({ schedule_id: 'a', status: 'pending_approval' })])
    auto.counts = { pending: 3 }
    expect(scheduledPendingApprovalCount(auto)).toBe(3)
  })

  it('prefers effective_status over raw status', () => {
    const auto = automation([
      request({ schedule_id: 'a', status: 'scheduled', effective_status: 'pending_approval' }),
    ])
    expect(scheduledPendingApprovalCount(auto)).toBe(1)
  })
})

describe('ScheduleAside', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders read-only pulse + triage buckets and opens details on click', () => {
    const onOpen = vi.fn()
    const requests: DashboardScheduledAutomationRequest[] = [
      request({ schedule_id: 'pending-1', status: 'pending_approval', payload_summary: 'approve me', risk_class: 'workspace_write' }),
      request({ schedule_id: 'due-1', status: 'due', payload_summary: 'due soon' }),
      request({
        schedule_id: 'failed-1',
        status: 'failed',
        payload_summary: 'it broke',
        last_execution: { execution_id: 'exec-1', schedule_id: 'failed-1', status: 'execution_failed', error: 'runtime refused' },
      }),
      request({
        schedule_id: 'unsupported-1',
        status: 'expired',
        payload_support: 'unsupported',
        payload_kind: 'orphan_auto_release',
        payload_summary: 'unsupported payload row',
      }),
      request({ schedule_id: 'done-1', status: 'succeeded', payload_summary: 'all good' }),
    ]

    render(
      html`<${ScheduleAside}
        requests=${requests}
        sum=${{ scheduled: 2, dueRunning: 1, pending: 1, total: 5 }}
        onOpen=${onOpen}
      />`,
      container,
    )

    const aside = container.querySelector('[data-testid="schedule-aside"]')
    expect(aside).not.toBeNull()
    expect(aside?.querySelector('.wka-pulse')?.textContent).toContain('예약됨')
    // Triage buckets derived from request statuses.
    expect(aside?.textContent).toContain('approve me') // pending → 해야 할 일
    expect(aside?.textContent).toContain('due soon') // due → 해야 할 일
    expect(aside?.textContent).toContain('it broke') // failed → 지금 상황
    expect(aside?.textContent).toContain('runtime refused') // failed execution error
    expect(aside?.textContent).toContain('unsupported payload row') // unsupported payload → 지금 상황
    expect(aside?.textContent).toContain('orphan_auto_release')
    expect(aside?.textContent).toContain('all good') // terminal → 최근 실행
    // Read-only: the aside never renders mutation controls.
    expect(aside?.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)

    const pendingButton = aside?.querySelector('[data-schedule-aside-open="pending-1"]') as HTMLElement
    pendingButton.click()
    expect(onOpen).toHaveBeenCalledWith('pending-1')
  })

  it('does not classify payload-blocked rows as actionable aside work', () => {
    const onOpen = vi.fn()
    const requests: DashboardScheduledAutomationRequest[] = [
      request({ schedule_id: 'due-ok', status: 'due', payload_summary: 'supported due work' }),
      request({
        schedule_id: 'due-unsupported',
        status: 'due',
        payload_support: 'unsupported',
        payload_kind: 'orphan_auto_release',
        payload_summary: 'unsupported due work',
      }),
      request({
        schedule_id: 'pending-unknown',
        status: 'pending_approval',
        payload_support: 'unknown',
        payload_kind: 'keeper.future',
        payload_summary: 'unknown pending work',
      }),
    ]

    render(
      html`<${ScheduleAside}
        requests=${requests}
        sum=${{ scheduled: 0, dueRunning: 1, pending: 1, total: 3 }}
        onOpen=${onOpen}
      />`,
      container,
    )

    const todoText = Array.from(container.querySelectorAll('.wka-todo'))
      .map(element => element.textContent ?? '')
      .join('\n')
    expect(todoText).toContain('supported due work')
    expect(todoText).not.toContain('unsupported due work')
    expect(todoText).not.toContain('unknown pending work')
    expect(container.textContent).toContain('unsupported · orphan_auto_release')
    expect(container.textContent).toContain('unknown · keeper.future')
  })
})
