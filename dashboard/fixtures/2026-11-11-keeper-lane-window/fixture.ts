// Keeper lane strip over a large synthetic waiting inventory (#26606).
//
// The actual KeeperLaneStrip with no backend: two Keepers, `?rows=` pending
// events each, a Keeper switch, an inventory refresh, a consumed batch and a
// queue that gives its events new addresses. `browser.mjs` drives this page;
// it also opens by hand through the dashboard dev server.

import { html } from 'htm/preact'
import { render } from 'preact'

import type {
  DashboardKeeperWaitingInventory,
  DashboardKeeperWaitingRow,
  KeeperEventQueueOperatorAction,
} from '../../src/api'
import type { LaneEventQueueActions } from '../../src/components/keeper-workspace/keeper-lane-event-actions'
import { KeeperLaneStrip } from '../../src/components/keeper-workspace/keeper-lane-strip'
import type { Keeper } from '../../src/types'
// The app's style order (main.ts). tokens.css sets the focus ring and
// colors_and_type.css the root font size; both decide a row's height and how
// far its ring reaches.
import '../../src/styles/ds-theme-tokens.css'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-workspace.css'
import '../../src/styles/keeper-v2/colors_and_type.css'

const KEEPER_NAMES = ['alpha', 'beta'] as const
type KeeperName = (typeof KEEPER_NAMES)[number]

const DEFAULT_ROWS = 5000
/** Rows the server drops from the front and adds at the back on one refresh. */
const REFRESH_TURNOVER = 3
const SECONDS_PER_MINUTE = 60
/** The newest row is already this old, so its bar is wide enough to read and a
 *  row added by a refresh still lies in the past. */
const NEWEST_ROW_AGE_MINUTES = 120
/** Distance between the addresses one event gets from two re-addressings, wide
 *  enough that no two events share an address. */
const READDRESS_STRIDE = 1_000_000_000

const requestedRows = Number(new URLSearchParams(location.search).get('rows') ?? DEFAULT_ROWS)
const rowsPerKeeper = Number.isInteger(requestedRows) && requestedRows > 0 ? requestedRows : DEFAULT_ROWS
const startedAtSec = Math.floor(Date.now() / 1000)
/** How many times the queue has re-addressed its pending events. */
let readdressed = 0

/** The exact-entry incarnation the queue currently gives the event `serial`. */
function incarnationOf(serial: number): string {
  return String(serial + 1 + readdressed * READDRESS_STRIDE)
}

/** One pending event per minute, oldest first, each with its own address. */
function eventRow(name: KeeperName, serial: number): DashboardKeeperWaitingRow {
  const since = startedAtSec - (rowsPerKeeper - serial + NEWEST_ROW_AGE_MINUTES) * SECONDS_PER_MINUTE
  return {
    keeper_name: name,
    source: 'event_queue_pending',
    waiting_on: 'workspace_message',
    what: `${name} 작업 ${serial}`,
    wake_producer: 'workspace_message',
    since,
    since_iso: new Date(since * 1000).toISOString(),
    next_action: 'keeper_drain_event_queue',
    detail: {
      source_ref: `${name === 'alpha' ? 'a' : 'b'}${serial.toString(16).padStart(63, '0')}`,
      source_incarnation: incarnationOf(serial),
    },
  }
}

/** A fresh response body: every row is a new object, as after a JSON parse. */
function inventoryFrom(firstSerial: number, count: number): DashboardKeeperWaitingInventory {
  const keepers = KEEPER_NAMES.map(name => {
    const waiting_on = Array.from({ length: count }, (_, index) => eventRow(name, firstSerial + index))
    return {
      keeper_name: name,
      state: 'waiting' as const,
      state_sources: ['event_queue_pending'],
      waiting_count: waiting_on.length,
      sources: { event_queue_pending: waiting_on.length },
      waiting_on,
    }
  })
  return {
    keeper_count: keepers.length,
    waiting_keeper_count: keepers.length,
    row_count: keepers.length * count,
    keepers,
  }
}

const operations: Array<{ key: string; operation: KeeperEventQueueOperatorAction }> = []
const actions: LaneEventQueueActions = {
  pendingKey: null,
  recoveries: [],
  error: null,
  operate: async (key, operation) => {
    operations.push({ key, operation })
  },
}

let selected: KeeperName = 'alpha'
let firstSerial = 0
/** Rows each Keeper holds now; a consumed batch lowers it. */
let rowCount = rowsPerKeeper
let inventory = inventoryFrom(firstSerial, rowCount)

const root = document.getElementById('fixture')!

function draw(): void {
  const keeper: Keeper = { name: selected, status: 'waiting' }
  render(
    html`
      <main class="min-h-screen px-4 py-8" style="background: var(--color-bg-page); color: var(--color-fg-primary);">
        <p class="mx-auto mb-3 max-w-[980px] text-xs">
          합성 inventory · 실제 KeeperLaneStrip · 백엔드 없음 · Keeper마다 ${rowCount.toLocaleString()}행
        </p>
        <div class="mx-auto mb-3 flex max-w-[980px] gap-2 text-xs">
          ${KEEPER_NAMES.map(name => html`
            <button
              type="button"
              class="rounded border px-2 py-1"
              aria-pressed=${selected === name}
              data-testid=${`fixture-keeper-${name}`}
              onClick=${() => select(name)}
            >${name}</button>
          `)}
          <button type="button" class="rounded border px-2 py-1" data-testid="fixture-refresh" onClick=${() => refresh()}>
            목록 갱신
          </button>
        </div>
        <section class="ctx-panel mx-auto max-w-[980px] rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
          <${KeeperLaneStrip}
            keeper=${keeper}
            inventory=${inventory}
            ready=${true}
            loading=${false}
            error=${null}
            eventActions=${actions}
          />
        </section>
      </main>
    `,
    root,
  )
}

function select(name: KeeperName): void {
  selected = name
  draw()
}

/** Replaces the inventory the way the next server response would and returns
 *  the time the page spent on it: the synchronous render plus the layout it
 *  forces. Paint is not included. */
function refresh(): number {
  firstSerial += REFRESH_TURNOVER
  inventory = inventoryFrom(firstSerial, rowCount)
  const before = performance.now()
  draw()
  void document.body.offsetHeight
  return performance.now() - before
}

/** Gives every pending event a new exact-entry address, as the queue does
 *  when it defers what a turn left unconsumed. Order and content stay. */
function readdress(): void {
  readdressed += 1
  inventory = inventoryFrom(firstSerial, rowCount)
  draw()
}

/** Drops the `count` oldest rows and adds none, as when the Keeper consumes a
 *  batch in one turn. */
function consume(count: number): void {
  firstSerial += count
  rowCount -= count
  inventory = inventoryFrom(firstSerial, rowCount)
  draw()
}

declare global {
  interface Window {
    laneFixture: {
      /** Serial of the oldest row in the current inventory. */
      firstSerial: () => number
      rowCount: () => number
      incarnationOf: (serial: number) => string
      refresh: () => number
      readdress: () => void
      consume: (count: number) => void
      operations: typeof operations
    }
  }
}

window.laneFixture = {
  firstSerial: () => firstSerial,
  rowCount: () => rowCount,
  incarnationOf,
  refresh,
  readdress,
  consume,
  operations,
}
draw()
