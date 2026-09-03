// Keeper Workspace — lane state section (#23507 PR-L1/L2, #29473 PR-3).
// Consume-only surface over the keeper-scoped `keeper_waiting_inventory`
// read model: per-keeper lane state (idle/busy/waiting/deferred) plus the
// waiting rows behind it, in the shape of `prototypes/keeper-v2/lanes.jsx`:
//
// - sources grouped into the stage pipeline they enter the keeper through
//   (external → schedule → queue → operator → keeper);
// - rows oldest first on a log age axis (지금 / 1시간 / 1일), bar width = age;
// - the server's operator sentence (`row.what`) by default, the raw wire
//   vocabulary (`waiting_on` / `wake_producer` / `next_action` / `detail`)
//   behind the 기술 상세 toggle.
//
// A keeper absent from the inventory renders an explicit data gap instead of
// a guessed "idle". The order is an observation order only: independent
// source queues retain their own processing authority, so no row is labelled
// as the next one to run.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper } from '../../types'
import {
  parseDashboardKeeperWaitingSource,
  type DashboardKeeperWaitingInventory,
  type DashboardKeeperWaitingKeeper,
  type DashboardKeeperWaitingRow,
  type DashboardKeeperWaitingSource,
} from '../../api'
import { StatusChip } from '../common/status-chip'
import { enumLabel, stateTone } from '../tools/keeper-waiting-inventory-panel'
import { formatDateTimeKo, formatRelativeSec, formatTimeUntil } from '../../lib/format-time'
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

const LANE_SOURCE_LABELS: Record<DashboardKeeperWaitingSource, string> = {
  event_queue_pending: '자율 이벤트',
  chat_operation_queued: '채팅 대기',
  chat_operation_running: '채팅 처리 중',
  hitl_pending: '승인 대기',
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
  fusion_running: 'var(--status-ok)',
  schedule_waiting: 'var(--status-warn)',
  owner_shutdown: 'var(--color-fg-muted)',
  operator_pending_confirm: 'var(--status-warn)',
  read_error: 'var(--color-danger)',
}

/** The stage a source enters the keeper through. The pipeline reads left to
 *  right in this order; each source has exactly one stage. */
type LaneStage = 'external' | 'schedule' | 'queue' | 'operator' | 'keeper'

const LANE_STAGES: readonly LaneStage[] = ['external', 'schedule', 'queue', 'operator', 'keeper']

const LANE_STAGE_LABELS: Record<LaneStage, { label: string; wire: string }> = {
  external: { label: '외부 자극', wire: 'connector · attention store' },
  schedule: { label: '예약', wire: 'schedule_runner' },
  queue: { label: '큐', wire: 'keeper_event_queue' },
  operator: { label: '운영자', wire: 'hitl · console' },
  keeper: { label: 'keeper', wire: 'turn 실행' },
}

const LANE_SOURCE_STAGE: Record<DashboardKeeperWaitingSource, LaneStage> = {
  event_queue_pending: 'queue',
  chat_operation_queued: 'queue',
  chat_operation_running: 'keeper',
  hitl_pending: 'operator',
  fusion_running: 'keeper',
  schedule_waiting: 'schedule',
  owner_shutdown: 'keeper',
  operator_pending_confirm: 'operator',
  read_error: 'queue',
}

const SECONDS_PER_MINUTE = 60
const HOUR_MINUTES = 60
export const DAY_MINUTES = 24 * HOUR_MINUTES
/** A bar never shrinks below this so a fresh row stays clickable. */
const MIN_BAR_PERCENT = 6

function laneStateLabel(value: string): string {
  return LANE_STATE_LABELS[value] ?? enumLabel(value)
}

function laneSourceLabel(value: string): string {
  const source = parseDashboardKeeperWaitingSource(value)
  return source === null ? enumLabel(value) : LANE_SOURCE_LABELS[source]
}

function inventoryEntry(
  inventory: DashboardKeeperWaitingInventory | null | undefined,
  keeper: Keeper,
): DashboardKeeperWaitingKeeper | null {
  if (!inventory) return null
  return inventory.keepers.find(k => k.keeper_name === keeper.name) ?? null
}

function LaneGap({ children }: { children: VNode | string }): VNode {
  return html`
    <div class="ctx-empty" data-missing="keeper-lane">
      <strong>레인 상태 미수신</strong>
      <span>${children}</span>
    </div>
  `
}

function rowSince(row: DashboardKeeperWaitingRow): number | null {
  if (row.since != null && Number.isFinite(row.since)) return row.since
  if (row.since_iso == null) return null
  const parsed = Date.parse(row.since_iso)
  return Number.isFinite(parsed) ? parsed / 1000 : null
}

/** Oldest observation first. Equal/missing timestamps keep their server order,
 * and missing timestamps stay visible at the end. */
export function waitingRowsOldestFirst(rows: readonly DashboardKeeperWaitingRow[]): DashboardKeeperWaitingRow[] {
  return rows
    .map((row, serverIndex) => ({ row, serverIndex, since: rowSince(row) }))
    .sort((left, right) => {
      if (left.since == null && right.since == null) return left.serverIndex - right.serverIndex
      if (left.since == null) return 1
      if (right.since == null) return -1
      return left.since - right.since || left.serverIndex - right.serverIndex
    })
    .map(({ row }) => row)
}

export function ageMinutes(row: DashboardKeeperWaitingRow, nowMs: number): number | null {
  const since = rowSince(row)
  if (since == null) return null
  return Math.max(0, (nowMs / 1000 - since) / SECONDS_PER_MINUTE)
}

/** Log position on the age axis: a 2-minute and a 3-day row both stay
 *  readable on one strip. `axisMax` is the axis end in minutes. */
function axisPosition(minutes: number, axisMax: number): number {
  return Math.min(100, (Math.log10(1 + minutes) / Math.log10(1 + axisMax)) * 100)
}

interface StageItem {
  source: string
  label: string
  count: string
  color: string | null
}

/** Per-stage source counts, each marked with the server's own per-source
 *  Sorted by count so the source driving the stage reads
 *  first. A key outside the closed source vocabulary is kept visible under
 *  `unknown` rather than filed into a stage it was never assigned. */
function stageBreakdown(entry: DashboardKeeperWaitingKeeper): {
  byStage: Record<LaneStage, StageItem[]>
  unknown: StageItem[]
} {
  const byStage: Record<LaneStage, StageItem[]> = {
    external: [],
    schedule: [],
    queue: [],
    operator: [],
    keeper: [],
  }
  const unknown: StageItem[] = []
  Object.entries(entry.sources ?? {})
    .sort(([, a], [, b]) => b - a)
    .forEach(([key, count]) => {
      const source = parseDashboardKeeperWaitingSource(key)
      const item: StageItem = {
        source: key,
        label: laneSourceLabel(key),
        count: String(count),
        color: source === null ? null : LANE_SOURCE_GRAPH_COLORS[source],
      }
      if (source === null) unknown.push(item)
      else byStage[LANE_SOURCE_STAGE[source]].push(item)
    })
  return { byStage, unknown }
}

function StageItems({ items, dev }: { items: StageItem[]; dev: boolean }): VNode {
  return html`${items.map(item => html`
    <div
      key=${item.source}
      class="flex items-baseline gap-1.5 border-l-2 border-[var(--color-border-default)] pl-1.5 text-2xs text-[var(--color-fg-secondary)]"
      style=${item.color === null ? null : { borderLeftColor: item.color }}
      title=${item.source}
    ><span>${dev ? item.source : item.label}</span><b class="ml-auto font-mono font-normal text-[var(--color-fg-primary)]">${item.count}</b></div>
  `)}`
}

function LanePipeline({ entry, dev }: { entry: DashboardKeeperWaitingKeeper; dev: boolean }): VNode {
  const { byStage, unknown } = stageBreakdown(entry)
  const stageBox = (active: boolean) =>
    `flex min-w-[7rem] flex-1 flex-col gap-1 rounded-[var(--r-0)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-page)] px-2 py-1.5 ${active ? '' : 'opacity-50'}`
  return html`
    <div class="flex items-stretch gap-1.5 overflow-x-auto pb-0.5" data-testid="keeper-lane-pipeline" aria-label="자극이 keeper 에 닿는 단계">
      ${LANE_STAGES.map((stage, index) => {
        const items = byStage[stage]
        const active = items.length > 0
        return html`
          ${index === 0 ? null : html`<span class=${`self-center text-xs ${active ? 'text-[var(--color-fg-muted)]' : 'text-[var(--color-border-default)]'}`} aria-hidden="true">→</span>`}
          <div key=${stage} class=${stageBox(active)} data-stage=${stage} data-active=${active ? 'true' : 'false'}>
            <div class="grid gap-px">
              <b class="text-3xs font-medium uppercase tracking-wide text-[var(--color-fg-secondary)]">${LANE_STAGE_LABELS[stage].label}</b>
              ${dev ? html`<span class="font-mono text-3xs text-[var(--color-fg-muted)]">${LANE_STAGE_LABELS[stage].wire}</span>` : null}
            </div>
            ${active
              ? html`<${StageItems} items=${items} dev=${dev} />`
              : html`<div class="text-2xs text-[var(--color-fg-muted)]">—</div>`}
          </div>
        `
      })}
      ${unknown.length === 0
        ? null
        : html`
            <div class=${stageBox(true)} data-stage="unknown" data-active="true">
              <div class="grid gap-px">
                <b class="text-3xs font-medium uppercase tracking-wide text-[var(--status-warn)]">미분류 source</b>
              </div>
              <${StageItems} items=${unknown} dev=${true} />
            </div>
          `}
    </div>
  `
}

export function LaneAgeAxis({ axisMax }: { axisMax: number }): VNode {
  const ticks: Array<{ label: string; at: number }> = [
    { label: '지금', at: 0 },
    { label: '1시간', at: axisPosition(HOUR_MINUTES, axisMax) },
    { label: '1일', at: axisPosition(DAY_MINUTES, axisMax) },
  ]
  // The axis end is labelled only once it reads differently from the 1일
  // tick, which already sits near the edge for a one-to-two-day axis.
  const edgeDays = Math.round(axisMax / DAY_MINUTES)
  if (edgeDays >= 2) {
    ticks.push({ label: `${edgeDays}일`, at: 100 })
  }
  return html`
    <div class="relative h-4 border-b border-dashed border-[var(--color-border-default)] font-mono text-3xs text-[var(--color-fg-muted)]" data-testid="keeper-lane-age-axis" aria-hidden="true">
      ${ticks.map(tick => html`
        <span
          key=${tick.label}
          class="absolute top-0 whitespace-nowrap"
          style=${{
            left: `${tick.at}%`,
            transform: tick.at === 0 ? 'none' : tick.at === 100 ? 'translateX(-100%)' : 'translateX(-50%)',
          }}
          data-axis-tick=${tick.label}
        >${tick.label}</span>
      `)}
    </div>
  `
}

export function LaneWaitingRow({
  row,
  age,
  axisMax,
  dev,
  actions,
}: {
  row: DashboardKeeperWaitingRow
  /** Minutes waited, or null when the server recorded no timestamp. */
  age: number | null
  axisMax: number
  dev: boolean
  /** Admin operator actions; null renders the row read-only. */
  actions: LaneEventQueueActions | null
}): VNode {
  const graphColor = LANE_SOURCE_GRAPH_COLORS[row.source]
  const width = age == null ? MIN_BAR_PERCENT : Math.max(MIN_BAR_PERCENT, axisPosition(age, axisMax))
  const ageText = age == null ? '시각 미기록' : formatRelativeSec(age * SECONDS_PER_MINUTE)
  const reading = dev ? row.waiting_on : row.what
  return html`
    <details
      data-testid="keeper-lane-waiting-row"
      data-source=${row.source}
      data-waiting-on=${row.waiting_on}
      class="grid min-w-0 gap-1"
    >
      <summary
        class="flex min-w-0 cursor-pointer list-none items-center gap-2 rounded-[var(--r-0)] border border-[var(--color-border-subtle)] border-l-[3px] bg-[var(--color-bg-page)] px-2 py-1 hover:bg-[var(--color-bg-hover)] [&::-webkit-details-marker]:hidden"
        style=${{ width: `${width}%`, borderLeftColor: graphColor }}
        data-testid="keeper-lane-waiting-bar"
        title=${dev ? row.what : row.waiting_on}
      >
        <span class="whitespace-nowrap text-2xs text-[var(--color-fg-secondary)]">${laneSourceLabel(row.source)}</span>
        <span class=${`min-w-0 truncate text-xs text-[var(--color-fg-primary)] ${dev ? 'font-mono' : ''}`} data-testid="keeper-lane-waiting-what">${reading}</span>
        <span class="ml-auto whitespace-nowrap font-mono text-3xs text-[var(--color-fg-muted)]">${ageText}</span>
      </summary>
      <div class="grid min-w-0 gap-1.5 rounded-[var(--r-0)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] px-2 py-1.5 text-2xs text-[var(--color-fg-muted)]" style=${{ overflowWrap: 'anywhere' }}>
        <div class="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-0.5" data-testid="keeper-lane-waiting-time">
          <span class="text-[var(--color-fg-secondary)]">${reading}</span>
          ${row.since_iso == null
            ? html`<span>시각 미기록</span>`
            : html`<span>대기 시작 · <time dateTime=${row.since_iso}>${formatDateTimeKo(row.since_iso)}</time></span>`}
          ${row.due_at_iso == null
            ? null
            : html`<span class="text-[var(--status-warn)]">실행 예정 · <time dateTime=${row.due_at_iso}>${formatDateTimeKo(row.due_at_iso)}</time> · ${formatTimeUntil(row.due_at_iso)}</span>`}
          ${dev
            ? html`
                <span>source · <code>${row.source}</code></span>
                <span>wake · <code>${row.wake_producer ?? '미기록'}</code></span>
                <span>다음 동작 · <code>${row.next_action}</code></span>
              `
            : null}
        </div>
        ${actions !== null && row.source === 'event_queue_pending'
          ? html`<${LaneEventRowActions} row=${row} actions=${actions} />`
          : null}
        ${dev ? html`<${JsonViewerCard} title="detail · typed" data=${row.detail ?? {}} />` : null}
      </div>
    </details>
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
  const [dev, setDev] = useState(false)
  const entry = inventoryEntry(inventory, keeper)
  const rows = waitingRowsOldestFirst(entry?.waiting_on ?? [])
  const nowMs = Date.now()
  const ages = rows.map(row => ageMinutes(row, nowMs))
  const axisMax = Math.max(DAY_MINUTES, ...ages.filter((age): age is number => age != null))
  const waitingCount = entry?.waiting_count ?? 0
  return html`
    <div class="ctx-sec" data-testid="keeper-lane-section">
      <h4 style=${{ display: 'flex', alignItems: 'center', gap: '7px' }}>
        작업 대기열
        ${waitingCount > 0
          ? html`<${CountBadge}>${waitingCount}<//>`
          : null}
        <button
          type="button"
          class=${`ml-auto rounded-[var(--r-0)] border px-1.5 py-0.5 text-3xs font-normal ${dev ? 'border-[var(--color-accent)] text-[var(--color-accent-fg)]' : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'}`}
          aria-pressed=${dev}
          title="내부 식별자 · 원본 필드 표시"
          data-testid="keeper-lane-dev-toggle"
          onClick=${() => setDev(current => !current)}
        >기술 상세</button>
      </h4>
      ${entry
        ? html`
            <div class="grid gap-1.5">
              <div class="flex flex-wrap items-center gap-1.5">
                <${StatusChip} tone=${stateTone(entry.state)} uppercase=${false} title=${entry.state}>${laneStateLabel(entry.state)}<//>
              </div>
              ${Object.keys(entry.sources ?? {}).length > 0
                ? html`<${LanePipeline} entry=${entry} dev=${dev} />`
                : null}
              ${eventActions === null
                ? null
                : html`<${LaneEventRecoveries} actions=${eventActions} />`}
              ${rows.length > 0
                ? html`
                    <div class="grid gap-1">
                      <div class="font-mono text-3xs uppercase tracking-wide text-[var(--color-fg-muted)]">오래 기다린 순서</div>
                      <${LaneAgeAxis} axisMax=${axisMax} />
                      <div class="grid max-h-[30rem] gap-1 overflow-y-auto pr-1" data-testid="keeper-lane-graph" aria-label="대기 나이순 작업 흐름">
                        ${rows.map((row, index) => html`
                          <${LaneWaitingRow}
                            key=${`${row.source}:${row.waiting_on}:${index}`}
                            row=${row}
                            age=${ages[index] ?? null}
                            axisMax=${axisMax}
                            dev=${dev}
                            actions=${eventActions}
                          />
                        `)}
                      </div>
                    </div>
                  `
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
