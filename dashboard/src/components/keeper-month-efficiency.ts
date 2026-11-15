// Keeper month efficiency — what one Keeper did with the turns it took this
// month, beside the same values of the whole fleet.
//
// The TUI draws these numbers in the Info tab of its Keepers view
// (bin/masc_tui_keeper_efficiency.ml). One read holds every Keeper of the
// month. The panel reads once each time it is drawn and picks the row of its
// Keeper by name. The Keeper page closes its detail when the Keeper changes
// (keeper-detail-page.ts), so each opening of the tab is one read.
//
// A failed read is not an empty month. The panel says the read failed and
// offers it again; a refresh that fails after a good read keeps the last
// numbers and says so beside them. Cost is not drawn: the view writes 0 for a
// lane that reports no money, so "nothing spent" and "not reported" look the
// same in it.
//
// Which number stands in which tile, and which value of the fleet beside it,
// is decided in keeperMonthEfficiencyView, where a test reads it. The drawing
// walks the tiles it is handed.

import { html } from 'htm/preact'
import { useCallback, useEffect } from 'preact/hooks'
import {
  fetchKeeperEfficiencyCurrentMonth,
  keeperEfficiencyRow,
  type KeeperEfficiencyMonth,
} from '../api/dashboard-keeper-efficiency'
import { formatNumber } from '../lib/format-number'
import {
  dashboardObservationOwnerHasWorkspace,
  readDashboardObservationOwner,
} from '../lib/observation-read-owner'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { Btn } from './btn'
import { StatTile } from './common/stat-tile'
import { TimeAgo } from './common/time-ago'
import { KpiSection } from './keeper-detail-kpi'

const MS_PER_SECOND = 1000

/** What the read of the month has come to, as the panel's resource holds it. */
export interface KeeperMonthEfficiencyRead {
  readonly data: KeeperEfficiencyMonth | null
  readonly loading: boolean
  readonly error: string | null
}

/** One number of the Keeper, as a tile draws it. A value per turn stands
 *  beside the fleet's value of the same kind. A count stands alone: the month
 *  holds no fleet total of calls, and the fleet's turns are in the line above
 *  the tiles. */
export type KeeperMonthEfficiencyTile =
  | { readonly id: 'turns' | 'calls' | 'failed_calls'; readonly value: number }
  | {
      readonly id: 'calls_per_turn' | 'tool_seconds_per_turn' | 'output_tokens_per_turn'
      readonly value: number
      readonly fleet: number
    }

/** What one Keeper has in a month that was read. */
export type KeeperMonthEfficiencyShare =
  /** The month holds no row of this Keeper: no counted turn, no tool call. */
  | { readonly kind: 'absent' }
  /** A row with no counted turn. Nothing is divided; its calls are counted. */
  | { readonly kind: 'no_turn_counted'; readonly tiles: readonly KeeperMonthEfficiencyTile[] }
  | { readonly kind: 'measured'; readonly tiles: readonly KeeperMonthEfficiencyTile[] }

/** Whether the numbers on the page are the latest answer of the server. */
export type KeeperMonthEfficiencyRefresh =
  | { readonly kind: 'settled' }
  | { readonly kind: 'refreshing' }
  | { readonly kind: 'failed'; readonly reason: string }

export type KeeperMonthEfficiencyView =
  /** No workspace is confirmed, so the resource asks nothing
   *  (use-managed-async-resource.ts). It is not a month without numbers. */
  | { readonly kind: 'no_workspace' }
  /** The first read is in flight, or the render that draws this sends it. */
  | { readonly kind: 'reading' }
  | { readonly kind: 'unread'; readonly reason: string }
  | {
      readonly kind: 'read'
      readonly month: string
      readonly daysCovered: number
      /** When the server counted the month, as ISO 8601. */
      readonly generatedAt: string
      readonly fleetTurns: number
      readonly share: KeeperMonthEfficiencyShare
      readonly refresh: KeeperMonthEfficiencyRefresh
    }

function shareOf(month: KeeperEfficiencyMonth, keeperName: string): KeeperMonthEfficiencyShare {
  const row = keeperEfficiencyRow(month, keeperName)
  if (row === null) return { kind: 'absent' }
  const calls: readonly KeeperMonthEfficiencyTile[] = [
    { id: 'calls', value: row.calls },
    { id: 'failed_calls', value: row.failed },
  ]
  if (row.turns === 0) return { kind: 'no_turn_counted', tiles: calls }
  const { fleet } = month
  return {
    kind: 'measured',
    tiles: [
      { id: 'turns', value: row.turns },
      { id: 'calls_per_turn', value: row.calls / row.turns, fleet: fleet.calls_per_turn },
      {
        id: 'tool_seconds_per_turn',
        value: row.tool_ms / MS_PER_SECOND / row.turns,
        fleet: fleet.tool_s_per_turn,
      },
      {
        id: 'output_tokens_per_turn',
        value: row.output_tokens / row.turns,
        fleet: fleet.output_tokens_per_turn,
      },
      ...calls,
    ],
  }
}

function refreshOf(read: KeeperMonthEfficiencyRead): KeeperMonthEfficiencyRefresh {
  if (read.loading) return { kind: 'refreshing' }
  if (read.error !== null) return { kind: 'failed', reason: read.error }
  return { kind: 'settled' }
}

/** The decoder holds `generated_at` within what a Date holds, so this does
 *  not throw. TimeAgo reads a bare number by its size, as seconds or as
 *  milliseconds; a string says which instant is meant. */
function isoOfUnixSeconds(seconds: number): string {
  return new Date(seconds * MS_PER_SECOND).toISOString()
}

/** What the panel draws for one Keeper from what the read has come to.
 *  `workspaceConfirmed` says whether the resource can ask at all.
 *
 *  The panel reads when it is drawn and again when its resource is replaced.
 *  So a resource that holds nothing and has failed at nothing, under a
 *  confirmed workspace, is reading: its read is in flight, or the render
 *  that draws this sends it. */
export function keeperMonthEfficiencyView(
  read: KeeperMonthEfficiencyRead,
  keeperName: string,
  workspaceConfirmed: boolean,
): KeeperMonthEfficiencyView {
  if (read.data === null) {
    if (read.error !== null) return { kind: 'unread', reason: read.error }
    return workspaceConfirmed ? { kind: 'reading' } : { kind: 'no_workspace' }
  }
  return {
    kind: 'read',
    month: read.data.month,
    daysCovered: read.data.days_covered,
    generatedAt: isoOfUnixSeconds(read.data.generated_at),
    fleetTurns: read.data.fleet.turns_total,
    share: shareOf(read.data, keeperName),
    refresh: refreshOf(read),
  }
}

const PANEL_TITLE = '이번 달 효율'
const PER_TURN_DIGITS = 1

type TileId = KeeperMonthEfficiencyTile['id']

const TILE_LABEL: Record<TileId, string> = {
  turns: '턴',
  calls_per_turn: '턴당 도구 호출',
  tool_seconds_per_turn: '턴당 도구 시간',
  output_tokens_per_turn: '턴당 출력 토큰',
  calls: '도구 호출',
  failed_calls: '실패한 호출',
}

const whole = (value: number): string => formatNumber(value)

/** How a tile writes its number. The fleet's value beside it is written the
 *  same way. */
const TILE_TEXT: Record<TileId, (value: number) => string> = {
  turns: whole,
  calls_per_turn: value => formatNumber(value, PER_TURN_DIGITS),
  tool_seconds_per_turn: value => `${formatNumber(value, PER_TURN_DIGITS)}초`,
  output_tokens_per_turn: whole,
  calls: whole,
  failed_calls: whole,
}

function Tile({ tile }: { tile: KeeperMonthEfficiencyTile }) {
  const text = TILE_TEXT[tile.id]
  return html`
    <${StatTile}
      label=${TILE_LABEL[tile.id]}
      value=${text(tile.value)}
      delta=${'fleet' in tile ? { direction: 'flat', text: `전체 ${text(tile.fleet)}` } : undefined}
    />
  `
}

/** The columns follow the width of the panel, not of the window: beside the
 *  page's other columns the panel is narrow in a wide window. StatTile cuts a
 *  number that does not fit its row, so a tile too narrow for a number with
 *  the fleet's beside it puts the fleet's on a line of its own. A tile starts
 *  its label and number at the top, so the numbers of one row of tiles stand
 *  on one line whether or not a fleet value is below them.
 *
 *  Both rules reach into the classes of StatTile (styles/kpi.css). That file
 *  is outside the cascade layers, so the rule that replaces one of its
 *  declarations carries `!`. */
function Tiles({ tiles }: { tiles: readonly KeeperMonthEfficiencyTile[] }) {
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(9rem,1fr))] gap-2 [&_.kpi-row]:flex-wrap [&_.kpi-cell]:!justify-start">
      ${tiles.map(tile => html`<${Tile} key=${tile.id} tile=${tile} />`)}
    </div>
  `
}

function Share({ share }: { share: KeeperMonthEfficiencyShare }) {
  switch (share.kind) {
    case 'absent':
      return html`<div class="text-xs text-[var(--color-fg-secondary)]">이 달에 이 Keeper 의 턴 없음</div>`
    case 'no_turn_counted':
      return html`
        <div class="text-xs text-[var(--color-fg-secondary)]">센 턴 없음</div>
        <${Tiles} tiles=${share.tiles} />
      `
    case 'measured':
      return html`<${Tiles} tiles=${share.tiles} />`
  }
}

/** The line beside the button. Each state has an element of its own, so an
 *  alert is a new element when it appears. The lines are not paragraphs: the
 *  page's rule for `p` sets a colour over the colour classes. */
function Headline({ view }: { view: KeeperMonthEfficiencyView }) {
  switch (view.kind) {
    case 'no_workspace':
      return html`
        <div key="no_workspace" class="text-xs text-[var(--color-fg-secondary)]" role="status">
          현재 작업 공간을 확인하는 중…
        </div>
      `
    case 'reading':
      return html`
        <div key="reading" class="text-xs text-[var(--color-fg-secondary)]" role="status">
          읽는 중 · 그 달의 첫 읽기는 1분쯤 걸릴 수 있음
        </div>
      `
    case 'unread':
      return html`<div key="unread" class="text-xs text-[var(--color-status-err)]" role="alert">읽지 못함: ${view.reason}</div>`
    case 'read':
      return html`
        <div key="read" class="text-xs text-[var(--color-fg-secondary)]">
          ${view.month} · ${formatNumber(view.daysCovered)}일 · 전체 ${formatNumber(view.fleetTurns)}턴 · 집계 <${TimeAgo} timestamp=${view.generatedAt} />
        </div>
      `
  }
}

/** What a press would do, or what the panel waits for when a press sends
 *  nothing. */
function readButtonText(view: KeeperMonthEfficiencyView): string {
  switch (view.kind) {
    case 'no_workspace':
      return '기다리는 중…'
    case 'reading':
      return '읽는 중…'
    case 'unread':
      return '다시 읽기'
    case 'read':
      return view.refresh.kind === 'refreshing' ? '읽는 중…' : '새로고침'
  }
}

/** What a screen reader is told of a read of numbers already on the page:
 *  that it runs, and that it has ended. The lines a sighted reader sees do
 *  not change when such a read ends with the same month. Waiting for a
 *  workspace, the first read and a failed read have lines of their own, a
 *  status or an alert. */
function spokenRefresh(view: KeeperMonthEfficiencyView): string {
  if (view.kind !== 'read') return ''
  switch (view.refresh.kind) {
    case 'refreshing':
      return '읽는 중'
    case 'settled':
      return '읽음'
    case 'failed':
      return ''
  }
}

interface KeeperMonthEfficiencyProps {
  keeperName: string
}

export function KeeperMonthEfficiency({ keeperName }: KeeperMonthEfficiencyProps) {
  const resource = useManagedAsyncResource<KeeperEfficiencyMonth>()
  const read = useCallback(() => {
    void resource.load(signal => fetchKeeperEfficiencyCurrentMonth({ signal }))
  }, [resource])
  // The read starts when the panel is drawn and again when the workspace or
  // the credential it was read under changes (a new resource). The resource
  // withdraws its request when the panel goes away.
  useEffect(() => { read() }, [read])
  // A press while a read runs sends nothing. Without a confirmed workspace
  // the resource asks nothing either (use-managed-async-resource.ts).
  const readAgain = useCallback(() => {
    if (resource.state.peek().loading) return
    read()
  }, [resource, read])

  const workspaceConfirmed = dashboardObservationOwnerHasWorkspace(readDashboardObservationOwner())
  const view = keeperMonthEfficiencyView(resource.state.value, keeperName, workspaceConfirmed)
  // Every state is drawn in this one tree, so the button is one element
  // through all of them, and it is never disabled. A disabled button drops
  // keyboard focus, and so does one that leaves the page: when it is pressed,
  // or when the page withdraws the workspace under it, as it does each time
  // the credential changes. The button says what a press would do, or what
  // the panel waits for.
  return html`
    <${KpiSection} title=${PANEL_TITLE}>
      <div
        class="flex flex-col gap-2"
        data-efficiency-state=${view.kind}
        data-efficiency-share=${view.kind === 'read' ? view.share.kind : undefined}
        data-efficiency-refresh=${view.kind === 'read' ? view.refresh.kind : undefined}
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <${Headline} view=${view} />
          <${Btn} size="xs" variant="ghost" onClick=${readAgain} testId="keeper-month-efficiency-read">${readButtonText(view)}<//>
        </div>
        <span class="sr-only" role="status">${spokenRefresh(view)}</span>
        ${view.kind === 'read'
          ? html`
              <div class="flex flex-col gap-2" aria-busy=${view.refresh.kind === 'refreshing' ? 'true' : 'false'}>
                <${Share} share=${view.share} />
              </div>
            `
          : null}
        ${view.kind === 'read' && view.refresh.kind === 'failed'
          ? html`<div class="text-xs text-[var(--color-status-warn)]" role="alert">마지막 새로고침 실패: ${view.refresh.reason}</div>`
          : null}
      </div>
    <//>
  `
}
