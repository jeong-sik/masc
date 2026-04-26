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

import { currentDashboardActor } from '../api/core'
import { fetchKeepersComposite } from '../api/keeper'
import type {
  FleetCompositeSnapshot,
  KeeperCompositeSnapshot,
} from '../api/keeper'
import { fleetCompositeSnapshot } from '../composite-signals'
import { dispatchOperatorAction } from '../operator-store'
import { showToast } from './common/toast'
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
  Running:      'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]',
  Failing:      'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
  Overflowed:   'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]',
  Compacting:   'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]',
  HandingOff:   'bg-[var(--accent-10)] text-[var(--color-accent-fg)] border-[var(--accent-20)]',
  Draining:     'bg-[var(--accent-10)] text-[var(--color-accent-fg)] border-[var(--accent-20)]',
  Paused:       'bg-[var(--white-5)] text-[var(--color-fg-muted)] border-[var(--white-10)]',
  Stopped:      'bg-[var(--white-5)] text-[var(--color-fg-muted)] border-[var(--white-10)]',
  Crashed:      'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
  Restarting:   'bg-[var(--accent-10)] text-[var(--color-accent-fg)] border-[var(--accent-20)]',
  Dead:         'bg-[var(--white-5)] text-[var(--bad-light)] border-[var(--bad-20)]',
  Offline:      'bg-[var(--white-5)] text-[var(--color-fg-muted)]0 border-[var(--white-10)]',
  // KTC
  idle:         'bg-[var(--white-5)] text-[var(--color-fg-muted)] border-[var(--white-10)]',
  prompting:    'bg-[var(--accent-10)] text-[var(--color-accent-fg)] border-[var(--accent-20)]',
  executing:    'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]',
  compacting:   'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]',
  finalizing:   'bg-[var(--accent-10)] text-[var(--color-accent-fg)] border-[var(--accent-20)]',
  // KDP
  undecided:          'bg-[var(--white-5)] text-[var(--color-fg-muted)] border-[var(--white-10)]',
  guard_ok:           'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]',
  gate_rejected:      'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
  tool_policy_selected: 'bg-[var(--accent-10)] text-[var(--color-accent-fg)] border-[var(--accent-20)]',
  // KCL
  selecting:    'bg-[var(--accent-10)] text-[var(--color-accent-fg)] border-[var(--accent-20)]',
  trying:       'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]',
  done:         'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]',
  exhausted:    'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
  // KMC
  accumulating: 'bg-[var(--white-5)] text-[var(--color-fg-muted)] border-[var(--white-10)]',
  // KCB (LT-16-KCB Phase 3). Clean = baseline grey same as any other
  // "nothing happening" state; warning = amber (partial failure
  // streak); cooling = blue (at least one past trip, currently
  // recovered). "tripped" is unobservable at snapshot time and has no
  // chip colour by design — the mutator resets the count before any
  // observer can see it.
  clean:   'bg-[var(--white-5)] text-[var(--color-fg-muted)] border-[var(--white-10)]',
  warning: 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]',
  cooling: 'bg-[var(--accent-10)] text-[var(--color-accent-fg)] border-[var(--accent-20)]',
}

const DEFAULT_CHIP = 'bg-[var(--white-5)] text-[var(--color-fg-muted)] border-[var(--white-10)]'

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
  cause: string
  nextStep: string
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

export type FleetRuntimeAssistRequest = {
  keeperName: string
  snapshot: KeeperCompositeSnapshot
  attention: FleetRuntimeAttention
  message: string
}

export type FleetRuntimeAssistHandler =
  (request: FleetRuntimeAssistRequest) => Promise<void> | void

const RUNTIME_ATTENTION_CLASS: Record<FleetRuntimeAttentionLevel, string> = {
  ok: 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]',
  stale: 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]',
  idle: 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]',
  blocked: 'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]',
}

export type FleetCellPresentation = {
  label: string
  className: string
  title: string
  runtimePhaseConflict: boolean
}

export function fleetCellPresentation(
  axis: LaneKey,
  raw: string,
  attention: FleetRuntimeAttention,
): FleetCellPresentation {
  const baseLabel = displayState(raw)
  if (axis === 'phase' && attention.level !== 'ok') {
    return {
      label: `${baseLabel} · ${attention.label}`,
      className: RUNTIME_ATTENTION_CLASS[attention.level],
      title: `KSM ${raw} · runtime ${attention.label} · 원인: ${attention.cause} · 다음: ${attention.nextStep}`,
      runtimePhaseConflict: true,
    }
  }
  return {
    label: baseLabel,
    className: chipClassFor(raw),
    title: raw,
    runtimePhaseConflict: false,
  }
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

function blockingCause(snapshot: KeeperCompositeSnapshot): string {
  const execution = snapshot.execution
  if (!execution) return 'blocking execution evidence present'
  const parts: string[] = []
  if (execution.operator_disposition === 'pause_human') {
    parts.push(
      execution.operator_disposition_reason
        ? `operator pause: ${execution.operator_disposition_reason}`
        : 'operator pause requested',
    )
  }
  if (execution.tool_contract_result === 'missing_required_tool_use') {
    parts.push('tool contract: missing_required_tool_use')
  } else if (execution.tool_contract_result === 'unknown' && execution.error != null) {
    parts.push('tool contract unknown with execution error')
  }
  if (execution.terminal_reason_code && execution.terminal_reason_code !== 'completed') {
    parts.push(`terminal: ${execution.terminal_reason_code}`)
  }
  if (execution.error?.kind) {
    parts.push(`error: ${execution.error.kind}`)
  }
  if (execution.outcome === 'error' && parts.length === 0) {
    parts.push('execution outcome: error')
  }
  return parts.length > 0 ? parts.join(' · ') : 'blocking execution evidence present'
}

function blockingNextStep(snapshot: KeeperCompositeSnapshot): string {
  const execution = snapshot.execution
  if (!execution) return 'latest execution receipt 확인'
  if (execution.tool_contract_result === 'missing_required_tool_use') {
    return '필수 tool contract를 만족시키거나 task/preset 조정'
  }
  if (execution.operator_disposition === 'pause_human') {
    return 'operator gate/approval 상태와 최신 receipt 확인'
  }
  if (execution.terminal_reason_code && execution.terminal_reason_code !== 'completed') {
    return `terminal=${execution.terminal_reason_code} receipt 확인`
  }
  if (execution.error?.kind) {
    return `error=${execution.error.kind} 로그와 receipt 확인`
  }
  return 'latest execution receipt 확인'
}

function staleCause(snapshot: KeeperCompositeSnapshot, ageText: string): string {
  const receiptReason = snapshot.execution?.operator_disposition_reason
  const base = snapshot.phase === 'Running'
    ? 'KSM=Running이지만 live turn 없음'
    : `live turn 없음 · KSM=${snapshot.phase}`
  const receipt = receiptReason ? ` · last receipt: ${receiptReason}` : ''
  return `${base} · latest ${ageText}${receipt}`
}

function staleNextStep(snapshot: KeeperCompositeSnapshot, latest: number | null): string {
  if (latest == null) {
    return 'turn 시작/keepalive 이벤트가 composite로 들어오는지 확인'
  }
  if (snapshot.phase === 'Running') {
    return 'keeper keepalive와 turn 시작 이벤트 경로 확인'
  }
  return `phase=${snapshot.phase} 전환 또는 재시작 경로 확인`
}

export function buildRuntimeAssistPrompt(
  keeperName: string,
  snapshot: KeeperCompositeSnapshot,
  attention: FleetRuntimeAttention,
): string {
  const breaker = snapshot.circuit_breaker?.state ?? 'clean'
  const receipt = snapshot.execution
    ? JSON.stringify({
      outcome: snapshot.execution.outcome,
      terminal_reason_code: snapshot.execution.terminal_reason_code,
      operator_disposition: snapshot.execution.operator_disposition,
      operator_disposition_reason: snapshot.execution.operator_disposition_reason,
      tool_contract_result: snapshot.execution.tool_contract_result,
      error_kind: snapshot.execution.error?.kind ?? null,
      error_preview: snapshot.execution.error?.message_preview ?? null,
    })
    : 'none'
  return [
    `감독형 런타임 진단 요청: ${keeperName}`,
    '',
    'Fleet FSM에서 이 keeper가 attention 상태입니다. 자동 복구를 바로 실행하지 말고 원인, 증거, 안전한 해결 후보를 짧게 제안하세요.',
    '',
    `attention=${attention.level} label=${attention.label}`,
    `cause=${attention.cause}`,
    `next_hint=${attention.nextStep}`,
    `evidence=${attention.reason}`,
    `is_live=${String(snapshot.is_live)}`,
    `KSM=${snapshot.phase} KTC=${snapshot.turn_phase} KDP=${snapshot.decision.stage} KCL=${snapshot.cascade.state} KMC=${snapshot.compaction.stage} KCB=${breaker}`,
    `last_receipt=${receipt}`,
    '',
    '응답 형식:',
    '1. 판정: 실제 막힘인지, 단순 idle/stale 표시인지',
    '2. 근거: 어떤 receipt/FSM 신호를 봤는지',
    '3. resolve 후보: keeper_probe, keeper_recover, operator 승인, task/preset 수정 중 무엇이 맞는지',
    '4. 위험: 실행 전 사람 확인이 필요한 항목',
  ].join('\n')
}

async function requestRuntimeAssistViaOperator(
  request: FleetRuntimeAssistRequest,
): Promise<void> {
  await dispatchOperatorAction({
    actor: currentDashboardActor(),
    action_type: 'keeper_message',
    target_type: 'keeper',
    target_id: request.keeperName,
    payload: {
      direct_reply: true,
      message: request.message,
    },
  })
  showToast(`${request.keeperName} AI 진단 요청을 보냈습니다`, 'success')
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
  const blocked = hasBlockingExecutionEvidence(snapshot)
  const idleComposite = isIdleComposite(snapshot)

  if (blocked) {
    const cause = blockingCause(snapshot)
    const nextStep = blockingNextStep(snapshot)
    return {
      level: 'blocked',
      label: '정체',
      reason: evidenceText,
      cause,
      nextStep,
      title: `원인: ${cause} · 다음: ${nextStep} · 증거: ${evidenceText} · latest activity ${ageText}`,
      ageSec,
    }
  }
  if (!snapshot.is_live) {
    const cause = staleCause(snapshot, ageText)
    const nextStep = staleNextStep(snapshot, latest)
    return {
      level: 'stale',
      label: 'stale',
      reason: evidenceText,
      cause,
      nextStep,
      title: `원인: ${cause} · 다음: ${nextStep} · 증거: ${evidenceText}`,
      ageSec,
    }
  }
  if (idleComposite && ageSec != null && ageSec >= LONG_IDLE_SECONDS) {
    const cause = `idle composite가 ${ageText} 유지`
    const nextStep = 'backlog, admission, trigger가 없는지 확인'
    return {
      level: 'idle',
      label: '무전환',
      reason: `idle composite · latest activity ${ageText}`,
      cause,
      nextStep,
      title: `원인: ${cause} · 다음: ${nextStep} · 증거: ${evidenceText}`,
      ageSec,
    }
  }
  const cause = snapshot.is_live
    ? `live turn 관측 중 · latest ${ageText}`
    : `latest ${ageText}`
  return {
    level: 'ok',
    label: 'live',
    reason: ageText,
    cause,
    nextStep: '조치 불필요',
    title: `원인: ${cause} · 증거: ${evidenceText}`,
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
  onRequestRuntimeAssist?: FleetRuntimeAssistHandler
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
  const [assistBusy, setAssistBusy] = useState<Set<string>>(() => new Set())
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

  const requestRuntimeAssist = useCallback(async (
    keeperName: string,
    snapshot: KeeperCompositeSnapshot,
    attention: FleetRuntimeAttention,
  ) => {
    const handler = props.onRequestRuntimeAssist ?? requestRuntimeAssistViaOperator
    const message = buildRuntimeAssistPrompt(keeperName, snapshot, attention)
    setAssistBusy(prev => new Set(prev).add(keeperName))
    try {
      await handler({ keeperName, snapshot, attention, message })
    } catch (err) {
      const message = err instanceof Error ? err.message : 'AI 진단 요청에 실패했습니다'
      showToast(message, 'error')
    } finally {
      setAssistBusy(prev => {
        const next = new Set(prev)
        next.delete(keeperName)
        return next
      })
    }
  }, [props.onRequestRuntimeAssist])

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
        class="rounded border border-[var(--white-10)] bg-[var(--white-5)] p-4 text-sm text-[var(--color-fg-muted)]"
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
        class="rounded border border-[var(--white-10)] bg-[var(--white-5)] p-4 text-sm text-[var(--color-fg-muted)]"
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
        <h2 class="text-sm font-semibold text-[var(--color-fg-muted)]">Fleet composite (KSM × KTC × KDP × KCL × KMC × KCB)</h2>
        <span class="text-xs text-[var(--color-fg-muted)]0">
          ${data.count} keepers · updated ${new Date(data.generated_at * 1000).toLocaleTimeString()}
        </span>
        <input
          type="search"
          value=${query}
          placeholder="name / 상태 필터 (예: gen12, trying)"
          aria-label="Keeper 필터"
          data-testid="fleet-fsm-matrix-filter"
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          class="min-w-40 max-w-65 rounded border border-[var(--white-10)] bg-[var(--white-5)] px-2 py-0.5 text-xs text-[var(--color-fg-muted)] placeholder:text-[var(--color-fg-muted)]0 focus:border-[var(--white-10)]0 focus:outline-none"
        />
        ${runtimeTallies
          ? html`
              <div class="flex flex-wrap gap-2" data-testid="runtime-truth-strip">
                <span
                  data-runtime-truth="live"
                  class="rounded border px-2 py-0.5 text-xs ${runtimeTallies.live === runtimeTallies.total ? RUNTIME_ATTENTION_CLASS.ok : RUNTIME_ATTENTION_CLASS.stale}"
                  title="통합 observer 의 is_live 카운트"
                >
                  런타임 활성: ${runtimeTallies.live}/${runtimeTallies.total}
                </span>
                <span
                  data-runtime-truth="blocked"
                  class="rounded border px-2 py-0.5 text-xs ${runtimeTallies.blocked === 0 ? RUNTIME_ATTENTION_CLASS.ok : RUNTIME_ATTENTION_CLASS.blocked}"
                  title="운영자 disposition, 터미널 에러, 또는 tool contract 위반 evidence 가 있는 row"
                >
                  근거 차단: ${runtimeTallies.blocked}
                </span>
                <span
                  data-runtime-truth="stale"
                  class="rounded border px-2 py-0.5 text-xs ${runtimeTallies.stale + runtimeTallies.idle === 0 ? RUNTIME_ATTENTION_CLASS.ok : RUNTIME_ATTENTION_CLASS.stale}"
                  title="활성 상태가 아니거나 운영자 임계값보다 오래 idle 통합 상태를 유지한 row"
                >
                  유휴/지연: ${runtimeTallies.stale + runtimeTallies.idle}
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
                    ? 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]'
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
              class="p-4 text-center text-xs text-[var(--color-fg-muted)]0"
            >
              필터 결과 없음 (${data.snapshots.length} keepers)
            </div>
          `
        : null}
      <div class="overflow-x-auto">
        <table class="min-w-full text-xs">
          <thead class="bg-[var(--white-5)] text-[var(--color-fg-muted)]">
            <tr>
              <th class="px-3 py-2 text-left font-semibold">키퍼</th>
              <th class="px-3 py-2 text-left font-semibold">런타임</th>
              ${AXES.map(a => html`
                <th class="px-3 py-2 text-left font-semibold" title=${a.label}>
                  ${a.acronym} <span class="text-[var(--color-fg-muted)]0">${a.label}</span>
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
              const assisting = assistBusy.has(name)
              return html`
                <tr
                  data-keeper=${name}
                  class="border-t border-[var(--white-10)] hover:bg-[var(--white-5)] ${rowTone}"
                  onClick=${props.onSelectKeeper ? () => props.onSelectKeeper?.(name) : undefined}
                >
                  <td class="px-3 py-2 font-mono text-[var(--color-fg-muted)]">${name}</td>
                  <td class="px-3 py-2 align-top">
                    <div class="flex max-w-72 flex-col gap-1">
                      <span
                        data-runtime-attention
                        data-runtime-level=${attention.level}
                        class="inline-block self-start rounded border px-2 py-0.5 ${RUNTIME_ATTENTION_CLASS[attention.level]}"
                        title=${attention.title}
                      >${attention.label}</span>
                      <span
                        data-runtime-evidence
                        data-runtime-cause
                        class="text-3xs leading-snug text-[var(--color-fg-muted)]0"
                        title=${attention.title}
                      >
                        원인: ${attention.cause}
                      </span>
                      <span
                        data-runtime-next
                        class="text-3xs leading-snug text-[var(--color-fg-muted)]0"
                        title=${attention.title}
                      >
                        다음: ${attention.nextStep}
                      </span>
                      ${attention.level !== 'ok'
                        ? html`
                            <button
                              type="button"
                              data-runtime-assist
                              class="self-start rounded border border-[var(--white-10)] bg-[var(--white-5)] px-2 py-0.5 text-3xs font-semibold text-[var(--color-accent-fg)] hover:bg-[var(--white-10)] disabled:cursor-not-allowed disabled:opacity-50"
                              title="현재 원인/증거를 keeper LLM에 보내 감독형 진단을 요청합니다"
                              disabled=${assisting}
                              onClick=${(event: MouseEvent) => {
                                event.stopPropagation()
                                void requestRuntimeAssist(name, snap, attention)
                              }}
                            >
                              ${assisting ? '진단 중' : 'AI 진단'}
                            </button>
                          `
                        : null}
                    </div>
                  </td>
                  ${AXES.map(a => {
                    const raw = extractLaneValue(snap, a.key)
                    const cell = fleetCellPresentation(a.key, raw, attention)
                    const series = historyRef.current[name]?.[a.key] ?? [raw]
                    return html`
                      <td class="px-3 py-2 align-top">
                        <div class="flex flex-col gap-1">
                          <span
                            data-cell
                            data-axis=${a.key}
                            data-runtime-phase-conflict=${cell.runtimePhaseConflict ? 'true' : 'false'}
                            class="inline-block self-start rounded border px-2 py-0.5 ${cell.className}"
                            title=${cell.title}
                          >${cell.label}</span>
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
