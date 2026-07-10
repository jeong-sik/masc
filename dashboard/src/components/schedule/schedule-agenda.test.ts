import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { DashboardScheduledAutomationRequest } from '../../api'
import {
  Agenda,
  CadenceSummary,
  PollingStrip,
  buildAgenda,
  cadenceCounts,
  cadenceOfRequest,
  fireTimestampMs,
  isTerminalRequest,
  selectPollingSchedules,
} from './schedule-agenda'

// Anchor the deterministic "now" to 2026-07-07 12:00 *local* time. The agenda
// splits days on the local midnight boundary (what an operator sees), so
// fixtures are built with local Date components to stay timezone-independent.
const NOW_MS = new Date(2026, 6, 7, 12, 0, 0).getTime()
const HOUR_MS = 3_600_000
const DAY_MS = 86_400_000
/** Epoch *seconds* for a local wall-clock time (matches the backend due_at). */
function localEpochSeconds(year: number, monthIndex: number, day: number, hour: number, minute = 0): number {
  return new Date(year, monthIndex, day, hour, minute, 0).getTime() / 1000
}

function req(
  overrides: Partial<DashboardScheduledAutomationRequest> & { schedule_id: string },
): DashboardScheduledAutomationRequest {
  return {
    status: 'scheduled',
    risk_class: 'read_only',
    approval_required: false,
    source: 'automated_request',
    recurrence: { kind: 'one_shot' },
    ...overrides,
  }
}

describe('cadenceOfRequest', () => {
  it('maps the closed backend recurrence set onto the operator cadence axis', () => {
    expect(cadenceOfRequest(req({ schedule_id: 'a', recurrence: { kind: 'one_shot' } }))).toBe('oneshot')
    expect(cadenceOfRequest(req({ schedule_id: 'b', recurrence: { kind: 'interval', interval_sec: 3600 } }))).toBe('interval')
    expect(cadenceOfRequest(req({ schedule_id: 'c', recurrence: { kind: 'daily', hour: 2, minute: 0 } }))).toBe('scheduled')
    // cron is a fixed time-scheduled job → 정기, not silently dropped to oneshot.
    expect(cadenceOfRequest(req({ schedule_id: 'd', recurrence: { kind: 'cron', expression: '0 2 * * *' } }))).toBe('scheduled')
  })

  it('falls back to recurrence_kind when the structured recurrence is absent', () => {
    expect(cadenceOfRequest(req({ schedule_id: 'e', recurrence: undefined, recurrence_kind: 'daily' }))).toBe('scheduled')
  })

  it('returns null for an unrecognized recurrence kind rather than a permissive default', () => {
    expect(cadenceOfRequest(req({ schedule_id: 'f', recurrence: { kind: 'lunar' }, recurrence_kind: undefined }))).toBeNull()
    expect(cadenceOfRequest(req({ schedule_id: 'g', recurrence: undefined, recurrence_kind: undefined }))).toBeNull()
  })
})

describe('cadenceCounts', () => {
  it('counts each cadence bucket and surfaces unknown kinds separately', () => {
    const counts = cadenceCounts([
      req({ schedule_id: 'a', recurrence: { kind: 'one_shot' } }),
      req({ schedule_id: 'b', recurrence: { kind: 'one_shot' } }),
      req({ schedule_id: 'c', recurrence: { kind: 'interval', interval_sec: 60 } }),
      req({ schedule_id: 'd', recurrence: { kind: 'daily', hour: 9, minute: 0 } }),
      req({ schedule_id: 'e', recurrence: { kind: 'cron', expression: '* * * * *' } }),
      req({ schedule_id: 'f', recurrence: { kind: 'lunar' } }),
    ])
    expect(counts).toEqual({ scheduled: 2, interval: 1, oneshot: 2, unknown: 1 })
  })
})

describe('isTerminalRequest', () => {
  it('treats terminal statuses (case-insensitive, effective first) as terminal', () => {
    expect(isTerminalRequest(req({ schedule_id: 'a', status: 'succeeded' }))).toBe(true)
    expect(isTerminalRequest(req({ schedule_id: 'b', status: 'scheduled', effective_status: 'cancelled' }))).toBe(true)
    expect(isTerminalRequest(req({ schedule_id: 'c', status: 'Expired' }))).toBe(true)
    expect(isTerminalRequest(req({ schedule_id: 'd', status: 'scheduled' }))).toBe(false)
    expect(isTerminalRequest(req({ schedule_id: 'e', status: 'due' }))).toBe(false)
  })
})

describe('fireTimestampMs', () => {
  it('prefers the ISO next-due field, then due ISO, then numeric epoch seconds', () => {
    expect(fireTimestampMs(req({ schedule_id: 'a', next_due_at_iso: '2026-07-08T01:00:00Z' })))
      .toBe(Date.parse('2026-07-08T01:00:00Z'))
    expect(fireTimestampMs(req({ schedule_id: 'b', due_at_iso: '2026-07-08T02:00:00Z' })))
      .toBe(Date.parse('2026-07-08T02:00:00Z'))
    expect(fireTimestampMs(req({ schedule_id: 'c', next_due_at: 1_780_000_000, due_at: 1 })))
      .toBe(1_780_000_000 * 1000)
    expect(fireTimestampMs(req({ schedule_id: 'd', due_at: 1_780_000_500 })))
      .toBe(1_780_000_500 * 1000)
  })

  it('returns null when the projection has no concrete wake time', () => {
    expect(fireTimestampMs(req({ schedule_id: 'e' }))).toBeNull()
  })
})

describe('selectPollingSchedules', () => {
  it('keeps only non-terminal interval schedules, soonest next-tick first', () => {
    const rows = selectPollingSchedules([
      req({ schedule_id: 'later', recurrence: { kind: 'interval', interval_sec: 3600 }, due_at_iso: '2026-07-07T15:00:00Z' }),
      req({ schedule_id: 'soon', recurrence: { kind: 'interval', interval_sec: 3600 }, due_at_iso: '2026-07-07T14:10:00Z' }),
      req({ schedule_id: 'terminal', status: 'succeeded', recurrence: { kind: 'interval', interval_sec: 3600 }, due_at_iso: '2026-07-07T14:05:00Z' }),
      req({ schedule_id: 'daily', recurrence: { kind: 'daily', hour: 2, minute: 0 }, due_at_iso: '2026-07-08T02:00:00Z' }),
    ])
    expect(rows.map(row => row.request.schedule_id)).toEqual(['soon', 'later'])
  })
})

describe('buildAgenda', () => {
  it('places scheduled/oneshot rows on the correct day column and excludes interval', () => {
    const columns = buildAgenda(
      [
        req({ schedule_id: 'today', recurrence: { kind: 'one_shot' }, due_at: localEpochSeconds(2026, 6, 7, 18) }),
        req({ schedule_id: 'tomorrow', recurrence: { kind: 'daily', hour: 2, minute: 0 }, next_due_at: localEpochSeconds(2026, 6, 8, 2) }),
        req({ schedule_id: 'interval', recurrence: { kind: 'interval', interval_sec: 3600 }, due_at: localEpochSeconds(2026, 6, 7, 15) }),
      ],
      { nowMs: NOW_MS, days: 7 },
    )
    const idsByOffset = columns.map(column => column.events.map(event => event.request.schedule_id))
    // 'today' lands on offset 0, 'tomorrow' on offset 1; interval is excluded.
    expect(idsByOffset[0]).toContain('today')
    expect(idsByOffset[1]).toContain('tomorrow')
    expect(idsByOffset.flat()).not.toContain('interval')
  })

  it('drops terminal rows and rows without a concrete wake time', () => {
    const columns = buildAgenda(
      [
        req({ schedule_id: 'terminal', status: 'succeeded', due_at_iso: '2026-07-07T18:00:00Z' }),
        req({ schedule_id: 'no-time', recurrence: { kind: 'one_shot' } }),
      ],
      { nowMs: NOW_MS },
    )
    expect(columns.flatMap(column => column.events)).toHaveLength(0)
  })

  it('keeps an unrecognized-cadence row on the agenda rather than dropping it', () => {
    const columns = buildAgenda(
      [
        req({ schedule_id: 'unknown', recurrence: { kind: 'lunar' }, recurrence_kind: undefined, due_at: localEpochSeconds(2026, 6, 7, 18) }),
        req({ schedule_id: 'interval', recurrence: { kind: 'interval', interval_sec: 3600 }, due_at: localEpochSeconds(2026, 6, 7, 15) }),
      ],
      { nowMs: NOW_MS, days: 7 },
    )
    const events = columns.flatMap(column => column.events)
    // The unknown-cadence row is surfaced (cadence null); the interval row is not
    // (it belongs in the polling strip).
    expect(events.map(event => event.request.schedule_id)).toContain('unknown')
    expect(events.map(event => event.request.schedule_id)).not.toContain('interval')
    expect(events.find(event => event.request.schedule_id === 'unknown')?.cadence).toBeNull()
  })

  it('clamps an overdue wake onto today and drops rows beyond the window', () => {
    const columns = buildAgenda(
      [
        req({ schedule_id: 'overdue', status: 'due', due_at: (NOW_MS - 2 * DAY_MS) / 1000 }),
        req({ schedule_id: 'far', recurrence: { kind: 'daily', hour: 0, minute: 0 }, next_due_at: (NOW_MS + 30 * DAY_MS) / 1000 }),
      ],
      { nowMs: NOW_MS, days: 7 },
    )
    expect(columns[0]!.events.map(event => event.request.schedule_id)).toContain('overdue')
    expect(columns.flatMap(column => column.events).map(event => event.request.schedule_id)).not.toContain('far')
  })

  it('sorts events within a day by wake time', () => {
    const columns = buildAgenda(
      [
        req({ schedule_id: 'late', due_at: (NOW_MS + 5 * HOUR_MS) / 1000 }),
        req({ schedule_id: 'early', due_at: (NOW_MS + 1 * HOUR_MS) / 1000 }),
      ],
      { nowMs: NOW_MS },
    )
    expect(columns[0]!.events.map(event => event.request.schedule_id)).toEqual(['early', 'late'])
  })
})

describe('schedule calendar components', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the cadence summary with counts and an unknown chip when present', () => {
    const counts = { scheduled: 3, interval: 2, oneshot: 5, unknown: 1 }
    render(html`<${CadenceSummary} counts=${counts} active=${null} onFilter=${() => {}} />`, container)
    expect(container.querySelector('[data-testid="sch-cadsum-scheduled"]')?.textContent).toContain('3')
    expect(container.querySelector('[data-testid="sch-cadsum-interval"]')?.textContent).toContain('2')
    expect(container.querySelector('[data-testid="sch-cadsum-oneshot"]')?.textContent).toContain('5')
    expect(container.querySelector('[data-testid="sch-cadsum-unknown"]')?.textContent).toContain('1')
  })

  it('omits the unknown chip when every recurrence kind is recognized', () => {
    const counts = { scheduled: 1, interval: 0, oneshot: 0, unknown: 0 }
    render(html`<${CadenceSummary} counts=${counts} active=${'scheduled'} onFilter=${() => {}} />`, container)
    expect(container.querySelector('[data-testid="sch-cadsum-unknown"]')).toBeNull()
  })

  it('renders active interval schedules in the polling strip and shows empty state otherwise', () => {
    render(
      html`<${PollingStrip}
        requests=${[req({ schedule_id: 'poll-1', recurrence: { kind: 'interval', interval_sec: 21600 }, due_at_iso: '2026-07-07T18:00:00Z' })]}
        onOpen=${() => {}}
      />`,
      container,
    )
    expect(container.querySelector('[data-schedule-id="poll-1"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="sch-polling-empty"]')).toBeNull()

    render(
      html`<${PollingStrip} requests=${[req({ schedule_id: 'one', recurrence: { kind: 'one_shot' } })]} onOpen=${() => {}} />`,
      container,
    )
    expect(container.querySelector('[data-testid="sch-polling-empty"]')).not.toBeNull()
  })

  it('renders agenda events and the empty state when nothing is upcoming', () => {
    render(
      html`<${Agenda}
        requests=${[req({ schedule_id: 'ev-1', due_at_iso: '2026-07-07T18:00:00Z' })]}
        nowMs=${NOW_MS}
        onOpen=${() => {}}
      />`,
      container,
    )
    expect(container.querySelector('[data-schedule-id="ev-1"]')).not.toBeNull()

    render(html`<${Agenda} requests=${[]} nowMs=${NOW_MS} onOpen=${() => {}} />`, container)
    expect(container.querySelector('[data-testid="sch-agenda-empty"]')).not.toBeNull()
  })

  it('surfaces a queue-drain miss on the agenda row (queue not_found + reaction not_found)', () => {
    render(
      html`<${Agenda}
        requests=${[
          req({
            schedule_id: 'miss-1',
            due_at_iso: '2026-07-07T18:00:00Z',
            keeper_queue_evidence: { projection_status: 'not_found' },
            keeper_reaction_evidence: { projection_status: 'not_found' },
          }),
        ]}
        nowMs=${NOW_MS}
        onOpen=${() => {}}
      />`,
      container,
    )
    const chip = container.querySelector('[data-schedule-id="miss-1"] [data-testid="sch-drain-chip"]')
    expect(chip?.textContent).toContain('누락')
  })

  it('does not chip a healthy completion (queue not_found + keeper reaction recorded)', () => {
    render(
      html`<${Agenda}
        requests=${[
          req({
            schedule_id: 'done-1',
            due_at_iso: '2026-07-07T18:00:00Z',
            keeper_queue_evidence: { projection_status: 'not_found' },
            keeper_reaction_evidence: { projection_status: 'matched_consumed_ack' },
          }),
        ]}
        nowMs=${NOW_MS}
        onOpen=${() => {}}
      />`,
      container,
    )
    expect(container.querySelector('[data-schedule-id="done-1"] [data-testid="sch-drain-chip"]')).toBeNull()
  })
})
