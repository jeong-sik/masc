import { html } from 'htm/preact'
import { useEffect, useMemo, useReducer, useRef, useState } from 'preact/hooks'
import { InlineSpinner } from './common/inline-spinner'
import { DialogOverlay } from './common/dialog'
import { TextInput } from './common/input'
import { formatMsCompact } from '../lib/format-number'

import {
  fetchKeeperComposite,
  type KeeperCompositeExecution,
  type KeeperCompositeSnapshot,
  type KeeperRuntimeTraceResponse,
} from '../api/keeper'
import { fetchGateKeepers } from '../api/gate'
import { executionLoaded, keepers, refreshExecution } from '../store'
import { compositeTick } from '../composite-signals'
import { nowSecondsSignal, useNowSecondsTicker } from '../lib/now-signal'
import { useGlobalShortcut } from '../lib/use-global-shortcut'
import { EmptyState } from './common/feedback-state'
import { Kbd } from './common/kbd'

import {
  type HoveredSegment,
  type HubAction,
  type HubFetchStatus,
  type HubState,
  initialHubState,
  fmtDuration,
  MAX_OBSERVATIONS,
} from './fsm-hub-types'
import {
  observeSnapshot,
  appendCompositeObservation,
  deriveTopTransitions,
  deriveTransitionHistory,
  derivePhaseLog,
  deriveStateEntries,
} from './fsm-hub-derivations'
import { OperationalMeaningPanel, HeroPhase, TurnPipelineStrip, CompositeGraphPanel } from './fsm-hub-pipeline-panels'
import { DwellHistogramPanel, SwimlaneTimeline, TopTransitionsPanel, TransitionTrail } from './fsm-hub-timeline-panels'
import { MeasurementCard, InvariantsPanel } from './fsm-hub-health-panels'
import { ringFocusClasses } from './common/ring'
import { formatIndependentCounters, formatRatioPair } from './counter-format'

export function shouldUseGateKeeperFallback(
  executionLoadedValue: boolean,
  storeNames: string[],
): boolean {
  return !executionLoadedValue && storeNames.length === 0
}

/**
 * Pure filter for the keeper tab list rendered in the FSM Hub status bar.
 *
 * Case-insensitive substring match on the full keeper name. Operators on a
 * fleet with many keepers (keeper-planner-agent, keeper-critic-agent,
 * keeper-router-agent, ...) otherwise scan the whole tab row to pick one.
 *
 * Empty/whitespace query returns the input reference unchanged so the
 * caller's useMemo identity is preserved for the non-filtering path (no
 * new array allocation, stable reference for downstream deps).
 *
 * Input is never mutated.
 */
export function filterKeeperNames(
  names: readonly string[],
  query: string,
): readonly string[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return names
  return names.filter(name => name.toLowerCase().includes(needle))
}

export function isCompositeFetchNotFound(err: unknown): boolean {
  return err instanceof Error && /composite fetch failed: 404$/.test(err.message)
}

function shortText(value: string | null | undefined, max = 80): string {
  const text = (value ?? '').trim()
  if (!text) return ''
  return text.length > max ? `${text.slice(0, max)}...` : text
}

const formatMs = formatMsCompact

function executionReceiptTone(execution: KeeperCompositeExecution | undefined): 'ok' | 'warn' | 'bad' | 'muted' {
  if (!execution?.latest_receipt_present) return 'muted'
  // `execution.outcome` wire format is the TLA-prefix form emitted by
  // `outcome_kind_to_tla_receipt`
  // (lib/keeper/keeper_execution_receipt.ml:24-29). 'ok' / 'error' short
  // forms never appear on this field — those compares were dead, so the
  // receipt tone never reached 'ok' or 'bad' regardless of actual outcome.
  const outcome = execution.outcome?.toLowerCase()
  const terminal = execution.terminal_reason_code?.toLowerCase() ?? ''
  if (outcome === 'receipt_done' || outcome === 'receipt_skipped' || terminal === 'completed') return 'ok'
  if (terminal.includes('config') || terminal.includes('exhausted') || outcome === 'receipt_failed') return 'bad'
  return 'warn'
}

function executionReceiptLabel(execution: KeeperCompositeExecution | undefined): string | null {
  if (!execution) return null
  if (!execution.latest_receipt_present) return 'receipt 없음'
  const terminal = shortText(execution.terminal_reason_code, 32)
  const elapsed = formatMs(execution.duration_ms)
  return [
    execution.outcome ?? 'unknown',
    terminal,
    elapsed,
  ].filter(Boolean).join(' · ')
}

function executionReceiptTitle(execution: KeeperCompositeExecution | undefined): string {
  if (!execution?.latest_receipt_present) return '아직 execution receipt가 없습니다.'
  return [
    execution.recorded_at ? `recorded_at: ${execution.recorded_at}` : '',
    execution.operator_disposition ? `operator: ${execution.operator_disposition}` : '',
    execution.operator_disposition_reason ? `reason: ${execution.operator_disposition_reason}` : '',
    execution.runtime?.fallback_reason ? `fallback: ${execution.runtime.fallback_reason}` : '',
    execution.error?.kind ? `error: ${execution.error.kind}` : '',
    execution.error?.message_preview ? execution.error.message_preview : '',
  ].filter(Boolean).join('\n')
}

function executionReceiptClass(execution: KeeperCompositeExecution | undefined): string {
  switch (executionReceiptTone(execution)) {
    case 'ok':
      return 'border-[var(--ok-20)] text-[var(--color-status-ok)] bg-[var(--ok-10)]'
    case 'bad':
      return 'border-[var(--bad-30)] text-[var(--bad-light)] bg-[var(--bad-6)]'
    case 'warn':
      return 'border-[var(--warn-20)] text-[var(--color-status-warn)] bg-[var(--warn-10)]'
    case 'muted':
      return 'border-[var(--color-border-default)] text-[var(--color-fg-disabled)] bg-[var(--color-bg-surface)]'
  }
}

function runtimeTraceTone(trace: KeeperRuntimeTraceResponse): 'ok' | 'warn' | 'bad' | 'muted' {
  const health = trace.health.toLowerCase()
  if (health === 'ok' || health === 'healthy') return 'ok'
  if (health === 'stale' || health === 'partial' || health === 'warning') return 'warn'
  if (health === 'missing' || health === 'error' || health.includes('gap')) return 'bad'
  return trace.manifest_path_present ? 'warn' : 'muted'
}

function runtimeTraceClass(trace: KeeperRuntimeTraceResponse): string {
  switch (runtimeTraceTone(trace)) {
    case 'ok':
      return 'border-[var(--ok-20)] text-[var(--color-status-ok)] bg-[var(--ok-10)]'
    case 'bad':
      return 'border-[var(--bad-30)] text-[var(--bad-light)] bg-[var(--bad-6)]'
    case 'warn':
      return 'border-[var(--warn-20)] text-[var(--color-status-warn)] bg-[var(--warn-10)]'
    case 'muted':
      return 'border-[var(--color-border-default)] text-[var(--color-fg-disabled)] bg-[var(--color-bg-surface)]'
  }
}

function runtimeProviderAttemptClass(trace: KeeperRuntimeTraceResponse): string {
  const provider = trace.provider_attempts
  const status = provider.terminal_status?.toLowerCase() ?? ''
  if (provider.finished_count < provider.started_count) {
    return 'border-[var(--bad-30)] text-[var(--bad-light)] bg-[var(--bad-6)]'
  }
  if (status === 'provider_returned') {
    return 'border-[var(--ok-20)] text-[var(--color-status-ok)] bg-[var(--ok-10)]'
  }
  if (status === 'timeout' || status === 'error' || status === 'exception' || status === 'cancelled') {
    return 'border-[var(--bad-30)] text-[var(--bad-light)] bg-[var(--bad-6)]'
  }
  return 'border-[var(--color-border-default)] text-[var(--color-fg-muted)] bg-[var(--color-bg-surface)]'
}

function runtimeProviderAttemptLabel(trace: KeeperRuntimeTraceResponse): string {
  const provider = trace.provider_attempts
  if (provider.started_count === 0 && provider.finished_count === 0) return 'prov none'
  const status = shortText(provider.terminal_status, 18) || 'unknown'
  return ['prov', status].filter(Boolean).join(' ')
}

function formatRuntimeTraceUnknown(value: unknown): string {
  if (value == null) return ''
  if (typeof value === 'string') return shortText(value, 160)
  try {
    return shortText(JSON.stringify(value), 160)
  } catch {
    return String(value)
  }
}

function runtimeTraceTurnLabel(trace: KeeperRuntimeTraceResponse): string {
  const keeperTurn = trace.turn_identity.requested_keeper_turn_id
    ?? trace.turn_identity.manifest_keeper_turn_ids.at(-1)
    ?? null
  const oasTurn = trace.turn_identity.max_oas_turn_count
  const keeperLabel = keeperTurn == null ? '—' : `#${keeperTurn}`
  const oasLabel = oasTurn == null ? '—' : String(oasTurn)
  return `turn ${keeperLabel} / oas ${oasLabel}`
}

function runtimeTraceTitle(trace: KeeperRuntimeTraceResponse): string {
  const turn = trace.turn_identity
  const eventBus = trace.event_bus
  const memory = trace.memory
  const provider = trace.provider_attempts
  return [
    `trace_id: ${trace.trace_id || '(unknown)'}`,
    trace.stale_reason ? `stale_reason: ${trace.stale_reason}` : '',
    trace.manifest_path ? `manifest: ${trace.manifest_path}` : '',
    // manifest_returned_rows ≤ manifest_total_rows is a true invariant pair.
    `manifest rows: ${formatRatioPair({ numerator: trace.manifest_returned_rows, denominator: trace.manifest_total_rows })}`,
    `receipt rows: ${trace.receipt_returned_rows}`,
	    turn.manifest_keeper_turn_ids.length > 0 ? `keeper_turn_ids: ${turn.manifest_keeper_turn_ids.join(', ')}` : '',
	    turn.receipt_turn_counts.length > 0 ? `receipt_turn_counts: ${turn.receipt_turn_counts.join(', ')}` : '',
	    // provider_attempt_finished ≤ provider_attempt_started is a true invariant pair
	    // (a finish is always preceded by a start). Started is the denominator.
	    `provider attempts: ${formatRatioPair({ numerator: turn.provider_attempt_finished_count, denominator: turn.provider_attempt_started_count })}`,
	    provider.terminal_status ? `provider terminal: ${provider.terminal_status}` : '',
	    provider.terminal_exception_kind ? `provider exception: ${provider.terminal_exception_kind}` : '',
	    provider.terminal_error ? `provider error: ${shortText(provider.terminal_error, 220)}` : '',
	    eventBus.correlation_ids.length > 0 ? `correlation_ids: ${eventBus.correlation_ids.join(', ')}` : '',
    eventBus.run_ids.length > 0 ? `run_ids: ${eventBus.run_ids.join(', ')}` : '',
    // context_compacted ≤ context_compact_started is a true invariant pair.
    `context compaction: ${formatRatioPair({ numerator: eventBus.context_compacted_count, denominator: eventBus.context_compact_started_count })}`,
    formatRuntimeTraceUnknown(eventBus.last_compaction),
    // memory_injected_count and memory_flushed_count are independent monotonic
    // lifetime counters — no invariant relation between them. Avoid slash UI
    // (e.g. "909/722" would read as 126% ratio).
    `memory: ${formatIndependentCounters({
      leftLabel: 'injected',
      leftValue: memory.memory_injected_count,
      rightLabel: 'flushed',
      rightValue: memory.memory_flushed_count,
    })}`,
    // memory_flush_success_count and memory_flush_error_count are independent
    // outcome tallies (one or the other increments per flush), not a ratio.
    `memory flush: ${formatIndependentCounters({
      leftLabel: 'ok',
      leftValue: memory.memory_flush_success_count,
      rightLabel: 'error',
      rightValue: memory.memory_flush_error_count,
    })}`,
  ].filter(Boolean).join('\n')
}

function RuntimeEvidenceSummary({
  trace,
}: {
  trace?: KeeperRuntimeTraceResponse | null
}) {
  if (!trace) return null
  const eventBus = trace.event_bus
  const memory = trace.memory
  const commonClass = 'px-1.5 py-0.5 rounded-[var(--r-1)] border text-3xs font-mono'
  const title = runtimeTraceTitle(trace)
  return html`
    <span class=${`${commonClass} ${runtimeTraceClass(trace)}`} title=${title}>
      trace ${trace.health || 'unknown'}
    </span>
	    <span class=${`${commonClass} border-[var(--color-border-default)] text-[var(--color-fg-primary)]`} title=${title}>
	      ${runtimeTraceTurnLabel(trace)}
	    </span>
	    <span class=${`${commonClass} ${runtimeProviderAttemptClass(trace)}`} title=${title}>
	      ${runtimeProviderAttemptLabel(trace)}
	    </span>
	    <span class=${`${commonClass} border-[var(--info-border)] text-[var(--info-fg)]`} title=${title}>
      evt ${eventBus.event_bus_correlated_count} · ctx ${formatRatioPair({ numerator: eventBus.context_compacted_count, denominator: eventBus.context_compact_started_count })}
    </span>
    <span class=${`${commonClass} border-[var(--color-border-default)] text-[var(--color-fg-muted)]`} title=${title}>
      mem ${formatIndependentCounters({ leftLabel: 'inj', leftValue: memory.memory_injected_count, rightLabel: 'flush', rightValue: memory.memory_flushed_count })}
    </span>
  `
}

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
    case 'fetch_started': {
      // Preserve `'fresh'` payload across a refetch only as `'stale'`.
      // The previous reducer kept `snapshot` populated and merely
      // flipped `loading=true, error=null` — that is the Workaround
      // Rejection Bar §2 surface (Unknown→Permissive Default).
      const prev = current.status
      const nextStatus: HubFetchStatus = ((): HubFetchStatus => {
        switch (prev.kind) {
          case 'idle':
          case 'loading':
          case 'error':
            return { kind: 'loading' }
          case 'fresh':
          case 'stale':
            return { kind: 'loading' }
        }
      })()
      return {
        ...current,
        keeperName: action.keeperName,
        status: nextStatus,
      }
    }
    case 'fetch_succeeded': {
      const observation = observeSnapshot(action.snapshot, action.fetchedAt)
      const inv = action.snapshot.invariants
      const violations = { ...current.invariantViolations }
      for (const key of Object.keys(violations) as Array<keyof typeof violations>) {
        if (!inv[key]) violations[key] += 1
      }
      return {
        keeperName: action.keeperName,
        status: { kind: 'fresh', snapshot: action.snapshot, fetchedAt: action.fetchedAt },
        observations: appendCompositeObservation(current.observations, observation),
        invariantSampleCount: current.invariantSampleCount + 1,
        invariantViolations: violations,
      }
    }
    case 'fetch_failed': {
      const prev = current.status
      const nextStatus: HubFetchStatus = ((): HubFetchStatus => {
        switch (prev.kind) {
          case 'fresh':
            return {
              kind: 'stale',
              snapshot: prev.snapshot,
              fetchedAt: prev.fetchedAt,
              stalenessMs: Math.max(0, action.failedAt - prev.fetchedAt),
              error: action.error,
            }
          case 'stale':
            return {
              kind: 'stale',
              snapshot: prev.snapshot,
              fetchedAt: prev.fetchedAt,
              stalenessMs: Math.max(0, action.failedAt - prev.fetchedAt),
              error: action.error,
            }
          case 'idle':
          case 'loading':
          case 'error':
            return { kind: 'error', error: action.error }
        }
      })()
      return {
        ...current,
        keeperName: action.keeperName,
        status: nextStatus,
      }
    }
  }
}

// ── Main Component ─────────────────────────────────────

/**
 * FSM Hub — architecture audit surface for the composite keeper lifecycle.
 *
 * Layout redesign: Hero (KSM) + Pipeline strip (KTC->KDP->KCL->KMC) +
 * Health grid (measurement/invariants) + collapsible graph.
 *
 * Data source: `/api/v1/keepers/:name/composite` (RFC-0003 S7).
 */
export interface FsmHubProps {
  /** Optional externally-driven selection — used by the fleet matrix
   *  (LT-16d) to drive drill-through. When it changes, the hub
   *  switches to the requested keeper on the next render. */
  selectedName?: string | null
  /** Surface variant. `'fleet'` (default) renders the keeper selector
   *  tablist for in-hub switching. `'detail'` (RFC-0046) hides the
   *  selector — the parent surface (keeper detail page) has already
   *  pinned a single keeper, so re-offering selection is noise. */
  mode?: 'fleet' | 'detail'
  /** RFC-0046 §7 #2 follow-up: parent-supplied composite snapshot.
   *  When the prop is present (not `undefined`), this hub stops
   *  issuing its own /composite poll and feeds the parent value into
   *  its reducer as a `fetch_succeeded` event. `null` means the
   *  parent is loading — wait, do not race a duplicate fetch.
   *  Only honoured in `mode='detail'`; in `'fleet'` mode the keeper
   *  selector tablist drives `selectedName` directly and the parent
   *  has no single snapshot to share. */
  externalSnapshot?: KeeperCompositeSnapshot | null
  /** Parent-supplied runtime manifest/receipt evidence for detail mode. */
  runtimeTrace?: KeeperRuntimeTraceResponse | null
}

export function FsmHub(props: FsmHubProps = {}) {
  const mode = props.mode ?? 'fleet'
  // RFC-0046 §7 #2: parent-supplied snapshot only honoured in 'detail'
  // mode. Fleet mode drives selection internally and has no single
  // snapshot to share, so we fall back to the existing fetch path.
  const externalSnapshot = mode === 'detail' ? props.externalSnapshot : undefined
  const [selected, setSelected] = useState<string | null>(props.selectedName ?? null)
  useEffect(() => {
    if (props.selectedName !== undefined && props.selectedName !== selected) {
      setSelected(props.selectedName)
    }
    // Only react to external changes; local selection stays internal.
  }, [props.selectedName])
  const [hub, dispatch] = useReducer(reduceHubState, initialHubState)
  const [keeperFilter, setKeeperFilter] = useState('')
  const [pollTick, setPollTick] = useState(0)
  // The 5 s wall-clock signal is now subscribed to by each leaf that
  // actually displays elapsed durations — this hub component itself
  // never reads `nowSecondsSignal.value`, so 5 s ticks no longer
  // re-render the full FsmHub render tree.  Each leaf (StatusBar,
  // OperationalMeaningPanel, HeroPhase + PhaseSparkline, PipelineStep,
  // SwimlaneTimeline, TransitionTrail, DwellHistogramPanel) calls
  // `useNowSecondsTicker` on its own and refcounts the shared interval.
  const [graphOpen, setGraphOpen] = useState(false)
  const [hoveredSegment, setHoveredSegment] = useState<HoveredSegment | null>(null)
  const [gateKeeperNames, setGateKeeperNames] = useState<string[]>([])
  const [refreshFlash, setRefreshFlash] = useState(false)
  const flashTimeoutRef = useRef<number | null>(null)
  const refreshNow = () => {
    setPollTick(t => t + 1)
    setRefreshFlash(true)
    if (flashTimeoutRef.current != null) window.clearTimeout(flashTimeoutRef.current)
    flashTimeoutRef.current = window.setTimeout(() => {
      setRefreshFlash(false)
      flashTimeoutRef.current = null
    }, 800)
  }

  useEffect(() => () => {
    if (flashTimeoutRef.current != null) window.clearTimeout(flashTimeoutRef.current)
  }, [])

  useEffect(() => {
    if (typeof window === 'undefined') return undefined
    const handler = (ev: KeyboardEvent) => {
      if (ev.metaKey || ev.ctrlKey || ev.altKey) return
      const target = ev.target as HTMLElement | null
      if (target) {
        const tag = target.tagName
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return
        if (target.isContentEditable) return
      }
      if (ev.key === 'r') {
        ev.preventDefault()
        refreshNow()
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [])
  const [paused, setPaused] = useState(() =>
    typeof document !== 'undefined' && document.visibilityState === 'hidden',
  )
  const [shortcutsOpen, setShortcutsOpen] = useState(false)
  const shortcutsOpenRef = useRef(false)
  const [density, setDensity] = useState<'comfortable' | 'compact'>(() => {
    if (typeof window === 'undefined') return 'comfortable'
    const stored = window.localStorage.getItem('fsm-hub:density')
    return stored === 'compact' ? 'compact' : 'comfortable'
  })
  const requestIdRef = useRef(0)

  useEffect(() => {
    shortcutsOpenRef.current = shortcutsOpen
  }, [shortcutsOpen])

  useEffect(() => {
    if (typeof window === 'undefined') return
    window.localStorage.setItem('fsm-hub:density', density)
  }, [density])

  useEffect(() => {
    if (typeof window === 'undefined') return undefined
    const handler = (ev: KeyboardEvent) => {
      if (ev.metaKey || ev.ctrlKey || ev.altKey) return
      const target = ev.target as HTMLElement | null
      if (target) {
        const tag = target.tagName
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return
        if (target.isContentEditable) return
      }
      if (ev.key === 'd') {
        ev.preventDefault()
        setDensity(d => d === 'comfortable' ? 'compact' : 'comfortable')
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [])

  useEffect(() => {
    if (typeof document === 'undefined') return undefined
    const handler = () => {
      const hidden = document.visibilityState === 'hidden'
      setPaused(hidden)
      if (!hidden) {
        setPollTick(t => t + 1)
      }
    }
    document.addEventListener('visibilitychange', handler)
    return () => document.removeEventListener('visibilitychange', handler)
  }, [])

  useEffect(() => {
    if (typeof window === 'undefined') return undefined
    const handler = (ev: KeyboardEvent) => {
      if (ev.metaKey || ev.ctrlKey || ev.altKey) return
      const target = ev.target as HTMLElement | null
      if (target) {
        const tag = target.tagName
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return
        if (target.isContentEditable) return
      }
      if (ev.key === '?') {
        ev.preventDefault()
        setShortcutsOpen(o => !o)
      } else if (ev.key === 'Escape' && shortcutsOpenRef.current) {
        setShortcutsOpen(false)
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [])

  // Primary source: store signal (from dashboard/shell polling).
  // Fallback: direct gate fetch — the shell endpoint omits keeper
  // details (only sends configured_keepers count), so without this
  // fallback the FsmHub sees zero keepers and renders empty state.
  const storeKeeperList = keepers.value
  const executionLoadedValue = executionLoaded.value
  const storeNames = useMemo(
    () => storeKeeperList.map(k => k.name).sort(),
    [storeKeeperList],
  )
  useEffect(() => {
    if (!shouldUseGateKeeperFallback(executionLoadedValue, storeNames)) return
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
        // Gate endpoint auth failure or network error — keep the last
        // successful fallback snapshot until the primary store path lands.
      }
    })()
    return () => { cancelled = true }
  }, [executionLoadedValue, storeNames, pollTick])

  const keeperNames = shouldUseGateKeeperFallback(executionLoadedValue, storeNames)
    ? gateKeeperNames
    : storeNames
  const visibleKeeperNames = useMemo(
    () => filterKeeperNames(keeperNames, keeperFilter),
    [keeperNames, keeperFilter],
  )
  const activeSelected = useMemo(() => {
    if (selected && keeperNames.includes(selected)) return selected
    return keeperNames[0] ?? null
  }, [keeperNames, selected])

  useEffect(() => {
    if (paused) return undefined
    // pollTick was previously a dep, but the interval body already
    // self-triggers via setPollTick(t => t + 1) — including pollTick
    // forced clearInterval + setInterval every 30 s for nothing.
    const id = setInterval(() => setPollTick(t => t + 1), 30_000)
    return () => clearInterval(id)
  }, [paused])

  // The 5 s tick that previously lived here is now provided by
  // useNowSecondsTicker() above (shared, ref-counted, runs once
  // module-wide regardless of how many fsm-hubs are mounted).

  const tick = compositeTick.value
  const shouldRefetchForTick =
    activeSelected != null && tick.name === activeSelected ? tick.ts_unix : 0

  useEffect(() => {
    if (!activeSelected) return

    // RFC-0046 §7 #2: parent supplies the snapshot in 'detail' mode.
    // Inject it into the reducer instead of issuing a duplicate fetch.
    // `null` = parent is still loading — emit fetch_started so the
    // skeleton UI shows, then wait for the next prop update.
    if (externalSnapshot !== undefined) {
      if (externalSnapshot == null) {
        dispatch({ type: 'fetch_started', keeperName: activeSelected })
      } else {
        dispatch({
          type: 'fetch_succeeded',
          keeperName: activeSelected,
          snapshot: externalSnapshot,
          fetchedAt: Date.now() / 1000,
        })
      }
      return
    }

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
        const failedAt = Date.now() / 1000
        if (isCompositeFetchNotFound(err)) {
          setGateKeeperNames(prev => prev.filter(name => name !== activeSelected))
          setSelected(prev => (prev === activeSelected ? null : prev))
          void refreshExecution({ force: true })
          dispatch({
            type: 'fetch_failed',
            keeperName: activeSelected,
            error: '선택한 keeper가 종료되었거나 등록 해제되었습니다',
            failedAt,
          })
          return
        }
        dispatch({
          type: 'fetch_failed',
          keeperName: activeSelected,
          error: err instanceof Error ? err.message : 'composite fetch failed',
          failedAt,
        })
      }
    })()
  }, [activeSelected, shouldRefetchForTick, pollTick, externalSnapshot])

  useGlobalShortcut(
    (ev) => ev.key >= '1' && ev.key <= '9',
    (ev) => {
      const idx = ev.key.charCodeAt(0) - '1'.charCodeAt(0)
      const name = keeperNames[idx]
      if (name) setSelected(name)
    },
    [keeperNames],
  )

  useGlobalShortcut(
    (ev) => ev.key === 'g',
    () => setGraphOpen(o => !o),
  )

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
  const topTransitions = useMemo(
    () => deriveTopTransitions(view.observations),
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
  // dwellHistograms moved into DwellHistogramPanel itself — that panel
  // owns its own 5 s clock subscription so this component stays stable
  // on ticks. (Previously this useMemo recomputed every 5 s because of
  // the `now` dep, dragging fsm-hub through the same render every time.)
  // Project the typed status onto the flat shape the JSX expects.
  // `snapshot` is only non-null when the status is `'fresh'` — the
  // prior reducer leaked stale snapshots through error paths (the
  // bug this PR closes). `'stale'` is intentionally surfaced via
  // `error` so the empty-state panel takes over and the operator
  // sees the failure message instead of rendered cards backed by a
  // last-known snapshot. Consumers that want explicit stale rendering
  // can `switch` on `view.status.kind` directly. Exhaustive — no
  // `default:` clause so a new arm is a compile error.
  const projectedView = ((): {
    snapshot: KeeperCompositeSnapshot | null
    loading: boolean
    error: string | null
    lastFetchAt: number
  } => {
    const status: HubFetchStatus = view.status
    switch (status.kind) {
      case 'idle':
        return { snapshot: null, loading: false, error: null, lastFetchAt: 0 }
      case 'loading':
        return { snapshot: null, loading: true, error: null, lastFetchAt: 0 }
      case 'fresh':
        return { snapshot: status.snapshot, loading: false, error: null, lastFetchAt: status.fetchedAt }
      case 'stale':
        return { snapshot: null, loading: false, error: status.error, lastFetchAt: status.fetchedAt }
      case 'error':
        return { snapshot: null, loading: false, error: status.error, lastFetchAt: 0 }
    }
  })()
  const { snapshot, loading, error, lastFetchAt } = projectedView

  const rootGap = density === 'compact' ? 'gap-1.5' : 'gap-3'
  return html`
    <div class=${`fsm-hub-surface v2-monitoring-surface contain-content flex flex-col ${rootGap}`} data-density=${density}>
      ${/* ── Zone 1: Status Bar ── */ ''}
      <${StatusBar}
        snapshot=${snapshot}
        lastFetchAt=${lastFetchAt}
        density=${density}
        onDensityToggle=${() => setDensity(d => d === 'comfortable' ? 'compact' : 'comfortable')}
        keeperNames=${keeperNames}
        visibleKeeperNames=${visibleKeeperNames}
        keeperFilter=${keeperFilter}
        onKeeperFilterChange=${setKeeperFilter}
        selected=${activeSelected}
        onSelect=${setSelected}
        loading=${loading}
        paused=${paused}
        onRefresh=${refreshNow}
        refreshFlash=${refreshFlash}
        transitionCount=${history.length}
        observationCount=${view.observations.length}
        mode=${mode}
        runtimeTrace=${mode === 'detail' ? props.runtimeTrace ?? null : null}
      />

      ${activeSelected == null ? html`
        <${EmptyState} message=${mode === 'detail'
          ? 'composite snapshot을 받지 못했습니다 — keeper 이름을 확인하거나 새로고침하세요'
          : keeperNames.length > 0
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
        />

        ${/* ── Zone 2: Hero — KSM Phase ── */ ''}
        <${HeroPhase} snapshot=${snapshot} phaseLog=${phaseLog} observations=${view.observations} phaseSince=${stateEntries?.phase ?? null} />

        ${/* ── Zone 2b: Turn Pipeline Strip (always visible) ── */ ''}
        <${TurnPipelineStrip} snapshot=${snapshot} stateEntries=${stateEntries} />

        ${/* ── Zone 3: Timeline + Analytics (2-column on wide screens) ── */ ''}
        <div class="grid gap-3 lg:grid-cols-2">
          <div class="flex flex-col gap-3">
            ${/* ── Zone 3a: Swimlane Timeline ── */ ''}
            <${CollapsibleZone} id="swimlane" title="상태 타임라인" defaultOpen=${true}>
              <${SwimlaneTimeline}
                observations=${view.observations}
                hoveredSegment=${hoveredSegment}
                onHoverSegment=${setHoveredSegment}
              />
            <//>
            ${/* ── Zone 3b: Transition History ── */ ''}
            <${CollapsibleZone} id="transition-trail" title="전환 이력" defaultOpen=${true}>
              <${TransitionTrail} history=${history} hoveredSegment=${hoveredSegment} />
            <//>
          </div>
          <div class="flex flex-col gap-3">
            ${/* ── Zone 3c: State Dwell Time ── */ ''}
            <${CollapsibleZone} id="dwell-histogram" title="상태 체류 시간" defaultOpen=${true}>
              <${DwellHistogramPanel} observations=${view.observations} hoveredSegment=${hoveredSegment} />
            <//>
            ${/* ── Zone 3d: Top Transitions ── */ ''}
            <${CollapsibleZone} id="top-transitions" title="빈발 전환" defaultOpen=${true}>
              <${TopTransitionsPanel} transitions=${topTransitions} hoveredSegment=${hoveredSegment} />
            <//>
          </div>
        </div>

        ${/* ── Zone 4: Health Grid (collapsible) ── */ ''}
        <${CollapsibleZone} id="health-grid" title="상태 격자" defaultOpen=${true}>
          <div class="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
            <${MeasurementCard} snapshot=${snapshot} />
            <${InvariantsPanel}
              snapshot=${snapshot}
              violationCounts=${view.invariantViolations}
              sampleCount=${view.invariantSampleCount}
            />
          </div>
        <//>

        ${/* ── Zone 5: Collapsible Graph ── */ ''}
        <details class="v2-monitoring-detail rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
          open=${graphOpen}
          onToggle=${(e: Event) => setGraphOpen((e.target as HTMLDetailsElement).open)}
        >
          <summary class="cursor-pointer select-none px-4 py-2.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)]">
            Compound Graph — 5 sub-FSMs (Cytoscape)
          </summary>
          <div class="px-3 pb-3">
            <${CompositeGraphPanel} snapshot=${snapshot} />
          </div>
        </details>
      ` : null}
      <${ShortcutsOverlay} open=${shortcutsOpen} onClose=${() => setShortcutsOpen(false)} />
    </div>
  `
}

function ShortcutsOverlay({
  open,
  onClose,
}: {
  open: boolean
  onClose: () => void
}) {
  if (!open) return null
  const rows: Array<{ keys: string; desc: string }> = [
    { keys: '1 – 9', desc: 'N번째 키퍼로 이동' },
    { keys: 'r', desc: '강제 새로고침' },
    { keys: 'g', desc: 'Compound Graph 토글' },
    { keys: 'd', desc: '밀도 토글 (여유 / 조밀)' },
    { keys: '? ', desc: '단축키 목록 토글' },
    { keys: 'Esc', desc: '오버레이 닫기' },
    { keys: '← →', desc: '키퍼 탭 이동 (탭 포커스 시)' },
    { keys: 'Home / End', desc: '첫 / 마지막 키퍼 (탭 포커스 시)' },
  ]
  return html`
    <${DialogOverlay}
      labelledBy="shortcuts-title"
      onClose=${onClose}
      overlayClass="fixed inset-0 z-50 flex items-center justify-center"
      panelClass="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-5 min-w-70 shadow-[var(--shadow-1)]"
    >
      <div class="flex items-center justify-between mb-3">
        <h2 id="shortcuts-title" class="m-0 text-2xs font-semibold uppercase tracking-2 text-[var(--color-fg-muted)]">
          키보드 단축키
        </h2>
        <button
          class="v2-monitoring-action text-3xs text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)] cursor-pointer"
          onClick=${onClose}
          aria-label="닫기"
        >Esc</button>
      </div>
      <div class="flex flex-col gap-1.5">
        ${rows.map(r => html`
          <div class="v2-monitoring-row flex items-center gap-3 text-2xs">
            <${Kbd} size="md" class="min-w-16">${r.keys}<//>
            <span class="text-[var(--color-fg-primary)]">${r.desc}</span>
          </div>
        `)}
      </div>
    <//>
  `
}

// ── Zone 1: Status Bar ──────────────────────────────────

function StatusBar({
  snapshot,
  lastFetchAt,
  density,
  onDensityToggle,
  keeperNames,
  visibleKeeperNames,
  keeperFilter,
  onKeeperFilterChange,
  selected,
  onSelect,
  loading,
  paused,
  onRefresh,
  refreshFlash,
  transitionCount,
  observationCount,
  mode,
  runtimeTrace,
}: {
  snapshot: KeeperCompositeSnapshot | null
  lastFetchAt: number
  density: 'comfortable' | 'compact'
  onDensityToggle: () => void
  keeperNames: string[]
  visibleKeeperNames: readonly string[]
  keeperFilter: string
  onKeeperFilterChange: (q: string) => void
  selected: string | null
  onSelect: (n: string) => void
  loading: boolean
  paused: boolean
  onRefresh: () => void
  refreshFlash: boolean
  transitionCount: number
  observationCount: number
  mode: 'fleet' | 'detail'
  runtimeTrace?: KeeperRuntimeTraceResponse | null
}) {
  useNowSecondsTicker()
  const now = nowSecondsSignal.value
  const isFilteringKeepers = keeperFilter.trim() !== ''
  const keeperFilterHasNoMatch =
    isFilteringKeepers && visibleKeeperNames.length === 0 && keeperNames.length > 0
  const idleDuration = snapshot && !snapshot.is_live
    ? fmtDuration(Math.max(0, now - (snapshot.last_outcome?.ended_at ?? snapshot.ts)))
    : null
  const idleIsLong = snapshot && !snapshot.is_live && idleDuration != null
    && (now - (snapshot.last_outcome?.ended_at ?? snapshot.ts)) > 300
  const liveBadge = snapshot
    ? snapshot.is_live
      ? html`<span class="px-2 py-0.5 rounded-[var(--r-0)] border text-3xs font-mono text-[var(--color-status-ok)] border-[var(--ok-20)] bg-[var(--ok-10)] animate-pulse">● 실행 중</span>`
      : html`<span class="px-2 py-0.5 rounded-[var(--r-0)] border text-3xs font-mono ${idleIsLong ? 'text-[var(--color-fg-muted)] border-[var(--warn-20)]' : 'text-[var(--color-fg-disabled)] border-[var(--color-border-default)]'}">○ 대기 ${idleDuration}${snapshot.last_outcome ? html` <span class="text-3xs opacity-70"><span aria-hidden="true">· </span>턴 #${snapshot.last_outcome.turn_id}</span>` : null}</span>`
    : null
  const receiptLabel = snapshot ? executionReceiptLabel(snapshot.execution) : null

  const staleSec = lastFetchAt > 0 ? Math.max(0, now - lastFetchAt) : 0

  // Object.entries+filter+map over snapshot.invariants. StatusBar re-renders on
  // the 1s useNowSecondsTicker tick (now changes every second) which is unrelated
  // to snapshot.invariants; memoize on [snapshot] to skip the rebuild on ticks
  // where the snapshot did not change.
  const brokenInvariants = useMemo(
    () => snapshot
      ? Object.entries(snapshot.invariants)
          .filter(([_, ok]) => !ok)
          .map(([k]) => k)
      : [],
    [snapshot],
  )
  const hasAnomaly = brokenInvariants.length > 0
  const anomalyTitle = hasAnomaly
    ? [
        brokenInvariants.length > 0 ? `깨진 invariant: ${brokenInvariants.join(', ')}` : '',
      ].filter(Boolean).join(' · ')
    : ''

  const containerPadding = density === 'compact' ? 'px-3 py-1.5' : 'px-4 py-2.5'
  return html`
    <div class=${`v2-monitoring-toolbar sticky top-0 z-20 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--panel-dark-60)] backdrop-blur-sm shadow-[var(--shadow-panel)] ${containerPadding}`}>
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-3">
          <span class="text-3xs font-semibold uppercase tracking-3 text-[var(--color-fg-muted)]">FSM Hub</span>
          <${Kbd} size="sm" class="hidden md:inline-flex" title="단축키 목록 (?)">?<//>
          <button
            class=${`v2-monitoring-action text-3xs font-mono px-1.5 py-0.5 rounded-[var(--r-1)] border cursor-pointer transition-[background-color,border-color] ${
              refreshFlash
                ? 'border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)]'
                : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)] hover:border-[var(--accent-30)]'
            }`}
            onClick=${onRefresh}
            aria-label="강제 새로고침"
            aria-keyshortcuts="r"
          >
            ${refreshFlash ? '✓' : '↻'}
          </button>
          <button
            class="v2-monitoring-action text-3xs font-mono px-1.5 py-0.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)] hover:border-[var(--accent-30)] cursor-pointer"
            onClick=${onDensityToggle}
            title=${`현재 밀도: ${density === 'compact' ? '조밀' : '여유'} (단축키 d)`}
            aria-label=${`밀도 토글: 현재 ${density === 'compact' ? '조밀' : '여유'}`}
          >
            ${density === 'compact' ? '▣ 조밀' : '▢ 여유'}
          </button>
          ${liveBadge}
          ${snapshot && receiptLabel ? html`
            <span
              class=${`inline-block max-w-[28rem] truncate align-middle px-2 py-0.5 rounded-[var(--r-0)] border text-3xs font-mono ${executionReceiptClass(snapshot.execution)}`}
              title=${executionReceiptTitle(snapshot.execution)}
            >
              receipt ${receiptLabel}
            </span>
          ` : null}
          <${RuntimeEvidenceSummary} trace=${runtimeTrace} />
          ${loading ? html`<${InlineSpinner} size="xs" />` : null}
          ${paused ? html`
            <span
              class="px-1.5 py-0.5 rounded-[var(--r-1)] border text-3xs font-mono text-[var(--color-fg-muted)] border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
              title="탭이 백그라운드 상태 — 폴링 중지됨. 탭으로 돌아오면 즉시 갱신됩니다."
            >
              ⏸ 일시 중지
            </span>
          ` : null}
          ${staleSec > 120 ? html`
            <span class="text-3xs font-mono text-[var(--bad-light)] animate-pulse" title="마지막 관측이 2분 이상 경과 — 대시보드 데이터가 현재 상태를 반영하지 않을 수 있습니다">
              ${fmtDuration(staleSec)} 전 갱신
            </span>
          ` : staleSec > 60 ? html`
            <span class="text-3xs font-mono text-[var(--color-status-warn)]" title="마지막 관측이 1분 이상 경과">
              ${fmtDuration(staleSec)} 전 갱신
            </span>
          ` : null}
        </div>
        ${mode === 'detail' ? null : html`
        <div class="flex items-center gap-1.5 flex-wrap" role="tablist" aria-label="Keeper 선택">
          ${keeperNames.length > 0 ? html`
            <${TextInput}
              type="search"
              value=${keeperFilter}
              placeholder="keeper 이름 필터"
              ariaLabel="Keeper 이름 필터"
              onInput=${(e: Event) => onKeeperFilterChange((e.target as HTMLInputElement).value)}
              class="min-w-30 max-w-45 !rounded-[var(--r-0)] !bg-[var(--color-bg-surface)] !px-2.5 !py-0.5 !text-3xs font-mono"
            />
          ` : null}
          ${keeperFilterHasNoMatch ? html`
            <span class="text-3xs font-mono text-[var(--color-fg-disabled)]">
              필터 결과 없음 (${keeperNames.length} keepers)
            </span>
          ` : visibleKeeperNames.map((name, i) => {
            const active = name === selected
            const cls = active
              ? 'bg-[var(--accent-10)] border-[var(--accent-30)] text-[var(--color-accent-fg)]'
              : 'bg-[var(--color-bg-surface)] border-[var(--color-border-default)] text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)] hover:border-[var(--accent-30)]'
            return html`
              <button
                role="tab"
                aria-selected=${active}
                tabindex=${active ? 0 : -1}
                class=${`v2-monitoring-action rounded-[var(--r-0)] border px-2.5 py-0.5 text-3xs font-mono transition-colors cursor-pointer ${ringFocusClasses({ tone: 'accent-fg', width: 2, offset: 1, offsetSurface: 'page' })} ${cls}`}
                onClick=${() => onSelect(name)}
                title=${i < 9 ? `${name} — 단축키 ${i + 1}` : name}
                onKeyDown=${(e: KeyboardEvent) => {
                  let next = -1
                  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = (i + 1) % visibleKeeperNames.length
                  else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = (i - 1 + visibleKeeperNames.length) % visibleKeeperNames.length
                  else if (e.key === 'Home') next = 0
                  else if (e.key === 'End') next = visibleKeeperNames.length - 1
                  if (next >= 0) {
                    e.preventDefault()
                    const nextName = visibleKeeperNames[next]
                    if (nextName) {
                      onSelect(nextName);
                      (e.currentTarget as HTMLElement)?.parentElement?.querySelectorAll<HTMLElement>('[role=tab]')[next]?.focus()
                    }
                  }
                }}
              >
                ${i < 9 ? html`<span class="opacity-50 mr-0.5">${i + 1}</span>` : null}${name.replace(/^keeper-|-agent$/g, '')}${active && hasAnomaly ? html`
                  <span class="ml-1 text-[var(--bad-light)]" title=${anomalyTitle} aria-label="이상 신호">⚠</span>
                ` : null}
              </button>
            `
          })}
        </div>
        `}
      </div>
      ${snapshot ? html`
        <div class="mt-1.5 flex items-center gap-2 text-3xs font-mono flex-wrap">
          ${/* KPI micro-metrics */ ''}
          <span class="px-1.5 py-0.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] text-[var(--color-fg-primary)]">
            턴 ${snapshot.last_outcome ? `#${snapshot.last_outcome.turn_id}` : '—'}
          </span>
          <span class=${`px-1.5 py-0.5 rounded-[var(--r-1)] border ${transitionCount > 0 ? 'border-[var(--info-border)] text-[var(--info-fg)]' : 'border-[var(--color-border-default)] text-[var(--color-fg-disabled)]'}`}>
            ${transitionCount} 전환
          </span>
          <span
            class=${`relative px-1.5 py-0.5 rounded-[var(--r-1)] border overflow-hidden ${
              observationCount >= MAX_OBSERVATIONS
                ? 'border-[var(--warn-border)] text-[var(--warn-fg)]'
                : 'border-[var(--color-border-default)] text-[var(--color-fg-disabled)]'
            }`}
            title=${`관측 버퍼 ${observationCount}/${MAX_OBSERVATIONS} — 가득 차면 오래된 관측부터 순환 교체됩니다`}
          >
            <span
              class=${`absolute inset-0 ${
                observationCount >= MAX_OBSERVATIONS
                  ? 'bg-[var(--warn-soft)]'
                  : 'bg-[var(--color-bg-surface)]'
              }`}
              style=${`width: ${Math.round((observationCount / MAX_OBSERVATIONS) * 100)}%`}
            ></span>
            <span class="relative">${observationCount}/${MAX_OBSERVATIONS} 관측</span>
          </span>
          ${/* Meta IDs */ ''}
          <span class="text-[var(--color-fg-disabled)] opacity-60">corr ${snapshot.correlation_id?.slice(-8) ?? '?'}</span>
          <span class="text-[var(--color-fg-disabled)] opacity-60">run ${snapshot.run_id?.slice(-8) ?? '?'}</span>
        </div>
      ` : null}
    </div>
  `
}

// ── Skeleton Loading (Linear/Stripe pattern) ────────────

const shimmerCls = 'animate-pulse rounded-[var(--r-1)] bg-[var(--color-bg-elevated)]'

function SkeletonBar({ w, h = 'h-3' }: { w: string; h?: string }) {
  return html`<div class=${`${shimmerCls} ${w} ${h}`}></div>`
}

function SkeletonLayout() {
  return html`
    <div class="flex flex-col gap-3" aria-hidden="true" aria-label="통합 스냅샷 로딩 중">
      ${/* Operator Meaning skeleton */ ''}
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
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
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-5">
        <${SkeletonBar} w="w-32" h="h-2" />
        <div class="mt-2"><${SkeletonBar} w="w-40" h="h-8" /></div>
        <div class="mt-2"><${SkeletonBar} w="w-20" h="h-2" /></div>
        <div class="mt-2 flex gap-1">
          ${[1,2,3,4,5,6,7,8].map(i => html`<${SkeletonBar} key=${i} w="w-2" h="h-2" />`)}
        </div>
      </div>

      ${/* Pipeline Strip skeleton */ ''}
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
        <${SkeletonBar} w="w-24" h="h-2" />
        <div class="mt-2 flex gap-2">
          ${[1,2,3,4].map(i => html`
            <div key=${i} class="v2-monitoring-card flex-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] p-2">
              <${SkeletonBar} w="w-10" h="h-2" />
              <div class="mt-1"><${SkeletonBar} w="w-16" h="h-4" /></div>
              <div class="mt-1"><${SkeletonBar} w="w-14" h="h-2" /></div>
            </div>
          `)}
        </div>
      </div>

      ${/* Swimlane skeleton */ ''}
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
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
          <div key=${i} class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
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
    <div class="v2-monitoring-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] overflow-hidden">
      <button
        type="button"
        class="v2-monitoring-detail w-full flex items-center justify-between px-4 py-2 text-left hover:bg-[var(--color-bg-surface)] transition-colors cursor-pointer select-none"
        onClick=${toggle}
        aria-expanded=${!collapsed}
        aria-controls=${`zone-${id}`}
      >
        <span class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${zoneTitle}</span>
        <span class=${`text-3xs text-[var(--color-fg-disabled)] transition-transform duration-[var(--t-med)] ${collapsed ? '' : 'rotate-180'}`} aria-hidden="true">▾</span>
      </button>
      ${!collapsed ? html`<div id=${`zone-${id}`} class="px-4 pb-3">${children}</div>` : null}
    </div>
  `
}
