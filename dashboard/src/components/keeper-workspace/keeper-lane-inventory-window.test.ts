import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DashboardKeeperWaitingInventory, DashboardKeeperWaitingRow } from '../../api'
import type { Keeper } from '../../types'
import { KeeperWaitingInventoryPanel } from '../tools/keeper-waiting-inventory-panel'
import { KeeperLaneStrip } from './keeper-lane-strip'
import type { LaneEventQueueActions } from './keeper-lane-event-actions'

const ROW_COUNT = 2000
const LAST = ROW_COUNT - 1
/** Few enough rows that the list keeps every one of them mounted. */
const SHORT_ROW_COUNT = 3
const VIEWPORT_HEIGHT_PX = 240
/** Past any content height the list can have, so the window lands on its end. */
const BELOW_EVERY_ROW_PX = 10_000_000

const LIST = '[aria-label="대기 나이순 작업 흐름"]'
const ROW = '[data-testid="keeper-lane-waiting-row"]'
const WHAT = '[data-testid="keeper-lane-waiting-what"]'

type EventRow = DashboardKeeperWaitingRow & { detail: { source_ref: string; source_incarnation: string } }

/** `count` pending events, oldest first, each with its own exact-entry address. */
function eventRows(name: string, count = ROW_COUNT): EventRow[] {
  return Array.from({ length: count }, (_, index) => ({
    keeper_name: name,
    source: 'event_queue_pending',
    waiting_on: 'workspace_message',
    what: `${name}-event-${index}`,
    since: 1000 + index,
    next_action: 'keeper_drain_event_queue',
    detail: {
      source_ref: index.toString(16).padStart(64, '0'),
      source_incarnation: (9007199254740993n + BigInt(index)).toString(),
    },
  }))
}

function inventory(entries: Array<[string, DashboardKeeperWaitingRow[]]>): DashboardKeeperWaitingInventory {
  return {
    keeper_count: entries.length,
    waiting_keeper_count: entries.length,
    row_count: entries.reduce((total, [, rows]) => total + rows.length, 0),
    keepers: entries.map(([keeper_name, waiting_on]) => ({
      keeper_name,
      state: 'waiting',
      state_sources: [...new Set(waiting_on.map(row => row.source))],
      waiting_count: waiting_on.length,
      waiting_on,
    })),
  }
}

function operatorActions(): LaneEventQueueActions {
  return { pendingKey: null, recoveries: [], error: null, operate: vi.fn(async () => undefined) }
}

function strip(name: string, data: DashboardKeeperWaitingInventory, actions: LaneEventQueueActions) {
  const keeper: Keeper = { name, status: 'waiting' }
  return html`
    <${KeeperLaneStrip}
      keeper=${keeper}
      inventory=${data}
      ready=${true}
      loading=${false}
      error=${null}
      eventActions=${actions}
    />
  `
}

/** The scroll list, given a height: happy-dom lays nothing out. */
function listOf(container: Element): HTMLElement {
  const list = container.querySelector<HTMLElement>(LIST)!
  Object.defineProperty(list, 'clientHeight', { configurable: true, value: VIEWPORT_HEIGHT_PX })
  return list
}

async function scrollTo(list: HTMLElement, scrollTop: number) {
  await act(async () => {
    list.scrollTop = scrollTop
    fireEvent.scroll(list)
  })
}

function rowOf(what: string): HTMLDetailsElement {
  return screen.getByText(what, { selector: WHAT }).closest<HTMLDetailsElement>('details')!
}

function mounted(what: string): boolean {
  return screen.queryByText(what, { selector: WHAT }) !== null
}

/** What the browser does when the operator clicks a row's bar. */
async function open(row: HTMLDetailsElement) {
  await act(async () => {
    row.open = true
    fireEvent(row, new Event('toggle'))
  })
}

/** Lets the focus hand-off queued by an unmounting row run. */
async function settled() {
  await act(async () => {
    await Promise.resolve()
  })
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('Keeper lane inventory window', () => {
  it('mounts a window of a large inventory and still reaches the last server row with its own address', async () => {
    const all = eventRows('alpha')
    const actions = operatorActions()
    const view = render(strip('alpha', inventory([['alpha', all]]), actions))
    expect(view.container.querySelectorAll(ROW).length).toBeLessThan(ROW_COUNT)

    await scrollTo(listOf(view.container), BELOW_EVERY_ROW_PX)
    await screen.findByText(`alpha-event-${LAST}`, { selector: WHAT })
    expect(mounted('alpha-event-0')).toBe(false)

    const last = rowOf(`alpha-event-${LAST}`)
    await open(last)
    fireEvent.click(within(last).getByRole('button', { name: 'normal' }))
    expect(actions.operate).toHaveBeenCalledTimes(1)
    expect(actions.operate).toHaveBeenCalledWith(`event:${all[LAST]!.detail.source_ref}`, {
      action: 'reprioritize',
      sourceRef: all[LAST]!.detail.source_ref,
      sourceIncarnation: all[LAST]!.detail.source_incarnation,
      urgency: 'normal',
    })
  })

  it('keeps a row open after it leaves the window and returns', async () => {
    const view = render(strip('alpha', inventory([['alpha', eventRows('alpha')]]), operatorActions()))
    await open(rowOf('alpha-event-0'))

    const list = listOf(view.container)
    await scrollTo(list, BELOW_EVERY_ROW_PX)
    await screen.findByText(`alpha-event-${LAST}`, { selector: WHAT })
    expect(mounted('alpha-event-0')).toBe(false)
    await scrollTo(list, 0)
    await screen.findByText('alpha-event-0', { selector: WHAT })
    expect(rowOf('alpha-event-0').open).toBe(true)
  })

  it.each([
    ['a short list', SHORT_ROW_COUNT],
    ['a windowed list', ROW_COUNT],
  ])('keeps a row of %s open and focused when the queue re-addresses its event', async (_list, count) => {
    const all = eventRows('alpha', count)
    const actions = operatorActions()
    const view = render(strip('alpha', inventory([['alpha', all]]), actions))
    const row = rowOf('alpha-event-0')
    await open(row)
    const button = within(row).getByRole('button', { name: 'normal' })
    button.focus()

    // The next inventory read after the queue deferred or reprioritized the event.
    const readdressed: EventRow = {
      ...all[0]!,
      detail: { source_ref: 'f'.repeat(64), source_incarnation: '42' },
    }
    view.rerender(strip('alpha', inventory([['alpha', [readdressed, ...all.slice(1)]]]), actions))
    await settled()
    expect(rowOf('alpha-event-0')).toBe(row)
    expect(row.open).toBe(true)
    expect(document.activeElement).toBe(button)

    fireEvent.click(button)
    expect(actions.operate).toHaveBeenCalledWith(`event:${readdressed.detail.source_ref}`, {
      action: 'reprioritize',
      sourceRef: readdressed.detail.source_ref,
      sourceIncarnation: readdressed.detail.source_incarnation,
      urgency: 'normal',
    })
  })

  it('forgets an open row once the list no longer has its place', async () => {
    const all = eventRows('alpha', SHORT_ROW_COUNT)
    const actions = operatorActions()
    const view = render(strip('alpha', inventory([['alpha', all]]), actions))
    const lastWhat = `alpha-event-${SHORT_ROW_COUNT - 1}`
    await open(rowOf(lastWhat))

    view.rerender(strip('alpha', inventory([['alpha', all.slice(0, 1)]]), actions))
    await waitFor(() => expect(mounted(lastWhat)).toBe(false))
    view.rerender(strip('alpha', inventory([['alpha', all]]), actions))
    await screen.findByText(lastWhat, { selector: WHAT })
    expect(rowOf(lastWhat).open).toBe(false)
  })

  it('starts another Keeper at its first row with nothing open', async () => {
    const data = inventory([['alpha', eventRows('alpha')], ['beta', eventRows('beta')]])
    const actions = operatorActions()
    const view = render(strip('alpha', data, actions))
    await open(rowOf('alpha-event-0'))
    const alphaList = listOf(view.container)
    await scrollTo(alphaList, BELOW_EVERY_ROW_PX)
    await screen.findByText(`alpha-event-${LAST}`, { selector: WHAT })

    view.rerender(strip('beta', data, actions))
    await screen.findByText('beta-event-0', { selector: WHAT })
    const betaList = listOf(view.container)
    expect(betaList).not.toBe(alphaList)
    expect(rowOf('beta-event-0').open).toBe(false)
    expect(mounted(`alpha-event-${LAST}`)).toBe(false)
  })

  it('hands keyboard focus to the list when the focused row leaves the window', async () => {
    const view = render(strip('alpha', inventory([['alpha', eventRows('alpha')]]), operatorActions()))
    const first = rowOf('alpha-event-0')
    await open(first)
    const button = within(first).getByRole('button', { name: 'normal' })
    button.focus()
    expect(document.activeElement).toBe(button)

    const list = listOf(view.container)
    await scrollTo(list, BELOW_EVERY_ROW_PX)
    await screen.findByText(`alpha-event-${LAST}`, { selector: WHAT })
    await waitFor(() => expect(document.activeElement).toBe(list))
  })

  it('does not take keyboard focus when no row in the list had it', async () => {
    const view = render(strip('alpha', inventory([['alpha', eventRows('alpha')]]), operatorActions()))
    await open(rowOf('alpha-event-0'))
    expect(document.activeElement).toBe(document.body)

    await scrollTo(listOf(view.container), BELOW_EVERY_ROW_PX)
    await screen.findByText(`alpha-event-${LAST}`, { selector: WHAT })
    await settled()
    expect(document.activeElement).toBe(document.body)
  })

  it('windows the fleet inventory panel through the same block', async () => {
    const view = render(html`
      <${KeeperWaitingInventoryPanel} inventory=${inventory([['alpha', eventRows('alpha')]])} />
    `)
    expect(view.container.querySelectorAll(ROW).length).toBeLessThan(ROW_COUNT)

    await scrollTo(listOf(view.container), BELOW_EVERY_ROW_PX)
    await screen.findByText(`alpha-event-${LAST}`, { selector: WHAT })
    expect(mounted('alpha-event-0')).toBe(false)
  })
})
