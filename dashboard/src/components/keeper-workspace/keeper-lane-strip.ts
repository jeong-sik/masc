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
} from '../../api'
import { StatusChip } from '../common/status-chip'
import {
  enumLabel,
  sourceTone,
  stateTone,
} from '../tools/keeper-waiting-inventory-panel'
import { formatDateTimeKo } from '../../lib/format-time'
import { CountBadge } from '../v2/primitives-v2'
import { dashboardWsReady } from '../../dashboard-ws-state'
import {
  keeperWaitingInventoryState,
  subscribeKeeperWaitingInventory,
} from '../../keeper-waiting-inventory-store'

const LANE_STATE_LABELS: Record<string, string> = {
  idle: '대기열 비어 있음',
  busy: '현재 작업 처리 중',
  waiting: '처리 대기 중',
  deferred: '외부 완료 대기 중',
}

const LANE_SOURCE_LABELS: Record<string, string> = {
  event_queue_pending: '자율 이벤트',
  chat_queue_pending: '채팅 대기',
  chat_queue_inflight: '채팅 처리 중',
  chat_queue_recovery_required: '채팅 복구 필요',
  chat_queue_persistence_blocked: '채팅 저장 복구 필요',
  hitl_pending: '승인 대기',
  external_attention: '외부 알림',
  fusion_running: 'Fusion 실행 중',
  schedule_waiting: '예약 실행',
  turn_admission_waiting: '실행 슬롯 대기',
  turn_admission_shutdown: '종료 정리',
  operator_pending_confirm: '운영자 확인',
  read_error: '읽기 오류',
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

function LaneWaitingRow({ row }: { row: DashboardKeeperWaitingRow }): VNode {
  return html`
    <div data-testid="keeper-lane-waiting-row" class="grid gap-0.5 border-t border-[var(--color-border-subtle)] py-1.5 first:border-t-0">
      <div class="flex min-w-0 flex-wrap items-center gap-1.5">
        <${StatusChip} tone=${sourceTone(row.source)} uppercase=${false} title=${row.source}>${laneSourceLabel(row.source)}<//>
        <span class="min-w-0 truncate font-mono text-2xs text-[var(--color-fg-primary)]">${row.waiting_on}</span>
      </div>
      <div class="flex flex-wrap gap-x-3 text-2xs text-[var(--color-fg-muted)]">
        ${row.since_iso ? html`<span>since ${formatDateTimeKo(row.since_iso)}</span>` : null}
        <span>다음 동작 · <span class="font-mono">${enumLabel(row.next_action)}</span></span>
      </div>
    </div>
  `
}

/** Pure presentational part; tests feed it fixtures. */
export function KeeperLaneStrip({
  keeper,
  inventory,
  ready,
  loading,
  error,
  pushReady = false,
}: {
  keeper: Keeper
  inventory: DashboardKeeperWaitingInventory | null | undefined
  /** true once the keeper-scoped resource has a response body — separates
   *  "field absent from the response" from "response not fetched yet". */
  ready: boolean
  loading: boolean
  error: string | null
  /** Whether the authenticated dashboard WS handshake completed. */
  pushReady?: boolean
}): VNode {
  const entry = inventoryEntry(inventory, keeper)
  const rows = entry?.waiting_on ?? []
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
              ${rows.length > 0
                ? html`
                    <div class="max-h-60 overflow-y-auto">
                      ${rows.map((row, index) => html`
                        <${LaneWaitingRow} key=${`${row.source}:${row.waiting_on}:${index}`} row=${row} />
                      `)}
                    </div>
                  `
                : null}
              ${rows.length === 0
                ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${entry.state === 'busy' ? '새 작업은 현재 턴 뒤에 처리됩니다.' : '지금 기다리는 작업이 없습니다.'}</div>`
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
              ${inventory?.generated_at
                ? html`<div class="text-2xs text-[var(--color-fg-muted)]">서버 기준 ${formatDateTimeKo(inventory.generated_at)}${pushReady ? ' · WS 즉시 반영' : ''}</div>`
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

/** Read only this keeper's lane projection. Queue commits and reconnects
 * invalidate the shared keeper-scoped store; no periodic poll is mounted. */
export function KeeperLaneSection({ keeper }: { keeper: Keeper }): VNode {
  useEffect(() => {
    return subscribeKeeperWaitingInventory(keeper.name)
  }, [keeper.name])

  const current = keeperWaitingInventoryState(keeper.name)
  return html`
    <${KeeperLaneStrip}
      keeper=${keeper}
      inventory=${current.inventory}
      ready=${current.ready}
      loading=${current.loading}
      error=${current.error}
      pushReady=${dashboardWsReady.value}
    />
  `
}
