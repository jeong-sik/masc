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
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'

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
import { TimeAgo } from './common/time-ago'

const POLL_INTERVAL_MS = 10_000

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
  Offline:      'bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--white-10)]',
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
 * Case-insensitive substring match on the keeper name (as derived
 * from the canonical correlation_id) and on the current value of
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
  // Observation ring. Ref rather than state because pushObservation
  // returns a fresh record per tick and we pair it with a setData call
  // which triggers the re-render — avoids a redundant state subscription.
  const historyRef = useRef<KeeperFleetHistory>({})

  useEffect(() => {
    if (!allowStreamedData) return
    const applyStreamedSnapshot = (snap: FleetCompositeSnapshot | null) => {
      if (!snap) return
      historyRef.current = pushObservation(
        historyRef.current,
        snap.snapshots,
        FLEET_HISTORY_LEN,
      )
      setData(snap)
      setError(null)
      setLoading(false)
    }
    applyStreamedSnapshot(fleetCompositeSnapshot.value)
    return fleetCompositeSnapshot.subscribe(applyStreamedSnapshot)
  }, [allowStreamedData])

  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | null = null
    const tick = async () => {
      try {
        const snap = await fetcher()
        if (!cancelled) {
          historyRef.current = pushObservation(
            historyRef.current,
            snap.snapshots,
            FLEET_HISTORY_LEN,
          )
          setData(snap)
          setError(null)
          setLoading(false)
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
    tick()
    return () => {
      cancelled = true
      if (timer) clearTimeout(timer)
    }
  }, [fetcher, intervalMs])

  const tallies = useMemo(
    () => (data ? tallyInvariantViolations(data.snapshots) : null),
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
        role="status"
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
        role="alert"
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
        role="status"
      >
        No keepers registered.
      </div>
    `
  }

  return html`
    <section
      data-testid="fleet-fsm-matrix"
      aria-label="플릿 FSM 매트릭스"
      class="rounded border border-[var(--white-10)] bg-[var(--white-5)]"
    >
      <header class="flex flex-wrap items-baseline gap-3 border-b border-[var(--white-10)] p-3">
        <h2 class="text-sm font-semibold text-[var(--text-muted)]">플릿 복합 (KSM × KTC × KDP × KCL × KMC)</h2>
        <span class="text-xs text-[var(--text-muted)]">
          ${data.count} 키퍼 · <${TimeAgo} timestamp=${data.generated_at} mode="both" />
        </span>
        <input
          type="search"
          autoComplete="off"
          value=${query}
          placeholder="name / 상태 필터 (예: gen12, trying)"
          aria-label="Keeper 필터"
          data-testid="fleet-fsm-matrix-filter"
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          class="min-w-40 max-w-65 rounded border border-[var(--white-10)] bg-[var(--white-5)] px-2 py-0.5 text-xs text-[var(--text-muted)] placeholder:text-[var(--text-muted)] focus:border-[var(--white-10)] focus:outline-none"
        />
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
              class="p-4 text-center text-xs text-[var(--text-muted)]"
              role="status"
            >
              필터 결과 없음 (${data.snapshots.length} keepers)
            </div>
          `
        : null}
      <div class="overflow-x-auto">
        <table class="min-w-full text-xs" aria-label="플릿 FSM 상태 매트릭스">
          <thead class="bg-[var(--white-5)] text-[var(--text-muted)]">
            <tr>
              <th scope="col" class="px-3 py-2 text-left font-semibold">Keeper</th>
              ${AXES.map(a => html`
                <th scope="col" class="px-3 py-2 text-left font-semibold" title=${a.label}>
                  ${a.acronym} <span class="text-[var(--text-muted)]">${a.label}</span>
                </th>
              `)}
            </tr>
          </thead>
          <tbody>
            ${visibleSnapshots.map(snap => {
              const anyViolated = INVARIANT_KEYS.some(k => !snap.invariants[k])
              const rowTone = anyViolated ? 'border-l-2 border-[var(--bad-20)]' : ''
              const name = inferKeeperNameFrom(snap)
              return html`
                <tr
                  data-keeper=${name}
                  class="border-t border-[var(--white-10)] hover:bg-[var(--white-5)] ${rowTone}"
                  onClick=${props.onSelectKeeper ? () => props.onSelectKeeper?.(name) : undefined}
                >
                  <td class="px-3 py-2 font-mono text-[var(--text-muted)]">${name}</td>
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
 * Best-effort keeper name extraction from the snapshot correlation id.
 * Format: `keeper:<name>:<transition_seq>` (see keeper_composite_observer
 * .ml:stable_correlation_id). Falls back to correlation_id verbatim so
 * the UI never renders an empty cell.
 */
export function inferKeeperNameFrom(snap: KeeperCompositeSnapshot): string {
  const m = /^keeper:([^:]+):/.exec(snap.correlation_id)
  return m?.[1] ?? snap.correlation_id
}

// Re-exported helpers let tests target the pure slices without spinning
// up the component. TRANSITION_FIELDS is re-exported for completeness
// so a caller doesn't need to reach into fsm-hub-types for AXES parity.
export { TRANSITION_FIELDS }
