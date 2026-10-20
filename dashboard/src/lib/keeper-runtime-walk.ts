import { Either, Schema } from 'effect'
import { isRecord } from '../components/common/normalize'

const integer = Schema.Number.pipe(Schema.filter(Number.isSafeInteger))
const ordinal = integer.pipe(Schema.nonNegative())
const timestamp = Schema.String.pipe(Schema.filter(value => Number.isFinite(Date.parse(value))))
const turnSchema = Schema.Struct({
  trace_id: Schema.String, turn_count: Schema.NullOr(integer), ended_at: timestamp,
})

const faultSchema = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('unattributed') }),
  Schema.Struct({ kind: Schema.Literal('unknown_after_dispatch') }),
  Schema.Struct({
    kind: Schema.Literal('binding'),
    fact: Schema.Literal(
      'credential', 'account_access', 'account', 'model_absent', 'rate_limit',
      'capacity', 'server', 'window', 'body_limit', 'admission', 'deadline',
      'output_dialect', 'refusal_unread',
    ),
  }),
)

// The source error remains opaque here. Only the backend's typed failure
// projection computes its summary; this client never classifies its prose or
// uses the source payload to choose runtime actions.
const failurePayload = Schema.Struct({ cause: Schema.Record({ key: Schema.String, value: Schema.Unknown }) })
const failureSchema = Schema.Struct({
  attempt: ordinal,
  runtime_id: Schema.String,
  dispatch: Schema.Literal('dispatched', 'rejected_before_dispatch'),
  failure: failurePayload,
  summary: Schema.String,
  api_candidate_fault: Schema.NullOr(faultSchema),
})
const terminalSchema = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('not_observed') }),
  Schema.Struct({
    kind: Schema.Literal('candidate'), runtime_id: Schema.String, attempt: ordinal,
    failure: failurePayload, summary: Schema.String,
  }),
)
const observationSchema = Schema.Union(
  Schema.Struct({
    state: Schema.Literal('observed'), turn: turnSchema, error: Schema.Null,
    evidence: Schema.Struct({ failures: Schema.Array(failureSchema), terminal: terminalSchema }),
  }),
  Schema.Struct({
    state: Schema.Literal('not_observed'), turn: turnSchema, evidence: Schema.Null, error: Schema.Null,
  }),
  Schema.Struct({
    state: Schema.Literal('unreadable'), turn: Schema.NullOr(turnSchema), evidence: Schema.Null, error: Schema.String,
  }),
)

export type RuntimeLaneObservation = typeof observationSchema.Type
export type RuntimeCandidateFault = typeof faultSchema.Type

const bindingLabels: Record<Extract<RuntimeCandidateFault, { kind: 'binding' }>['fact'], string> = {
  credential: '자격 증명', account_access: '계정 접근', account: '계정',
  model_absent: '모델 없음', rate_limit: '요청 한도', capacity: '용량', server: '서버',
  window: '입력 창', body_limit: '본문 크기', admission: '요청 허용', deadline: '요청 기한',
  output_dialect: '출력 형식', refusal_unread: '미확인 거절',
}

export function readRuntimeLaneObservation(raw: unknown): RuntimeLaneObservation | null {
  if (raw === null) return null // No receipt was read by the server.
  const parsed = Schema.decodeUnknownEither(observationSchema, { onExcessProperty: 'error' })(raw)
  if (Either.isRight(parsed)) return parsed.right
  const turn = Schema.decodeUnknownEither(turnSchema, { onExcessProperty: 'error' })(
    isRecord(raw) ? raw.turn : undefined,
  )
  return {
    state: 'unreadable', turn: Either.isRight(turn) ? turn.right : null,
    evidence: null, error: 'invalid_runtime_lane_observation',
  }
}

export function runtimeCandidateFaultLabel(fault: RuntimeCandidateFault | null): string {
  if (fault === null) return 'API 분류 대상 아님'
  switch (fault.kind) {
    case 'unattributed': return 'API 오류 · 귀속 미분류'
    case 'unknown_after_dispatch': return '결과 불확실'
    case 'binding': return `API 오류 · ${bindingLabels[fault.fact]}`
  }
}
