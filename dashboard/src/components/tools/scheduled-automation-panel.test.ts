import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationRequest,
} from '../../api/dashboard'
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
    request_count: requests.length,
    request_limit: 50,
    truncated: false,
    counts: {},
    fsm: { state: 'idle', active_count: requests.length, terminal_count: 0 },
    requests,
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
    // risk is the backend value, never a fabricated default
    expect(signals[1]?.risk).toBe('side_effecting')
  })

  it('falls back to due_at when next_due_at is absent', () => {
    const signals = selectWakeSignals(
      automation([request({ schedule_id: 's', due_at: 1500, execution_readiness: 'scheduled' })]),
    )
    expect(signals).toHaveLength(1)
    expect(signals[0]?.at).toBe(1500)
  })

  it('drops rows with no concrete wake time (not a signal)', () => {
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
        request({ schedule_id: 's-cancelled', next_due_at: 300, status: 'cancelled', effective_status: 'cancelled' }),
        request({ schedule_id: 's-live', next_due_at: 400, execution_readiness: 'scheduled' }),
      ]),
    )
    expect(signals.map(s => s.id)).toEqual(['s-live'])
  })

  it('keeps due-but-blocked rows — they are still pending wakes', () => {
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
          request({ schedule_id: 's-soon', next_due_at: 1000, payload_kind: 'masc.keeper_nudge', execution_readiness: 'ready' }),
          request({ schedule_id: 's-late', next_due_at: 2000, payload_kind: 'masc.board_post', execution_readiness: 'scheduled' }),
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
