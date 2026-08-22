// Keeper Workspace — lane state section (#23507 PR-L1/L2, slice 1).
// Consume-only surface over the keeper-scoped `keeper_waiting_inventory`
// read model: per-keeper lane state (idle/busy/waiting/deferred) plus
// the waiting rows behind it. The UI gives the closed server vocabulary clear
// operator labels while preserving raw values in titles/details; a keeper
// absent from the inventory renders an explicit data gap instead of a guessed
// "idle".
//
// Counts are the one place that rule cuts the other way. `waiting_count` and
// `sources` are both folds over a list the server already capped
// (`server_keeper_waiting_inventory.ml:529` takes 64 external-attention rows,
// then `:870`/`:877` measure what survived), so rendering either as a bare
// integer states a total the server never computed. When the server sets
// `waiting_count_truncated` the same numbers are lower bounds and must render
// as such.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper } from '../../types'
import type {
  DashboardKeeperWaitingInventory,
  DashboardKeeperWaitingKeeper,
  DashboardKeeperWaitingRow,
  DashboardKeeperWaitingSource,
} from '../../api'
import { StatusChip } from '../common/status-chip'
import {
  enumLabel,
  sourceTone,
  stateTone,
} from '../tools/keeper-waiting-inventory-panel'
import { formatDateTimeKo, formatTimeUntil, relativeTime } from '../../lib/format-time'
import { CountBadge } from '../v2/primitives-v2'
import { JsonViewerCard } from '../common/json-viewer'
import {
  keeperWaitingInventoryState,
  subscribeKeeperWaitingInventory,
} from '../../keeper-waiting-inventory-store'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { shellAuthSummary } from '../../store'
import {
  LaneEventRecoveries,
  LaneEventRowActions,
  useLaneEventQueueActions,
  type LaneEventQueueActions,
} from './keeper-lane-event-actions'

const LANE_STATE_LABELS: Record<string, string> = {
  idle: '비어 있음',
  busy: '처리 중',
  waiting: '대기 중',
  deferred: '외부 응답 대기',
}

const LANE_SOURCE_LABELS: Record<string, string> = {
  event_queue_pending: '자율 이벤트',
  chat_operation_queued: '채팅 대기',
  chat_operation_running: '채팅 처리 중',
  hitl_pending: '승인 대기',
  external_attention: '외부 알림',
  fusion_running: 'Fusion 실행 중',
  schedule_waiting: '예약 실행',
  owner_shutdown: '종료 정리',
  operator_pending_confirm: '운영자 확인',
  read_error: '읽기 오류',
}

const LANE_SOURCE_GRAPH_COLORS: Record<DashboardKeeperWaitingSource, string> = {
  event_queue_pending: 'var(--color-accent)',
  chat_operation_queued: 'var(--color-accent)',
  chat_operation_running: 'var(--status-warn)',
  hitl_pending: 'var(--status-warn)',
  external_attention: 'var(--color-accent)',
  fusion_running: 'var(--status-ok)',
  schedule_waiting: 'var(--status-warn)',
  owner_shutdown: 'var(--color-fg-muted)',
  operator_pending_confirm: 'var(--status-warn)',
  read_error: 'var(--color-danger)',
}

function laneStateLabel(value: string): string {
  return LANE_STATE_LABELS[value] ?? enumLabel(value)
}

function laneSourceLabel(value: string): string {
  return LANE_SOURCE_LABELS[value] ?? enumLabel(value)
}

function inventoryEntry(
  inventory: DashboardKeeperWaitingInventory | null | undefined,
  keeper: Keeper,
): DashboardKeeperWaitingKeeper | null {
  if (!inventory) return null
  const byName = inventory.keepers.find(k => k.keeper_name === keeper.name)
  if (byName) return byName
  if (keeper.agent_name != null && keeper.agent_name !== '') {
    return inventory.keepers.find(k => k.keeper_name === keeper.agent_name) ?? null
  }
  return null
}

function LaneGap({ children }: { children: VNode | string }): VNode {
  return html`
    <div class="ctx-empty" data-missing="keeper-lane">
      <strong>레인 상태 미수신</strong>
      <span>${children}</span>
    </div>
  `
}

/** A count the server folded over a possibly-capped row list. `truncated`
 *  carries the server's own `waiting_count_truncated` / `truncated_sources`
 *  verdict, so a capped count never renders as an exact total. */
function boundedCount(value: number, truncated: boolean): string {
  return truncated ? `≥${value}` : `${value}`
}

/** Per-source counts, each marked with the server's own per-source truncation
 *  verdict. Sorted by count so the source driving the lane reads first. */
function sourceBreakdown(entry: DashboardKeeperWaitingKeeper): Array<{
  source: string
  label: string
  count: string
}> {
  const truncated = entry.truncated_sources ?? {}
  return Object.entries(entry.sources ?? {})
    .sort(([, a], [, b]) => b - a)
    .map(([source, count]) => ({
      source,
      label: laneSourceLabel(source),
      count: boundedCount(count, truncated[source] === true),
    }))
}

/** Sources the server reported as capped, for the attribution line. */
function truncatedSourceLabels(entry: DashboardKeeperWaitingKeeper): string[] {
  return Object.entries(entry.truncated_sources ?? {})
    .filter(([, isTruncated]) => isTruncated)
    .map(([source]) => laneSourceLabel(source))
}

function rowSince(row: DashboardKeeperWaitingRow): number | null {
  if (row.since != null && Number.isFinite(row.since)) return row.since
  if (row.since_iso == null) return null
  const parsed = Date.parse(row.since_iso)
  return Number.isFinite(parsed) ? parsed / 1000 : null
}

/** Git log convention: newest observation first. Equal/missing timestamps keep
 * their server order, and missing timestamps stay visible at the end. This is
 * an observation order only; independent source queues retain their own
 * processing authority. */
function waitingRowsNewestFirst(rows: readonly DashboardKeeperWaitingRow[]): DashboardKeeperWaitingRow[] {
  return rows
    .map((row, serverIndex) => ({ row, serverIndex, since: rowSince(row) }))
    .sort((left, right) => {
      if (left.since == null && right.since == null) return left.serverIndex - right.serverIndex
      if (left.since == null) return 1
      if (right.since == null) return -1
      return right.since - left.since || left.serverIndex - right.serverIndex
    })
    .map(({ row }) => row)
}

function LaneWaitingRow({
  row,
  first,
  last,
  actions,
}: {
  row: DashboardKeeperWaitingRow
  first: boolean
  last: boolean
  /** Admin operator actions; null renders the row read-only. */
  actions: LaneEventQueueActions | null
}): VNode {
  const graphColor = LANE_SOURCE_GRAPH_COLORS[row.source]
  const sinceRelative = row.since_iso == null ? null : relativeTime(row.since_iso)
  return html`
    <article
      data-testid="keeper-lane-waiting-row"
      data-source=${row.source}
      data-waiting-on=${row.waiting_on}
      class="grid grid-cols-[1.25rem_minmax(0,1fr)] gap-2"
    >
      <div class="relative min-h-full" aria-hidden="true">
        ${first ? null : html`<span class="absolute left-1/2 top-0 h-1/2 -translate-x-1/2 border-l border-[var(--color-border-default)]"></span>`}
        ${last ? null : html`<span class="absolute bottom-0 left-1/2 h-1/2 -translate-x-1/2 border-l border-[var(--color-border-default)]"></span>`}
        <span
          class="absolute left-1/2 top-4 h-2.5 w-2.5 -translate-x-1/2 rounded-full border-2 border-[var(--color-bg-surface)] shadow-[0_0_0_1px_var(--color-border-default)]"
          style=${{ background: graphColor }}
        ></span>
      </div>
      <div class="my-1 grid min-w-0 gap-1.5 rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-page)] p-2">
        <div
          class="flex min-w-0 flex-wrap items-baseline justify-between gap-x-2 gap-y-0.5 text-3xs text-[var(--color-fg-muted)]"
          data-testid="keeper-lane-waiting-time"
        >
          ${row.since_iso == null
            ? html`<span>시각 미기록</span>`
            : html`<time dateTime=${row.since_iso}>${formatDateTimeKo(row.since_iso)}</time>`}
          ${sinceRelative == null ? null : html`<span>${sinceRelative}</span>`}
        </div>
        <div class="flex min-w-0 flex-wrap items-center gap-1.5">
          <${StatusChip} tone=${sourceTone(row.source)} uppercase=${false} title=${row.source}>${laneSourceLabel(row.source)}<//>
          <span class="min-w-0 truncate font-mono text-xs text-[var(--color-fg-primary)]" title=${row.waiting_on}>${row.waiting_on}</span>
        </div>
        <div class="flex min-w-0 items-start gap-1.5 text-2xs text-[var(--color-fg-muted)]">
          <span aria-hidden="true">↳</span>
          <span>다음 동작 · <span class="font-mono text-[var(--color-fg-secondary)]">${enumLabel(row.next_action)}</span></span>
        </div>
        ${row.due_at_iso == null
          ? null
          : html`<div class="text-2xs text-[var(--status-warn)]">실행 예정 · <time dateTime=${row.due_at_iso}>${formatDateTimeKo(row.due_at_iso)}</time> · ${formatTimeUntil(row.due_at_iso)}</div>`}
        ${actions !== null && row.source === 'event_queue_pending'
          ? html`<${LaneEventRowActions} row=${row} actions=${actions} />`
          : null}
        <details class="min-w-0 text-3xs text-[var(--color-fg-muted)]" style=${{ overflowWrap: 'anywhere' }}>
          <summary class="cursor-pointer select-none">Typed queue evidence</summary>
          <div class="mt-2 grid min-w-0 gap-2">
            <div class="flex min-w-0 flex-wrap gap-x-3">
              <span>wake producer · <code>${row.wake_producer ?? '미기록'}</code></span>
              <span>source · <code>${row.source}</code></span>
            </div>
            <${JsonViewerCard} title="detail · typed" data=${row.detail ?? {}} />
          </div>
        </details>
      </div>
    </article>
  `
}

/** Pure presentational part; tests feed it fixtures. */
export function KeeperLaneStrip({
  keeper,
  inventory,
  ready,
  loading,
  error,
  eventActions = null,
}: {
  keeper: Keeper
  inventory: DashboardKeeperWaitingInventory | null | undefined
  /** true once the keeper-scoped resource has a response body — separates
   *  "field absent from the response" from "response not fetched yet". */
  ready: boolean
  loading: boolean
  error: string | null
  /** Present only for a session admitted to the event-queue operator route;
   *  absent renders every row read-only. */
  eventActions?: LaneEventQueueActions | null
}): VNode {
  const entry = inventoryEntry(inventory, keeper)
  const rows = waitingRowsNewestFirst(entry?.waiting_on ?? [])
  const waitingCount = entry?.waiting_count ?? 0
  const countTruncated = entry?.waiting_count_truncated === true
  const truncatedSources = entry ? truncatedSourceLabels(entry) : []
  const breakdown = entry ? sourceBreakdown(entry) : []
  const rowLimit = inventory?.external_attention_row_limit
  return html`
    <div class="ctx-sec" data-testid="keeper-lane-section">
      <h4 style=${{ display: 'flex', alignItems: 'center', gap: '7px' }}>
        작업 대기열
        ${waitingCount > 0
          ? html`<${CountBadge}>${boundedCount(waitingCount, countTruncated)}<//>`
          : null}
      </h4>
      ${entry
        ? html`
            <div class="grid gap-1.5">
              <div class="flex flex-wrap items-center gap-1.5">
                <${StatusChip} tone=${stateTone(entry.state)} uppercase=${false} title=${entry.state}>${laneStateLabel(entry.state)}<//>
              </div>
              ${eventActions === null
                ? null
                : html`<${LaneEventRecoveries} actions=${eventActions} />`}
              ${rows.length > 0
                ? html`
                    <div class="grid gap-1">
                      <div class="flex flex-wrap items-center gap-2 text-3xs text-[var(--color-fg-muted)]">
                        <span class="font-semibold uppercase tracking-wide text-[var(--color-fg-secondary)]">HEAD</span>
                        <span>최신 → 오래된</span>
                      </div>
                    <div class="max-h-[30rem] overflow-y-auto pr-1" data-testid="keeper-lane-graph" aria-label="대기 시작 시각순 작업 흐름">
                      ${rows.map((row, index) => html`
                        <${LaneWaitingRow}
                          key=${`${row.source}:${row.waiting_on}:${index}`}
                          row=${row}
                          first=${index === 0}
                          last=${index === rows.length - 1}
                          actions=${eventActions}
                        />
                      `)}
                    </div>
                    </div>
                  `
                : null}
              ${countTruncated
                ? html`<div class="text-2xs text-[var(--color-fg-muted)]" data-testid="keeper-lane-truncation">
                    서버 상한${rowLimit != null ? ` ${rowLimit}` : ''}에서 잘림${truncatedSources.length > 0 ? ` — ${truncatedSources.join(', ')}` : ''}. 실제 대기 건수는 더 많습니다.
                  </div>`
                : null}
              ${breakdown.length > 0
                ? html`<div class="flex flex-wrap gap-1" data-testid="keeper-lane-sources">
                    ${breakdown.map(item => html`
                      <span
                        key=${item.source}
                        class="rounded-[var(--r-0)] bg-[var(--color-bg-hover)] px-2 py-0.5 text-2xs text-[var(--color-fg-secondary)]"
                        title=${item.source}
                      >${item.label} <span class="font-mono text-[var(--color-fg-primary)]">${item.count}</span></span>
                    `)}
                  </div>`
                : null}
            </div>
          `
        : inventory
          ? html`<${LaneGap}>waiting inventory에 이 키퍼 항목이 없습니다.<//>`
          : ready
            ? html`<${LaneGap}>서버가 keeper_waiting_inventory를 보내지 않았습니다.<//>`
            : error
              ? html`<${LaneGap}>${`대기열 응답 실패: ${error}`}<//>`
              : html`<div class="text-2xs text-[var(--color-fg-muted)]">${loading ? '레인 상태 로딩…' : '레인 상태 로딩 대기…'}</div>`}
    </div>
  `
}

/** Read this keeper's lane projection. Queue commits and reconnects
 * invalidate the shared keeper-scoped store; no periodic poll is mounted.
 * Event-queue operator actions mount only for an Admin session, the same
 * admission the `/events/operator` route enforces. */
export function KeeperLaneSection({ keeper }: { keeper: Keeper }): VNode {
  useEffect(() => {
    return subscribeKeeperWaitingInventory(keeper.name)
  }, [keeper.name])

  const current = keeperWaitingInventoryState(keeper.name)
  const eventActions = useLaneEventQueueActions(keeper.name)
  const operatorAccess = dashboardAuthAccess(shellAuthSummary.value, 'admin')
  return html`
    <${KeeperLaneStrip}
      keeper=${keeper}
      inventory=${current.inventory}
      ready=${current.ready}
      loading=${current.loading}
      error=${current.error}
      eventActions=${operatorAccess.allowed ? eventActions : null}
    />
  `
}
