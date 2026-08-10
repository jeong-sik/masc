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
import { ChatTranscript } from './primitives'

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
    opts: { unreadAfterTs?: number | null; showDayDividers?: boolean } = {},
  ) => {
    render(
      html`<${ChatTranscript}
        entries=${entries}
        emptyText="대화 없음"
        showDayDividers=${opts.showDayDividers ?? true}
        groupToolCalls=${true}
        unreadAfterTs=${opts.unreadAfterTs ?? null}
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
})
