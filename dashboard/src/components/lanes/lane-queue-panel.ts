// Lane · Queue panel — the lanes.jsx Monitor surface, wired to live data.
//
//   · 진행 타임라인 (sw-*): composite observations accumulated from the fleet
//     composite stream/poll (`fetchKeepersComposite`, one call for the whole
//     roster — the same payload fleet-fsm-matrix.ts consumes), clipped to the
//     design's 20-minute window. Buffers accumulate while the panel is
//     mounted, exactly like the FSM hub's SwimlaneTimeline.
//   · 무엇을 기다리는가 (pl-*/wa-*): keeper_waiting_inventory.v3 via the
//     shared keeper-scoped store (subscribeKeeperWaitingInventory) — one
//     subscription per tab keeper, push-invalidated, no local polling.
//   · 기동 · 재시작 기록 (lc-*): /api/v1/keepers/:name/lifecycle (30 events).
//   · 예약 실행 결과 (dl-*/dm-*): the scheduled-automation projection's
//     keeper_queue_evidence × keeper_reaction_evidence rows; the miss count
//     reuses countQueueDrainMisses from schedule/queue-drain-status.ts.
//
// "기술 상세" toggle follows the design: wire names (source / wake_producer /
// next_action / evidence statuses) only appear behind it.

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { signal } from '@preact/signals'
import type { VNode } from 'preact'

import { keepers } from '../../store'
import { fleetCompositeSnapshot } from '../../composite-signals'
import {
  fetchKeeperLifecycle,
  fetchKeepersComposite,
  type KeeperLifecycleEvent,
} from '../../api/keeper'
import type { FleetCompositeSnapshot, KeeperCompositeSnapshot } from '../../api/schemas/keeper-composite'
import type {
  DashboardKeeperWaitingInventory,
  DashboardKeeperWaitingKeeper,
} from '../../api'
import {
  appendCompositeObservation,
  deriveSwimlaneSegments,
  observeSnapshot,
} from '../fsm-hub-derivations'
import type { CompositeObservation, LaneKey } from '../fsm-hub-types'
import {
  keeperWaitingInventoryStates,
  subscribeKeeperWaitingInventory,
} from '../../keeper-waiting-inventory-store'
import {
  scheduledAutomation,
  subscribeScheduledAutomationRefresh,
} from '../schedule/schedule-state'
import { countQueueDrainMisses } from '../schedule/queue-drain-status'
import { nowSecondsSignal, useNowSecondsTicker } from '../../lib/now-signal'
import { formatTimeHmMs } from '../../lib/format-time'
import { CountBadge } from '../v2/primitives-v2'

import {
  DRAIN_LEGEND_STATES,
  DRAIN_PRESENT,
  DRAIN_QUEUE_AXIS,
  DRAIN_REACTION_AXIS,
  LANE_QUEUE_LANES,
  LANE_QUEUE_MAX_OBSERVATIONS,
  LANE_QUEUE_WINDOW_S,
  LANE_STAGES,
  LANE_STAGE_LABELS,
  drainStateOfEvidence,
  laneAgoText,
  laneLifecycleItemOf,
  laneReading,
  laneSecText,
  laneStageBreakdown,
  laneStatePresent,
  laneSourceLabel,
  laneSourceTone,
  laneUntilText,
  laneValueLabel,
  laneValueTone,
  positionLaneSegments,
  sortedDrainRows,
  waitAxisMaxMinutes,
  waitAxisPosition,
  waitingAgeMinutes,
  waitingDueMinutes,
  waitingRowsOldestFirst,
  type DrainEvidenceRow,
  type LaneQueueSegment,
} from './lane-queue-model'

const MIN_BAR_PERCENT = 6
/** Design renders the in-segment value label once the segment is ≥ 8.5% of
 *  the window (lanes.jsx `(s.d / WINDOW_S) >= 0.085`). */
const SEGMENT_LABEL_MIN_PCT = 8.5
const LIFECYCLE_EVENT_LIMIT = 30
const FLEET_POLL_MS = 30_000

/* ── Observation buffers (module-level so tab switches keep history) ───── */

const laneObservationBuffers = signal<Record<string, CompositeObservation[]>>({})
const laneLatestSnapshots = signal<Record<string, KeeperCompositeSnapshot>>({})

/** Test hook — drop accumulated buffers/snapshots between cases. */
export function resetLaneQueueObservations(): void {
  laneObservationBuffers.value = {}
  laneLatestSnapshots.value = {}
}

function snapshotName(snapshot: KeeperCompositeSnapshot): string | null {
  if (typeof snapshot.keeper === 'string' && snapshot.keeper !== '') return snapshot.keeper
  return snapshot.correlation_id !== '' ? snapshot.correlation_id : null
}

/** Fold every keeper in a fleet snapshot into the per-keeper observation
 *  buffers. appendCompositeObservation dedupes unchanged values, so a poll
 *  that returns the same states does not fabricate transitions. */
export function ingestLaneQueueFleetSnapshot(snapshot: FleetCompositeSnapshot | null): void {
  if (!snapshot) return
  const fallbackTs = nowSecondsSignal.value
  let buffersChanged = false
  const nextBuffers = { ...laneObservationBuffers.value }
  const nextSnapshots = { ...laneLatestSnapshots.value }
  for (const snap of snapshot.snapshots) {
    const name = snapshotName(snap)
    if (!name) continue
    const previous = nextBuffers[name] ?? []
    const ts = typeof snap.ts === 'number' && snap.ts > 0 ? snap.ts : fallbackTs
    const merged = appendCompositeObservation(previous, observeSnapshot(snap, ts), LANE_QUEUE_MAX_OBSERVATIONS)
    if (merged !== previous) {
      nextBuffers[name] = merged
      buffersChanged = true
    }
    nextSnapshots[name] = snap
  }
  laneObservationBuffers.value = buffersChanged ? nextBuffers : laneObservationBuffers.value
  laneLatestSnapshots.value = nextSnapshots
}

/* ── 스윔레인 ─────────────────────────────────────────────────────────── */

interface HoverState extends LaneQueueSegment {
  lane: LaneKey
}

function LaneSwimlane({
  observations,
  live,
  focus,
  onFocus,
  dev,
  nowSec,
}: {
  observations: readonly CompositeObservation[]
  live: boolean
  focus: LaneKey
  onFocus: (key: LaneKey) => void
  dev: boolean
  nowSec: number
}): VNode {
  const [hover, setHover] = useState<HoverState | null>(null)
  if (observations.length === 0) {
    return html`
      <div class="lq-gap" data-testid="lane-swimlane-gap">
        <b>기록 없음</b>
        <span>composite 스냅샷 스트림이 이 keeper 를 아직 관측하지 않았습니다.</span>
      </div>
    `
  }
  if (observations.length < 2) {
    return html`
      <div class="lq-gap" data-testid="lane-swimlane-gap">
        <b>관측 수집 중</b>
        <span>스냅샷이 2회 이상 쌓이면 ${LANE_QUEUE_LANES.length}개 레인의 시간 흐름이 표시됩니다.</span>
      </div>
    `
  }
  const windowEnd = nowSec
  const windowStart = nowSec - LANE_QUEUE_WINDOW_S
  const ticks = [1200, 900, 600, 300, 0]
  return html`
    <div class="sw">
      <div class="sw-axis">
        <span class="sw-axis-pad"></span>
        <div class="sw-axis-track">
          ${ticks.map(t => html`
            <span key=${t} class="sw-tick" style=${{ left: `${(1 - t / LANE_QUEUE_WINDOW_S) * 100}%` }}>
              ${t === 0 ? 'now' : `-${t / 60}m`}
            </span>
          `)}
        </div>
      </div>
      ${LANE_QUEUE_LANES.map(lane => {
        const segments = positionLaneSegments(
          deriveSwimlaneSegments(observations as CompositeObservation[], lane.key, windowEnd),
          windowStart,
          windowEnd,
        )
        const now = laneReading(observations, lane.key, live, nowSec)
        return html`
          <div
            key=${lane.key}
            class="sw-row ${focus === lane.key ? 'on' : ''}"
            data-testid="lane-swimlane-row"
            data-lane=${lane.key}
            onClick=${() => onFocus(lane.key)}
          >
            <div class="sw-lbl">
              <span>${dev ? lane.devLabel : lane.label}</span>
              ${dev ? html`<span class="sw-field mono">${lane.field}</span>` : null}
            </div>
            <div class="sw-track">
              ${segments.map((seg, index) => html`
                <span
                  key=${index}
                  class="sw-seg ${seg.clipped ? 'clip' : ''} ${seg.last && now?.stalled ? 'stall' : ''}"
                  data-tone=${laneValueTone(seg.value)}
                  style=${{ left: `${seg.leftPct}%`, width: `${seg.widthPct}%` }}
                  onMouseEnter=${() => setHover({ lane: lane.key, ...seg })}
                  onMouseLeave=${() => setHover(null)}
                  title=${`${dev ? seg.value : laneValueLabel(seg.value)} · ${laneSecText(seg.durSec)}${seg.clipped ? ' (창 이전부터 계속)' : ''}`}
                >
                  ${seg.widthPct >= SEGMENT_LABEL_MIN_PCT
                    ? html`<b class="sw-seg-v ${dev ? 'mono' : ''}">${dev ? seg.value : laneValueLabel(seg.value)}</b>`
                    : null}
                </span>
              `)}
              ${now?.stalled
                ? html`<span class="sw-stallmark" title="정체 임계 초과">정체 ${laneSecText(now.observedForSec)}</span>`
                : null}
            </div>
          </div>
        `
      })}
      ${hover
        ? html`
            <div class="sw-foot">
              <b class="${dev ? 'mono' : ''}">${dev ? hover.value : laneValueLabel(hover.value)}</b>
              ${' · '}${laneSecText(hover.durSec)} 유지${hover.clipped ? ' · 이전부터 계속' : ''}
            </div>
          `
        : null}
    </div>
  `
}

/* ── 큐 파이프라인 (pl-*) ─────────────────────────────────────────────── */

function LanePipeline({ entry, dev }: { entry: DashboardKeeperWaitingKeeper; dev: boolean }): VNode {
  const { byStage, unknown } = laneStageBreakdown(entry)
  return html`
    <div class="pl" data-testid="lane-pipeline">
      ${LANE_STAGES.map((stage, index) => {
        const items = byStage[stage]
        return html`
          ${index > 0 ? html`<span class="pl-arrow ${items.length ? 'on' : ''}" aria-hidden="true">→</span>` : null}
          <div key=${stage} class="pl-stage ${items.length ? 'on' : ''}" data-stage=${stage}>
            <div class="pl-stage-h">
              <b>${LANE_STAGE_LABELS[stage].label}</b>
              ${dev ? html`<span class="mono">${LANE_STAGE_LABELS[stage].wire}</span>` : null}
            </div>
            ${items.length
              ? items.map(item => html`
                  <div key=${item.source} class="pl-item" data-tone=${item.tone}>
                    <span>${dev ? item.source : item.label}</span><b class="mono">${item.count}</b>
                  </div>
                `)
              : html`<div class="pl-empty">—</div>`}
          </div>
        `
      })}
    </div>
    ${unknown.length
      ? html`
          <div>
            <div class="lq-sec-sub">미분류 source</div>
            ${unknown.map(item => html`
              <div key=${item.source} class="pl-item" data-tone=${item.tone}>
                <span class="mono">${item.source}</span><b class="mono">${item.count}</b>
              </div>
            `)}
          </div>
        `
      : null}
  `
}

/* ── 대기 나이 축 (wa-*) ──────────────────────────────────────────────── */

function WaitAges({
  entry,
  dev,
  nowSec,
}: {
  entry: DashboardKeeperWaitingKeeper
  dev: boolean
  nowSec: number
}): VNode {
  const [open, setOpen] = useState<number | null>(null)
  const rows = waitingRowsOldestFirst(entry.waiting_on ?? [])
  if (rows.length === 0) {
    return html`<div class="lq-gap"><b>기다리는 작업 없음</b></div>`
  }
  const ages = rows.map(row => waitingAgeMinutes(row, nowSec))
  const axisMax = waitAxisMaxMinutes(ages)
  return html`
    <div class="wa">
      <div class="wa-scale"><span>지금</span><span>1시간</span><span>1일+</span></div>
      ${rows.map((row, index) => {
        const age = ages[index] ?? null
        const dueMinutes = waitingDueMinutes(row, nowSec)
        const on = open === index
        const width = age == null ? MIN_BAR_PERCENT : Math.max(MIN_BAR_PERCENT, waitAxisPosition(age, axisMax))
        const reading = dev ? row.waiting_on : row.what
        return html`
          <div key=${`${row.source}:${row.waiting_on}:${index}`} class="wa-row" data-tone=${laneSourceTone(row.source)} data-testid="lane-wait-row">
            <button
              type="button"
              class="wa-bar"
              aria-expanded=${on}
              onClick=${() => setOpen(on ? null : index)}
              style=${{ width: `${width}%` }}
            >
              <span class="wa-src">${laneSourceLabel(row.source)}</span>
              <span class="wa-on ${dev ? 'mono' : ''}" title=${row.waiting_on}>${reading}</span>
              <span class="wa-age mono">${laneAgoText(age)}</span>
            </button>
            ${on
              ? html`
                  <div class="wa-detail">
                    <div class="wa-meta">
                      <span>${reading}</span>
                      ${dueMinutes != null
                        ? html`<span class="warn">실행 예정 · ${laneUntilText(dueMinutes)}</span>`
                        : null}
                      ${dev ? html`<span>wake · <b class="mono">${row.wake_producer ?? '미기록'}</b></span>` : null}
                      ${dev ? html`<span>다음 동작 · <b class="mono">${row.next_action}</b></span>` : null}
                    </div>
                    ${dev
                      ? html`<pre class="mono">${JSON.stringify({ source: row.source, wake_producer: row.wake_producer ?? null, detail: row.detail ?? null }, null, 2)}</pre>`
                      : null}
                  </div>
                `
              : null}
          </div>
        `
      })}
    </div>
  `
}

/* ── 라이프사이클 이벤트 (lc-*) ───────────────────────────────────────── */

function LaneLifecycleEvents({
  events,
  loading,
  error,
  dev,
  nowSec,
}: {
  events: readonly KeeperLifecycleEvent[] | null
  loading: boolean
  error: string | null
  dev: boolean
  nowSec: number
}): VNode {
  if (error) {
    return html`<div class="lq-gap"><b>기록 읽기 실패</b><span>${error}</span></div>`
  }
  if (events === null) {
    return html`<div class="lq-gap"><b>${loading ? '기록 읽는 중…' : '기록 읽기 대기…'}</b></div>`
  }
  if (events.length === 0) {
    return html`<div class="lq-gap"><b>기동 · 재시작 기록 없음</b></div>`
  }
  return html`
    <div class="lc">
      ${events.map((event, index) => {
        const item = laneLifecycleItemOf(event, nowSec)
        return html`
          <div key=${`${event.ts}:${index}`} class="lc-row" data-tone=${item.tone} data-testid="lane-lifecycle-row">
            <span class="lc-dot" aria-hidden="true"></span>
            <span class="lc-ev">${item.label}</span>
            <span class="lc-phase mono">${item.phase ?? '—'}</span>
            <span class="lc-detail" title=${item.detail}>
              ${dev ? `${item.event}${item.detail ? ` · ${item.detail}` : ''}` : (item.detail || item.label)}
            </span>
            <span class="lc-ago mono">${laneAgoText(item.ageMinutes)}</span>
          </div>
        `
      })}
    </div>
  `
}

/* ── 예약 wake 드레인 (dl-* / dm-*) ───────────────────────────────────── */

function DrainList({ rows }: { rows: readonly DrainEvidenceRow[] }): VNode {
  if (rows.length === 0) {
    return html`
      <div class="lq-gap" data-testid="lane-drain-gap">
        <b>예약 wake 기록 없음</b>
        <span>keeper queue 증거를 가진 예약 실행이 아직 없습니다.</span>
      </div>
    `
  }
  return html`
    <div class="dl">
      ${rows.map(row => {
        const present = DRAIN_PRESENT[row.state]
        return html`
          <div key=${row.scheduleId} class="dl-row" data-tone=${present.tone} data-testid="lane-drain-row" data-state=${row.state}>
            <span class="lq-chip" data-tone=${present.tone} title=${present.op}>${present.label}</span>
            <span class="dl-payload">${row.payload}</span>
            <span class="dl-keeper mono">${row.keeper ?? '—'}</span>
            <span class="dl-at mono">${row.atIso ? formatTimeHmMs(Date.parse(row.atIso), '—') : '—'}</span>
          </div>
        `
      })}
      <div class="dl-legend">
        ${DRAIN_LEGEND_STATES.map(state => html`
          <span key=${state} class="dl-leg">
            <span class="lq-chip" data-tone=${DRAIN_PRESENT[state].tone}>${DRAIN_PRESENT[state].label}</span>
            <span>${DRAIN_PRESENT[state].op}</span>
          </span>
        `)}
      </div>
    </div>
  `
}

function DrainMatrix({ rows }: { rows: readonly DrainEvidenceRow[] }): VNode {
  const [sel, setSel] = useState<{ q: string; r: string | null } | null>(null)
  const cellRows = (q: string, r: string | null) => rows.filter(row => row.queue === q && row.reaction === r)
  const selRows = sel ? cellRows(sel.q, sel.r) : []
  const selState = sel ? drainStateOfEvidence(sel.q, sel.r) : null
  return html`
    <div class="dm">
      <div class="dm-grid" style=${{ gridTemplateColumns: `132px repeat(${DRAIN_REACTION_AXIS.length}, minmax(0,1fr))` }}>
        <div class="dm-corner mono">queue \ reaction</div>
        ${DRAIN_REACTION_AXIS.map(r => html`<div key=${String(r)} class="dm-h mono">${r ?? '없음'}</div>`)}
        ${DRAIN_QUEUE_AXIS.map(q => html`
          <div key=${q} class="dm-rh mono">${q}</div>
          ${DRAIN_REACTION_AXIS.map(r => {
            const cell = cellRows(q, r)
            const state = drainStateOfEvidence(q, r)
            const present = state ? DRAIN_PRESENT[state] : null
            const on = sel !== null && sel.q === q && sel.r === r
            return html`
              <button
                key=${String(r)}
                type="button"
                class="dm-c ${cell.length ? 'has' : ''} ${on ? 'on' : ''}"
                data-tone=${present ? present.tone : 'dim'}
                data-testid="lane-drain-cell"
                data-queue=${q}
                data-reaction=${r ?? 'none'}
                onClick=${() => setSel(cell.length ? { q, r } : null)}
                title=${present ? present.why : ''}
              >
                <span class="dm-c-l">${present ? present.label : '—'}</span>
                ${cell.length > 0 ? html`<b class="mono">${cell.length}</b>` : null}
              </button>
            `
          })}
        `)}
      </div>
      <div class="dm-detail">
        ${sel && selState && selRows.length
          ? html`
              <div class="dm-detail-h">
                <span class="lq-chip" data-tone=${DRAIN_PRESENT[selState].tone}>${DRAIN_PRESENT[selState].label}</span>
                <span>${DRAIN_PRESENT[selState].why}</span>
              </div>
              ${selRows.map(row => html`
                <div key=${row.scheduleId} class="dm-row">
                  <b class="mono">${row.scheduleId}</b>
                  <span class="mono">${row.keeper ?? '—'}</span>
                  <span>${row.payload}</span>
                  <span class="mono">${row.atIso ? formatTimeHmMs(Date.parse(row.atIso), '—') : '—'}</span>
                </div>
              `)}
            `
          : html`<span class="dm-hint">칸을 누르면 해당 조합의 예약이 나옵니다.</span>`}
      </div>
    </div>
  `
}

/* ── 컨텍스트 레일 (design KeeperWaitQueue) ───────────────────────────── */

function inventoryEntryFor(
  inventory: DashboardKeeperWaitingInventory | null | undefined,
  keeperName: string,
): DashboardKeeperWaitingKeeper | null {
  if (!inventory) return null
  return inventory.keepers.find(k => k.keeper_name === keeperName) ?? null
}

/** Design KeeperWaitQueue — the keeper detail rail's 작업 대기열 section.
 *  Standalone (own store subscription); the monitor panel renders its
 *  waiting data inline instead. */
export function KeeperWaitQueueRail({ keeperName, dev = false }: { keeperName: string; dev?: boolean }): VNode {
  useNowSecondsTicker()
  const nowSec = nowSecondsSignal.value
  useEffect(() => subscribeKeeperWaitingInventory(keeperName), [keeperName])
  const current = keeperWaitingInventoryStates.value[keeperName]
  const entry = inventoryEntryFor(current?.inventory, keeperName)
  const present = entry ? laneStatePresent(entry.state) : null
  const waitingCount = entry?.waiting_count ?? 0
  return html`
    <div class="ctx-sec" data-testid="keeper-wait-queue-rail">
      <h4 style=${{ display: 'flex', alignItems: 'center', gap: '7px' }}>
        작업 대기열
        ${entry && waitingCount > 0
          ? html`<${CountBadge}>${waitingCount}<//>`
          : null}
      </h4>
      ${!entry || !present
        ? html`<div class="lq-gap"><b>상태 알 수 없음</b></div>`
        : html`
            <div class="lq-rail-body">
              <div class="lq-state-row"><span class="lq-chip" data-tone=${present.tone}>${present.label}</span></div>
              <${WaitAges}
                entry=${entry}
                dev=${dev}
                nowSec=${nowSec}
              />
            </div>
          `}
    </div>
  `
}

/* ── Monitor 섹션 (design LaneQueuePanel) ─────────────────────────────── */

export interface LaneQueuePanelProps {
  /** Injectable for tests; defaults to the real fleet composite read. */
  fetchFleet?: () => Promise<FleetCompositeSnapshot>
  fetchLifecycle?: typeof fetchKeeperLifecycle
  pollMs?: number
}

export function LaneQueuePanel(props: LaneQueuePanelProps = {}): VNode {
  useNowSecondsTicker()
  const nowSec = nowSecondsSignal.value
  const fetchFleet = useMemo(() => props.fetchFleet ?? (() => fetchKeepersComposite()), [props.fetchFleet])
  const fetchLifecycle = useMemo(() => props.fetchLifecycle ?? fetchKeeperLifecycle, [props.fetchLifecycle])
  const pollMs = props.pollMs ?? FLEET_POLL_MS

  const roster = keepers.value
  const buffers = laneObservationBuffers.value
  const latestSnapshots = laneLatestSnapshots.value
  const waitingStates = keeperWaitingInventoryStates.value
  const schedule = scheduledAutomation.value

  const tabIds = useMemo(() => {
    const names = roster.map(k => k.name)
    if (names.length > 0) return names
    return Object.keys(latestSnapshots)
  }, [roster, latestSnapshots])
  const tabKey = tabIds.join('\n')

  const [selected, setSelected] = useState<string | null>(null)
  const sel = selected !== null && tabIds.includes(selected) ? selected : tabIds[0] ?? null
  const [focus, setFocus] = useState<LaneKey>('turn')
  const [dev, setDev] = useState(false)

  // Fleet composite ingestion: the SSE-hydrated stream is primary; the poll
  // is the seed/watchdog so the panel also works where the stream is off.
  // Ingestion dedupes unchanged states, so a poll that overlaps the stream
  // never fabricates transitions.
  useEffect(() => {
    ingestLaneQueueFleetSnapshot(fleetCompositeSnapshot.value)
    const unsubscribe = fleetCompositeSnapshot.subscribe(ingestLaneQueueFleetSnapshot)
    let cancelled = false
    const poll = () => {
      void fetchFleet()
        .then(snapshot => { if (!cancelled) ingestLaneQueueFleetSnapshot(snapshot) })
        .catch(() => undefined)
    }
    poll()
    const timer = setInterval(poll, pollMs)
    return () => {
      cancelled = true
      clearInterval(timer)
      unsubscribe()
    }
  }, [fetchFleet, pollMs])

  // Waiting inventory: one shared keeper-scoped subscription per tab keeper
  // (push-invalidated; the store coalesces concurrent consumers).
  useEffect(() => {
    const names = tabKey === '' ? [] : tabKey.split('\n')
    const unsubscribers = names.map(name => subscribeKeeperWaitingInventory(name))
    return () => { for (const unsubscribe of unsubscribers) unsubscribe() }
  }, [tabKey])

  // Scheduled-automation projection (shared visibility-aware poller).
  useEffect(() => subscribeScheduledAutomationRefresh(), [])

  // Lifecycle event stream for the selected keeper.
  const [lifecycle, setLifecycle] = useState<{
    name: string
    events: KeeperLifecycleEvent[]
    error: string | null
  } | null>(null)
  useEffect(() => {
    if (sel === null) {
      setLifecycle(null)
      return
    }
    let cancelled = false
    const name = sel
    fetchLifecycle(name, LIFECYCLE_EVENT_LIMIT)
      .then(res => { if (!cancelled) setLifecycle({ name, events: res.events, error: null }) })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setLifecycle({ name, events: [], error: cause instanceof Error ? cause.message : String(cause) })
        }
      })
    return () => { cancelled = true }
  }, [sel, fetchLifecycle])

  const selObservations = sel !== null ? buffers[sel] ?? [] : []
  const selSnapshot = sel !== null ? latestSnapshots[sel] ?? null : null
  const selLive = selSnapshot?.is_live ?? false
  const selInventoryState = sel !== null ? waitingStates[sel] : undefined
  const selEntry = sel !== null ? inventoryEntryFor(selInventoryState?.inventory, sel) : null
  const selLifecycle = lifecycle !== null && lifecycle.name === sel ? lifecycle : null

  const reading = laneReading(selObservations, focus, selLive, nowSec)
  const focusLane = LANE_QUEUE_LANES.find(lane => lane.key === focus) ?? LANE_QUEUE_LANES[0]

  const stalledLanesByKeeper = (name: string): number => {
    const observations = buffers[name] ?? []
    if (observations.length === 0) return 0
    const live = latestSnapshots[name]?.is_live ?? false
    return LANE_QUEUE_LANES.filter(lane => laneReading(observations, lane.key, live, nowSec)?.stalled === true).length
  }
  const stalls = tabIds.reduce((count, name) => count + stalledLanesByKeeper(name), 0)
  const waitingKeeperCount = tabIds.filter(name =>
    inventoryEntryFor(waitingStates[name]?.inventory, name) !== null,
  ).length
  const misses = schedule ? countQueueDrainMisses(schedule.requests) : 0
  const drainRows = sortedDrainRows(schedule?.requests ?? [])
  const lifecycleEvents = selLifecycle?.events ?? null

  return html`
    <div class="ia-wrap lq-wrap" data-testid="lane-queue-panel">
      <div class="ia-head">
        <h3>레인 · 큐</h3>
        <span class="ia-count">진행 타임라인 · 대기 파이프라인 · 예약 실행</span>
        <span class="ia-devslot">
          <button
            type="button"
            class="ia-filter ${dev ? 'on' : ''}"
            aria-pressed=${dev}
            title="내부 식별자 · 원본 필드 표시"
            data-testid="lane-queue-dev-toggle"
            onClick=${() => setDev(current => !current)}
          >기술 상세</button>
        </span>
      </div>

      <div class="lq-kpis">
        <div class="lq-kpi"><span class="k">멈춘 진행</span><b class="${stalls > 0 ? 'warn' : 'ok'}" data-testid="lane-kpi-stalls">${stalls}</b></div>
        <div class="lq-kpi"><span class="k">기다리는 keeper</span><b data-testid="lane-kpi-waiting">${waitingKeeperCount}</b></div>
        <div class="lq-kpi"><span class="k">실행 안 된 예약</span><b class="${misses > 0 ? 'bad' : 'ok'}" data-testid="lane-kpi-misses">${misses}</b></div>
        <div class="lq-kpi"><span class="k">보는 구간</span><b>${Math.floor(LANE_QUEUE_WINDOW_S / 60)}분</b></div>
      </div>

      <div class="lq-sec">
        <div class="lq-sec-h">
          <h4>진행 타임라인</h4>
          ${dev ? html`<span class="mono">wire format = lowercase snake_case</span>` : null}
          <div class="lq-tabs">
            ${tabIds.map(id => html`
              <button
                key=${id}
                type="button"
                class="lq-tab mono ${sel === id ? 'on' : ''}"
                data-testid="lane-queue-tab"
                data-keeper=${id}
                onClick=${() => setSelected(id)}
              >${id}${stalledLanesByKeeper(id) > 0 ? html`<i class="lq-tab-dot"></i>` : null}</button>
            `)}
          </div>
        </div>
        ${sel === null
          ? html`<div class="lq-gap"><b>기록 없음</b><span>관측된 keeper 가 없습니다.</span></div>`
          : html`
              <${LaneSwimlane}
                observations=${selObservations}
                live=${selLive}
                focus=${focus}
                onFocus=${setFocus}
                dev=${dev}
                nowSec=${nowSec}
              />
              ${reading && focusLane
                ? html`
                    <div class="lq-read ${reading.stalled ? 'stalled' : ''}" data-testid="lane-read">
                      <span class="lq-read-l">${dev ? focusLane.devLabel : focusLane.label}</span>
                      <b class="${dev ? 'mono' : ''}">${dev ? reading.value : laneValueLabel(reading.value)}</b>
                      <span class="lq-read-m">${dev ? reading.meaningDev : reading.meaning}</span>
                      <span class="lq-read-o">${laneSecText(reading.observedForSec)} 지속 · ${selLive ? '진행 중인 턴 있음' : '진행 중인 턴 없음'}</span>
                    </div>
                  `
                : null}
            `}
      </div>

      <div class="lq-split">
        <div class="lq-sec">
          <div class="lq-sec-h">
            <h4>${sel ?? '—'} · 무엇을 기다리는가</h4>
            ${selEntry
              ? html`
                  <span class="lq-chip" data-tone=${laneStatePresent(selEntry.state).tone}>${laneStatePresent(selEntry.state).label}</span>
                  <span class="mono">${selEntry.waiting_count}건</span>
                `
              : null}
          </div>
          ${selEntry
            ? html`
                <${LanePipeline} entry=${selEntry} dev=${dev} />
                <div class="lq-batch">한 턴이 밀린 자극을 묶어서 처리합니다.</div>
                <div class="lq-sec-sub">오래 기다린 순서</div>
                <${WaitAges}
                  entry=${selEntry}
                  dev=${dev}
                  nowSec=${nowSec}
                />
              `
            : html`<div class="lq-gap"><b>상태 알 수 없음</b></div>`}
        </div>
        <div class="lq-sec">
          <div class="lq-sec-h">
            <h4>${sel ?? '—'} · 기동 · 재시작 기록</h4>
            ${dev ? html`<span class="mono">supervisor stream · 최근 ${LIFECYCLE_EVENT_LIMIT}건</span>` : null}
          </div>
          <${LaneLifecycleEvents}
            events=${lifecycleEvents}
            loading=${selLifecycle === null}
            error=${selLifecycle?.error ?? null}
            dev=${dev}
            nowSec=${nowSec}
          />
        </div>
      </div>

      <div class="lq-sec">
        <div class="lq-sec-h">
          <h4>예약 실행 결과</h4>
          ${dev ? html`<span class="mono">queue evidence × reaction evidence</span>` : null}
          ${misses > 0 ? html`<span class="lq-chip" data-tone="bad">누락 ${misses}</span>` : null}
        </div>
        ${dev
          ? html`<${DrainMatrix} rows=${drainRows} />`
          : html`<${DrainList} rows=${drainRows} />`}
      </div>
    </div>
  `
}
