import type { Keeper } from '../types'
import type { KeeperRuntimeTraceResponse } from '../api/keeper'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import { ATTENTION_PHASES, isKeeperOffline } from './keeper-predicates'
import { deriveFiberAlive, type FiberAliveDecision } from './keeper-fiber-alive'
import {
  deriveKeeperOperationalState,
  type KeeperOperationalState,
} from './keeper-operational-state'
import { formatDuration } from './format-time'

export type KeeperLinkedRuntimeState = 'offline' | 'online' | 'unlinked'
export type KeeperRuntimeProjectionTone = 'ok' | 'warn' | 'bad' | 'info' | 'neutral'

export type KeeperRuntimeProjectionSignalKind =
  | 'operational_state'
  | 'ksm_phase'
  | 'heartbeat'
  | 'context_ratio'
  | 'fiber_alive'
  | 'stop_requested'
  | 'runtime_trace'
  | 'runtime_warning'
  | 'fsm_raw_lanes'

export type KeeperRuntimeProjectionSignalState =
  | 'ok'
  | 'attention'
  | 'bad'
  | 'info'
  | 'unknown'

export interface KeeperRuntimeProjectionSignal {
  readonly kind: KeeperRuntimeProjectionSignalKind
  readonly label: string
  readonly value: string
  readonly detail: string
  readonly tone: KeeperRuntimeProjectionTone
  readonly state: KeeperRuntimeProjectionSignalState
  readonly contributesToAttention: boolean
  readonly hint: string | null
}

export interface KeeperRuntimeProjectionRuntimeInput {
  readonly status?: string | null
  readonly warnings?: string[]
  readonly source_mismatch?: boolean
  readonly server_repo_path?: { readonly path?: string | null } | null
  readonly server_repo_git_commit?: string | null
  readonly workspace_git_commit?: string | null
  readonly build?: {
    readonly commit?: string | null
    readonly started_at?: string | null
  } | null
}

export interface KeeperRuntimeProjectionFsmLane {
  readonly axis: 'KSM' | 'KTC' | 'KDP' | 'KCL' | 'KMC' | 'KCB'
  readonly source: string
  readonly value: string
  readonly contributesToAttention: boolean
}

export interface KeeperHeartbeatProjection {
  readonly stale: boolean
  readonly lastHeartbeat: string | null
  readonly ageMs: number | null
  readonly thresholdMs: number
}

export interface KeeperContextProjection {
  readonly breach: boolean
  readonly ratio: number | null
  readonly threshold: number
}

export interface KeeperRuntimeTraceProjection {
  readonly value: string
  readonly detail: string
  readonly tone: KeeperRuntimeProjectionTone
  readonly loaded: boolean
}

export interface KeeperRuntimeProjection {
  readonly opState: KeeperOperationalState
  readonly linkedState: KeeperLinkedRuntimeState
  readonly fiberAlive: FiberAliveDecision
  readonly activeTurn: boolean
  readonly blocked: boolean
  readonly stopRequested: boolean
  readonly heartbeat: KeeperHeartbeatProjection
  readonly context: KeeperContextProjection
  readonly traceEvidence: KeeperRuntimeTraceProjection
  readonly runtimeWarnings: string[]
  readonly fsmLanes: KeeperRuntimeProjectionFsmLane[]
  readonly signals: KeeperRuntimeProjectionSignal[]
  readonly headline: string
  readonly tone: KeeperRuntimeProjectionTone
  readonly turnPhase: string
  readonly idleLabel: string
  readonly runtimeReason: string
  readonly runtimeBuildLabel: string | null
  readonly runtimeRepoLabel: string | null
  readonly synchronizationLabel: string
  readonly synchronizationDetail: string
}

interface DeriveKeeperRuntimeProjectionInput {
  readonly keeper: Keeper
  readonly composite: KeeperCompositeSnapshot | null
  readonly runtimeTrace?: KeeperRuntimeTraceResponse | null
  readonly runtimeResolution?: KeeperRuntimeProjectionRuntimeInput | null
  readonly linkedState?: KeeperLinkedRuntimeState
  readonly nowMs?: number
}

// 5-minute threshold for the operator-facing monitoring band. This is longer
// than transport heartbeat checks so short SSE reconnects do not become keeper
// attention events.
export const KEEPER_RUNTIME_HEARTBEAT_STALE_MS = 5 * 60 * 1000
export const KEEPER_RUNTIME_CONTEXT_ATTENTION_RATIO = 0.95

export function compactToken(value: string | null | undefined, fallback = 'unknown'): string {
  const text = value?.trim()
  return text ? text : fallback
}

export function shortCommit(value: string | null | undefined): string | null {
  const text = value?.trim()
  return text ? text.slice(0, 10) : null
}

export function deriveKeeperLinkedRuntimeState(keeper: Keeper | null | undefined): KeeperLinkedRuntimeState {
  if (!keeper) return 'unlinked'
  if (keeper.agent?.exists === false) return 'offline'
  return isKeeperOffline(keeper) ? 'offline' : 'online'
}

export function deriveKeeperRuntimeProjection({
  keeper,
  composite,
  runtimeTrace = null,
  runtimeResolution = null,
  linkedState = deriveKeeperLinkedRuntimeState(keeper),
  nowMs = Date.now(),
}: DeriveKeeperRuntimeProjectionInput): KeeperRuntimeProjection {
  const opState = deriveKeeperOperationalState({ keeper, composite })
  const turnPhase = compactToken(opState.turnPhase)
  const fiberAlive = deriveFiberAlive({ keeper, composite, linkedState })
  const activeTurn = composite?.is_live === true || !isIdleTurnPhase(opState.turnPhase)
  const blocked = opState.kind === 'stuck' || opState.attention !== 'clean'
  const stopRequested =
    composite?.runtime_attention?.fiber_stop_requested === true
    || composite?.phase_diagnosis?.conditions.stop_requested === true
  const heartbeat = deriveHeartbeatProjection(keeper, nowMs)
  const context = deriveContextProjection(keeper)
  const traceEvidence = terminalEventLabel(runtimeTrace)
  const runtimeWarnings = runtimeWarningList(runtimeResolution)
  const fsmLanes = deriveFsmLanes(composite, opState)
  const idleLabel =
    typeof composite?.idle_seconds === 'number'
      ? `${formatDuration(composite.idle_seconds)} idle`
      : typeof keeper.last_turn_ago_s === 'number'
        ? `${formatDuration(keeper.last_turn_ago_s)} since turn`
        : 'idle age unknown'
  const runtimeReason = compactToken(opState.displaySummary, 'no blocker reason')
  const runtimeCommit =
    shortCommit(runtimeResolution?.server_repo_git_commit)
    ?? shortCommit(runtimeResolution?.build?.commit)
  const workspaceCommit = shortCommit(runtimeResolution?.workspace_git_commit)
  const runtimeBuildLabel = runtimeCommit
    ? workspaceCommit && workspaceCommit !== runtimeCommit
      ? `${runtimeCommit} vs workspace ${workspaceCommit}`
      : runtimeCommit
    : null
  const runtimeRepoLabel = runtimeResolution?.server_repo_path?.path
    ? runtimeResolution.server_repo_path.path.split('/').slice(-2).join('/')
    : null

  const signals = buildProjectionSignals({
    opState,
    heartbeat,
    context,
    fiberAlive,
    stopRequested,
    traceEvidence,
    runtimeWarnings,
    fsmLanes,
    runtimeReason,
  })
  const attentionSignals = signals.filter(signal => signal.contributesToAttention)
  const headline =
    stopRequested
      ? '종료 신호'
      : attentionSignals.length > 0
        ? '조치 필요'
        : fiberAlive.alive && activeTurn
          ? '턴 진행 중'
          : fiberAlive.alive
            ? '대기 중'
            : runtimeTrace
              ? '실행 미확인'
              : '증거 부족'
  const tone: KeeperRuntimeProjectionTone =
    stopRequested
      ? 'bad'
      : attentionSignals.length > 0
        ? 'warn'
        : fiberAlive.alive && activeTurn
          ? 'ok'
          : fiberAlive.alive
            ? 'neutral'
            : runtimeTrace
              ? 'warn'
              : 'neutral'
  const synchronizationDetail = [
    `hb ${heartbeat.stale ? 'stale' : heartbeat.lastHeartbeat ? 'fresh' : 'unknown'}`,
    `ctx ${context.breach ? 'breach' : context.ratio === null ? 'unknown' : 'ok'}`,
    `fiber ${fiberAlive.alive ? 'alive' : 'not_proven'}`,
    stopRequested ? 'stop requested' : 'stop clear',
    fsmLaneSummary(fsmLanes),
  ].join(' · ')

  return {
    opState,
    linkedState,
    fiberAlive,
    activeTurn,
    blocked,
    stopRequested,
    heartbeat,
    context,
    traceEvidence,
    runtimeWarnings,
    fsmLanes,
    signals,
    headline,
    tone,
    turnPhase,
    idleLabel,
    runtimeReason,
    runtimeBuildLabel,
    runtimeRepoLabel,
    synchronizationLabel: attentionSignals.length > 0 ? `${attentionSignals.length} attention signal${attentionSignals.length === 1 ? '' : 's'}` : 'signals aligned',
    synchronizationDetail,
  }
}

function deriveHeartbeatProjection(keeper: Keeper, nowMs: number): KeeperHeartbeatProjection {
  const lastHeartbeat = keeper.last_heartbeat ?? null
  if (!lastHeartbeat) {
    return {
      stale: false,
      lastHeartbeat,
      ageMs: null,
      thresholdMs: KEEPER_RUNTIME_HEARTBEAT_STALE_MS,
    }
  }
  const ts = Date.parse(lastHeartbeat)
  if (Number.isNaN(ts)) {
    return {
      stale: false,
      lastHeartbeat,
      ageMs: null,
      thresholdMs: KEEPER_RUNTIME_HEARTBEAT_STALE_MS,
    }
  }
  const ageMs = nowMs - ts
  return {
    stale: ageMs > KEEPER_RUNTIME_HEARTBEAT_STALE_MS,
    lastHeartbeat,
    ageMs,
    thresholdMs: KEEPER_RUNTIME_HEARTBEAT_STALE_MS,
  }
}

function deriveContextProjection(keeper: Keeper): KeeperContextProjection {
  const threshold =
    typeof keeper.runtime_warning_ctx_ratio === 'number' && Number.isFinite(keeper.runtime_warning_ctx_ratio)
      ? keeper.runtime_warning_ctx_ratio
      : KEEPER_RUNTIME_CONTEXT_ATTENTION_RATIO
  const ratio =
    typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio)
      ? keeper.context_ratio
      : null
  return {
    breach: ratio !== null && ratio >= threshold,
    ratio,
    threshold,
  }
}

function runtimeWarningList(runtimeResolution: KeeperRuntimeProjectionRuntimeInput | null | undefined): string[] {
  if (!runtimeResolution) return []
  const warnings = Array.isArray(runtimeResolution.warnings)
    ? runtimeResolution.warnings.filter((warning): warning is string => warning.trim() !== '')
    : []
  if (runtimeResolution.source_mismatch && warnings.length === 0) {
    return ['Runtime source mismatch detected.']
  }
  return warnings
}

function terminalEventLabel(trace: KeeperRuntimeTraceResponse | null): KeeperRuntimeTraceProjection {
  if (!trace) {
    return {
      value: 'trace unavailable',
      detail: 'runtime_trace evidence not loaded',
      tone: 'neutral',
      loaded: false,
    }
  }
  const clock = trace.runtime_lens.turn_clock
  const keeperTurn = clock.keeper_turn_id ?? trace.turn_identity.requested_keeper_turn_id ?? trace.turn_id
  const turnLabel = keeperTurn == null ? 'turn unknown' : `turn #${keeperTurn}`
  const terminal = clock.terminal_event_present ? compactToken(clock.terminal_event, 'terminal present') : 'terminal missing'
  const gapCount = trace.runtime_lens.gaps.length
  const terminalTone: KeeperRuntimeProjectionTone =
    gapCount > 0
      ? 'warn'
      : !clock.terminal_event_present
        ? 'warn'
        : terminal === 'turn_finished'
          ? 'ok'
          : 'info'
  const detailParts = [
    `oas ${clock.max_oas_turn_count ?? '-'}`,
    `manifest ${trace.manifest_total_rows}`,
    `health ${compactToken(trace.health)}`,
    gapCount > 0 ? `${gapCount} lens gap${gapCount === 1 ? '' : 's'}` : 'no lens gaps',
  ]
  return {
    value: `${turnLabel} ${terminal === 'turn_finished' ? 'finished' : terminal}`,
    detail: detailParts.join(' · '),
    tone: terminalTone,
    loaded: true,
  }
}

function isIdleTurnPhase(value: string | null | undefined): boolean {
  const normalized = value?.trim().toLowerCase()
  return !normalized || normalized === 'idle' || normalized === 'unknown'
}

function deriveFsmLanes(
  composite: KeeperCompositeSnapshot | null,
  opState: KeeperOperationalState,
): KeeperRuntimeProjectionFsmLane[] {
  const phase = compactToken(composite?.phase ?? opState.phase ?? null, 'phase unknown')
  return [
    { axis: 'KSM', source: 'composite.phase', value: phase, contributesToAttention: phaseNeedsAttention(opState.phase ?? phase) },
    { axis: 'KTC', source: 'composite.turn_phase', value: compactToken(composite?.turn_phase ?? null, 'turn_phase unknown'), contributesToAttention: false },
    { axis: 'KDP', source: 'composite.decision.stage', value: compactToken(composite?.decision?.stage ?? null, 'decision unknown'), contributesToAttention: false },
    { axis: 'KCL', source: 'composite.runtime.state', value: compactToken(composite?.runtime?.state ?? null, 'runtime unknown'), contributesToAttention: false },
    { axis: 'KMC', source: 'composite.compaction.stage', value: compactToken(composite?.compaction?.stage ?? null, 'compaction unknown'), contributesToAttention: false },
    { axis: 'KCB', source: 'composite.circuit_breaker.state', value: compactToken(composite?.circuit_breaker?.state ?? null, 'breaker unknown'), contributesToAttention: false },
  ]
}

function phaseNeedsAttention(phase: string | null | undefined): boolean {
  if (!phase) return false
  if (ATTENTION_PHASES.has(phase)) return true
  const normalized = phase.toLowerCase()
  for (const attentionPhase of ATTENTION_PHASES) {
    if (attentionPhase.toLowerCase() === normalized) return true
  }
  return false
}

function fsmLaneSummary(lanes: readonly KeeperRuntimeProjectionFsmLane[]): string {
  return lanes.map(lane => `${lane.axis} ${lane.value}`).join(' / ')
}

function buildProjectionSignals({
  opState,
  heartbeat,
  context,
  fiberAlive,
  stopRequested,
  traceEvidence,
  runtimeWarnings,
  fsmLanes,
  runtimeReason,
}: {
  readonly opState: KeeperOperationalState
  readonly heartbeat: KeeperHeartbeatProjection
  readonly context: KeeperContextProjection
  readonly fiberAlive: FiberAliveDecision
  readonly stopRequested: boolean
  readonly traceEvidence: KeeperRuntimeTraceProjection
  readonly runtimeWarnings: readonly string[]
  readonly fsmLanes: readonly KeeperRuntimeProjectionFsmLane[]
  readonly runtimeReason: string
}): KeeperRuntimeProjectionSignal[] {
  const blockerAttention = opState.kind === 'stuck' || opState.attention !== 'clean'
  const ksmAttention = fsmLanes.some(lane => lane.axis === 'KSM' && lane.contributesToAttention)
  const heartbeatAge = heartbeat.ageMs === null ? 'age unknown' : `${Math.round(heartbeat.ageMs / 1000)}s old`
  const contextValue = context.ratio === null ? 'unknown' : `${Math.round(context.ratio * 100)}%`
  const contextThreshold = `${Math.round(context.threshold * 100)}%`
  const blockerHint = blockerAttention && runtimeReason !== 'no blocker reason' ? runtimeReason : null
  return [
    {
      kind: 'operational_state',
      label: 'operational',
      value: opState.kind,
      detail: runtimeReason,
      tone: blockerAttention ? 'warn' : 'ok',
      state: blockerAttention ? 'attention' : 'ok',
      contributesToAttention: blockerAttention,
      hint: blockerHint,
    },
    {
      kind: 'ksm_phase',
      label: 'ksm',
      value: String(opState.phase ?? 'unknown'),
      detail: fsmLaneSummary(fsmLanes),
      tone: ksmAttention ? 'warn' : 'ok',
      state: ksmAttention ? 'attention' : 'ok',
      contributesToAttention: ksmAttention,
      hint: ksmAttention ? 'FSM phase가 복구/오류/전이 상태입니다.' : null,
    },
    {
      kind: 'heartbeat',
      label: 'heartbeat',
      value: heartbeat.stale ? 'stale' : heartbeat.lastHeartbeat ? 'fresh' : 'unknown',
      detail: heartbeatAge,
      tone: heartbeat.stale ? 'warn' : 'neutral',
      state: heartbeat.stale ? 'attention' : heartbeat.lastHeartbeat ? 'ok' : 'unknown',
      contributesToAttention: heartbeat.stale,
      hint: heartbeat.stale ? '오래 응답이 없어 실제 상태 확인이 필요합니다.' : null,
    },
    {
      kind: 'context_ratio',
      label: 'context',
      value: contextValue,
      detail: `threshold ${contextThreshold}`,
      tone: context.breach ? 'warn' : 'neutral',
      state: context.breach ? 'attention' : context.ratio === null ? 'unknown' : 'ok',
      contributesToAttention: context.breach,
      hint: context.breach ? `컨텍스트 사용량이 ${contextValue}입니다.` : null,
    },
    {
      kind: 'fiber_alive',
      label: 'fiber',
      value: fiberAlive.alive ? 'alive' : 'not_proven',
      detail: fiberAlive.source,
      tone: fiberAlive.alive ? 'ok' : 'warn',
      state: fiberAlive.alive ? 'ok' : 'attention',
      contributesToAttention: !fiberAlive.alive,
      hint: fiberAlive.alive ? null : 'fiber 생존 증거가 없습니다.',
    },
    {
      kind: 'stop_requested',
      label: 'stop',
      value: stopRequested ? 'requested' : 'clear',
      detail: 'runtime_attention/phase_diagnosis',
      tone: stopRequested ? 'bad' : 'neutral',
      state: stopRequested ? 'bad' : 'ok',
      contributesToAttention: stopRequested,
      hint: stopRequested ? '종료 요청이 runtime projection에 반영됐습니다.' : null,
    },
    {
      kind: 'runtime_trace',
      label: 'trace',
      value: traceEvidence.value,
      detail: traceEvidence.detail,
      tone: traceEvidence.tone,
      state: traceEvidence.loaded ? (traceEvidence.tone === 'warn' ? 'attention' : 'ok') : 'unknown',
      contributesToAttention: traceEvidence.loaded && traceEvidence.tone === 'warn',
      hint: traceEvidence.loaded && traceEvidence.tone === 'warn' ? traceEvidence.detail : null,
    },
    {
      kind: 'runtime_warning',
      label: 'warnings',
      value: runtimeWarnings.length === 0 ? 'none' : `${runtimeWarnings.length}`,
      detail: runtimeWarnings[0] ?? 'no runtime warnings',
      tone: runtimeWarnings.length > 0 ? 'warn' : 'neutral',
      state: runtimeWarnings.length > 0 ? 'attention' : 'ok',
      contributesToAttention: runtimeWarnings.length > 0,
      hint: runtimeWarnings[0] ?? null,
    },
    {
      kind: 'fsm_raw_lanes',
      label: 'fsm',
      value: fsmLaneSummary(fsmLanes),
      detail: fsmLanes.map(lane => lane.source).join(' · '),
      tone: ksmAttention ? 'warn' : 'neutral',
      state: ksmAttention ? 'attention' : 'ok',
      contributesToAttention: false,
      hint: null,
    },
  ]
}
