import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { DashboardScheduledAutomationRequest } from '../../api'
import {
  Agenda,
  CadenceSummary,
  PollingStrip,
  ScheduleCalendar,
  buildAgenda,
  cadenceCounts,
  cadenceOfRequest,
  calendarCoverage,
  dayIsComplete,
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
    expect(isTerminalRequest(req({ schedule_id: 'b', status: 'cancelled' }))).toBe(true)
    expect(isTerminalRequest(req({ schedule_id: 'c', status: 'expired' }))).toBe(true)
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

describe('the subject on a row', () => {
  it('names the Keeper the wake reaches, and keeps the scheduler on the tooltip', () => {
    // Live 2026-09-02: a cron created through an MCP client read
    // "codex-mcp-client" on the row while edgar.a.poe, the Keeper it wakes
    // every 45 minutes, was nowhere on it.
    const container = document.createElement('div')
    document.body.appendChild(container)
    try {
      render(
        html`<${Agenda}
          requests=${[
            req({
              schedule_id: 'sched-cron',
              status: 'scheduled',
              recurrence: { kind: 'cron', expression: '45 8-23 * * *' },
              due_at: localEpochSeconds(2026, 6, 7, 15),
              payload_keeper_name: 'edgar.a.poe',
              payload_target: 'keeper:edgar.a.poe',
              scheduled_by: { id: 'codex-mcp-client', kind: 'automated_actor' },
            }),
          ]}
          coverage=${{ kind: 'complete' }}
          nowMs=${NOW_MS}
          onOpen=${() => {}}
        />`,
        container,
      )
      const subject = container.querySelector('.sch-ev-by')
      expect(subject?.textContent).toBe('edgar.a.poe')
      expect(subject?.getAttribute('title')).toContain('codex-mcp-client')
    } finally {
      render(null, container)
      container.remove()
    }
  })

  it('falls back to the scheduler when the payload names no Keeper', () => {
    const container = document.createElement('div')
    document.body.appendChild(container)
    try {
      render(
        html`<${PollingStrip}
          requests=${[
            req({
              schedule_id: 'sched-poll',
              status: 'scheduled',
              recurrence: { kind: 'interval', interval_sec: 300 },
              next_due_at_iso: '2026-07-07T04:00:00Z',
              payload_keeper_name: 'lane-smith',
              payload_target: 'keeper:lane-smith',
              scheduled_by: { id: 'claude-fable-schedule-probe', kind: 'automated_actor' },
            }),
            req({
              schedule_id: 'sched-poll-2',
              status: 'scheduled',
              recurrence: { kind: 'interval', interval_sec: 300 },
              next_due_at_iso: '2026-07-07T04:00:00Z',
              scheduled_by: { id: 'dashboard-admin', kind: 'human_operator' },
            }),
          ]}
          coverage=${{ kind: 'complete' }}
          onOpen=${() => {}}
        />`,
        container,
      )
      const subjects = Array.from(container.querySelectorAll('.sch-poll-by'))
      expect(subjects.map(node => node.textContent)).toEqual(['lane-smith', 'dashboard-admin'])
      expect(subjects[1]?.getAttribute('title')).toContain('예약자')
      expect(subjects[1]?.getAttribute('title')).not.toContain('깨우는 keeper')
    } finally {
      render(null, container)
      container.remove()
    }
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

describe('buildAgenda on a local day that is not 24 hours long', () => {
  // #52963: America/New_York leaves daylight time on 2026-11-01, which makes
  // that local day 25 hours long.
  const runnerTimeZone = process.env.TZ

  beforeEach(() => {
    process.env.TZ = 'America/New_York'
  })

  afterEach(() => {
    if (runnerTimeZone === undefined) delete process.env.TZ
    else process.env.TZ = runnerTimeZone
  })

  it('dates every column by the local calendar', () => {
    const nextMidnight = new Date(2026, 10, 2).getTime()
    // The case below means nothing unless this runtime applied the time zone.
    expect(nextMidnight - new Date(2026, 10, 1).getTime()).toBe(25 * HOUR_MS)

    const columns = buildAgenda(
      [req({ schedule_id: 'next-morning', due_at: localEpochSeconds(2026, 10, 2, 9) })],
      { nowMs: new Date(2026, 10, 1, 12, 0, 0).getTime(), days: 3 },
    )

    expect(columns.map(column => {
      const date = new Date(column.dateMs)
      return [date.getMonth() + 1, date.getDate(), date.getHours()]
    })).toEqual([[11, 1, 0], [11, 2, 0], [11, 3, 0]])
    expect(columns[1]!.dateMs).toBe(nextMidnight)
    expect(columns[1]!.events.map(event => event.request.schedule_id)).toEqual(['next-morning'])
  })
})

describe('calendarCoverage', () => {
  const at = (hour: number, minute = 0) => localEpochSeconds(2026, 6, 7, hour, minute)

  it('is complete when the page holds every active schedule', () => {
    const page = [
      req({ schedule_id: 'a', due_at: at(13) }),
      req({ schedule_id: 'b', status: 'running', due_at: at(11) }),
      // Terminal rows fill the rest of a page only after every active one.
      req({ schedule_id: 'done', status: 'succeeded', due_at: at(9) }),
    ]
    expect(calendarCoverage(page, 2)).toEqual({ kind: 'complete' })
    expect(calendarCoverage(page.slice(0, 2), 2)).toEqual({ kind: 'complete' })
    expect(calendarCoverage([], 0)).toEqual({ kind: 'complete' })
  })

  it('is partial from the last row returned when the server left active schedules out', () => {
    const page = [
      req({ schedule_id: 'a', due_at: at(12, 10) }),
      req({ schedule_id: 'b', due_at: at(12, 40) }),
      req({ schedule_id: 'c', recurrence: { kind: 'interval', interval_sec: 600 }, due_at: at(12, 25) }),
    ]
    expect(calendarCoverage(page, 7)).toEqual({
      kind: 'partial',
      omittedActive: 4,
      omittedFromMs: at(12, 40) * 1000,
    })
  })

  it('has no such point when no row on the page carries a time', () => {
    expect(calendarCoverage([req({ schedule_id: 'a' })], 3)).toEqual({
      kind: 'partial',
      omittedActive: 2,
      omittedFromMs: null,
    })
    expect(calendarCoverage([], 1)).toEqual({ kind: 'partial', omittedActive: 1, omittedFromMs: null })
  })
})

describe('dayIsComplete', () => {
  const dayStart = new Date(2026, 6, 7, 0, 0, 0).getTime()
  const dayEnd = new Date(2026, 6, 8, 0, 0, 0).getTime()
  const omittedFrom = (omittedFromMs: number | null) =>
    ({ kind: 'partial', omittedActive: 1, omittedFromMs }) as const

  it('holds for every day when every active schedule is on hand', () => {
    expect(dayIsComplete({ kind: 'complete' }, dayEnd)).toBe(true)
  })

  it('holds for a day that ends by the time the omitted schedules start', () => {
    expect(dayIsComplete(omittedFrom(dayEnd), dayEnd)).toBe(true)
    expect(dayIsComplete(omittedFrom(dayEnd + HOUR_MS), dayEnd)).toBe(true)
  })

  it('does not hold for a day an omitted schedule may fall in', () => {
    // One of them may be due in the last millisecond of the day.
    expect(dayIsComplete(omittedFrom(dayEnd - 1), dayEnd)).toBe(false)
    expect(dayIsComplete(omittedFrom(dayStart + 12 * HOUR_MS), dayEnd)).toBe(false)
    expect(dayIsComplete(omittedFrom(dayStart), dayEnd)).toBe(false)
    expect(dayIsComplete(omittedFrom(null), dayEnd)).toBe(false)
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
        coverage=${{ kind: 'complete' }}
        onOpen=${() => {}}
      />`,
      container,
    )
    expect(container.querySelector('[data-schedule-id="poll-1"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="sch-polling-empty"]')).toBeNull()

    render(
      html`<${PollingStrip} requests=${[req({ schedule_id: 'one', recurrence: { kind: 'one_shot' } })]} coverage=${{ kind: 'complete' }} onOpen=${() => {}} />`,
      container,
    )
    expect(container.querySelector('[data-testid="sch-polling-empty"]')).not.toBeNull()
  })

  it('renders agenda events and the empty state when nothing is upcoming', () => {
    render(
      html`<${Agenda}
        requests=${[req({ schedule_id: 'ev-1', due_at_iso: '2026-07-07T18:00:00Z' })]}
        coverage=${{ kind: 'complete' }}
        nowMs=${NOW_MS}
        onOpen=${() => {}}
      />`,
      container,
    )
    expect(container.querySelector('[data-schedule-id="ev-1"]')).not.toBeNull()

    render(html`<${Agenda} requests=${[]} coverage=${{ kind: 'complete' }} nowMs=${NOW_MS} onOpen=${() => {}} />`, container)
    expect(container.querySelector('[data-testid="sch-agenda-empty"]')).not.toBeNull()
  })

  describe('when the server left active schedules out of the page (#52961)', () => {
    // The issue's page: every row is a polling loop due within the hour, and
    // the schedule for tomorrow is the one the server did not return. The last
    // row is due 20 minutes after NOW_MS (12:00), at 12:20.
    const pollingPage = Array.from({ length: 20 }, (_, index) => req({
      schedule_id: `poll-${index}`,
      recurrence: { kind: 'interval', interval_sec: 600 },
      due_at: (NOW_MS + (index + 1) * 60_000) / 1000,
    }))
    const calendar = (
      requests: readonly DashboardScheduledAutomationRequest[],
      activeCount: number,
      cadenceFilter: 'scheduled' | 'interval' | 'oneshot' | null = null,
    ) => render(
      html`<${ScheduleCalendar} requests=${requests} activeCount=${activeCount} nowMs=${NOW_MS} cadenceFilter=${cadenceFilter} onOpen=${() => {}} />`,
      container,
    )
    const shown = (testId: string) => container.querySelector(`[data-testid="${testId}"]`) !== null
    const note = () => container.querySelector('[data-testid="sch-calendar-partial"]')?.textContent ?? ''
    const emptyDays = () => Array.from(container.querySelectorAll('[data-testid="sch-day-empty"]'))
      .map(node => node.textContent)
    const todayCount = () => container.querySelector('.sch-day.today .sch-day-n')?.textContent

    it('does not call the coming days empty', () => {
      // With every active schedule on hand these rows do mean empty days.
      calendar(pollingPage, 20)
      expect(shown('sch-agenda-empty')).toBe(true)
      expect(shown('sch-calendar-partial')).toBe(false)
      const [knownEmpty] = emptyDays()
      expect(emptyDays()).toEqual([knownEmpty, knownEmpty])

      calendar(pollingPage, 21)
      expect(shown('sch-agenda-empty')).toBe(false)
      // The schedule left out may be due today after 12:20 or tomorrow:
      // neither day reads like a day known to be empty.
      const [today, tomorrow] = emptyDays()
      expect(today).not.toBe(knownEmpty)
      expect(tomorrow).toBe(today)
    })

    it('says how many active schedules were left out and from when they are due', () => {
      calendar(pollingPage, 23)
      expect(note()).toContain('3건')
      expect(note()).toContain('7/7 (화) 12:20')
      // Every row is on the page: nothing to say.
      calendar(pollingPage, 20)
      expect(shown('sch-calendar-partial')).toBe(false)
    })

    it('says it under a cadence filter too', () => {
      calendar(pollingPage, 21, 'interval')
      expect(note()).toContain('1건')
      calendar(pollingPage, 21, 'oneshot')
      expect(note()).toContain('1건')
    })

    it('names no time when no row on the page carries one', () => {
      calendar([req({ schedule_id: 'untimed' })], 4)
      expect(note()).toContain('3건')
      expect(note()).not.toMatch(/\d{1,2}:\d{2}/)
      expect(shown('sch-agenda-empty')).toBe(false)
    })

    it('does not call the polling strip empty either', () => {
      const oneShots = pollingPage.map(row => ({ ...row, recurrence: { kind: 'one_shot' } }))
      const pollingEmpty = () => container.querySelector('[data-testid="sch-polling-empty"]')?.textContent
      calendar(oneShots, 20)
      const complete = pollingEmpty()
      expect(complete).toBeDefined()
      // The schedule left out may be a polling loop.
      calendar(oneShots, 21)
      expect(pollingEmpty()).toBeDefined()
      expect(pollingEmpty()).not.toBe(complete)
    })

    it('reads coverage from the whole page, not from the rows a cadence filter keeps', () => {
      // Every active schedule is on the page; the filter hides them all. The
      // days are still known to be empty of one-shot schedules.
      calendar(pollingPage, 20, 'oneshot')
      expect(shown('sch-agenda-empty')).toBe(true)
      expect(shown('sch-calendar-partial')).toBe(false)
    })

    it('still calls the window empty when the page reaches past it', () => {
      const beyond = req({ schedule_id: 'far', due_at: (NOW_MS + 30 * DAY_MS) / 1000 })
      calendar([beyond], 5)
      // Whatever was left out is due after `far`, so after the window too. The
      // calendar as a whole is still short of four schedules.
      expect(shown('sch-agenda-empty')).toBe(true)
      expect(note()).toContain('4건')
      const days = emptyDays()
      calendar([beyond], 1)
      expect(days).toEqual(emptyDays())
    })

    it('does not call the window empty when the page ends inside its last day', () => {
      const lastDayNoon = new Date(2026, 6, 13, 12, 0, 0).getTime()
      const poll = req({
        schedule_id: 'poll-late',
        recurrence: { kind: 'interval', interval_sec: 600 },
        due_at: lastDayNoon / 1000,
      })
      // The schedule left out may be due that afternoon.
      calendar([poll], 2)
      expect(shown('sch-agenda-empty')).toBe(false)
      // Today and tomorrow end before it: they are known to be empty.
      const days = emptyDays()
      calendar([poll], 1)
      expect(shown('sch-agenda-empty')).toBe(true)
      expect(days).toEqual(emptyDays())
    })

    it('marks a day count that may be short', () => {
      const lunch = req({ schedule_id: 'lunch', due_at: (NOW_MS + HOUR_MS) / 1000 })
      calendar([lunch], 1)
      expect(todayCount()).toBe('1건')
      calendar([lunch], 2)
      expect(todayCount()).toBe('1건 이상')
    })

    it('marks the count of a day the page ended before', () => {
      // Overdue rows are drawn on today; the page ended yesterday, so the
      // schedules left out may be due today as well.
      const overdue = [1, 2, 3].map(hour => req({
        schedule_id: `late-${hour}`,
        due_at: (NOW_MS - DAY_MS + hour * HOUR_MS) / 1000,
      }))
      calendar(overdue, 3)
      expect(todayCount()).toBe('3건')
      calendar(overdue, 5)
      expect(todayCount()).toBe('3건 이상')
    })
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
        coverage=${{ kind: 'complete' }}
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
        coverage=${{ kind: 'complete' }}
        nowMs=${NOW_MS}
        onOpen=${() => {}}
      />`,
      container,
    )
    expect(container.querySelector('[data-schedule-id="done-1"] [data-testid="sch-drain-chip"]')).toBeNull()
  })
})
