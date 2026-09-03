// keeper-v2 Fleet aside 잔여 섹션 (fleet.jsx AsideQueue / AsideRotation /
// 활동 미니). 전부 라이브 소스에 연결한다 — 관측되지 않는 값은 행 자체를
// 렌더하지 않는다 (mark, don't fake):
//
//   · fl-q-*   — keeper_waiting_inventory keeper-scoped read
//                (subscribeKeeperWaitingInventory 공유 스토어, keeper-shared /
//                lanes 패널과 같은 소스) + keeper keepalive/heartbeat 필드.
//                디자인의 admitted/deferred/dropped 회계(fl-q-acct/fl-q-c)는
//                라이브 소스가 없어 렌더하지 않는다.
//   · fl-rot-* — GET /api/v1/runtime/resolved 의 lane 후보 체인
//                (Runtime_lane_preference sticky 선호 포함). 디자인의
//                failover 이벤트 피드(fl-rot-ev*)는 keeper 별 라이브 이벤트
//                소스가 없어 생략한다.
//   · fl-as-mini/fl-mini — keeper 카운터 필드 중 관측되는 것만. 디자인의
//                초당 토큰(tps)·트레이스는 roster 모델에 소스가 없다
//                (agent-roster.ts 의 P1-6 감사 주석 참조).
//   · fl-actbar/fl-btn/fl-noact — aside 액션 섹션. keeperActionVisibility
//                (directive/boot/shutdown/purge API) 가 여는 조작만 버튼으로
//                렌더하고, 하나도 없으면 디자인의 fl-noact 문구를 렌더한다.

import { html } from 'htm/preact'
import { Fragment } from 'preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import type { Keeper } from '../types'
import type {
  DashboardKeeperWaitingRow,
  DashboardKeeperWaitingSource,
  RuntimeLaneSnapshot,
  RuntimeResolvedResponse,
} from '../api'
import {
  keeperWaitingInventoryState,
  subscribeKeeperWaitingInventory,
} from '../keeper-waiting-inventory-store'
import { loadRuntimeResolved, runtimeResolvedState } from '../lib/runtime-resolved-resource'
import { getData } from '../lib/async-state'
import {
  keeperDisplayRuntime,
  keeperDisplayStatus,
} from '../lib/keeper-runtime-display'
import { keeperActionVisibility } from '../lib/keeper-predicates'
import { keeperPurgePending } from '../store'
import { PHASE_LABEL_KO } from '../lib/fleet-tone'
import { laneSourceLabel } from './lanes/lane-queue-model'
import { TimeAgo } from './common/time-ago'
import {
  KEEPER_ACTION_LABELS,
  KEEPER_PURGE_PENDING_LABEL,
  runKeeperAction,
  type KeeperActionKey,
} from './keeper-action-panel'

/* ── 활동 미니 (fl-as-mini / fl-mini) ──────────────────────────────────── */

export interface FleetActivityMini {
  readonly k: string
  readonly v: string
}

function finiteCount(value: number | null | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/** 활동 미니 행. 디자인 슬롯은 초당 토큰/트레이스/맡은 작업이지만 tps·traces
 *  는 라이브 소스가 없고 맡은 작업은 런타임 vitals 가 이미 다루므로, 여기서는
 *  keeper 가 실제로 보고하는 자율/반응 턴 카운터와 드리프트 누계만 쓴다. */
export function fleetActivityMinis(keeper: Keeper | null | undefined): FleetActivityMini[] {
  if (!keeper) return []
  const minis: FleetActivityMini[] = []

  const drifts = finiteCount(keeper.drift_count_total)
  if (drifts != null) minis.push({ k: '드리프트', v: String(drifts) })

  return minis
}

/* ── 이벤트 큐 + 하트비트 (fl-q-*) ─────────────────────────────────────── */

// 디자인 EVENT_KIND (ops-data.jsx) 의 글리프 어휘를 waiting-inventory source
// 닫힌 집합에 대응시킨다. mention @ · board ▤ · gate ⚿ · wake ○ · handoff ⇄.
const QUEUE_SOURCE_GLYPH: Record<DashboardKeeperWaitingSource, string> = {
  event_queue_pending: '○',
  chat_operation_queued: '▤',
  chat_operation_running: '▤',
  hitl_pending: '⚿',
  fusion_running: '▶',
  schedule_waiting: '○',
  owner_shutdown: '■',
  operator_pending_confirm: '⚿',
  read_error: '!',
}

function queueRowFrom(row: DashboardKeeperWaitingRow): string {
  const producer = row.wake_producer?.trim()
  return producer || row.waiting_on
}

/** 디자인 AsideQueue. pending 이벤트 행은 keeper_waiting_inventory 가,
 *  깨어남 주기는 keeper keepalive 필드가 담당한다. 둘 다 없으면 섹션 자체를
 *  렌더하지 않는다 (디자인의 `if (!q && k.hb == null) return null`). */
export function FleetQueueSection({ keeper }: { keeper: Keeper }) {
  const keeperName = keeper.name.trim()
  useEffect(() => subscribeKeeperWaitingInventory(keeperName), [keeperName])

  const inventoryState = keeperWaitingInventoryState(keeperName)
  const entry = inventoryState.inventory?.keepers
    .find(item => item.keeper_name === keeperName) ?? null
  const rows = entry?.waiting_on ?? []
  const draining = keeper.phase === 'Draining'

  const heartbeatError = keeper.heartbeat_observation_error?.trim() || null
  const interval = finiteCount(keeper.keeper_keepalive_interval_s)
  const wakes = keeper.keepalive_running === true && interval != null && interval > 0
  // keepalive_running 이 false 로 보고된 경우만 "꺼짐" 을 단정한다. 필드
  // 부재(미보고)는 꺼짐이 아니라 미관측이므로 heartbeat 행을 생략한다.
  const heartbeatKnownOff = keeper.keepalive_running === false
  const hasHeartbeat = heartbeatError != null || wakes || heartbeatKnownOff

  if (rows.length === 0 && !hasHeartbeat) return null

  return html`
    <div class="fl-as-sec" data-testid="fleet-queue-section">
      <h4>${draining ? '드레인 대기' : '들어온 이벤트'}</h4>
      <div class="fl-q">
        ${rows.length > 0 ? html`
          <div class="fl-q-list">
            ${rows.map(row => html`
              <div class="fl-q-item ${draining ? 'drain' : ''}" title=${row.what}>
                <span class="fl-q-gl mono">${QUEUE_SOURCE_GLYPH[row.source]}</span>
                <span class="fl-q-kind mono">${laneSourceLabel(row.source)}</span>
                <span class="fl-q-from">${queueRowFrom(row)}</span>
                <span class="fl-q-at mono">${row.since_iso
                  ? html`<${TimeAgo} timestamp=${row.since_iso} />`
                  : '시각 미기록'}</span>
              </div>
            `)}
          </div>
        ` : null}
        ${heartbeatError != null ? html`
          <div class="fl-q-hb off">하트비트 기록 읽기 실패 · ${heartbeatError}</div>
        ` : wakes ? html`
          <div class="fl-q-hb" title="keepalive 주기 (keeper_keepalive_interval_s)">
            <span class="fl-q-hb-dot"></span>${interval}초마다 깨어남${keeper.last_heartbeat
              ? html` · 마지막 <${TimeAgo} timestamp=${keeper.last_heartbeat} />`
              : null}
          </div>
        ` : html`
          <div class="fl-q-hb off">깨어나지 않음 · ${PHASE_LABEL_KO[keeperDisplayStatus(keeper)]}</div>
        `}
      </div>
    </div>
  `
}

/* ── 런타임 후보 체인 (fl-rot-*) ───────────────────────────────────────── */

function fleetRotationLane(
  data: RuntimeResolvedResponse,
  keeper: Keeper,
): { lane: RuntimeLaneSnapshot | null; note: string } {
  const assignment = data.assignments.find(item => item.keeper === keeper.name.trim()) ?? null
  if (!assignment) {
    return { lane: null, note: 'runtime/resolved 에 이 keeper 의 할당이 없습니다.' }
  }
  if (assignment.resolved.kind === 'single_runtime') {
    return { lane: null, note: '단일 런타임에 고정 — 후보 체인 없음' }
  }
  if (assignment.resolved.kind === 'missing') {
    return { lane: null, note: '할당 대상 런타임을 해석하지 못했습니다.' }
  }
  const lane = data.lanes.find(item => item.id === assignment.resolved.id) ?? null
  if (!lane) {
    return { lane: null, note: `lane 정의를 찾지 못했습니다 · ${assignment.resolved.id ?? '미상'}` }
  }
  return { lane, note: '' }
}

/** 디자인 AsideRotation. 후보 체인은 runtime/resolved 의 lane 정의가, 현재
 *  후보 표시(cur)는 keeper 의 runtime_canonical 이 담당한다. 디자인의
 *  "수동 전환" 태그는 masc 에 맞지 않는다 — lane 은 마지막 성공 후보를 먼저
 *  시도하는 sticky 선호(Runtime_lane_preference)를 가지므로, 태그 문구는
 *  관측된 사실(후보 수)만 담는다. */
export function FleetRotationSection({ keeper }: { keeper: Keeper }) {
  useEffect(() => {
    void loadRuntimeResolved()
  }, [])

  const data = getData(runtimeResolvedState.value)
  if (!data) return null

  const runtime = keeperDisplayRuntime(keeper)
  const { lane, note } = fleetRotationLane(data, keeper)

  return html`
    <div class="fl-as-sec" data-testid="fleet-rotation-section">
      <h4>런타임 후보 ${lane
        ? html`<span class="fl-as-tag" title="lane ${lane.id} — 마지막 성공 후보를 먼저 시도하는 sticky 선호">후보 ${lane.runtime_ids.length}</span>`
        : null}</h4>
      ${lane && lane.runtime_ids.length > 0 ? html`
        <div class="fl-rot">
          <div class="fl-rot-chain">
            ${lane.runtime_ids.map((id, index) => html`
              <${Fragment} key=${id}>
                ${index > 0 ? html`<span class="fl-rot-arr">→</span>` : null}
                <span class="fl-rot-cand mono ${index === 0 ? 'head' : ''} ${runtime && id === runtime.value ? 'cur' : ''}">${id}</span>
              <//>
            `)}
          </div>
          <div class="fl-rot-note mono">${lane.preferred_candidate
            ? `마지막 성공 후보 ${lane.preferred_candidate} 를 먼저 시도합니다 (sticky 선호)`
            : '기록된 선호 후보 없음'}</div>
        </div>
      ` : html`
        <div class="fl-rot-na">${note}</div>
      `}
    </div>
  `
}

/* ── aside 액션 (fl-actbar / fl-btn / fl-noact) ────────────────────────── */

// 버튼 순서는 행 액션(KeeperActionButtons) 과 맞춘다: 기동 · 멈춤 · 재개 ·
// 깨움 · 종료 · 제거. 디자인 fleet.jsx 의 aside 액션 섹션은 FSM 단계별
// FSM_ACTIONS 를 나열하고, 가능한 조작이 없으면 fl-noact 문구를 보인다.
// 라이브 측 가시성 SSOT 는 keeperActionVisibility 다.
const ASIDE_ACTION_ORDER: readonly KeeperActionKey[] = [
  'boot',
  'pause',
  'resume',
  'wakeup',
  'shutdown',
  'purge',
]

function asideActionVisible(
  vis: ReturnType<typeof keeperActionVisibility>,
  action: KeeperActionKey,
): boolean {
  switch (action) {
    case 'boot': return vis.canBoot
    case 'pause': return vis.canPause
    case 'resume': return vis.canResume
    case 'wakeup': return vis.canWake
    case 'shutdown': return vis.canShutdown
    case 'purge': return vis.canPurge
  }
}

/** 디자인 fleet.jsx FleetAside 의 액션 섹션. 확인 대화(종료/제거)는
 *  runKeeperAction 이 담당하므로 여기서 다시 묻지 않는다. */
export function FleetAsideActions({ keeper }: { keeper: Keeper }) {
  const busy = useSignal(false)
  const vis = keeperActionVisibility(keeper)
  const purgePending = keeperPurgePending.value.has(keeper.name.trim())
  const actions = ASIDE_ACTION_ORDER.filter(action => asideActionVisible(vis, action))

  async function handle(action: KeeperActionKey) {
    if (busy.value) return
    busy.value = true
    try {
      await runKeeperAction(keeper.name, action)
    } finally {
      busy.value = false
    }
  }

  return html`
    <div class="fl-as-sec" data-testid="fleet-aside-actions">
      <h4>액션</h4>
      ${actions.length > 0 ? html`
        <div class="fl-actbar">
          ${actions.map(action => {
            const meta = KEEPER_ACTION_LABELS[action]
            const Icon = meta.icon
            const pending = action === 'purge' && purgePending
            return html`
              <button
                key=${action}
                type="button"
                class="fl-btn ${meta.danger ? 'danger' : ''} ${busy.value ? 'busy' : ''}"
                data-action=${action}
                disabled=${busy.value}
                title=${pending ? KEEPER_PURGE_PENDING_LABEL.title : meta.title}
                onClick=${() => void handle(action)}
              >
                <span class="g"><${Icon} size=${13} /></span>${pending
                  ? KEEPER_PURGE_PENDING_LABEL.compact
                  : meta.verb}
              </button>
            `
          })}
        </div>
      ` : html`
        <div class="fl-noact">이 단계에서는 할 수 있는 조작이 없습니다.</div>
      `}
    </div>
  `
}
