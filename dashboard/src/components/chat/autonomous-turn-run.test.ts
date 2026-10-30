// @vitest-environment happy-dom
//
// Rendering of a folded run of autonomous turns. The unit-level contract lives
// in autonomous-turn-group.test.ts; what is asserted here is what the fold does
// to the transcript around it, which is only observable after a render: the
// run must replace N identical rows with one header, must still hold N rows
// inside, and must not swallow a divider the transcript still has to draw.
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { html } from 'htm/preact'
import type { KeeperConversationEntry } from '../../types'
import { autonomousRunWindow, ChatTranscript } from './primitives'

const wake = (id: string, timestamp: string): KeeperConversationEntry =>
  ({
    id,
    role: 'assistant',
    source: 'autonomous_turn',
    label: 'keeper',
    text: '',
    delivery: 'history',
    timestamp,
  }) as KeeperConversationEntry

const said = (id: string, timestamp: string): KeeperConversationEntry =>
  ({
    id,
    role: 'user',
    source: 'direct_user',
    label: 'vincent',
    text: '상태 알려줘',
    delivery: 'history',
    timestamp,
  }) as KeeperConversationEntry

// A keeper wakes on the order of once a minute. Two days chosen 48h apart so
// they land on different calendar days in every timezone the suite might run in.
const DAY_ONE = '2026-08-10T12:00:00.000Z'
const DAY_THREE = '2026-08-12T12:00:00.000Z'

const minutesAfter = (iso: string, minutes: number): string =>
  new Date(Date.parse(iso) + minutes * 60_000).toISOString()

const secondsOf = (iso: string): number => Math.floor(Date.parse(iso) / 1000)

const wakesFrom = (prefix: string, start: string, count: number): KeeperConversationEntry[] =>
  Array.from({ length: count }, (_, i) => wake(`${prefix}${i + 1}`, minutesAfter(start, i)))

describe('ChatTranscript — folded autonomous runs', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const draw = (
    entries: KeeperConversationEntry[],
    opts: {
      unreadAfterTs?: number | null
      showDayDividers?: boolean
      expandAutonomousRuns?: boolean
    } = {},
  ) => {
    render(
      html`<${ChatTranscript}
        entries=${entries}
        emptyText="대화 없음"
        showDayDividers=${opts.showDayDividers ?? true}
        groupToolCalls=${true}
        unreadAfterTs=${opts.unreadAfterTs ?? null}
        expandAutonomousRuns=${opts.expandAutonomousRuns ?? false}
      />`,
      container,
    )
  }

  const headerCounts = (): (string | null)[] =>
    [...container.querySelectorAll('.chat-block-trace-count')].map((node) => node.textContent)

  const runHeaders = (): HTMLElement[] =>
    [...container.querySelectorAll('.chat-auto-run > .chat-block-trace-hd')] as HTMLElement[]

  it('replaces a wall of identical rows with one header carrying the count', () => {
    draw([said('u1', DAY_ONE), ...wakesFrom('a', minutesAfter(DAY_ONE, 1), 6)])
    // One chip, not six reading "1개".
    expect(headerCounts()).toEqual(['6개'])
  })

  it('leaves every autonomous turn unfolded when the global preference is enabled', () => {
    draw(wakesFrom('a', DAY_ONE, 6), { expandAutonomousRuns: true })
    expect(container.querySelectorAll('.chat-auto-run').length).toBe(0)
    expect(headerCounts()).toEqual(['1개', '1개', '1개', '1개', '1개', '1개'])
  })

  it('holds every turn as its own row inside, so the run is a container and not a merge', () => {
    draw(wakesFrom('a', DAY_ONE, 6))
    act(() => {
      runHeaders()[0]?.click()
    })
    const nested = container.querySelectorAll('.chat-auto-run-turns > .chat-block-trace')
    expect(nested.length).toBe(6)
    // Each nested turn is still closed and still counts one turn.
    expect([...nested].map((node) => node.querySelector('.chat-block-trace-count')?.textContent))
      .toEqual(['1개', '1개', '1개', '1개', '1개', '1개'])
  })

  it('leaves a short run of wakes inline', () => {
    draw([said('u1', DAY_ONE), ...wakesFrom('a', minutesAfter(DAY_ONE, 1), 2)])
    expect(container.querySelectorAll('.chat-auto-run').length).toBe(0)
    expect(headerCounts()).toEqual(['1개', '1개'])
  })

  it('still draws a day divider for every day the run covers', () => {
    // A run that folded across midnight would take the second day's divider
    // with it, and the transcript would claim those turns happened on day one.
    draw([...wakesFrom('a', DAY_ONE, 4), ...wakesFrom('b', DAY_THREE, 4)])
    expect(container.querySelectorAll('.kw-daydiv:not(.kw-unreaddiv)').length).toBe(2)
    expect(container.querySelectorAll('.chat-auto-run').length).toBe(2)
  })

  it('still draws the unread line when the cursor falls inside a run', () => {
    // The anchor is computed before folding. Folding the anchored turn into a
    // run that starts earlier would leave the line with nothing to attach to.
    const wakes = wakesFrom('a', DAY_ONE, 8)
    const cutoff = secondsOf(minutesAfter(DAY_ONE, 3)) + 1
    draw(wakes, { unreadAfterTs: cutoff })
    expect(container.querySelectorAll('.kw-unreaddiv').length).toBe(1)
    expect(container.querySelectorAll('.chat-auto-run').length).toBe(2)
  })

  it('keeps the unread line above the first unseen turn', () => {
    const wakes = wakesFrom('a', DAY_ONE, 8)
    const cutoff = secondsOf(minutesAfter(DAY_ONE, 3)) + 1
    draw(wakes, { unreadAfterTs: cutoff })
    const divider = container.querySelector('.kw-unreaddiv')
    const runs = [...container.querySelectorAll('.chat-auto-run')]
    expect(divider).not.toBeNull()
    expect(runs.length).toBe(2)
    // The second run begins at the first unseen turn, so the line sits
    // immediately before it rather than after the whole block.
    expect(divider?.nextElementSibling).toBe(runs[1])
  })

  const openFirstRun = () => {
    act(() => {
      runHeaders()[0]?.click()
    })
  }

  const nestedTurns = (): Element[] => [
    ...container.querySelectorAll('.chat-auto-run-turns > .chat-block-trace'),
  ]

  const moreControl = (): HTMLElement | null =>
    container.querySelector('.chat-auto-run-more')

  it('draws only the two ends of a long run, with the middle behind one control', () => {
    // Opening a 30-turn run must not trade the wall of headers the fold
    // removed for a wall of rows.
    draw(wakesFrom('a', DAY_ONE, 30))
    openFirstRun()
    expect(nestedTurns().length).toBe(6)
    expect(moreControl()?.textContent?.trim()).toBe('가운데 24개 더 보기')
  })

  it('draws the run whole when the control would stand for a single turn', () => {
    // 7 turns is head(3) + tail(3) + 1: a press to save one row is a worse
    // trade than the row, so no control belongs in the output.
    draw(wakesFrom('a', DAY_ONE, 7))
    openFirstRun()
    expect(nestedTurns().length).toBe(7)
    expect(moreControl()).toBeNull()
  })

  it('reveals a step of turns per press and reports what is still hidden', () => {
    draw(wakesFrom('a', DAY_ONE, 30))
    openFirstRun()
    act(() => {
      moreControl()?.click()
    })
    // head 3 -> 13, tail 3, so 16 rows drawn and 14 still behind the control.
    expect(nestedTurns().length).toBe(16)
    expect(moreControl()?.textContent?.trim()).toBe('가운데 14개 더 보기')
  })

  it('retires the control once every turn is drawn', () => {
    draw(wakesFrom('a', DAY_ONE, 20))
    openFirstRun()
    act(() => {
      moreControl()?.click()
    })
    act(() => {
      moreControl()?.click()
    })
    // head reaches 23 >= 20, so the window degenerates to the whole run.
    expect(nestedTurns().length).toBe(20)
    expect(moreControl()).toBeNull()
  })
})

describe('autonomousRunWindow', () => {
  it('draws a run whole up to the point where hiding saves more than one turn', () => {
    // 0..7 inclusive: the window never hides a single turn behind a press.
    for (const total of [0, 1, 5, 6, 7]) {
      expect(autonomousRunWindow(total, 3)).toEqual({ head: total, tail: 0, hidden: 0 })
    }
  })

  it('splits into both ends once the middle is worth a control', () => {
    expect(autonomousRunWindow(8, 3)).toEqual({ head: 3, tail: 3, hidden: 2 })
    expect(autonomousRunWindow(200, 3)).toEqual({ head: 3, tail: 3, hidden: 194 })
  })

  it('closes the window as the head walks down, never overlapping the tail', () => {
    // The head grows by presses; the sum of drawn ends can never exceed the run.
    for (const head of [3, 13, 23, 33]) {
      const w = autonomousRunWindow(30, head)
      expect(w.head + w.tail + w.hidden).toBe(30)
      expect(w.hidden).toBeGreaterThanOrEqual(0)
    }
    expect(autonomousRunWindow(30, 33)).toEqual({ head: 30, tail: 0, hidden: 0 })
  })
})
