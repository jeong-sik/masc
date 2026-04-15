import { html } from 'htm/preact'
import { useEffect, useMemo, useReducer, useRef, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  type KeeperCompositeSnapshot,
} from '../api/keeper'
import { fetchGateKeepers } from '../api/gate'
import { keepers } from '../store'
import { compositeTick } from '../composite-signals'
import { EmptyState } from './common/empty-state'

import {
  type HoveredSegment,
  type HubAction,
  type HubState,
  initialHubState,
  fmtDuration,
} from './fsm-hub-types'
import {
  observeSnapshot,
  appendCompositeObservation,
  deriveTransitionHistory,
  derivePhaseLog,
  deriveStateEntries,
} from './fsm-hub-derivations'
import { OperationalMeaningPanel, HeroPhase, TurnPipelineStrip, CompositeGraphPanel } from './fsm-hub-pipeline-panels'
import { SwimlaneTimeline, TransitionTrail } from './fsm-hub-timeline-panels'
import { MeasurementCard, InvariantsPanel, RecoveryStatePanel } from './fsm-hub-health-panels'

// ── Backward-compatible re-exports ─────────────────────
// External consumers (agents-unified.ts, fsm-hub.test.ts)
// import from './fsm-hub' — these re-exports keep that working.

export type {
  CompositeObservation,
  HoveredSegment,
  OperationalInsight,
  ObservedLaneSummary,
  StateEntries,
  TimeAxisTick,
  SwimlaneSegment,
} from './fsm-hub-types'

export { displayState } from './fsm-hub-types'

export {
  appendCompositeObservation,
  deriveTransitionHistory,
  derivePhaseLog,
  deriveStateEntries,
  deriveTimeAxisTicks,
  deriveSwimlaneSegments,
  laneTransitionCount,
} from './fsm-hub-derivations'

export { deriveOperationalInsight } from './fsm-hub-invariant-analysis'
export { deriveObservedLaneSummaries } from './fsm-hub-lane-analysis'

export {
  flagTooltip,
  invariantDescription,
  recoveryStateDescription,
} from './fsm-hub-health-panels'

export {
  isTransitionInSegment,
} from './fsm-hub-timeline-panels'

// ── State Reducer ──────────────────────────────────────

function reduceHubState(state: HubState, action: HubAction): HubState {
  const current =
    state.keeperName === action.keeperName
      ? state
      : {
          ...initialHubState,
          keeperName: action.keeperName,
        }

  switch (action.type) {
    case 'fetch_started':
      return {
        ...current,
        loading: true,
        error: null,
      }
    case 'fetch_succeeded': {
      const observation = observeSnapshot(action.snapshot, action.fetchedAt)
      return {
        keeperName: action.keeperName,
        snapshot: action.snapshot,
        loading: false,
        error: null,
        lastFetchAt: action.fetchedAt,
        observations: appendCompositeObservation(current.observations, observation),
      }
    }
    case 'fetch_failed':
      return {
        ...current,
        loading: false,
        error: action.error,
      }
  }
}

// ── Main Component ─────────────────────────────────────

/**
 * FSM Hub — architecture audit surface for the composite keeper lifecycle.
 *
 * Layout redesign: Hero (KSM) + Pipeline strip (KTC->KDP->KCL->KMC) +
 * Health grid (measurement/invariants/recovery) + collapsible graph.
 *
 * Data source: `/api/v1/keepers/:name/composite` (RFC-0003 S7).
 */
export function FsmHub() {
  const [selected, setSelected] = useState<string | null>(null)
  const [hub, dispatch] = useReducer(reduceHubState, initialHubState)
  const [pollTick, setPollTick] = useState(0)
  const [now, setNow] = useState(() => Date.now() / 1000)
  const [graphOpen, setGraphOpen] = useState(false)
  const [hoveredSegment, setHoveredSegment] = useState<HoveredSegment | null>(null)
  const [gateKeeperNames, setGateKeeperNames] = useState<string[]>([])
  const requestIdRef = useRef(0)

  // Primary source: store signal (from dashboard/shell polling).
  // Fallback: direct gate fetch — the shell endpoint omits keeper
  // details (only sends configured_keepers count), so without this
  // fallback the FsmHub sees zero keepers and renders empty state.
  const storeKeeperList = keepers.value
  const storeNames = useMemo(
    () => storeKeeperList.map(k => k.name).sort(),
    [storeKeeperList],
  )
  useEffect(() => {
    if (storeNames.length > 0 || gateKeeperNames.length > 0) return
    let cancelled = false
    void (async () => {
      try {
        const data = await fetchGateKeepers()
        if (cancelled) return
        const next = data.keepers.map(k => k.name).sort()
        setGateKeeperNames(prev =>
          prev.length === next.length && prev.every((v, i) => v === next[i])
            ? prev
            : next,
        )
      } catch {
        // Gate endpoint auth failure or network error — leave names empty
        // so the primary store path can populate once shell refresh lands.
      }
    })()
    return () => { cancelled = true }
  }, [storeNames.length, gateKeeperNames.length, pollTick])

  const keeperNames = storeNames.length > 0 ? storeNames : gateKeeperNames
  const activeSelected = useMemo(() => {
    if (selected && keeperNames.includes(selected)) return selected
    return keeperNames[0] ?? null
  }, [keeperNames, selected])

  useEffect(() => {
    const id = setInterval(() => setPollTick(t => t + 1), 30_000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now() / 1000), 1_000)
    return () => clearInterval(id)
  }, [])

  const tick = compositeTick.value
  const shouldRefetchForTick =
    activeSelected != null && tick.name === activeSelected ? tick.ts_unix : 0

  useEffect(() => {
    if (!activeSelected) return
    const requestId = requestIdRef.current + 1
    requestIdRef.current = requestId
    dispatch({ type: 'fetch_started', keeperName: activeSelected })
    void (async () => {
      try {
        const data = await fetchKeeperComposite(activeSelected)
        if (requestIdRef.current !== requestId) return
        dispatch({
          type: 'fetch_succeeded',
          keeperName: activeSelected,
          snapshot: data,
          fetchedAt: Date.now() / 1000,
        })
      } catch (err) {
        if (requestIdRef.current !== requestId) return
        dispatch({
          type: 'fetch_failed',
          keeperName: activeSelected,
          error: err instanceof Error ? err.message : 'composite fetch failed',
        })
      }
    })()
  }, [activeSelected, shouldRefetchForTick, pollTick])

  const view = useMemo(
    () =>
      hub.keeperName === activeSelected
        ? hub
        : {
            ...initialHubState,
            keeperName: activeSelected,
          },
    [activeSelected, hub],
  )
  const history = useMemo(
    () => deriveTransitionHistory(view.observations),
    [view.observations],
  )
  const phaseLog = useMemo(
    () => derivePhaseLog(view.observations),
    [view.observations],
  )
  const stateEntries = useMemo(
    () => deriveStateEntries(view.observations),
    [view.observations],
  )
  const { snapshot, loading, error, lastFetchAt } = view

  return html`
    <div class="flex flex-col gap-3">
      ${/* ── Zone 1: Status Bar ── */ ''}
      <${StatusBar}
        snapshot=${snapshot}
        now=${now}
        lastFetchAt=${lastFetchAt}
        keeperNames=${keeperNames}
        selected=${activeSelected}
        onSelect=${setSelected}
        loading=${loading}
        transitionCount=${history.length}
        observationCount=${view.observations.length}
      />

      ${activeSelected == null ? html`
        <${EmptyState} message=${keeperNames.length > 0
          ? `위 탭에서 키퍼를 선택하면 composite FSM 스냅샷을 표시합니다 (${keeperNames.length}개 사용 가능)`
          : '등록된 키퍼가 없습니다 — MASC에 키퍼를 기동하면 자동으로 표시됩니다'} />
      ` : loading && !snapshot ? html`
        <${SkeletonLayout} />
      ` : error ? html`
        <${EmptyState} message=${error} compact />
      ` : snapshot ? html`
        <${OperationalMeaningPanel}
          snapshot=${snapshot}
          observations=${view.observations}
          now=${now}
        />

        ${/* ── Zone 2: Hero — KSM Phase ── */ ''}
        <${HeroPhase} snapshot=${snapshot} phaseLog=${phaseLog} phaseSince=${stateEntries?.phase ?? null} now=${now} />

        ${/* ── Zone 2b: Transition History Trail (collapsible) ── */ ''}
        <${CollapsibleZone} id="transition-trail" title="전환 이력" defaultOpen=${true}>
          <${TransitionTrail} history=${history} now=${now} hoveredSegment=${hoveredSegment} />
        <//>

        ${/* ── Zone 3: Turn Pipeline Strip ── */ ''}
        <${TurnPipelineStrip} snapshot=${snapshot} stateEntries=${stateEntries} now=${now} />

        ${/* ── Zone 3b: Swimlane Timeline (collapsible) ── */ ''}
        <${CollapsibleZone} id="swimlane" title="상태 타임라인" defaultOpen=${true}>
          <${SwimlaneTimeline}
            observations=${view.observations}
            now=${now}
            hoveredSegment=${hoveredSegment}
            onHoverSegment=${setHoveredSegment}
          />
        <//>

        ${/* ── Zone 4: Health Grid (collapsible) ── */ ''}
        <${CollapsibleZone} id="health-grid" title="상태 격자" defaultOpen=${true}>
          <div class="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
            <${MeasurementCard} snapshot=${snapshot} />
            <${InvariantsPanel} snapshot=${snapshot} />
            <${RecoveryStatePanel}
              dataRecord=${snapshot.recovery.data_record}
              fsmCondition=${snapshot.recovery.fsm_condition}
            />
          </div>
        <//>

        ${/* ── Zone 5: Collapsible Graph ── */ ''}
        <details class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)]"
          open=${graphOpen}
          onToggle=${(e: Event) => setGraphOpen((e.target as HTMLDetailsElement).open)}
        >
          <summary class="cursor-pointer select-none px-4 py-2.5 text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] hover:text-[var(--text-body)]">
            Compound Graph — 5 sub-FSMs (Cytoscape)
          </summary>
          <div class="px-3 pb-3">
            <${CompositeGraphPanel} snapshot=${snapshot} />
          </div>
        </details>
      ` : null}
    </div>
  `
}

// ── Zone 1: Status Bar ──────────────────────────────────

function StatusBar({
  snapshot,
  now,
  lastFetchAt,
  keeperNames,
  selected,
  onSelect,
  loading,
  transitionCount,
  observationCount,
}: {
  snapshot: KeeperCompositeSnapshot | null
  now: number
  lastFetchAt: number
  keeperNames: string[]
  selected: string | null
  onSelect: (n: string) => void
  loading: boolean
  transitionCount: number
  observationCount: number
}) {
  const idleDuration = snapshot && !snapshot.is_live
    ? fmtDuration(Math.max(0, now - (snapshot.last_outcome?.ended_at ?? snapshot.ts)))
    : null
  const idleIsLong = snapshot && !snapshot.is_live && idleDuration != null
    && (now - (snapshot.last_outcome?.ended_at ?? snapshot.ts)) > 300
  const liveBadge = snapshot
    ? snapshot.is_live
      ? html`<span class="px-2 py-0.5 rounded-full border text-[10px] font-mono text-emerald-400 border-emerald-500/40 bg-emerald-500/10 animate-pulse">● 실행 중</span>`
      : html`<span class="px-2 py-0.5 rounded-full border text-[10px] font-mono ${idleIsLong ? 'text-[var(--text-muted)] border-amber-500/30' : 'text-[var(--text-dim)] border-white/10'}">○ 대기 ${idleDuration}${snapshot.last_outcome ? html` <span class="text-[8px] opacity-70">· 턴 #${snapshot.last_outcome.turn_id}</span>` : ''}</span>`
    : null

  const staleSec = lastFetchAt > 0 ? Math.max(0, now - lastFetchAt) : 0

  return html`
    <div class="sticky top-0 z-20 rounded-xl border border-[var(--white-8)] bg-[var(--panel-dark-60)] backdrop-blur-md px-4 py-2.5 shadow-[0_4px_12px_rgba(0,0,0,0.25)]">
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-3">
          <span class="text-[10px] font-semibold uppercase tracking-[0.12em] text-[var(--text-muted)]">FSM Hub</span>
          ${liveBadge}
          ${loading ? html`<span class="inline-block h-2.5 w-2.5 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin"></span>` : null}
          ${staleSec > 60 ? html`<span class="text-[9px] font-mono text-amber-400">${fmtDuration(staleSec)} 전 갱신</span>` : null}
        </div>
        <div class="flex items-center gap-1.5 flex-wrap" role="tablist" aria-label="Keeper 선택">
          ${keeperNames.map((name, i) => {
            const active = name === selected
            const cls = active
              ? 'bg-[var(--accent-10)] border-[var(--accent-30)] text-[var(--accent)]'
              : 'bg-[var(--white-3)] border-[var(--white-8)] text-[var(--text-dim)] hover:text-[var(--text-body)] hover:border-[var(--accent-30)]'
            return html`
              <button
                role="tab"
                aria-selected=${active}
                tabindex=${active ? 0 : -1}
                class=${`rounded-full border px-2.5 py-0.5 text-[10px] font-mono transition-colors cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] focus-visible:ring-offset-1 focus-visible:ring-offset-[var(--bg-0)] ${cls}`}
                onClick=${() => onSelect(name)}
                onKeyDown=${(e: KeyboardEvent) => {
                  let next = -1
                  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = (i + 1) % keeperNames.length
                  else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = (i - 1 + keeperNames.length) % keeperNames.length
                  else if (e.key === 'Home') next = 0
                  else if (e.key === 'End') next = keeperNames.length - 1
                  if (next >= 0) {
                    e.preventDefault()
                    const nextName = keeperNames[next]
                    if (nextName) {
                      onSelect(nextName);
                      (e.currentTarget as HTMLElement)?.parentElement?.querySelectorAll<HTMLElement>('[role=tab]')[next]?.focus()
                    }
                  }
                }}
              >
                ${name.replace(/^keeper-|-agent$/g, '')}
              </button>
            `
          })}
        </div>
      </div>
      ${snapshot ? html`
        <div class="mt-1.5 flex items-center gap-2 text-[9px] font-mono flex-wrap">
          ${/* KPI micro-metrics */ ''}
          <span class="px-1.5 py-0.5 rounded border border-[var(--white-8)] text-[var(--text-body)]">
            턴 ${snapshot.last_outcome ? `#${snapshot.last_outcome.turn_id}` : '—'}
          </span>
          <span class=${`px-1.5 py-0.5 rounded border ${transitionCount > 0 ? 'border-[rgba(129,140,248,0.3)] text-[#818cf8]' : 'border-[var(--white-8)] text-[var(--text-dim)]'}`}>
            ${transitionCount} 전환
          </span>
          <span class="px-1.5 py-0.5 rounded border border-[var(--white-8)] text-[var(--text-dim)]">
            ${observationCount} 관측
          </span>
          ${/* Meta IDs */ ''}
          <span class="text-[var(--text-dim)] opacity-60">corr ${snapshot.correlation_id?.slice(-8) ?? '?'}</span>
          <span class="text-[var(--text-dim)] opacity-60">run ${snapshot.run_id?.slice(-8) ?? '?'}</span>
        </div>
      ` : null}
    </div>
  `
}

// ── Skeleton Loading (Linear/Stripe pattern) ────────────

const shimmerCls = 'animate-pulse rounded bg-[var(--white-5)]'

function SkeletonBar({ w, h = 'h-3' }: { w: string; h?: string }) {
  return html`<div class=${`${shimmerCls} ${w} ${h}`}></div>`
}

function SkeletonLayout() {
  return html`
    <div class="flex flex-col gap-3" aria-hidden="true" aria-label="Loading composite snapshot">
      ${/* Operator Meaning skeleton */ ''}
      <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-4">
        <${SkeletonBar} w="w-24" h="h-2" />
        <div class="mt-3"><${SkeletonBar} w="w-3/4" h="h-5" /></div>
        <div class="mt-2"><${SkeletonBar} w="w-full" h="h-3" /></div>
        <div class="mt-3 flex gap-2">
          <${SkeletonBar} w="w-16" h="h-4" />
          <${SkeletonBar} w="w-20" h="h-4" />
          <${SkeletonBar} w="w-14" h="h-4" />
        </div>
      </div>

      ${/* Hero Phase skeleton */ ''}
      <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-5">
        <${SkeletonBar} w="w-32" h="h-2" />
        <div class="mt-2"><${SkeletonBar} w="w-40" h="h-8" /></div>
        <div class="mt-2"><${SkeletonBar} w="w-20" h="h-2" /></div>
        <div class="mt-2 flex gap-1">
          ${[1,2,3,4,5,6,7,8].map(i => html`<${SkeletonBar} key=${i} w="w-2" h="h-2" />`)}
        </div>
      </div>

      ${/* Pipeline Strip skeleton */ ''}
      <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
        <${SkeletonBar} w="w-24" h="h-2" />
        <div class="mt-2 flex gap-2">
          ${[1,2,3,4].map(i => html`
            <div key=${i} class="flex-1 rounded-lg border border-[var(--white-8)] p-2">
              <${SkeletonBar} w="w-10" h="h-2" />
              <div class="mt-1"><${SkeletonBar} w="w-16" h="h-4" /></div>
              <div class="mt-1"><${SkeletonBar} w="w-14" h="h-2" /></div>
            </div>
          `)}
        </div>
      </div>

      ${/* Swimlane skeleton */ ''}
      <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
        <${SkeletonBar} w="w-28" h="h-2" />
        <div class="mt-2 flex flex-col gap-1.5">
          ${[1,2,3,4,5].map(i => html`
            <div key=${i} class="flex items-center gap-2">
              <${SkeletonBar} w="w-10" h="h-2" />
              <div class=${`${shimmerCls} flex-1 h-4`}></div>
            </div>
          `)}
        </div>
      </div>

      ${/* Health Grid skeleton */ ''}
      <div class="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
        ${[1,2,3].map(i => html`
          <div key=${i} class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
            <${SkeletonBar} w="w-20" h="h-2" />
            <div class="mt-2 flex flex-wrap gap-1.5">
              <${SkeletonBar} w="w-14" h="h-5" />
              <${SkeletonBar} w="w-12" h="h-5" />
              <${SkeletonBar} w="w-16" h="h-5" />
            </div>
          </div>
        `)}
      </div>
    </div>
  `
}

// ── Collapsible Zone ────────────────────────────────────

const COLLAPSED_ZONES_KEY = 'fsm-hub:collapsed-zones'

function loadCollapsedZones(): Set<string> {
  try {
    const stored = localStorage.getItem(COLLAPSED_ZONES_KEY)
    if (stored) return new Set(JSON.parse(stored) as string[])
  } catch { /* ignore corrupt localStorage */ }
  return new Set<string>()
}

function saveCollapsedZones(collapsed: Set<string>): void {
  try {
    localStorage.setItem(COLLAPSED_ZONES_KEY, JSON.stringify([...collapsed]))
  } catch { /* quota exceeded — non-critical */ }
}

function CollapsibleZone({
  id,
  title: zoneTitle,
  defaultOpen = true,
  children,
}: {
  id: string
  title: string
  defaultOpen?: boolean
  children: unknown
}) {
  const [collapsed, setCollapsed] = useState(() => {
    const stored = loadCollapsedZones()
    return stored.has(id) ? true : !defaultOpen
  })

  const toggle = () => {
    setCollapsed(prev => {
      const next = !prev
      const stored = loadCollapsedZones()
      if (next) stored.add(id)
      else stored.delete(id)
      saveCollapsedZones(stored)
      return next
    })
  }

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] overflow-hidden">
      <button
        type="button"
        class="w-full flex items-center justify-between px-4 py-2 text-left hover:bg-[var(--white-3)] transition-colors cursor-pointer select-none"
        onClick=${toggle}
        aria-expanded=${!collapsed}
        aria-controls=${`zone-${id}`}
      >
        <span class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">${zoneTitle}</span>
        <span class=${`text-[10px] text-[var(--text-dim)] transition-transform duration-200 ${collapsed ? '' : 'rotate-180'}`}>▾</span>
      </button>
      ${!collapsed ? html`<div id=${`zone-${id}`} class="px-4 pb-3">${children}</div>` : null}
    </div>
  `
}
