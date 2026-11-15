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

import { html } from 'htm/preact'
import { useCallback, useEffect } from 'preact/hooks'
import {
  fetchKeeperEfficiencyCurrentMonth,
  keeperEfficiencyRow,
  type KeeperEfficiencyFleet,
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

/** What one Keeper has in a month that was read. */
export type KeeperMonthEfficiencyShare =
  /** The month holds no row of this Keeper: no counted turn, no tool call. */
  | { readonly kind: 'absent' }
  /** A row with no counted turn. It can still hold tool calls. */
  | { readonly kind: 'no_turn_counted'; readonly calls: number; readonly failed: number }
  | {
      readonly kind: 'measured'
      readonly turns: number
      readonly callsPerTurn: number
      readonly toolSecondsPerTurn: number
      readonly outputTokensPerTurn: number
      readonly calls: number
      readonly failed: number
    }

/** Whether the numbers on the page are the latest answer of the server. */
export type KeeperMonthEfficiencyRefresh =
  | { readonly kind: 'settled' }
  | { readonly kind: 'refreshing' }
  | { readonly kind: 'failed'; readonly reason: string }

export type KeeperMonthEfficiencyView =
  /** The panel was drawn and has not asked yet: one frame, nothing to say. */
  | { readonly kind: 'not_asked' }
  /** No workspace is confirmed, so the resource asks nothing
   *  (use-managed-async-resource.ts). It is not a month without numbers. */
  | { readonly kind: 'no_workspace' }
  | { readonly kind: 'reading' }
  | { readonly kind: 'unread'; readonly reason: string }
  | {
      readonly kind: 'read'
      readonly month: string
      readonly daysCovered: number
      readonly generatedAt: number
      readonly fleet: KeeperEfficiencyFleet
      readonly share: KeeperMonthEfficiencyShare
      readonly refresh: KeeperMonthEfficiencyRefresh
    }

function shareOf(month: KeeperEfficiencyMonth, keeperName: string): KeeperMonthEfficiencyShare {
  const row = keeperEfficiencyRow(month, keeperName)
  if (row === null) return { kind: 'absent' }
  if (row.turns === 0) return { kind: 'no_turn_counted', calls: row.calls, failed: row.failed }
  return {
    kind: 'measured',
    turns: row.turns,
    callsPerTurn: row.calls / row.turns,
    toolSecondsPerTurn: row.tool_ms / MS_PER_SECOND / row.turns,
    outputTokensPerTurn: row.output_tokens / row.turns,
    calls: row.calls,
    failed: row.failed,
  }
}

function refreshOf(read: KeeperMonthEfficiencyRead): KeeperMonthEfficiencyRefresh {
  if (read.loading) return { kind: 'refreshing' }
  if (read.error !== null) return { kind: 'failed', reason: read.error }
  return { kind: 'settled' }
}

/** What the panel draws for one Keeper from what the read has come to.
 *  `workspaceConfirmed` says whether the resource can ask at all. */
export function keeperMonthEfficiencyView(
  read: KeeperMonthEfficiencyRead,
  keeperName: string,
  workspaceConfirmed: boolean,
): KeeperMonthEfficiencyView {
  if (read.data === null) {
    if (read.loading) return { kind: 'reading' }
    if (read.error !== null) return { kind: 'unread', reason: read.error }
    return workspaceConfirmed ? { kind: 'not_asked' } : { kind: 'no_workspace' }
  }
  return {
    kind: 'read',
    month: read.data.month,
    daysCovered: read.data.days_covered,
    generatedAt: read.data.generated_at,
    fleet: read.data.fleet,
    share: shareOf(read.data, keeperName),
    refresh: refreshOf(read),
  }
}

const PANEL_TITLE = '이번 달 효율'
const PER_TURN_DIGITS = 1

/** The decoder holds `generated_at` within what a Date holds, so this does
 *  not throw. TimeAgo reads a bare number by its size, as seconds or as
 *  milliseconds; a string says which instant is meant. */
function isoOfUnixSeconds(seconds: number): string {
  return new Date(seconds * MS_PER_SECOND).toISOString()
}

function fleetNote(text: string) {
  return { direction: 'flat' as const, text: `전체 ${text}` }
}

function Share({ share, fleet }: { share: KeeperMonthEfficiencyShare; fleet: KeeperEfficiencyFleet }) {
  switch (share.kind) {
    case 'absent':
      return html`<div class="text-xs text-[var(--color-fg-secondary)]">이 달에 이 Keeper 의 턴 없음</div>`
    case 'no_turn_counted':
      return html`
        <div class="text-xs text-[var(--color-fg-secondary)]">
          센 턴 없음 · 도구 호출 ${formatNumber(share.calls)}회, 실패 ${formatNumber(share.failed)}회
        </div>
      `
    case 'measured':
      return html`
        <div class="grid grid-cols-2 sm:grid-cols-5 gap-2">
          <${StatTile} label="턴" value=${formatNumber(share.turns)} />
          <${StatTile}
            label="턴당 도구 호출"
            value=${formatNumber(share.callsPerTurn, PER_TURN_DIGITS)}
            delta=${fleetNote(formatNumber(fleet.calls_per_turn, PER_TURN_DIGITS))}
          />
          <${StatTile}
            label="턴당 도구 시간"
            value=${`${formatNumber(share.toolSecondsPerTurn, PER_TURN_DIGITS)}초`}
            delta=${fleetNote(`${formatNumber(fleet.tool_s_per_turn, PER_TURN_DIGITS)}초`)}
          />
          <${StatTile}
            label="턴당 출력 토큰"
            value=${formatNumber(share.outputTokensPerTurn)}
            delta=${fleetNote(formatNumber(fleet.output_tokens_per_turn))}
          />
          <${StatTile}
            label="실패 / 호출"
            value=${`${formatNumber(share.failed)} / ${formatNumber(share.calls)}`}
          />
        </div>
      `
  }
}

/** A view that draws the month or what became of its read. */
type DrawnView = Exclude<KeeperMonthEfficiencyView, { kind: 'not_asked' | 'no_workspace' }>

function readRuns(view: DrawnView): boolean {
  switch (view.kind) {
    case 'reading':
      return true
    case 'unread':
      return false
    case 'read':
      return view.refresh.kind === 'refreshing'
  }
}

/** The line beside the button. Each state has an element of its own, so an
 *  alert is a new element when it appears. The lines are not paragraphs: the
 *  page's rule for `p` sets a colour over the colour classes. */
function Headline({ view }: { view: DrawnView }) {
  switch (view.kind) {
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
          ${view.month} · ${formatNumber(view.daysCovered)}일 · 전체 ${formatNumber(view.fleet.turns_total)}턴 · 집계 <${TimeAgo} timestamp=${isoOfUnixSeconds(view.generatedAt)} />
        </div>
      `
  }
}

function readButtonText(view: DrawnView): string {
  if (readRuns(view)) return '읽는 중…'
  return view.kind === 'unread' ? '다시 읽기' : '새로고침'
}

/** The month, or what became of its read, with the button that reads again.
 *  The three states share one tree, so the button is one element through
 *  all of them. */
function Drawn({ view, onRead }: { view: DrawnView; onRead: () => void }) {
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
          <${Btn} size="xs" variant="ghost" onClick=${onRead} testId="keeper-month-efficiency-read">${readButtonText(view)}<//>
        </div>
        ${view.kind === 'read' ? html`<${Share} share=${view.share} fleet=${view.fleet} />` : null}
        ${view.kind === 'read' && view.refresh.kind === 'failed'
          ? html`<div class="text-xs text-[var(--color-status-warn)]" role="alert">마지막 새로고침 실패: ${view.refresh.reason}</div>`
          : null}
      </div>
    <//>
  `
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
  // The button is never disabled and never leaves the page while the month
  // or its read is drawn: a disabled button drops keyboard focus, and so does
  // one that is removed when it is pressed. A press while a read runs sends
  // nothing; the button says a read runs.
  const readAgain = useCallback(() => {
    if (resource.state.peek().loading) return
    read()
  }, [resource, read])

  const workspaceConfirmed = dashboardObservationOwnerHasWorkspace(readDashboardObservationOwner())
  const view = keeperMonthEfficiencyView(resource.state.value, keeperName, workspaceConfirmed)
  switch (view.kind) {
    case 'not_asked':
      return null
    case 'no_workspace':
      return html`
        <${KpiSection} title=${PANEL_TITLE}>
          <div class="text-xs text-[var(--color-fg-secondary)]" role="status" data-efficiency-state="no_workspace">
            현재 작업 공간을 확인하는 중…
          </div>
        <//>
      `
    case 'reading':
    case 'unread':
    case 'read':
      return html`<${Drawn} view=${view} onRead=${readAgain} />`
  }
}
