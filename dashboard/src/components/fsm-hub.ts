import { html } from 'htm/preact'
import { useEffect, useMemo, useReducer, useRef, useState } from 'preact/hooks'

import {
  fetchKeeperComposite,
  type KeeperCompositeSnapshot,
  type KeeperCompositeInvariants,
} from '../api/keeper'
import { keepers } from '../store'
import { compositeTick } from '../composite-signals'
import { EmptyState } from './common/empty-state'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { buildCompositeFsmSpec } from './keeper-fsm-specs'

export type CompositeObservation = {
  ts: number
  phase: string
  turn: string
  decision: string
  cascade: string
  compaction: string
}

type TransitionEntry = {
  ts: number
  from: string
  to: string
  field: string
}

type HubState = {
  keeperName: string | null
  snapshot: KeeperCompositeSnapshot | null
  loading: boolean
  error: string | null
  lastFetchAt: number
  observations: CompositeObservation[]
}

type HubAction =
  | { type: 'fetch_started'; keeperName: string }
  | { type: 'fetch_succeeded'; keeperName: string; snapshot: KeeperCompositeSnapshot; fetchedAt: number }
  | { type: 'fetch_failed'; keeperName: string; error: string }

const MAX_OBSERVATIONS = 30
const MAX_TRANSITION_HISTORY = 20

const initialHubState: HubState = {
  keeperName: null,
  snapshot: null,
  loading: false,
  error: null,
  lastFetchAt: 0,
  observations: [],
}

const TRANSITION_FIELDS: Array<{ field: string; key: keyof Omit<CompositeObservation, 'ts'> }> = [
  { field: 'KSM', key: 'phase' },
  { field: 'KTC', key: 'turn' },
  { field: 'KDP', key: 'decision' },
  { field: 'KCL', key: 'cascade' },
  { field: 'KMC', key: 'compaction' },
]

function observeSnapshot(
  snapshot: KeeperCompositeSnapshot,
  ts: number,
): CompositeObservation {
  return {
    ts,
    phase: snapshot.phase,
    turn: snapshot.turn_phase,
    decision: snapshot.decision.stage,
    cascade: snapshot.cascade.state,
    compaction: snapshot.compaction.stage,
  }
}

function sameObservation(
  left: CompositeObservation,
  right: CompositeObservation,
): boolean {
  return left.phase === right.phase
    && left.turn === right.turn
    && left.decision === right.decision
    && left.cascade === right.cascade
    && left.compaction === right.compaction
}

export function appendCompositeObservation(
  observations: CompositeObservation[],
  next: CompositeObservation,
  maxEntries = MAX_OBSERVATIONS,
): CompositeObservation[] {
  const last = observations[observations.length - 1]
  if (last && sameObservation(last, next)) return observations
  return [...observations, next].slice(-Math.max(1, maxEntries))
}

export function deriveTransitionHistory(
  observations: CompositeObservation[],
  maxEntries = MAX_TRANSITION_HISTORY,
): TransitionEntry[] {
  const entries: TransitionEntry[] = []
  for (let index = 1; index < observations.length; index += 1) {
    const prev = observations[index - 1]
    const next = observations[index]
    if (!prev || !next) continue
    for (const { field, key } of TRANSITION_FIELDS) {
      if (prev[key] !== next[key]) {
        entries.push({
          ts: next.ts,
          from: prev[key],
          to: next[key],
          field,
        })
      }
    }
  }
  return entries.slice(-Math.max(1, maxEntries)).reverse()
}

export function derivePhaseLog(
  observations: CompositeObservation[],
  maxEntries = MAX_OBSERVATIONS,
): string[] {
  const phases: string[] = []
  for (const observation of observations) {
    if (phases[phases.length - 1] !== observation.phase) {
      phases.push(observation.phase)
    }
  }
  return phases.slice(-Math.max(1, maxEntries))
}

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

/**
 * FSM Hub — architecture audit surface for the composite keeper lifecycle.
 *
 * Layout redesign: Hero (KSM) + Pipeline strip (KTC→KDP→KCL→KMC) +
 * Health grid (measurement/invariants/recovery) + collapsible graph.
 *
 * Data source: `/api/v1/keepers/:name/composite` (RFC-0003 §7).
 */
export function FsmHub() {
  const [selected, setSelected] = useState<string | null>(null)
  const [hub, dispatch] = useReducer(reduceHubState, initialHubState)
  const [pollTick, setPollTick] = useState(0)
  const [now, setNow] = useState(() => Date.now() / 1000)
  const [graphOpen, setGraphOpen] = useState(false)
  const requestIdRef = useRef(0)

  const keeperList = keepers.value
  const keeperNames = useMemo(
    () => keeperList.map(k => k.name).sort(),
    [keeperList],
  )
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
        observationCount=${phaseLog.length}
      />

      ${activeSelected == null ? html`
        <${EmptyState} message="관찰할 키퍼를 선택하세요" />
      ` : loading && !snapshot ? html`
        <div class="flex items-center justify-center gap-2 py-10 text-[11px] text-[var(--text-dim)]">
          <span class="inline-block h-3 w-3 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin"></span>
          composite 스냅샷 로딩중
        </div>
      ` : error ? html`
        <${EmptyState} message=${error} compact />
      ` : snapshot ? html`
        ${/* ── Zone 2: Hero — KSM Phase ── */ ''}
        <${HeroPhase} snapshot=${snapshot} phaseLog=${phaseLog} />

        ${/* ── Zone 2b: Transition History Trail ── */ ''}
        <${TransitionTrail} history=${history} now=${now} />

        ${/* ── Zone 3: Turn Pipeline Strip ── */ ''}
        <${TurnPipelineStrip} snapshot=${snapshot} />

        ${/* ── Zone 4: Health Grid ── */ ''}
        <div class="grid gap-3 lg:grid-cols-3">
          <${MeasurementCard} snapshot=${snapshot} />
          <${InvariantsPanel} invariants=${snapshot.invariants} />
          <${RecoveryStatePanel}
            dataRecord=${snapshot.recovery.data_record}
            fsmCondition=${snapshot.recovery.fsm_condition}
          />
        </div>

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
  const liveBadge = snapshot
    ? snapshot.is_live
      ? html`<span class="px-2 py-0.5 rounded-full border text-[10px] font-mono text-emerald-400 border-emerald-500/40 bg-emerald-500/10 animate-pulse">● LIVE</span>`
      : html`<span class="px-2 py-0.5 rounded-full border text-[10px] font-mono text-[var(--text-dim)] border-white/10">○ idle ${fmtDuration(Math.max(0, now - (snapshot.last_outcome?.ended_at ?? snapshot.ts)))}</span>`
    : null

  const staleSec = lastFetchAt > 0 ? Math.max(0, now - lastFetchAt) : 0

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] px-4 py-2.5">
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-3">
          <span class="text-[10px] font-semibold uppercase tracking-[0.12em] text-[var(--text-muted)]">FSM Hub</span>
          ${liveBadge}
          ${loading ? html`<span class="inline-block h-2.5 w-2.5 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin"></span>` : null}
          ${staleSec > 60 ? html`<span class="text-[9px] font-mono text-amber-400">${fmtDuration(staleSec)} ago</span>` : null}
        </div>
        <div class="flex items-center gap-1.5 flex-wrap">
          ${keeperNames.map(name => {
            const active = name === selected
            const cls = active
              ? 'bg-[var(--accent-10)] border-[var(--accent-30)] text-[var(--accent)]'
              : 'bg-[var(--white-3)] border-[var(--white-8)] text-[var(--text-dim)] hover:text-[var(--text-body)] hover:border-[var(--accent-30)]'
            return html`
              <button
                class=${`rounded-full border px-2.5 py-0.5 text-[10px] font-mono transition-colors cursor-pointer ${cls}`}
                onClick=${() => onSelect(name)}
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
            turn ${snapshot.last_outcome ? `#${snapshot.last_outcome.turn_id}` : '—'}
          </span>
          <span class=${`px-1.5 py-0.5 rounded border ${transitionCount > 0 ? 'border-[rgba(129,140,248,0.3)] text-[#818cf8]' : 'border-[var(--white-8)] text-[var(--text-dim)]'}`}>
            ${transitionCount} transitions
          </span>
          <span class="px-1.5 py-0.5 rounded border border-[var(--white-8)] text-[var(--text-dim)]">
            ${observationCount} obs
          </span>
          ${/* Meta IDs */ ''}
          <span class="text-[var(--text-dim)] opacity-60">corr ${snapshot.correlation_id?.slice(-8) ?? '?'}</span>
          <span class="text-[var(--text-dim)] opacity-60">run ${snapshot.run_id?.slice(-8) ?? '?'}</span>
        </div>
      ` : null}
    </div>
  `
}

// ── Zone 2: Hero Phase ──────────────────────────────────

const PHASE_DOT_COLOR: Record<string, string> = {
  Running: 'bg-emerald-400',
  Compacting: 'bg-amber-400',
  HandingOff: 'bg-violet-400',
  Failing: 'bg-red-400',
  Crashed: 'bg-red-500',
  Draining: 'bg-amber-300',
  Restarting: 'bg-blue-400',
  Offline: 'bg-zinc-600',
  Paused: 'bg-zinc-600',
  Stopped: 'bg-zinc-600',
  Dead: 'bg-zinc-800',
}

function PhaseSparkline({ log }: { log: string[] }) {
  if (log.length < 2) return null
  return html`
    <div class="flex items-center gap-[3px] mt-2" title="Phase history (oldest → newest)">
      <span class="text-[8px] text-[var(--text-dim)] mr-1">history</span>
      ${log.map((phase, i) => {
        const isLast = i === log.length - 1
        const dotColor = PHASE_DOT_COLOR[phase] ?? 'bg-[var(--accent)]'
        const size = isLast ? 'w-2.5 h-2.5 ring-1 ring-white/20' : 'w-1.5 h-1.5'
        return html`<span class=${`rounded-full ${dotColor} ${size} shrink-0`} title=${phase}></span>`
      })}
    </div>
  `
}

function HeroPhase({ snapshot, phaseLog }: { snapshot: KeeperCompositeSnapshot; phaseLog: string[] }) {
  const prevRef = useRef(snapshot.phase)
  const [flash, setFlash] = useState(false)
  useEffect(() => {
    if (prevRef.current !== snapshot.phase) {
      prevRef.current = snapshot.phase
      setFlash(true)
      const id = setTimeout(() => setFlash(false), 2000)
      return () => clearTimeout(id)
    }
    return undefined
  }, [snapshot.phase])

  const phaseColor: Record<string, string> = {
    Running: 'text-emerald-400',
    Compacting: 'text-amber-400',
    HandingOff: 'text-violet-400',
    Failing: 'text-red-400',
    Crashed: 'text-red-500',
    Offline: 'text-[var(--text-dim)]',
    Paused: 'text-[var(--text-dim)]',
    Stopped: 'text-[var(--text-dim)]',
  }
  const color = phaseColor[snapshot.phase] ?? 'text-[var(--accent)]'

  return html`
    <div class=${`rounded-xl border p-5 transition-all duration-700 ${flash ? 'border-[var(--accent)] bg-[rgba(71,184,255,0.06)] shadow-[0_0_16px_rgba(71,184,255,0.2)]' : 'border-[var(--white-8)] bg-[var(--white-2)]'}`}>
      <div class="flex items-baseline justify-between">
        <div>
          <div class="text-[10px] font-semibold uppercase tracking-[0.1em] text-[var(--text-muted)]">KSM · Keeper Lifecycle</div>
          <div class=${`mt-1 font-mono text-[32px] font-bold tracking-tight ${color}`}>
            ${snapshot.phase}
          </div>
        </div>
        ${flash ? html`<span class="text-[10px] text-[var(--accent)] animate-pulse font-mono">phase changed</span>` : null}
      </div>
      <${PhaseSparkline} log=${phaseLog} />
    </div>
  `
}

// ── Zone 3: Turn Pipeline Strip ─────────────────────────

function PipelineStep({
  label,
  shortLabel,
  value,
  isLast,
}: {
  label: string
  shortLabel: string
  value: string
  isLast?: boolean
}) {
  const prevRef = useRef(value)
  const [flash, setFlash] = useState(false)
  useEffect(() => {
    if (prevRef.current !== value) {
      prevRef.current = value
      setFlash(true)
      const id = setTimeout(() => setFlash(false), 1200)
      return () => clearTimeout(id)
    }
    return undefined
  }, [value])

  const isActive = value !== 'idle' && value !== 'undecided' && value !== 'accumulating'
  const borderCls = flash
    ? 'border-[var(--accent)] shadow-[0_0_8px_rgba(71,184,255,0.35)]'
    : isActive
      ? 'border-[rgba(129,140,248,0.5)] shadow-[0_0_6px_rgba(129,140,248,0.15)]'
      : 'border-[var(--white-8)]'
  const bgCls = isActive && !flash
    ? 'bg-[rgba(129,140,248,0.04)]'
    : 'bg-[var(--white-2)]'
  const activePulse = isActive && !flash ? 'animate-pulse' : ''

  // Connector: animated dashes when active, static when idle
  const connectorCls = isActive
    ? 'border-t border-dashed border-[rgba(129,140,248,0.5)] animate-[marching-ants_1s_linear_infinite]'
    : 'border-t border-[var(--white-10)]'

  return html`
    <div class="flex items-center gap-0 flex-1 min-w-0">
      <div class=${`flex-1 rounded-lg border px-3 py-2 transition-all duration-500 ${borderCls} ${bgCls}`}>
        <div class="flex items-center gap-1.5">
          ${isActive ? html`<span class="h-1.5 w-1.5 rounded-full bg-[#818cf8] ${activePulse} shrink-0"></span>` : null}
          <span class="text-[9px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">${shortLabel}</span>
        </div>
        <div class=${`mt-0.5 font-mono text-[13px] font-semibold ${isActive ? 'text-[var(--text-strong)]' : 'text-[var(--text-dim)]'} ${flash ? 'animate-pulse' : ''}`}>
          ${value}
        </div>
        <div class="text-[8px] text-[var(--text-dim)] mt-0.5">${label}</div>
      </div>
      ${!isLast ? html`<div class=${`w-5 shrink-0 ${connectorCls}`}></div>` : null}
    </div>
  `
}

function TurnPipelineStrip({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="mb-2 text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        Turn Pipeline
      </div>
      <div class="flex gap-0 items-stretch">
        <${PipelineStep} shortLabel="KTC" label="Turn cycle" value=${snapshot.turn_phase} />
        <${PipelineStep} shortLabel="KDP" label="Decision" value=${snapshot.decision.stage} />
        <${PipelineStep} shortLabel="KCL" label="Cascade" value=${snapshot.cascade.state} />
        <${PipelineStep} shortLabel="KMC" label="Compaction" value=${snapshot.compaction.stage} isLast />
      </div>
    </div>
  `
}

// ── Zone 4: Health Grid ─────────────────────────────────

function MeasurementCard({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const m = snapshot.measurement
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">
        Measurement
      </div>
      ${m.captured && m.auto_rules ? html`
        <div class="flex flex-col gap-1.5 text-[11px] text-[var(--text-body)]">
          <div class="flex flex-wrap gap-1.5 font-mono">
            <${Flag} label="reflect" on=${m.auto_rules.reflect} />
            <${Flag} label="plan" on=${m.auto_rules.plan} />
            <${Flag} label="compact" on=${m.auto_rules.compact} />
            <${Flag} label="handoff" on=${m.auto_rules.handoff} />
          </div>
          <div class="flex items-center gap-2 font-mono">
            <${Flag} label="guardrail" on=${m.auto_rules.guardrail_stop} tone="warn" />
            <span class="text-[10px] text-[var(--text-dim)]">drift ${m.auto_rules.goal_drift.toFixed(2)}</span>
          </div>
          ${m.auto_rules.guardrail_reason ? html`
            <div class="text-[9px] text-[#f59e0b] mt-0.5">사유: ${m.auto_rules.guardrail_reason}</div>
          ` : null}
        </div>
      ` : html`
        <div class="text-[10px] text-[var(--text-dim)]">관측 대기</div>
      `}
    </div>
  `
}

function Flag({ label, on, tone = 'ok' }: { label: string; on: boolean; tone?: 'ok' | 'warn' }) {
  const offCls = 'text-[var(--text-dim)] border-[var(--white-8)]'
  const onCls =
    tone === 'warn'
      ? 'text-[#f59e0b] border-[rgba(251,191,36,0.3)] bg-[rgba(251,191,36,0.08)]'
      : 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
  return html`
    <span class=${`rounded-full border px-2 py-0.5 text-[10px] ${on ? onCls : offCls}`}>
      ${label}
    </span>
  `
}

const INVARIANT_LABELS: Record<keyof KeeperCompositeInvariants, string> = {
  phase_turn_alignment: 'Phase ⇔ Turn',
  no_cascade_before_measurement: 'Cascade ordering',
  compaction_atomicity: 'Compaction atomic',
  event_priority_monotone: 'Event priority',
  recovery_two_store_sync: 'Two-store sync',
}

function InvariantsPanel({ invariants }: { invariants: KeeperCompositeInvariants }) {
  const entries = Object.entries(invariants) as [keyof KeeperCompositeInvariants, boolean][]
  const allOk = entries.every(([, ok]) => ok)
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="flex items-center justify-between mb-2">
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          Safety
        </div>
        <span class=${`rounded-full border px-2 py-0.5 text-[9px] font-mono ${
          allOk
            ? 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
            : 'text-[#ef4444] border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)]'
        }`}>
          ${allOk ? '5/5' : 'violation'}
        </span>
      </div>
      <ul class="flex flex-col gap-1">
        ${entries.map(([key, ok]) => html`
          <li class="flex items-center gap-1.5 text-[10px]">
            <span class=${`h-1.5 w-1.5 rounded-full shrink-0 ${ok ? 'bg-[#22c55e]' : 'bg-[#ef4444]'}`}></span>
            <span class=${ok ? 'text-[var(--text-body)]' : 'text-[#f87171] font-semibold'}>
              ${INVARIANT_LABELS[key]}
            </span>
          </li>
        `)}
      </ul>
    </div>
  `
}

function RecoveryStatePanel({
  dataRecord,
  fsmCondition,
}: {
  dataRecord: boolean
  fsmCondition: boolean
}) {
  const state =
    !dataRecord && !fsmCondition ? 'clean' :
    dataRecord && fsmCondition ? 'reconcile_pending' :
    dataRecord && !fsmCondition ? 'drift: data↑ fsm↓' :
    'drift: fsm↑ data↓'
  const isClean = state === 'clean'
  const isDrift = state.startsWith('drift')
  const toneCls = isClean ? 'text-[#22c55e]' : isDrift ? 'text-[#ef4444]' : 'text-[#f59e0b]'
  const borderCls = isClean ? 'border-[var(--white-8)]' : isDrift ? 'border-[rgba(239,68,68,0.3)]' : 'border-[rgba(245,158,11,0.3)]'

  return html`
    <div class=${`rounded-xl border bg-[var(--white-2)] p-3 ${borderCls}`}>
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">
        Recovery
      </div>
      <div class=${`font-mono text-[13px] font-semibold ${toneCls}`}>${state}</div>
      <div class="mt-1.5 flex gap-3 text-[9px] text-[var(--text-dim)]">
        <span>data <span class="font-mono">${String(dataRecord)}</span></span>
        <span>fsm <span class="font-mono">${String(fsmCondition)}</span></span>
      </div>
    </div>
  `
}

// ── Compound Graph (collapsed by default) ───────────────

function CompositeGraphPanel({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const spec = useMemo(() => buildCompositeFsmSpec({
    phase: snapshot.phase,
    turnPhase: snapshot.turn_phase,
    decisionStage: snapshot.decision.stage,
    cascadeState: snapshot.cascade.state,
    compactionStage: snapshot.compaction.stage,
  }), [
    snapshot.phase,
    snapshot.turn_phase,
    snapshot.decision.stage,
    snapshot.cascade.state,
    snapshot.compaction.stage,
  ])

  return html`<${CytoscapeFsm} spec=${spec} height="320px" />`
}

// ── Zone 2b: Transition History Trail ────────────────────

const FIELD_COLOR: Record<string, string> = {
  KSM: 'text-[var(--accent)]',
  KTC: 'text-[#818cf8]',
  KDP: 'text-[#818cf8]',
  KCL: 'text-[#818cf8]',
  KMC: 'text-[#f59e0b]',
}

function TransitionTrail({
  history,
  now,
}: {
  history: { ts: number; from: string; to: string; field: string }[]
  now: number
}) {
  if (history.length === 0) {
    return html`
      <div class="rounded-lg border border-dashed border-[var(--white-8)] px-4 py-2 text-center text-[10px] text-[var(--text-dim)]">
        관찰 시작 이후 상태 전이 없음 — 전이가 발생하면 여기에 기록됩니다
      </div>
    `
  }

  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] px-3 py-2">
      <div class="mb-1.5 text-[9px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        Transition History (${history.length})
      </div>
      <div class="flex flex-col gap-0.5 max-h-[120px] overflow-y-auto">
        ${history.map(entry => {
          const ago = fmtDuration(Math.max(0, now - entry.ts))
          const color = FIELD_COLOR[entry.field] ?? 'text-[var(--text-body)]'
          return html`
            <div class="flex items-center gap-2 text-[10px] font-mono leading-tight">
              <span class="w-[52px] shrink-0 text-right text-[var(--text-dim)]">${ago} ago</span>
              <span class=${`w-[28px] shrink-0 font-semibold ${color}`}>${entry.field}</span>
              <span class="text-[var(--text-dim)]">${entry.from}</span>
              <span class="text-[var(--text-muted)]">→</span>
              <span class="text-[var(--text-strong)]">${entry.to}</span>
            </div>
          `
        })}
      </div>
    </div>
  `
}

// ── Utilities ───────────────────────────────────────────

function fmtDuration(seconds: number): string {
  if (seconds < 0) return '0s'
  const s = Math.floor(seconds)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  const rem = s % 60
  if (m < 60) return `${m}m ${rem}s`
  const h = Math.floor(m / 60)
  return `${h}h ${m % 60}m`
}
