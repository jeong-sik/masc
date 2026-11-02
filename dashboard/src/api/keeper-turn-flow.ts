import { isRecord } from '../components/common/normalize'
import { get, type GetOptions } from './core'
import { fetchKeeperRuntimeTrace, type KeeperRuntimeTraceResponse } from './keeper-runtime-trace'
import {
  normalizeSkillActivationProjection,
  validateAsyncActionLinks,
  type DashboardSkillActivationProjection,
} from './dashboard-tools-prompts'

export interface TurnFlowTarget {
  keeper: string
  traceId: string
  absoluteTurn: number
  turnRef: string
}

export interface TurnIntakeSource {
  stimulusId: string
  sourceKind: string | null
  snapshotRef: string
  admittedRevision: string
  firstAdmittedAt: number | null
}

export type TurnIntake =
  | { state: 'observed'; channel: string | null; sources: TurnIntakeSource[] }
  | { state: 'not_recorded'; reason: string }
  | { state: 'ambiguous'; starts: number }

export interface TurnFlowEvent {
  event: string
  status: string
  runtimeId: string | null
  routingAction: string | null
  routingReason: string | null
}

export interface TurnFlow {
  intake: TurnIntake
  events: TurnFlowEvent[]
  trace: KeeperRuntimeTraceResponse
}

export type TraceSkillActivations =
  | Extract<DashboardSkillActivationProjection, { status: 'available' }>
  | { status: 'not_recorded' }
  | { status: 'unavailable'; reason: string; detail: string }

function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`turn flow: ${field}가 유효하지 않습니다`)
  }
  return value
}

function optionalString(value: unknown, field: string): string | null {
  return value === undefined || value === null ? null : requiredString(value, field)
}

function sourceOf(raw: unknown): TurnIntakeSource {
  if (!isRecord(raw)) throw new Error('turn flow: 자극 참조가 유효하지 않습니다')
  const first = raw.first_admitted_at
  if (first !== null && (typeof first !== 'number' || !Number.isFinite(first))) {
    throw new Error('turn flow: 자극의 선택 시각이 유효하지 않습니다')
  }
  return {
    stimulusId: requiredString(raw.stimulus_id, 'stimulus_id'),
    sourceKind: optionalString(raw.source_kind, 'source_kind'),
    snapshotRef: requiredString(raw.source_snapshot_ref, 'source_snapshot_ref'),
    admittedRevision: requiredString(raw.admitted_revision, 'admitted_revision'),
    firstAdmittedAt: first,
  }
}

export function decodeTurnFlow(trace: KeeperRuntimeTraceResponse, target: TurnFlowTarget): TurnFlow {
  if (target.turnRef !== `${target.traceId}#${target.absoluteTurn}`
    || trace.keeper !== target.keeper || trace.trace_id !== target.traceId
    || trace.turn_id !== target.absoluteTurn) {
    throw new Error('runtime-trace가 선택한 Keeper 턴과 일치하지 않습니다')
  }
  for (const row of trace.manifest_rows) {
    if (row.keeper_name !== target.keeper || row.trace_id !== target.traceId
      || row.keeper_turn_id !== target.absoluteTurn) {
      throw new Error('runtime-trace에 다른 Keeper 턴의 행이 있습니다')
    }
  }
  const starts = trace.manifest_rows.filter(row => row.event === 'turn_started')
  let intake: TurnIntake
  if (starts.length > 1) {
    // Repeated attempts must not silently borrow the last attempt's intake.
    intake = { state: 'ambiguous', starts: starts.length }
  } else {
    const decision = starts[0]?.decision
    if (!isRecord(decision) || !Object.hasOwn(decision, 'intake_sources')) {
      intake = { state: 'not_recorded', reason: starts.length === 0
        ? '조회한 범위에 턴 시작 기록이 없습니다'
        : '이 서버의 기록에는 공개된 자극 참조가 없습니다' }
    } else {
      if (!Array.isArray(decision.intake_sources)) throw new Error('turn flow: 자극 목록이 유효하지 않습니다')
      intake = {
        state: 'observed', channel: optionalString(decision.channel, 'channel'),
        sources: decision.intake_sources.map(sourceOf),
      }
    }
  }
  const events = trace.manifest_rows.map((row): TurnFlowEvent => {
    const decision = isRecord(row.decision) ? row.decision : {}
    return {
      event: requiredString(row.event, 'event'),
      status: requiredString(row.status, 'status'),
      runtimeId: optionalString(row.runtime_id, 'runtime_id'),
      routingAction: optionalString(decision.routing_action, 'routing_action'),
      routingReason: optionalString(decision.routing_reason, 'routing_reason'),
    }
  })
  return { intake, events, trace }
}

export async function fetchTurnFlow(target: TurnFlowTarget, opts: GetOptions = {}): Promise<TurnFlow> {
  const trace = await fetchKeeperRuntimeTrace(target.keeper, {
    traceId: target.traceId, turnId: target.absoluteTurn, limit: 500, signal: opts.signal,
  })
  return decodeTurnFlow(trace, target)
}

export function decodeTraceSkillActivations(raw: unknown, target: TurnFlowTarget): TraceSkillActivations {
  if (!isRecord(raw) || raw.schema !== 'masc.dashboard.skill-activations/v1'
    || raw.trace_id !== target.traceId) {
    throw new Error('Skill 기록이 선택한 trace와 일치하지 않습니다')
  }
  if (raw.status === 'not_recorded') return { status: 'not_recorded' }
  if (raw.status === 'unavailable') return {
    status: 'unavailable', reason: requiredString(raw.reason, 'reason'),
    detail: requiredString(raw.detail, 'detail'),
  }
  if (raw.status !== 'available') throw new Error('Skill 기록의 상태가 유효하지 않습니다')
  // Reuse the canonical ledger decoder, including delivery/action order and
  // physical async-result identities. Do not infer use from the skill catalog.
  const projection = normalizeSkillActivationProjection({
    status: raw.status, keeper_name: target.keeper, summary: raw.summary,
    scoped_summaries: raw.scoped_summaries, ledger: raw.ledger,
  })
  if (projection?.status !== 'available' || projection.ledger.session_id !== target.traceId) {
    throw new Error('Skill 원장이 선택한 trace와 일치하지 않습니다')
  }
  validateAsyncActionLinks(projection)
  return projection
}

export async function fetchTraceSkillActivations(
  target: TurnFlowTarget, opts: GetOptions = {},
): Promise<TraceSkillActivations> {
  const params = new URLSearchParams({ trace_id: target.traceId })
  const raw = await get<unknown>(`/api/v1/dashboard/skill-activations?${params}`, opts)
  return decodeTraceSkillActivations(raw, target)
}
