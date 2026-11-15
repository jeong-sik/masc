// Keeper month efficiency — what one Keeper did with the turns it took this
// month, beside the same values of the whole fleet.
//
// The TUI draws these numbers in the Info tab of its Keepers view
// (bin/masc_tui_keeper_efficiency.ml). One read holds every Keeper of the
// month, so the panel reads when it is first drawn and picks the row of the
// Keeper on the page; moving to another Keeper asks nothing.
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
  /** Nothing was asked yet, or the read was withdrawn: nothing to say. */
  | { readonly kind: 'not_asked' }
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

/** What the panel draws for one Keeper from what the read has come to. */
export function keeperMonthEfficiencyView(
  read: KeeperMonthEfficiencyRead,
  keeperName: string,
): KeeperMonthEfficiencyView {
  if (read.data === null) {
    if (read.loading) return { kind: 'reading' }
    if (read.error !== null) return { kind: 'unread', reason: read.error }
    return { kind: 'not_asked' }
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

function fleetNote(text: string) {
  return { direction: 'flat' as const, text: `전체 ${text}` }
}

function Share({ share, fleet }: { share: KeeperMonthEfficiencyShare; fleet: KeeperEfficiencyFleet }) {
  switch (share.kind) {
    case 'absent':
      return html`<p class="m-0 text-xs text-[var(--color-fg-muted)]">이 달에 이 Keeper 의 턴 없음</p>`
    case 'no_turn_counted':
      return html`
        <p class="m-0 text-xs text-[var(--color-fg-muted)]">
          센 턴 없음 · 도구 호출 ${formatNumber(share.calls)}회, 실패 ${formatNumber(share.failed)}회
        </p>
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

  const view = keeperMonthEfficiencyView(resource.state.value, keeperName)
  switch (view.kind) {
    case 'not_asked':
      return null
    case 'reading':
      return html`
        <${KpiSection} title=${PANEL_TITLE}>
          <p class="m-0 text-xs text-[var(--color-fg-muted)]" role="status" data-efficiency-state="reading">
            읽는 중 · 그 달의 첫 읽기는 1분쯤 걸릴 수 있음
          </p>
        <//>
      `
    case 'unread':
      return html`
        <${KpiSection} title=${PANEL_TITLE}>
          <div class="flex flex-wrap items-center gap-2" data-efficiency-state="unread">
            <p class="m-0 text-xs text-[var(--color-status-err)]" role="alert">읽지 못함: ${view.reason}</p>
            <${Btn} size="xs" onClick=${read} testId="keeper-month-efficiency-read-again">다시 읽기<//>
          </div>
        <//>
      `
    case 'read':
      return html`
        <${KpiSection} title=${PANEL_TITLE}>
          <div class="flex flex-col gap-2" data-efficiency-state="read" data-efficiency-share=${view.share.kind} data-efficiency-refresh=${view.refresh.kind}>
            <div class="flex flex-wrap items-center justify-between gap-2">
              <p class="m-0 text-2xs text-[var(--color-fg-muted)]">
                ${view.month} · ${formatNumber(view.daysCovered)}일 · 전체 ${formatNumber(view.fleet.turns_total)}턴 · 집계 <${TimeAgo} timestamp=${view.generatedAt} />
              </p>
              <${Btn}
                size="xs"
                variant="ghost"
                disabled=${view.refresh.kind === 'refreshing'}
                onClick=${read}
                testId="keeper-month-efficiency-refresh"
              >새로고침<//>
            </div>
            <${Share} share=${view.share} fleet=${view.fleet} />
            ${view.refresh.kind === 'failed'
              ? html`<p class="m-0 text-2xs text-[var(--color-status-warn)]" role="alert">마지막 새로고침 실패: ${view.refresh.reason}</p>`
              : null}
          </div>
        <//>
      `
  }
}
