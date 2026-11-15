import { isRecord } from '../components/common/normalize'

export interface SlotHttpBinding {
  providerId: string | null
  modelId: string
  providerKind: string
  endpoint: string
}
export type SlotBinding =
  | { kind: 'http'; value: SlotHttpBinding }
  | { kind: 'http_unobserved' | 'official_client' }
export type SlotOutcome =
  | { kind: 'unresolved' | 'accepted' | 'semantic_rejected' }
  | { kind: 'admission_rejected' | 'execution_failed' | 'cli_failed'; cause: string; httpStatus?: number }
export interface ExactSlotObservation {
  slotId: string
  laneKey: string | null
  binding: SlotBinding
  callId: string | null
  flowId: string | null
  visitOrdinal: number | null
  planFingerprint: string | null
  requestBodySha256: string | null
  catalogGeneration: string | null
  catalogEvidence: string | null
  targetIdentity: string | null
  phase: 'Prepared' | 'Before_dispatch' | 'Dispatch_started' | 'Response_received' | 'Terminal'
  generationDispatched: boolean
  startedAt: number | null
  finishedAt: number | null
  outcome: SlotOutcome
}
export type SlotObservationState =
  | { state: 'unobserved' }
  | { state: 'unavailable'; detail: string }
  | { state: 'available'; observations: ExactSlotObservation[] }
export interface RetainedSlotObservation {
  runId: string
  observation: ExactSlotObservation
}
export interface ExactSlotState {
  slotId: string
  laneKey: string
  transport: 'http' | 'official_client'
  declared: boolean
  currentBinding: SlotHttpBinding | null
  lastObservation: RetainedSlotObservation | null
  lastAttempt: RetainedSlotObservation | null
  lastSuccess: RetainedSlotObservation | null
  lastFailure: RetainedSlotObservation | null
  undatedOutcomes: RetainedSlotObservation[]
}
export type SlotMatrixState =
  | { state: 'unobserved' }
  | { state: 'unavailable'; detail: string }
  | { state: 'available'; slots: ExactSlotState[]; unavailableRuns: number }

function invalid(): never { throw new Error('슬롯 관측 형식을 읽지 못했습니다.') }
function object(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) invalid()
  return value
}
function text(value: unknown): string {
  if (typeof value !== 'string' || !value.trim()) invalid()
  return value
}
function nullableText(value: unknown): string | null { return value === null ? null : text(value) }
function number(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) invalid()
  return value
}
function count(value: unknown): number {
  const result = number(value)
  if (!Number.isSafeInteger(result)) invalid()
  return result
}
function time(value: unknown): number | null { return value === null ? null : number(value) }
function bool(value: unknown): boolean {
  if (typeof value !== 'boolean') invalid()
  return value
}
function array(value: unknown): unknown[] { if (!Array.isArray(value)) invalid(); return value }
function variant(value: unknown): [string, unknown?] {
  const parts = array(value)
  if (parts.length !== 1 && parts.length !== 2) invalid()
  return [text(parts[0]), parts[1]]
}
function nullary(value: unknown, names: readonly string[]): string {
  const parts = array(value)
  if (parts.length !== 1 || !names.includes(text(parts[0]))) invalid()
  return parts[0] as string
}
function binding(value: unknown): SlotHttpBinding {
  const raw = object(value)
  const endpoint = text(raw.endpoint)
  const url = new URL(endpoint)
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash) invalid()
  return { providerId: nullableText(raw.provider_id), modelId: text(raw.model_id),
    providerKind: text(raw.provider_kind), endpoint }
}
function observationBinding(value: unknown): SlotBinding {
  const [tag, raw] = variant(value)
  switch (tag) {
    case 'Http': return { kind: 'http', value: binding(raw) }
    case 'Http_unobserved': nullary(value, [tag]); return { kind: 'http_unobserved' }
    case 'Official_client': nullary(value, [tag]); return { kind: 'official_client' }
    default: return invalid()
  }
}
const REFUSALS = ['Request_body_refused', 'Refusal_body_not_received', 'Rate_limited', 'Overloaded',
  'Server_error', 'Auth_failed', 'Authorization_refused', 'Payment_required', 'Invalid_request',
  'Not_found', 'Context_overflow', 'Input_capacity', 'Network_error', 'Timeout']
const LOCAL_REJECTIONS = ['Runtime_unavailable', 'Runtime_contract', 'Input_contract',
  'Output_requirement', 'Local_input_capacity', 'Preparation_failed']
const COMPLETION_CAUSES = ['Http_failure', 'Accept_rejected', 'Provider_terminal', 'Capacity_exhausted',
  'Hard_quota', 'Capability_mismatch', 'Cli_policy_invalid', 'Cli_startup_failed', 'Provider_parse_error',
  'Provider_wire_error', 'Provider_reported_error', 'Provider_interrupted', 'Response_body_too_large',
  'Context_overflow_failure', 'Unknown_provider_failure']
function completionCause(value: unknown): string {
  const [tag, nested] = variant(value)
  switch (tag) {
    case 'Network_failure': return `${tag} / ${nullary(nested, ['Connection_refused', 'Dns_failure', 'Unreachable',
      'Tls_error', 'Network_timeout', 'Local_resource_exhaustion', 'Connection_reset', 'End_of_file',
      'Unknown_network'])}`
    // Keep the measured failure family. No inference from an exception message.
    case 'Deadline': case 'Empty_completion': {
      const [detail] = variant(nested)
      return `${tag} / ${detail}`
    }
    default: return nullary(value, COMPLETION_CAUSES)
  }
}
function apiFailure(value: unknown): Extract<SlotOutcome, { kind: 'execution_failed' | 'admission_rejected' | 'cli_failed' }> {
  const [tag, payload] = variant(value)
  switch (tag) {
    case 'Provider_refused': {
      const raw = object(payload)
      const httpStatus = count(raw.http_status)
      if (httpStatus < 100 || httpStatus > 599) invalid()
      return { kind: 'execution_failed', cause: `${tag} / ${nullary(raw.refusal, REFUSALS)}`, httpStatus }
    }
    case 'Completion_failed': {
      const raw = object(payload)
      bool(raw.sent)
      return { kind: 'execution_failed', cause: `${tag} / ${completionCause(raw.cause)}` }
    }
    case 'Ambiguous': if (count(payload) <= 1) invalid(); return { kind: 'execution_failed', cause: tag }
    default: return { kind: 'execution_failed', cause: nullary(value,
      ['Output_limit', 'Incomplete', 'Missing', 'Unexpected', 'Invalid_json', 'Body_deadline']) }
  }
}
function cliFailure(value: unknown): SlotOutcome {
  const raw = object(value)
  text(raw.runtime_id)
  const [tag, payload] = variant(raw.cause)
  switch (tag) {
    case 'Native_failed': return { kind: 'cli_failed', cause: `${tag} / ${nullary(payload,
      ['Codex', 'Claude', 'Claude_admission', 'Antigravity', 'Muse', 'Vibe', 'Host'])}` }
    case 'Codex_context_refused': case 'Claude_context_refused': {
      const detail = object(payload)
      if (typeof detail.message !== 'string') invalid()
      bool(detail.tool_effect_attempted)
      if (tag === 'Claude_context_refused') bool(detail.response_emitted)
      return { kind: 'cli_failed', cause: tag }
    }
    case 'Codex_measured_input_refused': {
      const detail = object(payload); count(detail.actual_chars); count(detail.max_chars)
      return { kind: 'cli_failed', cause: tag }
    }
    default: return { kind: 'cli_failed', cause: nullary(raw.cause,
      ['Unknown_runtime', 'Not_official', 'Invalid_json_answer', 'Invalid_domain_answer']) }
  }
}
function outcome(value: unknown): SlotOutcome {
  const [tag, payload] = variant(value)
  switch (tag) {
    case 'Unresolved': nullary(value, [tag]); return { kind: 'unresolved' }
    case 'Accepted': nullary(value, [tag]); return { kind: 'accepted' }
    case 'Semantic_rejected': nullary(value, [tag]); return { kind: 'semantic_rejected' }
    case 'Admission_rejected': return { kind: 'admission_rejected', cause: nullary(payload, LOCAL_REJECTIONS) }
    case 'Execution_failed': return apiFailure(payload)
    case 'Cli_failed': return cliFailure(payload)
    default: return invalid()
  }
}
function observation(value: unknown): ExactSlotObservation {
  const raw = object(value)
  const startedAt = time(raw.started_at), finishedAt = time(raw.finished_at)
  if (finishedAt !== null && startedAt === null) invalid()
  const phase = nullary(raw.phase, ['Prepared', 'Before_dispatch', 'Dispatch_started', 'Response_received', 'Terminal'])
  return { slotId: text(raw.slot_id), laneKey: nullableText(raw.lane_key), binding: observationBinding(raw.binding), callId: nullableText(raw.call_id),
    flowId: nullableText(raw.flow_id), visitOrdinal: raw.visit_ordinal === null ? null : count(raw.visit_ordinal),
    planFingerprint: nullableText(raw.plan_fingerprint), requestBodySha256: nullableText(raw.request_body_sha256),
    catalogGeneration: nullableText(raw.catalog_generation), catalogEvidence: nullableText(raw.catalog_evidence),
    targetIdentity: nullableText(raw.target_identity), phase: phase as ExactSlotObservation['phase'],
    generationDispatched: bool(raw.generation_dispatched), startedAt, finishedAt, outcome: outcome(raw.outcome) }
}

// This diagnostic is independent of original execution output and proof validity.
export function parseSlotObservations(value: unknown): SlotObservationState {
  if (value === undefined) return { state: 'unobserved' }
  try {
    const raw = object(value)
    switch (raw.state) {
      case 'unobserved': return { state: 'unobserved' }
      case 'unavailable': return { state: 'unavailable', detail: text(raw.detail) }
      case 'available': return { state: 'available', observations: array(raw.observations).map(observation) }
      default: return invalid()
    }
  } catch { return { state: 'unavailable', detail: '슬롯 관측 형식을 읽지 못했습니다.' } }
}
function slotState(value: unknown, laneKey: string): ExactSlotState {
  const raw = object(value), slotId = text(raw.slot_id)
  if (raw.lane_key !== laneKey) invalid()
  if (raw.transport !== 'http' && raw.transport !== 'official_client') invalid()
  const transport = raw.transport
  if (raw.ordering_scope !== 'dated_only') invalid()
  const retained = (value: unknown): RetainedSlotObservation => {
    const item = object(value), observed = observation(item.observation)
    const kind = observed.binding.kind === 'official_client' ? 'official_client' : 'http'
    if (observed.slotId !== slotId || observed.laneKey !== laneKey || kind !== transport) invalid()
    return { runId: text(item.run_id), observation: observed }
  }
  const nullable = (value: unknown) => value === null ? null : retained(value)
  const lastObservation = nullable(raw.last_observation), lastAttempt = nullable(raw.last_attempt)
  const lastSuccess = nullable(raw.last_success), lastFailure = nullable(raw.last_failure)
  if (lastObservation && lastObservation.observation.startedAt === null) invalid()
  if (lastAttempt && lastAttempt.observation.startedAt === null) invalid()
  if (lastSuccess && (lastSuccess.observation.finishedAt === null || lastSuccess.observation.outcome.kind !== 'accepted')) invalid()
  if (lastFailure && (lastFailure.observation.finishedAt === null ||
    ['accepted', 'unresolved'].includes(lastFailure.observation.outcome.kind))) invalid()
  const undatedOutcomes = array(raw.undated_outcomes).map(retained)
  if (undatedOutcomes.some(item => item.observation.finishedAt !== null || item.observation.outcome.kind === 'unresolved')) invalid()
  const currentBinding = raw.current_binding === null ? null : binding(raw.current_binding)
  if (transport === 'official_client' && currentBinding !== null) invalid()
  return { slotId, laneKey, transport, declared: bool(raw.declared), currentBinding, lastObservation, lastAttempt,
    lastSuccess, lastFailure, undatedOutcomes }
}
export function parseSlotMatrix(value: unknown, unavailableRuns: unknown, owner: unknown): SlotMatrixState {
  if (value === undefined) return { state: 'unobserved' }
  try {
    const laneKey = text(owner)
    const slots = array(value).map(value => slotState(value, laneKey))
    if (new Set(slots.map(slot => `${slot.transport}/${slot.slotId}`)).size !== slots.length) invalid()
    return { state: 'available', slots, unavailableRuns: count(unavailableRuns) }
  } catch { return { state: 'unavailable', detail: '슬롯 관측 형식을 읽지 못했습니다.' } }
}
