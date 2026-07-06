import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationRequest,
} from '../../api'

const mocks = vi.hoisted(() => ({
  cancelSchedule: vi.fn(),
  resolveScheduleApproval: vi.fn(),
  showToast: vi.fn(),
}))

vi.mock('../../api', () => ({
  cancelSchedule: mocks.cancelSchedule,
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

function unknownAutomation(): DashboardScheduledAutomation {
  return {
    schema: 'masc.dashboard.scheduled_automation.v1',
    status: 'unknown',
    source: 'schedule_store',
    generated_at: '2026-06-21T00:00:00Z',
    schedule_store_known: false,
    schedule_store_read_error: 'schedule ledger is present but unparseable',
    request_count: null,
    request_limit: 50,
    truncated: null,
    counts: null,
    derived_counts: {
      due_effective: null,
      blocked_approval: null,
      due_execution_ready: null,
      expired_effective: null,
      unsupported_payload_kind: null,
      unknown_payload_kind: null,
    },
    payload_support: null,
    fsm: { state: 'unknown', active_count: null, terminal_count: null, next_due_at: null },
    requests: [],
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
        payload_dispatch_tool: 'masc_board_post',
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
    mocks.cancelSchedule.mockReset()
    mocks.resolveScheduleApproval.mockReset()
    mocks.showToast.mockReset()
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
    mocks.cancelSchedule.mockReset()
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
    expect(container.textContent).toContain('tool masc_board_post')

    approve?.click()
    await flush()

    expect(mocks.resolveScheduleApproval).toHaveBeenCalledWith('sched-1', 'approve', undefined)
    expect(onResolved).toHaveBeenCalledTimes(1)
    expect(mocks.showToast).toHaveBeenCalledWith('sched-1 approved', 'success')
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
        lifecycle_audit: {
          source: 'schedule_lifecycle_audit_jsonl',
          status: 'ok',
          limit: 10,
          event_count: 2,
          coverage: 'events_recorded',
          backfill_policy: 'not_synthesized_from_schedule_snapshot',
          events: [
            {
              schema: 'masc.schedule.lifecycle_audit.v1',
              schema_version: 1,
              event_id: 'sched-audit-created',
              recorded_at: 1782000000,
              action: 'request_created',
              schedule_id: 'sched-keeper-review',
              state_version: 1,
              previous_status: null,
              current_status: 'pending_approval',
              payload_digest: 'sha256:abc123',
              due_at: 1782003600,
            },
            {
              schema: 'masc.schedule.lifecycle_audit.v1',
              schema_version: 1,
              event_id: 'sched-audit-cancelled',
              recorded_at: 1782000100,
              action: 'request_cancelled',
              schedule_id: 'sched-keeper-review',
              state_version: 2,
              previous_status: 'scheduled',
              current_status: 'cancelled',
              payload_digest: 'sha256:abc123',
              due_at: 1782003600,
              actor: {
                id: 'operator',
                kind: 'human_operator',
                display_name: 'Operator',
              },
              detail: {
                reason: 'operator cleanup',
              },
            },
          ],
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
    expect(container.textContent).toContain('lifecycle audit')
    expect(container.textContent).toContain('schedule_lifecycle_audit_jsonl')
    expect(container.textContent).toContain('events_recorded')
    expect(container.textContent).toContain('not_synthesized_from_schedule_snapshot')
    expect(container.textContent).toContain('request created')
    expect(container.textContent).toContain('none -> pending approval')
    expect(container.textContent).toContain('request cancelled')
    expect(container.textContent).toContain('Operator')
    expect(container.textContent).toContain('reason: operator cleanup')
    expect(container.querySelector('[data-schedule-lifecycle-event="sched-audit-created"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-lifecycle-detail="sched-audit-cancelled:reason"]')).not.toBeNull()
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

  it('renders runner wake enqueue counts', () => {
    const automation = sampleAutomation()
    automation.runner_status = {
      status: 'degraded',
      tick_count: 1,
      last_counts: {
        due_changed: 1,
        emitted: 2,
        rescheduled: 0,
        dispatch_succeeded: 0,
        dispatch_failed: 0,
        dispatch_unsupported: 0,
        dispatch_start_rejected: 0,
        wake_enqueued: 1,
        wake_skipped_no_keeper: 3,
        wake_skipped_missing_schedule: 1,
        wake_skipped_non_keeper_actor: 1,
        wake_skipped_unregistered_keeper: 1,
        wake_failed: 1,
      },
    }

    render(html`<${ScheduledAutomationPanel} automation=${automation} />`, container)

    expect(container.textContent).toContain('wake queued')
    expect(container.textContent).toContain('wake skipped')
    expect(container.textContent).toContain('missing schedule')
    expect(container.textContent).toContain('non-keeper actor')
    expect(container.textContent).toContain('unregistered keeper')
    expect(container.textContent).toContain('wake failed')
  })

  it('renders schedule store read errors without false zero counts', () => {
    render(html`<${ScheduledAutomationPanel} automation=${unknownAutomation()} />`, container)

    expect(container.querySelector('[data-schedule-store-read-error]')).not.toBeNull()
    expect(container.textContent).toContain('schedule store read error')
    expect(container.textContent).toContain('unknown')
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

  it('renders durable schedule runner signal decode errors', async () => {
    const automation = sampleAutomation()
    automation.signal_error_count = 1
    automation.signal_errors = [
      { ordinal: 0, error: 'missing field: schedule_id' },
    ]

    render(html`<${ScheduledAutomationPanel} automation=${automation} />`, container)

    expect(container.textContent).toContain('signal decode error')
    expect(container.textContent).toContain('missing field: schedule_id')
    expect(container.querySelector('[data-schedule-signal-error="0"]')).not.toBeNull()
  })

  it('does not render prototype action buttons without a backend action callback', () => {
    render(html`<${ScheduledAutomationPanel} automation=${sampleAutomation()} />`, container)

    expect(container.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)
    expect(container.textContent).not.toContain('승인 — grant 발급')
    expect(container.textContent).not.toContain('거부')
    expect(container.textContent).not.toContain('취소')
  })

  it('renders v2 durable signal decode errors instead of the empty signal placeholder', () => {
    const automation = sampleAutomation()
    automation.signals = []
    automation.signal_error_count = 1
    automation.signal_errors = [
      { ordinal: 0, error: 'missing field: schedule_id' },
    ]

    render(
      html`<${ScheduledAutomationPanel}
        automation=${automation}
        variant="v2"
      />`,
      container,
    )

    expect(container.querySelector('[data-schedule-signal-error="0"]')).not.toBeNull()
    expect(container.textContent).toContain('missing field: schedule_id')
    expect(container.querySelector('[data-missing="durable runner signals"]')).toBeNull()
  })

  it('cancels a v2 schedule only after an explicit operator reason', async () => {
    mocks.cancelSchedule.mockResolvedValue({
      ok: true,
      schedule_id: 'sched-keeper-review',
      decision: 'cancel',
      reason: 'operator cancelled',
    })
    const onResolved = vi.fn()

    render(
      html`<${ScheduledAutomationPanel}
        automation=${sampleAutomation()}
        variant="v2"
        onResolved=${onResolved}
      />`,
      container,
    )

    const detail = container.querySelector(
      '[data-schedule-detail="sched-keeper-review"]',
    ) as HTMLButtonElement | null
    detail?.click()
    await flush()

    const reason = container.querySelector(
      '[data-testid="schedule-cancel-reason-sched-keeper-review"]',
    ) as HTMLInputElement | null
    const cancel = container.querySelector(
      '[data-testid="schedule-cancel-sched-keeper-review"]',
    ) as HTMLButtonElement | null
    expect(reason).not.toBeNull()
    expect(cancel).not.toBeNull()
    expect(container.querySelector('[data-schedule-lifecycle-event="sched-audit-created"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-lifecycle-detail="sched-audit-cancelled:reason"]')).not.toBeNull()
    expect(cancel?.disabled).toBe(true)

    reason!.value = 'operator cancelled'
    reason!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    expect(cancel?.disabled).toBe(false)
    cancel?.click()
    await flush()

    expect(mocks.cancelSchedule).toHaveBeenCalledWith('sched-keeper-review', 'operator cancelled')
    expect(onResolved).toHaveBeenCalledTimes(1)
    expect(mocks.showToast).toHaveBeenCalledWith('sched-keeper-review cancelled', 'success')
  })

  it('does not render v2 mutation buttons for terminal canceled schedules', async () => {
    const automation = sampleAutomation()
    automation.requests = [{
      ...automation.requests[0]!,
      schedule_id: 'sched-canceled-terminal',
      status: 'canceled',
      effective_status: 'canceled',
      execution_readiness: 'blocked_approval',
      operator_action: 'approve_or_reject',
    }]

    render(
      html`<${ScheduledAutomationPanel}
        automation=${automation}
        variant="v2"
        onResolved=${vi.fn()}
        selectedScheduleId="sched-canceled-terminal"
      />`,
      container,
    )
    await flush()

    expect(container.querySelector('[data-schedule-detail-panel="sched-canceled-terminal"]')).not.toBeNull()
    expect(container.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)
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
    expect(filterMatches('pending', request({ schedule_id: 'pb', effective_status: 'blocked_approval' }))).toBe(true)
    expect(filterMatches('pending', request({ schedule_id: 'pa', operator_action: 'approve_or_reject' }))).toBe(true)
    expect(filterMatches('due', request({ schedule_id: 'd', effective_status: 'due' }))).toBe(true)
  })

  it('does not infer pending approval from status/action substrings', () => {
    expect(filterMatches('pending', request({ schedule_id: 's', status: 'approval_not_required' }))).toBe(false)
    expect(filterMatches('pending', request({ schedule_id: 'a', operator_action: 'preapprove_later' }))).toBe(false)
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

  it('returns unknown for unreadable schedule store projections', () => {
    expect(scheduledPendingApprovalCount(unknownAutomation())).toBeNull()
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
      request({ schedule_id: 'done-1', status: 'succeeded', payload_summary: 'all good' }),
    ]

    render(
      html`<${ScheduleAside}
        requests=${requests}
        sum=${{ scheduled: 2, dueRunning: 1, pending: 1, total: 4 }}
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
    expect(aside?.textContent).toContain('all good') // terminal → 최근 실행
    // Read-only: the aside never renders mutation controls.
    expect(aside?.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)

    const pendingButton = aside?.querySelector('[data-schedule-aside-open="pending-1"]') as HTMLElement
    pendingButton.click()
    expect(onOpen).toHaveBeenCalledWith('pending-1')
  })
})
