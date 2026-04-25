/**
 * FleetFsmMatrix (LT-16b)
 *
 * Small-multiples matrix of all registered keepers × 5 orthogonal FSM
 * axes (KSM/KTC/KDP/KCL/KMC). One chip per (keeper, axis) cell showing
 * the current state. A top strip summarises the 4 joint invariant
 * counts from KeeperCompositeLifecycle.tla.
 *
 * Design: docs/observability/composite-fsm-matrix-design.md (LT-12).
 * Backend: #7723 (LT-16a) → GET /api/v1/keepers/composite.
 * Spec↔code drift: docs/observability/fsm-spec-code-drift.md (LT-15).
 *
 * LT-16c added a per-(keeper, axis) observation ring and a horizontal
 * sparkline renderer so each cell now carries its last 30 poll ticks.
 * The ring lives client-side; the backend remains stateless. A keeper
 * that disappears from a fleet poll is pruned from history on the next
 * tick (operators care about currently-registered keepers).
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'

import { fetchKeepersComposite } from '../api/keeper'
import type {
  FleetCompositeSnapshot,
  KeeperCompositeSnapshot,
} from '../api/keeper'
import { fleetCompositeSnapshot } from '../composite-signals'
import {
  displayState,
  extractLaneValue,
  INVARIANT_LABELS,
  TRANSITION_FIELDS,
  type LaneKey,
} from './fsm-hub-types'

const POLL_INTERVAL_MS = 10_000
const LONG_IDLE_SECONDS = 10 * 60

/**
 * Time-axis window (LT-16c). 30 snapshots × 10s poll = 5-minute
 * history per (keeper, axis). Matches MAX_OBSERVATIONS = 30 in
 * fsm-hub-types.ts so the FsmHub drill-down and this matrix keep
 * visually compatible timelines.
 */
export const FLEET_HISTORY_LEN = 30

// Axis order is fixed by the TLA+ joint spec
// (KeeperCompositeLifecycle.tla): KSM → KTC → KDP → KCL → KMC.
// Keep it identical to TRANSITION_FIELDS so an operator scanning
// left-to-right sees "lifecycle → turn → decision → cascade →
// compaction" — the natural causal order of a turn.
// 6 axes (LT-16-KCB Phase 3 added KCB). Causal order: lifecycle →
// turn → decision → cascade → compaction → circuit-breaker. KCB sits
// at the tail because its state is derived from the *outcome* of the
// cascade's tool calls (failure streak counter), so it is temporally
// downstream of the other five for any given turn.
const AXES: Array<{ key: LaneKey; label: string; acronym: string }> = [
  { key: 'phase',      label: 'Lifecycle',   acronym: 'KSM' },
  { key: 'turn',       label: 'Turn',        acronym: 'KTC' },
  { key: 'decision',   label: 'Decision',    acronym: 'KDP' },
  { key: 'cascade',    label: 'Cascade',     acronym: 'KCL' },
  { key: 'compaction', label: 'Compaction',  acronym: 'KMC' },
  { key: 'breaker',    label: 'Breaker',     acronym: 'KCB' },
]

const INVARIANT_KEYS = Object.keys(INVARIANT_LABELS) as Array<
  keyof typeof INVARIANT_LABELS
>

// Tailwind-only chip palette. Colour groups mirror the drift-audit
// recommendation: stable=gray, in-motion=amber/blue, terminal=red.
const CHIP_CLASS_BY_STATE: Record<string, string> = {
  // KSM
  Running:      'bg-[var(--ok-10)] text-[var(--ok)] border-[var(--ok-20)]',
  Failing:      'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
  Overflowed:   'bg-[var(--warn-10)] text-[var(--warn)] border-[var(--warn-20)]',
  Compacting:   'bg-[var(--warn-10)] text-[var(--warn)] border-[var(--warn-20)]',
  HandingOff:   'bg-[var(--accent-10)] text-[var(--accent)] border-[var(--accent-20)]',
  Draining:     'bg-[var(--accent-10)] text-[var(--accent)] border-[var(--accent-20)]',
  Paused:       'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--white-10)]',
  Stopped:      'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--white-10)]',
  Crashed:      'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
  Restarting:   'bg-[var(--accent-10)] text-[var(--accent)] border-[var(--accent-20)]',
  Dead:         'bg-[var(--white-5)] text-[var(--bad-light)] border-[var(--bad-20)]',
  Offline:      'bg-[var(--white-5)] text-[var(--text-muted)]0 border-[var(--white-10)]',
  // KTC
  idle:         'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--white-10)]',
  prompting:    'bg-[var(--accent-10)] text-[var(--accent)] border-[var(--accent-20)]',
  executing:    'bg-[var(--ok-10)] text-[var(--ok)] border-[var(--ok-20)]',
  compacting:   'bg-[var(--warn-10)] text-[var(--warn)] border-[var(--warn-20)]',
  finalizing:   'bg-[var(--accent-10)] text-[var(--accent)] border-[var(--accent-20)]',
  // KDP
  undecided:          'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--white-10)]',
  guard_ok:           'bg-[var(--ok-10)] text-[var(--ok)] border-[var(--ok-20)]',
  gate_rejected:      'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
  tool_policy_selected: 'bg-[var(--accent-10)] text-[var(--accent)] border-[var(--accent-20)]',
  // KCL
  selecting:    'bg-[var(--accent-10)] text-[var(--accent)] border-[var(--accent-20)]',
  trying:       'bg-[var(--warn-10)] text-[var(--warn)] border-[var(--warn-20)]',
  done:         'bg-[var(--ok-10)] text-[var(--ok)] border-[var(--ok-20)]',
  exhausted:    'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
  // KMC
  accumulating: 'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--white-10)]',
  // KCB (LT-16-KCB Phase 3). Clean = baseline grey same as any other
  // "nothing happening" state; warning = amber (partial failure
  // streak); cooling = blue (at least one past trip, currently
  // recovered). "tripped" is unobservable at snapshot time and has no
  // chip colour by design — the mutator resets the count before any
  // observer can see it.
  clean:   'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--white-10)]',
  warning: 'bg-[var(--warn-10)] text-[var(--warn)] border-[var(--warn-20)]',
  cooling: 'bg-[var(--accent-10)] text-[var(--accent)] border-[var(--accent-20)]',
}

const DEFAULT_CHIP = 'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--white-10)]'

export function chipClassFor(value: string): string {
  return CHIP_CLASS_BY_STATE[value] ?? DEFAULT_CHIP
}

/**
 * Reduce a chip class to a single `bg-...` Tailwind utility so the
 * sparkline bars can be 2–3 px wide without losing their state
 * encoding. Neutral grey on unknown values.
 */
export function sparkClassFor(value: string): string {
  const full = chipClassFor(value)
  // Chip strings mix semantic tokens (`bg-[var(--ok-10)]`) with size /
  // border utilities. Extract just the bg-* token, whether it uses
  // Tailwind's arbitrary-value bracket syntax or a plain palette class.
  const m = /\bbg-(?:\[[^\]]+\]|[a-z0-9/-]+)/i.exec(full)
  return m?.[0] ?? 'bg-[var(--white-5)]'
}

/** Per-axis observation ring keyed by keeper name. */
export type KeeperFleetHistory = Record<string, Record<LaneKey, string[]>>

const AXIS_KEYS: LaneKey[] = ['phase', 'turn', 'decision', 'cascade', 'compaction', 'breaker']

export type FleetRuntimeAttentionLevel = 'ok' | 'stale' | 'idle' | 'blocked'

export type FleetRuntimeAttention = {
  level: FleetRuntimeAttentionLevel
  label: string
  reason: string
  title: string
  ageSec: number | null
}

export type FleetRuntimeTallies = {
  live: number
  blocked: number
  stale: number
  idle: number
  total: number
}

const RUNTIME_ATTENTION_CLASS: Record<FleetRuntimeAttentionLevel, string> = {
  ok: 'bg-[var(--ok-10)] text-[var(--ok)] border-[var(--ok-20)]',
  stale: 'bg-[var(--warn-10)] text-[var(--warn)] border-[var(--warn-20)]',
  idle: 'bg-[var(--warn-10)] text-[var(--warn)] border-[var(--warn-20)]',
  blocked: 'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
}

function parseEpochSeconds(value: string | null | undefined): number | null {
  if (!value) return null
  const ms = Date.parse(value)
  if (!Number.isFinite(ms)) return null
  return ms / 1000
}

export function latestRuntimeActivityEpoch(snapshot: KeeperCompositeSnapshot): number | null {
  const candidates: number[] = []
  if (snapshot.last_outcome?.ended_at != null) {
    candidates.push(snapshot.last_outcome.ended_at)
  }
  const recordedAt = parseEpochSeconds(snapshot.execution?.recorded_at)
  if (recordedAt != null) {
    candidates.push(recordedAt)
  }
  if (candidates.length === 0) return null
  return Math.max(...candidates)
}

function formatAge(seconds: number | null): string {
  if (seconds == null) return 'no activity timestamp'
  if (seconds < 60) return `${seconds}s ago`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  return rest > 0 ? `${hours}h ${rest}m ago` : `${hours}h ago`
}

function isIdleComposite(snapshot: KeeperCompositeSnapshot): boolean {
  return snapshot.turn_phase === 'idle'
    && snapshot.decision.stage === 'undecided'
    && snapshot.cascade.state === 'idle'
    && snapshot.compaction.stage === 'accumulating'
    && (snapshot.circuit_breaker?.state ?? 'clean') === 'clean'
}

function executionEvidence(snapshot: KeeperCompositeSnapshot): string[] {
  const execution = snapshot.execution
  const parts: string[] = []
  if (!snapshot.is_live) parts.push('is_live=false')
  if (execution?.operator_disposition) {
    parts.push(`operator=${execution.operator_disposition}`)
  }
  if (execution?.operator_disposition_reason) {
    parts.push(`reason=${execution.operator_disposition_reason}`)
  }
  if (execution?.terminal_reason_code) {
    parts.push(`terminal=${execution.terminal_reason_code}`)
  }
  if (execution?.tool_contract_result) {
    parts.push(`tool=${execution.tool_contract_result}`)
  }
  if (execution?.error?.kind) {
    parts.push(`error=${execution.error.kind}`)
  }
  return parts
}

function hasBlockingExecutionEvidence(snapshot: KeeperCompositeSnapshot): boolean {
  const execution = snapshot.execution
  if (!execution) return false
  if (execution.operator_disposition === 'pause_human') return true
  if (execution.outcome === 'error') return true
  if (execution.terminal_reason_code && execution.terminal_reason_code !== 'completed') return true
  if (execution.tool_contract_result === 'missing_required_tool_use') return true
  if (execution.tool_contract_result === 'unknown' && execution.error != null) return true
  return false
}

export function runtimeAttentionForSnapshot(
  snapshot: KeeperCompositeSnapshot,
  generatedAt: number,
): FleetRuntimeAttention {
  const latest = latestRuntimeActivityEpoch(snapshot)
  const ageSec = latest == null ? null : Math.max(0, Math.floor(generatedAt - latest))
  const ageText = formatAge(ageSec)
  const evidence = executionEvidence(snapshot)
  const evidenceText = evidence.length > 0 ? evidence.join(' · ') : 'no blocking evidence'
  const title = `${evidenceText} · latest activity ${ageText}`
  const blocked = hasBlockingExecutionEvidence(snapshot)
  const idleComposite = isIdleComposite(snapshot)

  if (blocked) {
    return {
      level: 'blocked',
      label: '정체',
      reason: evidenceText,
      title,
      ageSec,
    }
  }
  if (!snapshot.is_live) {
    return {
      level: 'stale',
      label: 'stale',
      reason: evidenceText,
      title,
      ageSec,
    }
  }
  if (idleComposite && ageSec != null && ageSec >= LONG_IDLE_SECONDS) {
    return {
      level: 'idle',
      label: '무전환',
      reason: `idle composite · latest activity ${ageText}`,
      title,
      ageSec,
    }
  }
  return {
    level: 'ok',
    label: 'live',
    reason: ageText,
    title,
    ageSec,
  }
}

export function tallyRuntimeAttention(
  snapshots: readonly KeeperCompositeSnapshot[],
  generatedAt: number,
): FleetRuntimeTallies {
  const tallies: FleetRuntimeTallies = {
    live: 0,
    blocked: 0,
    stale: 0,
    idle: 0,
    total: snapshots.length,
  }
  for (const snap of snapshots) {
    if (snap.is_live) tallies.live += 1
    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    if (attention.level === 'blocked') tallies.blocked += 1
    if (attention.level === 'stale') tallies.stale += 1
    if (attention.level === 'idle') tallies.idle += 1
  }
  return tallies
}

/**
 * Fold an incoming batch of snapshots into the running history, capping
 * each axis series at [maxLen]. Returns a fresh top-level record so
 * Preact's identity render path notices the change. Keepers that
 * disappear from the latest snapshot are dropped — operators care
 * about currently-registered keepers and a restart re-populates the
 * name on the next poll.
 */
export function pushObservation(
  history: KeeperFleetHistory,
  snapshots: KeeperCompositeSnapshot[],
  maxLen: number = FLEET_HISTORY_LEN,
): KeeperFleetHistory {
  const next: KeeperFleetHistory = {}
  for (const snap of snapshots) {
    const name = inferKeeperNameFrom(snap)
    const prev = history[name]
    const perAxis: Record<LaneKey, string[]> = {
      phase:      prev?.phase      ? prev.phase.slice()      : [],
      turn:       prev?.turn       ? prev.turn.slice()       : [],
      decision:   prev?.decision   ? prev.decision.slice()   : [],
      cascade:    prev?.cascade    ? prev.cascade.slice()    : [],
      compaction: prev?.compaction ? prev.compaction.slice() : [],
      breaker:    prev?.breaker    ? prev.breaker.slice()    : [],
    }
    for (const axis of AXIS_KEYS) {
      perAxis[axis].push(extractLaneValue(snap, axis))
      if (perAxis[axis].length > maxLen) {
        perAxis[axis] = perAxis[axis].slice(-maxLen)
      }
    }
    next[name] = perAxis
  }
  return next
}

/**
 * Pure filter for fleet keeper snapshots.
 *
 * Case-insensitive substring match on the keeper name (prefer the
 * explicit backend identity, falling back to canonical correlation_id)
 * and on the current value of
 * each of the six FSM axes so an operator can isolate a single
 * keeper by name, or every keeper currently in a specific state
 * (e.g. `trying`, `Overflowed`, `warning`).
 *
 * Empty/whitespace query returns the input reference unchanged so
 * useMemo callers keep identity for the non-filtering path and
 * skip a downstream render pass.
 *
 * Input is never mutated.
 */
export function filterKeeperSnapshots(
  snapshots: readonly KeeperCompositeSnapshot[],
  query: string,
): readonly KeeperCompositeSnapshot[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return snapshots
  return snapshots.filter(snap => {
    const name = inferKeeperNameFrom(snap)
    if (name.toLowerCase().includes(needle)) return true
    for (const axis of AXIS_KEYS) {
      const value = extractLaneValue(snap, axis)
      if (value && value.toLowerCase().includes(needle)) return true
    }
    return false
  })
}

/**
 * Sum invariant violations across the fleet. Value is the number of
 * keepers where the invariant is currently failing; matches the
 * denominator the operator cares about ("how many keepers are bad?"),
 * not the counter delta from #7708 (which is a rate).
 */
export function tallyInvariantViolations(
  snapshots: KeeperCompositeSnapshot[],
): Record<keyof typeof INVARIANT_LABELS, number> {
  const counts = {
    phase_turn_alignment: 0,
    no_cascade_before_measurement: 0,
    compaction_atomicity: 0,
    event_priority_monotone: 0,
  }
  for (const s of snapshots) {
    for (const k of INVARIANT_KEYS) {
      // invariants[k] === true means *holds*, false means violated.
      if (!s.invariants[k]) counts[k] += 1
    }
  }
  return counts
}

interface FleetFsmMatrixProps {
  onSelectKeeper?: (name: string) => void
  // Injectable for tests.
  fetcher?: () => Promise<FleetCompositeSnapshot>
  pollIntervalMs?: number
}

export function FleetFsmMatrix(props: FleetFsmMatrixProps = {}) {
  const fetcher = props.fetcher ?? fetchKeepersComposite
  const allowStreamedData = props.fetcher == null
  const intervalMs = props.pollIntervalMs ?? POLL_INTERVAL_MS
  const [data, setData] = useState<FleetCompositeSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState<boolean>(true)
  const [query, setQuery] = useState<string>('')
  const lastStreamedAtRef = useRef<number | null>(null)
  // Observation ring. Ref rather than state because pushObservation
  // returns a fresh record per tick and we pair it with a setData call
  // which triggers the re-render — avoids a redundant state subscription.
  const historyRef = useRef<KeeperFleetHistory>({})

  const applySnapshot = useCallback((snap: FleetCompositeSnapshot) => {
    historyRef.current = pushObservation(
      historyRef.current,
      snap.snapshots,
      FLEET_HISTORY_LEN,
    )
    setData(snap)
    setError(null)
    setLoading(false)
  }, [])

  useEffect(() => {
    if (!allowStreamedData) return
    const applyStreamedSnapshot = (snap: FleetCompositeSnapshot | null) => {
      if (!snap) return
      lastStreamedAtRef.current = Date.now()
      applySnapshot(snap)
    }
    applyStreamedSnapshot(fleetCompositeSnapshot.value)
    return fleetCompositeSnapshot.subscribe(applyStreamedSnapshot)
  }, [allowStreamedData, applySnapshot])

  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | null = null
    const streamStaleAfterMs = Math.max(intervalMs * 2, 1)
    // In live mode the pushed fleet snapshot is primary; polling is only a
    // seed/watchdog path so this matrix does not double-hit the backend every
    // interval while the stream is healthy.
    const shouldFetchFallback = (): boolean => {
      if (!allowStreamedData) return true
      const lastStreamedAt = lastStreamedAtRef.current
      if (lastStreamedAt == null) return true
      return Date.now() - lastStreamedAt >= streamStaleAfterMs
    }
    const tick = async () => {
      if (!shouldFetchFallback()) {
        if (!cancelled) {
          timer = setTimeout(tick, intervalMs)
        }
        return
      }
      try {
        const snap = await fetcher()
        if (!cancelled) {
          applySnapshot(snap)
        }
      } catch (e) {
        if (!cancelled) {
          setError(String(e))
          setLoading(false)
        }
      } finally {
        if (!cancelled) {
          timer = setTimeout(tick, intervalMs)
        }
      }
    }
    if (allowStreamedData && fleetCompositeSnapshot.value) {
      timer = setTimeout(tick, intervalMs)
    } else {
      void tick()
    }
    return () => {
      cancelled = true
      if (timer) clearTimeout(timer)
    }
  }, [allowStreamedData, applySnapshot, fetcher, intervalMs])

  const tallies = useMemo(
    () => (data ? tallyInvariantViolations(data.snapshots) : null),
    [data],
  )
  const runtimeTallies = useMemo(
    () => (data ? tallyRuntimeAttention(data.snapshots, data.generated_at) : null),
    [data],
  )
  const visibleSnapshots = useMemo(
    () => (data ? filterKeeperSnapshots(data.snapshots, query) : []),
    [data, query],
  )
  const isFiltering = query.trim() !== ''

  if (loading) {
    return html`
      <div
        data-testid="fleet-fsm-matrix"
        class="rounded border border-[var(--white-10)] bg-[var(--white-5)] p-4 text-sm text-[var(--text-muted)]"
      >
        Loading fleet composite snapshot…
      </div>
    `
  }

  if (error) {
    return html`
      <div
        data-testid="fleet-fsm-matrix"
        class="rounded border border-[var(--bad-20)] bg-[var(--bad-10)] p-4 text-sm text-[var(--bad-light)]"
      >
        Fleet snapshot failed: ${error}
      </div>
    `
  }

  if (!data || data.count === 0) {
    return html`
      <div
        data-testid="fleet-fsm-matrix"
        class="rounded border border-[var(--white-10)] bg-[var(--white-5)] p-4 text-sm text-[var(--text-muted)]"
      >
        No keepers registered.
      </div>
    `
  }

  return html`
    <section
      data-testid="fleet-fsm-matrix"
      class="rounded border border-[var(--white-10)] bg-[var(--white-5)]"
    >
      <header class="flex flex-wrap items-baseline gap-3 border-b border-[var(--white-10)] p-3">
        <h2 class="text-sm font-semibold text-[var(--text-muted)]">Fleet composite (KSM × KTC × KDP × KCL × KMC × KCB)</h2>
        <span class="text-xs text-[var(--text-muted)]0">
          ${data.count} keepers · updated ${new Date(data.generated_at * 1000).toLocaleTimeString()}
        </span>
        <input
          type="search"
          value=${query}
          placeholder="name / 상태 필터 (예: gen12, trying)"
          aria-label="Keeper 필터"
          data-testid="fleet-fsm-matrix-filter"
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          class="min-w-40 max-w-65 rounded border border-[var(--white-10)] bg-[var(--white-5)] px-2 py-0.5 text-xs text-[var(--text-muted)] placeholder:text-[var(--text-muted)]0 focus:border-[var(--white-10)]0 focus:outline-none"
        />
        ${runtimeTallies
          ? html`
              <div class="flex flex-wrap gap-2" data-testid="runtime-truth-strip">
                <span
                  data-runtime-truth="live"
                  class="rounded border px-2 py-0.5 text-xs ${runtimeTallies.live === runtimeTallies.total ? RUNTIME_ATTENTION_CLASS.ok : RUNTIME_ATTENTION_CLASS.stale}"
                  title="Composite observer is_live count"
                >
                  Runtime live: ${runtimeTallies.live}/${runtimeTallies.total}
                </span>
                <span
                  data-runtime-truth="blocked"
                  class="rounded border px-2 py-0.5 text-xs ${runtimeTallies.blocked === 0 ? RUNTIME_ATTENTION_CLASS.ok : RUNTIME_ATTENTION_CLASS.blocked}"
                  title="Rows with operator disposition, terminal error, or failed tool contract evidence"
                >
                  Evidence blocked: ${runtimeTallies.blocked}
                </span>
                <span
                  data-runtime-truth="stale"
                  class="rounded border px-2 py-0.5 text-xs ${runtimeTallies.stale + runtimeTallies.idle === 0 ? RUNTIME_ATTENTION_CLASS.ok : RUNTIME_ATTENTION_CLASS.stale}"
                  title="Rows that are not live or stayed in the idle composite longer than the operator threshold"
                >
                  Idle/stale: ${runtimeTallies.stale + runtimeTallies.idle}
                </span>
              </div>
            `
          : null}
        ${tallies
          ? html`
              <div class="ml-auto flex flex-wrap gap-2" data-testid="invariant-strip">
                ${INVARIANT_KEYS.map(k => {
                  const count = tallies[k]
                  const tone = count === 0
                    ? 'bg-[var(--ok-10)] text-[var(--ok)] border-[var(--ok-20)]'
                    : 'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]'
                  return html`
                    <span
                      data-invariant=${k}
                      class="rounded border px-2 py-0.5 text-xs ${tone}"
                      title=${`Violating keepers: ${count}`}
                    >
                      ${INVARIANT_LABELS[k]}: ${count}
                    </span>
                  `
                })}
              </div>
            `
          : null}
      </header>
      ${isFiltering && visibleSnapshots.length === 0
        ? html`
            <div
              data-testid="fleet-fsm-matrix-empty"
              class="p-4 text-center text-xs text-[var(--text-muted)]0"
            >
              필터 결과 없음 (${data.snapshots.length} keepers)
            </div>
          `
        : null}
      <div class="overflow-x-auto">
        <table class="min-w-full text-xs">
          <thead class="bg-[var(--white-5)] text-[var(--text-muted)]">
            <tr>
              <th class="px-3 py-2 text-left font-semibold">Keeper</th>
              <th class="px-3 py-2 text-left font-semibold">Runtime</th>
              ${AXES.map(a => html`
                <th class="px-3 py-2 text-left font-semibold" title=${a.label}>
                  ${a.acronym} <span class="text-[var(--text-muted)]0">${a.label}</span>
                </th>
              `)}
            </tr>
          </thead>
          <tbody>
            ${visibleSnapshots.map(snap => {
              const anyViolated = INVARIANT_KEYS.some(k => !snap.invariants[k])
              const attention = runtimeAttentionForSnapshot(snap, data.generated_at)
              let rowTone = ''
              if (anyViolated || attention.level === 'blocked') {
                rowTone = 'border-l-2 border-[var(--bad-20)]'
              } else if (attention.level === 'stale' || attention.level === 'idle') {
                rowTone = 'border-l-2 border-[var(--warn-20)]'
              }
              const name = inferKeeperNameFrom(snap)
              return html`
                <tr
                  data-keeper=${name}
                  class="border-t border-[var(--white-10)] hover:bg-[var(--white-5)] ${rowTone}"
                  onClick=${props.onSelectKeeper ? () => props.onSelectKeeper?.(name) : undefined}
                >
                  <td class="px-3 py-2 font-mono text-[var(--text-muted)]">${name}</td>
                  <td class="px-3 py-2 align-top">
                    <div class="flex max-w-56 flex-col gap-1">
                      <span
                        data-runtime-attention
                        data-runtime-level=${attention.level}
                        class="inline-block self-start rounded border px-2 py-0.5 ${RUNTIME_ATTENTION_CLASS[attention.level]}"
                        title=${attention.title}
                      >${attention.label}</span>
                      <span
                        data-runtime-evidence
                        class="truncate text-3xs text-[var(--text-muted)]0"
                        title=${attention.title}
                      >
                        ${attention.reason}
                      </span>
                    </div>
                  </td>
                  ${AXES.map(a => {
                    const raw = extractLaneValue(snap, a.key)
                    const cls = chipClassFor(raw)
                    const series = historyRef.current[name]?.[a.key] ?? [raw]
                    return html`
                      <td class="px-3 py-2 align-top">
                        <div class="flex flex-col gap-1">
                          <span
                            data-cell
                            data-axis=${a.key}
                            class="inline-block self-start rounded border px-2 py-0.5 ${cls}"
                          >${displayState(raw)}</span>
                          <div
                            data-spark
                            data-axis=${a.key}
                            class="flex h-2 overflow-hidden rounded-sm border border-[var(--white-10)] bg-[var(--white-5)]"
                            title=${`last ${series.length}/${FLEET_HISTORY_LEN} ticks`}
                          >
                            ${series.map((v, i) => html`
                              <span
                                key=${i}
                                data-spark-bar
                                class="h-full w-0.5 ${sparkClassFor(v)}"
                                title=${displayState(v)}
                              ></span>
                            `)}
                          </div>
                        </div>
                      </td>
                    `
                  })}
                </tr>
              `
            })}
          </tbody>
        </table>
      </div>
    </section>
  `
}

/**
 * Keeper row identity for fleet views. New backends emit the registry
 * keeper name explicitly as `keeper`; older payloads fall back to the
 * canonical correlation_id format `keeper:<name>:<transition_seq>`.
 * Non-canonical ids still render verbatim rather than collapsing to an
 * empty row key.
 */
export function inferKeeperNameFrom(snap: KeeperCompositeSnapshot): string {
  const explicit = snap.keeper?.trim()
  if (explicit) return explicit
  const m = /^keeper:([^:]+):/.exec(snap.correlation_id)
  return m?.[1] ?? snap.correlation_id
}

// Re-exported helpers let tests target the pure slices without spinning
// up the component. TRANSITION_FIELDS is re-exported for completeness
// so a caller doesn't need to reach into fsm-hub-types for AXES parity.
export { TRANSITION_FIELDS }
