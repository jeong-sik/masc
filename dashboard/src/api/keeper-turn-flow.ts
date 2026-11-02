import { isRecord } from '../components/common/normalize'
import type { GetOptions } from './core'
import { fetchKeeperRuntimeTrace, type KeeperRuntimeTraceResponse } from './keeper-runtime-trace'

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
  | { state: 'unavailable'; reason: string }
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
  const scannedStarts = trace.runtime_lens.axes.lifecycle.turn_started_count
  const validCount = Number.isSafeInteger(scannedStarts) && scannedStarts >= 0
  const observedStarts = Math.max(starts.length, validCount ? scannedStarts : 0)
  const diagnostics = trace.manifest_scan_diagnostics
  let intake: TurnIntake
  if (observedStarts > 1) {
    // The scan counts starts beyond the bounded returned page. Even a partial
    // scan can prove repetition; its absence cannot prove a single attempt.
    intake = { state: 'ambiguous', starts: observedStarts }
  } else if (trace.manifest_total_rows_exact !== true) {
    intake = { state: 'unavailable', reason: trace.manifest_total_rows_exact === false
      ? '전체 manifest를 읽지 못해 같은 턴의 다른 시작 여부를 확정할 수 없습니다'
      : 'manifest 조회 범위의 완전성이 기록되지 않았습니다' }
  } else if (diagnostics.state !== 'available'
    || diagnostics.invalid_manifest_row_count > 0 || diagnostics.invalid_json_row_count > 0
    || diagnostics.unsupported_event_unattributed_count > 0) {
    intake = { state: 'unavailable', reason: '읽지 못한 manifest 행이 있어 턴 시작 횟수를 확정할 수 없습니다' }
  } else if (!validCount || scannedStarts !== starts.length) {
    intake = { state: 'unavailable', reason: '전체 조회의 시작 횟수와 반환된 시작 기록이 일치하지 않습니다' }
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
