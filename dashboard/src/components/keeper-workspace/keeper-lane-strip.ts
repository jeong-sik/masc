// Keeper Workspace — lane state section (#23507 PR-L1/L2, slice 1).
// Consume-only surface over the already-served `keeper_waiting_inventory`
// (`GET /api/v1/dashboard/tools`, same shared resource the Tools/Schedule
// surfaces read): per-keeper lane state (idle/busy/waiting/deferred) plus
// the waiting rows behind it. State strings and rows render exactly as the
// server sent them — no client-side judgement — and a keeper absent from
// the inventory renders an explicit data gap instead of a guessed "idle".

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper } from '../../types'
import type {
  DashboardKeeperWaitingInventory,
  DashboardKeeperWaitingKeeper,
  DashboardKeeperWaitingRow,
} from '../../api'
import {
  KEEPER_WAITING_INVENTORY_REFRESH_MS,
  subscribeToolsAutoRefresh,
  toolsData,
  toolsError,
  toolsLoading,
} from '../tools/tool-state'
import { StatusChip } from '../common/status-chip'
import {
  enumLabel,
  sourceTone,
  stateTone,
} from '../tools/keeper-waiting-inventory-panel'
import { formatDateTimeKo } from '../../lib/format-time'
import { formatAutoRefreshLabel } from '../../lib/auto-refresh'
import { CountBadge } from '../v2/primitives-v2'

const LANE_ROW_LIMIT = 3

// The strip mirrors a heavy server-side aggregation (per-keeper event-queue,
// turn-admission, external-attention, HITL, schedule scans). It is refreshed
// by polling — not server push — while the keeper detail is open, so a busy
// fleet does not pay that aggregation on every event. 15s is tighter than the
// 30s shared panel default because this is the live "what is this keeper
// waiting on right now" surface; setupVisibleAutoRefresh still pauses when the
// tab is hidden and refreshes immediately on focus/return.
const LANE_REFRESH_MS = KEEPER_WAITING_INVENTORY_REFRESH_MS

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

function LaneWaitingRow({ row }: { row: DashboardKeeperWaitingRow }): VNode {
  return html`
    <div class="grid gap-0.5 border-t border-[var(--color-border-subtle)] py-1.5 first:border-t-0">
      <div class="flex min-w-0 flex-wrap items-center gap-1.5">
        <${StatusChip} tone=${sourceTone(row.source)} uppercase=${false}>${enumLabel(row.source)}<//>
        <span class="min-w-0 truncate font-mono text-2xs text-[var(--color-fg-primary)]">${row.waiting_on}</span>
      </div>
      <div class="flex flex-wrap gap-x-3 text-2xs text-[var(--color-fg-muted)]">
        ${row.since_iso ? html`<span>since ${formatDateTimeKo(row.since_iso)}</span>` : null}
        <span class="font-mono">${enumLabel(row.next_action)}</span>
      </div>
    </div>
  `
}

/** Pure presentational part — container feeds it from the shared tools
 *  resource; tests feed it fixtures. */
export function KeeperLaneStrip({
  keeper,
  inventory,
  ready,
  loading,
  error,
  autoRefreshMs,
}: {
  keeper: Keeper
  inventory: DashboardKeeperWaitingInventory | null | undefined
  /** true once the shared tools resource has a response body — separates
   *  "field absent from the response" from "response not fetched yet". */
  ready: boolean
  loading: boolean
  error: string | null
  /** when set, the container polls at this cadence — shown next to the
   *  snapshot time so the operator knows the panel refreshes on its own. */
  autoRefreshMs?: number
}): VNode {
  const entry = inventoryEntry(inventory, keeper)
  const rows = (entry?.waiting_on ?? []).slice(0, LANE_ROW_LIMIT)
  const waitingCount = entry?.waiting_count ?? 0
  return html`
    <div class="ctx-sec" data-testid="keeper-lane-section">
      <h4 style=${{ display: 'flex', alignItems: 'center', gap: '7px' }}>
        레인
        ${waitingCount > 0 ? html`<${CountBadge}>${waitingCount}<//>` : null}
      </h4>
      ${entry
        ? html`
            <div class="grid gap-1.5">
              <div class="flex flex-wrap items-center gap-1.5">
                <${StatusChip} tone=${stateTone(entry.state)} uppercase=${false}>${enumLabel(entry.state)}<//>
                ${entry.next_action
                  ? html`<span class="font-mono text-2xs text-[var(--color-fg-muted)]">${enumLabel(entry.next_action)}</span>`
                  : null}
              </div>
              ${rows.length > 0
                ? html`
                    <div>
                      ${rows.map((row, index) => html`
                        <${LaneWaitingRow} key=${`${row.source}:${row.waiting_on}:${index}`} row=${row} />
                      `)}
                      ${waitingCount > rows.length
                        ? html`<div class="pt-1 text-2xs text-[var(--color-fg-muted)]">+${waitingCount - rows.length} more</div>`
                        : null}
                    </div>
                  `
                : null}
              ${inventory?.generated_at
                ? html`<div class="text-2xs text-[var(--color-fg-muted)]">기준 ${formatDateTimeKo(inventory.generated_at)}${autoRefreshMs ? html` · ${formatAutoRefreshLabel(autoRefreshMs)}` : null}</div>`
                : autoRefreshMs
                  ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${formatAutoRefreshLabel(autoRefreshMs)}</div>`
                  : null}
            </div>
          `
        : inventory
          ? html`<${LaneGap}>waiting inventory에 이 키퍼 항목이 없습니다.<//>`
          : ready
            ? html`<${LaneGap}>서버가 keeper_waiting_inventory를 보내지 않았습니다.<//>`
            : error
              ? html`<${LaneGap}>${`tools 응답 실패: ${error}`}<//>`
              : html`<div class="text-2xs text-[var(--color-fg-muted)]">${loading ? '레인 상태 로딩…' : '레인 상태 로딩 대기…'}</div>`}
    </div>
  `
}

/** Container: reads the shared tools resource, loads it once if absent, and
 *  keeps it live while mounted by polling on a visibility-aware interval
 *  (paused when the tab is hidden, refreshed immediately on focus/return).
 *  The shared resource is stale-while-revalidate, so each refetch swaps the
 *  inventory in place without flashing a loading gap. */
export function KeeperLaneSection({ keeper }: { keeper: Keeper }): VNode {
  useEffect(() => {
    return subscribeToolsAutoRefresh()
  }, [])
  return html`
    <${KeeperLaneStrip}
      keeper=${keeper}
      inventory=${toolsData.value?.keeper_waiting_inventory ?? null}
      ready=${toolsData.value != null}
      loading=${toolsLoading.value}
      error=${toolsError.value}
      autoRefreshMs=${LANE_REFRESH_MS}
    />
  `
}
