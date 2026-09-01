// MASC Dashboard — Keeper turn records / transcript (RFC-0233).
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import { isRecord, asBoolean, asNumber, asString, asRecordArray } from '../components/common/normalize'
import { type TelemetryFreshnessMetadata } from './dashboard-shared'

// The type is derived from the list, and the decoder reads the list, so a
// block id is added or removed in one place. It used to be a hand-written
// union with a switch beside it and a second switch in dashboard-keeper-prompt:
// the persona hard-cut (masc#27048) updated the type and one switch, the twin
// kept `case 'persona'`, and three adversarial-review rounds ran red on it.
export const TURN_PROMPT_BLOCK_IDS = [
  'keeper_instructions',
  'dynamic_context',
  'temporal_summary',
  'memory_os_recall',
  'operator_note',
] as const

export type TurnPromptBlockId = (typeof TURN_PROMPT_BLOCK_IDS)[number]

export function decodeTurnPromptBlockId(raw: unknown): TurnPromptBlockId | null {
  return (TURN_PROMPT_BLOCK_IDS as readonly unknown[]).includes(raw)
    ? (raw as TurnPromptBlockId)
    : null
}

export type TurnInputComponentId =
  | `prompt.${TurnPromptBlockId}`
  | 'tool_schemas'
  | 'message_user'
  | 'message_system'
  | 'message_assistant_text'
  | 'message_thinking'
  | 'message_redacted_thinking'
  | 'message_tool_use'
  | 'message_tool_result'
  | 'message_image'
  | 'message_document'
  | 'message_audio'

export type TurnBlock = {
  block: TurnPromptBlockId
  bytes: number
  digest: string
}

export type TurnInputComponent = {
  component: TurnInputComponentId
  bytes: number
}

export type TurnRequestWireObservation =
  | {
      request_runtime_profile: string
      request_body_bytes: number
    }
  | {
      request_runtime_profile: null
      request_body_bytes: null
    }

// lib/types/turn_record.ml:118-125 — the writer emits exactly these two.
export type TurnKind = 'autonomous' | 'direct'

// lib/types/turn_record.ml:127-135 — the exact-run reference into the keeper's
// own raw-trace store. null when the turn recorded no exact run.
export type TurnRawTraceRunRef = {
  worker_run_id: string
  path: string
  start_seq: number
  end_seq: number
  agent_name: string
  session_id: string
}

export type TurnRecordEntry = {
  execution_ids: string[]
  keeper: string
  // lib/types/turn_record.ml:148-163 writes these four unconditionally and its
  // own reader [require]s them, so the wire always carries them.
  agent_name: string
  generation: number
  turn_kind: TurnKind
  raw_trace_run_ref: TurnRawTraceRunRef | null
  trace_id: string
  absolute_turn: number
  turn_ref: string
  blocks: TurnBlock[]
  // null means the producer reached no exact composition observation; an
  // observed empty input remains [].
  input_components: TurnInputComponent[] | null
  request_runtime_profile: string | null
  request_body_bytes: number | null
  runtime_profile: string
  // RFC-0233 §2.3 — exact selected model from the successful runtime attempt.
  // Absent (undefined) when the producer observed no selected model; the
  // inspector renders absence, never a fabricated value.
  selected_model?: string
  finish_reason?: string
  temperature?: number
  top_p?: number
  max_tokens?: number
  thinking_budget?: number
  enable_thinking?: boolean
  input_tokens?: number
  output_tokens?: number
  // #25779 made the provider cache counts durable on the turn record
  // (lib/types/turn_record.ml:79-82 writes them as optional fields). Same
  // absent-means-absent contract as the neighbours: a provider that reports no
  // cache usage leaves these undefined and the inspector renders absence rather
  // than a fabricated zero.
  cache_creation_input_tokens?: number
  cache_read_input_tokens?: number
  // RFC-0233 §8 — runtime model metadata. context_window is the keeper-resolved
  // effective token budget (the ctx-fill% denominator); the two prices are USD
  // per 1M tokens declared on the runtime binding. Absent (undefined) when the
  // runtime is unknown or the operator left runtime.toml unset; the inspector
  // renders "미상" (unknown) rather than a fabricated 200K / Claude $3·$15.
  context_window?: number
  // How much of the keeper's own history the dispatched request carried, in
  // atoms (one user message, or one assistant message plus the tool messages
  // answering it). Reported beside request_body_bytes, which counts the bytes
  // the provider admitted — neither substitutes for the other. Absent when no
  // model-input projection ran for the turn; that is not a zero-length
  // history, so the inspector renders absence rather than 0.
  transmitted_atoms?: number
  total_atoms?: number
  // Which shape the budget was measured against. 'durable_shape' means the
  // reasoning projection declined and the window was sized against the
  // checkpoint, so this turn saw less history than it needed to — and nothing
  // about the decline ages out, so a keeper can stay there.
  model_input_measurement?: 'wire_shape' | 'durable_shape'
  price_input_per_million?: number
  price_output_per_million?: number
  // RFC-0233 §9 — wall-clock duration of the provider call (ms), sourced from
  // Agent Core inference_telemetry.request_latency_ms. Absent when the turn errored
  // before a response existed; the inspector renders "측정 없음" rather than a
  // fabricated duration for the response-generation phase.
  request_latency_ms?: number
  // RFC-0233 §10 — time-to-first-response-chunk (ms, wall-clock), sourced from
  // Agent Core inference_telemetry.ttfrc_ms. Unlike request_latency_ms (end-to-end),
  // this isolates time-to-first-token on the streaming path; the streaming
  // transport fills it for every provider, so it is populated across the
  // streaming keeper fleet. Absent for non-streaming turns and on the error
  // path. The decode (post-first-chunk) duration is NOT derived from
  // request_latency_ms - ttfrc_ms (§9.6 fabrication guard).
  ttfrc_ms?: number
  ts: number
}

export type TurnBlockDiff = {
  added: TurnBlock[]
  removed: TurnBlock[]
  changed: { prev: TurnBlock; next: TurnBlock }[]
}

export type TurnRecordRow = {
  record: TurnRecordEntry
  // null on the first record of a trace (no same-trace predecessor)
  diff_vs_prev: TurnBlockDiff | null
}

// The librarian taxonomy mirrors the OCaml `category` sum in
// keeper_memory_os_types.ml; category_to_string is the wire SSOT.
// The wire carries a string token; it is parsed once at this decode boundary into
// a tagged value. An out-of-vocabulary token is a contract error, matching the
// backend's closed decoder.
export type MemoryOsFactCategoryTag =
  | 'code_change'
  | 'fact'
  | 'preference'
  | 'blocker'
  | 'goal'
  | 'constraint'
  | 'validated_approach'
  | 'lesson'
export type MemoryOsFactCategory = { readonly tag: MemoryOsFactCategoryTag }

export type MemoryOsDerivation = {
  readonly rule_id: string
  readonly premise_ids: string[]
}

export type MemoryOsFactBasis =
  | { readonly kind: 'observed' }
  | { readonly kind: 'derived'; readonly derivations: MemoryOsDerivation[] }

// SSOT token list — must stay byte-identical to the known arms of
// category_of_string/category_to_string. A drift-guard test pins this set.
const MEMORY_OS_FACT_CATEGORY_TAGS: readonly MemoryOsFactCategoryTag[] = [
  'code_change',
  'fact',
  'preference',
  'blocker',
  'goal',
  'constraint',
  'validated_approach',
  'lesson',
]

export function parseMemoryOsFactCategory(raw: string): MemoryOsFactCategory | null {
  const known = MEMORY_OS_FACT_CATEGORY_TAGS.find(tag => tag === raw)
  return known ? { tag: known } : null
}

// One fact row as projected by memory_os_fact_json (server_dashboard_http_keeper_api.ml).
// Carries only the structure RFC-0247 left on the record — there is no salience /
// uses / confidence field to decode because the backend has none to emit.
export type MemoryOsFact = {
  readonly memory_id: string
  readonly claim: string
  readonly category: MemoryOsFactCategory
  readonly first_seen: number
  readonly basis: MemoryOsFactBasis
  // Derived from membership in the current snapshot; never persisted as a
  // second Memory authority.
  readonly current: boolean
}

export type MemoryOsUpdateSource = {
  readonly kind: 'librarian' | 'explicit_write' | 'explicit_retract'
  readonly trace_id: string
}

export type MemoryOsSupportInvalidation = {
  readonly fact: MemoryOsFact
  readonly missing_premise_ids: string[]
}

export type MemoryOsTurnRecordSnapshot = {
  keeper: string
  snapshot_store: string
  recall_enabled: boolean
  revision: number
  updated_at: number | null
  update_source: MemoryOsUpdateSource | null
  read_errors: { scope: string; error: string }[]
  facts: {
    shown: number
    current: number
    // Every persisted fact row.
    items: MemoryOsFact[]
  }
  change: {
    added: MemoryOsFact[]
    removed: MemoryOsFact[]
    retained: number
    invalidated: MemoryOsSupportInvalidation[]
  }
}

export type TurnRecordsResponse = TelemetryFreshnessMetadata & {
  source: 'turn_record'
  producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer'
  durable_store: string
  dashboard_surface: '/api/v1/keepers/:name/turn-records'
  freshness_slo_s: number
  // Emitted unconditionally by the turn-records handler
  // (server_dashboard_http_keeper_api.ml): live_turn_in_progress is true iff a
  // turn is mid-flight for this keeper, in which case both timestamps are
  // non-null wall-clock seconds; all three are null/false together otherwise.
  live_turn_in_progress: boolean
  live_turn_started_at_unix: number | null
  live_turn_last_progress_at_unix: number | null
  latest_ts_unix: number | null
  latest_ts_iso: string | null
  latest_age_s: number | null
  // 'live' and 'ok' are different answers. A running turn has not written its
  // record yet, so the newest finished record's age says nothing about whether
  // the store is keeping up; 'ok' additionally asserts that age is inside the
  // SLO. The server used to send 'ok' for both, and the age check below read a
  // live keeper's over-SLO age as a contract violation and dropped the whole
  // payload (masc#28720).
  health: 'empty' | 'incompatible' | 'stale' | 'ok' | 'live'
  stale_reason: 'no_entries' | 'incompatible_rows' | 'freshness_slo_exceeded' | null
  keeper: string
  count: number
  // malformed JSONL rows the server refused to decode (never repaired)
  skipped_rows: number
  memory_os: MemoryOsTurnRecordSnapshot
  entries: TurnRecordRow[]
}

function hasExactKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(raw)
  return keys.length === allowed.length && keys.every(key => allowed.includes(key))
}

function hasNoUnknownKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(raw).every(key => allowed.includes(key))
}

function decodeExactNonEmptyString(raw: unknown): string | null {
  return typeof raw === 'string' && raw.trim().length > 0 ? raw : null
}

export function isMemoryOsMemoryId(raw: unknown): raw is string {
  if (typeof raw !== 'string' || raw.length !== 71 || !raw.startsWith('sha256:')) return false
  return [...raw.slice(7)].every(char => (
    (char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')
  ))
}

function decodeNullableString(raw: unknown): string | null | undefined {
  if (raw === null) return null
  return typeof raw === 'string' ? raw : undefined
}

function decodeNullableNumber(raw: unknown): number | null | undefined {
  if (raw === null) return null
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : undefined
}

function decodeNonNegativeSafeInteger(raw: unknown): number | null {
  const value = asNumber(raw)
  return value != null && Number.isSafeInteger(value) && value >= 0 ? value : null
}

function decodeFiniteNumber(raw: unknown): number | null {
  return asNumber(raw) ?? null
}

function decodeBoolean(raw: unknown): boolean | null {
  return asBoolean(raw) ?? null
}

function decodeOptionalField<T>(
  raw: Record<string, unknown>,
  key: string,
  decode: (value: unknown) => T | null,
): T | undefined | null {
  if (!Object.hasOwn(raw, key)) return undefined
  return decode(raw[key])
}

function decodeArray<T>(
  raw: unknown,
  decode: (item: unknown) => T | null,
): T[] | null {
  if (!Array.isArray(raw)) return null
  const decoded = raw.map(decode)
  return decoded.every((item): item is T => item !== null) ? decoded : null
}

function wholeSecondIsoOfUnixSeconds(raw: number): string | null {
  const date = new Date(Math.floor(raw) * 1000)
  if (!Number.isFinite(date.getTime())) return null
  return date.toISOString().replace('.000Z', 'Z')
}

function decodeTurnBlock(raw: unknown): TurnBlock | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['block', 'bytes', 'digest'])) return null
  const block = decodeTurnPromptBlockId(raw.block)
  const digest = decodeExactNonEmptyString(raw.digest)
  const bytes = asNumber(raw.bytes)
  if (
    block === null
    || digest === null
    || !/^[0-9a-f]{64}$/.test(digest)
    || bytes == null
    || !Number.isSafeInteger(bytes)
    || bytes < 0
  ) return null
  return { block, bytes, digest }
}

function decodeTurnBlockList(raw: unknown): TurnBlock[] | null {
  const blocks = decodeArray(raw, decodeTurnBlock)
  if (blocks === null) return null
  return new Set(blocks.map(block => block.block)).size === blocks.length
    ? blocks
    : null
}

function decodeTurnInputComponentId(raw: unknown): TurnInputComponentId | null {
  switch (raw) {
    case 'prompt.keeper_instructions':
    case 'prompt.dynamic_context':
    case 'prompt.temporal_summary':
    case 'prompt.memory_os_recall':
    case 'prompt.operator_note':
    case 'tool_schemas':
    case 'message_user':
    case 'message_system':
    case 'message_assistant_text':
    case 'message_thinking':
    case 'message_redacted_thinking':
    case 'message_tool_use':
    case 'message_tool_result':
    case 'message_image':
    case 'message_document':
    case 'message_audio':
      return raw
    default:
      return null
  }
}

function decodeTurnInputComponents(raw: unknown): TurnInputComponent[] | null {
  if (!Array.isArray(raw)) return null
  const components: TurnInputComponent[] = []
  for (const item of raw) {
    if (!isRecord(item) || !hasExactKeys(item, ['component', 'bytes'])) return null
    const component = decodeTurnInputComponentId(item.component)
    const bytes = decodeNonNegativeSafeInteger(item.bytes)
    if (component === null || bytes === null) {
      return null
    }
    components.push({ component, bytes })
  }
  return new Set(components.map(component => component.component)).size
    === components.length
    ? components
    : null
}

// Mirrors [raw_trace_run_ref_to_json] (lib/types/turn_record.ml:127-135): six
// fields, no optionals. A reference that names no run is written as null by the
// producer, so a partial object is a producer defect and stays rejected.
function decodeTurnRawTraceRunRef(raw: unknown): TurnRawTraceRunRef | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'worker_run_id',
    'path',
    'start_seq',
    'end_seq',
    'agent_name',
    'session_id',
  ])) return null
  const worker_run_id = decodeExactNonEmptyString(raw.worker_run_id)
  const path = decodeExactNonEmptyString(raw.path)
  const start_seq = decodeNonNegativeSafeInteger(raw.start_seq)
  const end_seq = decodeNonNegativeSafeInteger(raw.end_seq)
  const agent_name = decodeExactNonEmptyString(raw.agent_name)
  const session_id = decodeExactNonEmptyString(raw.session_id)
  if (
    worker_run_id === null
    || path === null
    || start_seq === null
    || end_seq === null
    || end_seq < start_seq
    || agent_name === null
    || session_id === null
  ) {
    return null
  }
  return { worker_run_id, path, start_seq, end_seq, agent_name, session_id }
}

function decodeTurnRecordEntry(raw: unknown): TurnRecordEntry | null {
  if (!isRecord(raw) || !hasNoUnknownKeys(raw, [
    'execution_ids',
    'keeper',
    'agent_name',
    'generation',
    'turn_kind',
    'raw_trace_run_ref',
    'trace_id',
    'absolute_turn',
    'turn_ref',
    'blocks',
    'input_components',
    'request_runtime_profile',
    'request_body_bytes',
    'transmitted_atoms',
    'total_atoms',
    'model_input_measurement',
    'runtime_profile',
    'selected_model',
    'finish_reason',
    'context_window',
    'price_input_per_million',
    'price_output_per_million',
    'request_latency_ms',
    'ttfrc_ms',
    'temperature',
    'top_p',
    'max_tokens',
    'thinking_budget',
    'enable_thinking',
    'input_tokens',
    'cache_creation_input_tokens',
    'cache_read_input_tokens',
    'output_tokens',
    'ts',
  ])) return null
  const keeper = decodeExactNonEmptyString(raw.keeper)
  const agent_name = decodeExactNonEmptyString(raw.agent_name)
  const generation = decodeNonNegativeSafeInteger(raw.generation)
  const turn_kind =
    raw.turn_kind === 'autonomous' || raw.turn_kind === 'direct' ? raw.turn_kind : null
  const raw_trace_run_ref =
    raw.raw_trace_run_ref === null ? null : decodeTurnRawTraceRunRef(raw.raw_trace_run_ref)
  const trace_id = decodeExactNonEmptyString(raw.trace_id)
  const absolute_turn = asNumber(raw.absolute_turn)
  const turn_ref = decodeExactNonEmptyString(raw.turn_ref)
  const runtime_profile = decodeExactNonEmptyString(raw.runtime_profile)
  const ts = asNumber(raw.ts)
  const blocks = decodeTurnBlockList(raw.blocks)
  const input_components =
    raw.input_components === null
      ? null
      : decodeTurnInputComponents(raw.input_components)
  const request_runtime_profile =
    raw.request_runtime_profile === null
      ? null
      : decodeExactNonEmptyString(raw.request_runtime_profile)
  const request_body_bytes =
    raw.request_body_bytes === null
      ? null
      : decodeNonNegativeSafeInteger(raw.request_body_bytes)
  const requestWireObservation: TurnRequestWireObservation | null =
    request_runtime_profile !== null && request_body_bytes !== null
      ? { request_runtime_profile, request_body_bytes }
      : request_runtime_profile === null && request_body_bytes === null
        ? { request_runtime_profile: null, request_body_bytes: null }
        : null
  const selected_model = decodeOptionalField(raw, 'selected_model', decodeExactNonEmptyString)
  const finish_reason = decodeOptionalField(raw, 'finish_reason', decodeExactNonEmptyString)
  const context_window = decodeOptionalField(raw, 'context_window', decodeNonNegativeSafeInteger)
  const transmitted_atoms =
    decodeOptionalField(raw, 'transmitted_atoms', decodeNonNegativeSafeInteger)
  const total_atoms = decodeOptionalField(raw, 'total_atoms', decodeNonNegativeSafeInteger)
  const model_input_measurement = decodeOptionalField(
    raw,
    'model_input_measurement',
    value => (value === 'wire_shape' || value === 'durable_shape' ? value : null),
  )
  const price_input_per_million =
    decodeOptionalField(raw, 'price_input_per_million', decodeFiniteNumber)
  const price_output_per_million =
    decodeOptionalField(raw, 'price_output_per_million', decodeFiniteNumber)
  const request_latency_ms =
    decodeOptionalField(raw, 'request_latency_ms', decodeNonNegativeSafeInteger)
  const ttfrc_ms = decodeOptionalField(raw, 'ttfrc_ms', decodeFiniteNumber)
  const temperature = decodeOptionalField(raw, 'temperature', decodeFiniteNumber)
  const top_p = decodeOptionalField(raw, 'top_p', decodeFiniteNumber)
  const max_tokens = decodeOptionalField(raw, 'max_tokens', decodeNonNegativeSafeInteger)
  const thinking_budget =
    decodeOptionalField(raw, 'thinking_budget', decodeNonNegativeSafeInteger)
  const enable_thinking = decodeOptionalField(raw, 'enable_thinking', decodeBoolean)
  const input_tokens = decodeOptionalField(raw, 'input_tokens', decodeNonNegativeSafeInteger)
  const output_tokens = decodeOptionalField(raw, 'output_tokens', decodeNonNegativeSafeInteger)
  const cache_creation_input_tokens =
    decodeOptionalField(raw, 'cache_creation_input_tokens', decodeNonNegativeSafeInteger)
  const cache_read_input_tokens =
    decodeOptionalField(raw, 'cache_read_input_tokens', decodeNonNegativeSafeInteger)
  if (
    keeper === null
    || agent_name === null
    || generation === null
    || turn_kind === null
    || !Object.hasOwn(raw, 'raw_trace_run_ref')
    || (raw_trace_run_ref === null && raw.raw_trace_run_ref !== null)
    || trace_id === null
    || absolute_turn == null
    || !Number.isSafeInteger(absolute_turn)
    || absolute_turn < 0
    || turn_ref === null
    || turn_ref !== `${trace_id}#${absolute_turn}`
    || runtime_profile === null
    || ts == null
    || blocks === null
    || !Object.hasOwn(raw, 'input_components')
    || input_components === null && raw.input_components !== null
    || !Object.hasOwn(raw, 'request_runtime_profile')
    || request_runtime_profile === null && raw.request_runtime_profile !== null
    || !Object.hasOwn(raw, 'request_body_bytes')
    || request_body_bytes === null && raw.request_body_bytes !== null
    || requestWireObservation === null
    || !Array.isArray(raw.execution_ids)
    || !raw.execution_ids.every((id): id is string => typeof id === 'string' && id.length > 0)
    || selected_model === null
    || finish_reason === null
    || context_window === null
    || price_input_per_million === null
    || price_output_per_million === null
    || request_latency_ms === null
    || ttfrc_ms === null
    || temperature === null
    || top_p === null
    || max_tokens === null
    || thinking_budget === null
    || enable_thinking === null
    || input_tokens === null
    || output_tokens === null
    || cache_creation_input_tokens === null
    || cache_read_input_tokens === null
  ) {
    return null
  }
  const execution_ids = raw.execution_ids
  return {
    execution_ids,
    keeper,
    agent_name,
    generation,
    turn_kind,
    raw_trace_run_ref,
    trace_id,
    absolute_turn,
    turn_ref,
    blocks,
    input_components,
    ...requestWireObservation,
    runtime_profile,
    selected_model,
    finish_reason,
    temperature,
    top_p,
    max_tokens,
    thinking_budget,
    enable_thinking,
    input_tokens,
    output_tokens,
    cache_creation_input_tokens,
    cache_read_input_tokens,
    context_window,
    // A turn whose runtime assembles its own input emits these as null, which
    // is an observation that no cut was selected — not a failed decode. Folding
    // null into undefined keeps that turn's record instead of rejecting it, and
    // reaches the inspector as absence rather than a fabricated 0.
    transmitted_atoms: transmitted_atoms ?? undefined,
    total_atoms: total_atoms ?? undefined,
    model_input_measurement: model_input_measurement ?? undefined,
    price_input_per_million,
    price_output_per_million,
    request_latency_ms,
    ttfrc_ms,
    ts,
  }
}

function decodeTurnBlockDiff(raw: unknown): TurnBlockDiff | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['added', 'removed', 'changed'])) return null
  const added = decodeTurnBlockList(raw.added)
  const removed = decodeTurnBlockList(raw.removed)
  if (added === null || removed === null || !Array.isArray(raw.changed)) return null
  const changed = raw.changed.map((pair) => {
    if (!isRecord(pair) || !hasExactKeys(pair, ['prev', 'next'])) return null
    const prev = decodeTurnBlock(pair.prev)
    const next = decodeTurnBlock(pair.next)
    return prev && next ? { prev, next } : null
  })
  if (!changed.every((pair): pair is { prev: TurnBlock; next: TurnBlock } => pair !== null)) {
    return null
  }
  return {
    added,
    removed,
    changed,
  }
}

function decodeTurnRecordRow(raw: unknown): TurnRecordRow | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['record', 'diff_vs_prev'])) return null
  const record = decodeTurnRecordEntry(raw.record)
  const diff_vs_prev = raw.diff_vs_prev === null
    ? null
    : decodeTurnBlockDiff(raw.diff_vs_prev)
  if (!record || (raw.diff_vs_prev !== null && diff_vs_prev === null)) return null
  return {
    record,
    diff_vs_prev,
  }
}

function decodeMemoryOsDerivation(raw: unknown): MemoryOsDerivation | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['rule_id', 'premise_ids'])) return null
  const rule_id = decodeExactNonEmptyString(raw.rule_id)
  const premise_ids = decodeArray(raw.premise_ids, decodeExactNonEmptyString)
  if (
    rule_id === null
    || premise_ids === null
    || premise_ids.length === 0
    || new Set(premise_ids).size !== premise_ids.length
    || premise_ids.some((value, index) => {
      const previous = premise_ids[index - 1]
      return previous !== undefined && previous >= value
    })
    || premise_ids.some(premiseId => !isMemoryOsMemoryId(premiseId))
  ) return null
  return { rule_id, premise_ids }
}

export function decodeMemoryOsBasis(raw: unknown): MemoryOsFactBasis | null {
  if (!isRecord(raw)) return null
  if (hasExactKeys(raw, ['kind']) && raw.kind === 'observed') {
    return { kind: 'observed' }
  }
  if (!hasExactKeys(raw, ['kind', 'derivations']) || raw.kind !== 'derived') return null
  const derivations = decodeArray(raw.derivations, decodeMemoryOsDerivation)
  if (
    derivations === null
    || derivations.length === 0
    || new Set(derivations.map(derivation => derivation.rule_id)).size
      !== derivations.length
  ) return null
  return { kind: 'derived', derivations }
}

function decodeMemoryOsFact(raw: unknown): MemoryOsFact | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'memory_id',
    'claim',
    'category',
    'first_seen',
    'current',
    'basis',
  ])) return null
  const memory_id = isMemoryOsMemoryId(raw.memory_id) ? raw.memory_id : null
  const claim = decodeExactNonEmptyString(raw.claim)
  const category = typeof raw.category === 'string'
    ? parseMemoryOsFactCategory(raw.category)
    : null
  const first_seen = asNumber(raw.first_seen)
  const current = asBoolean(raw.current)
  const basis = decodeMemoryOsBasis(raw.basis)
  if (
    memory_id === null
    || claim === null
    || category === null
    || first_seen == null
    || current == null
    || basis === null
  ) {
    return null
  }
  return {
    memory_id,
    claim,
    category,
    first_seen,
    current,
    basis,
  }
}

function decodeMemoryOsSupportInvalidation(
  raw: unknown,
): MemoryOsSupportInvalidation | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['fact', 'missing_premise_ids'])) return null
  const fact = decodeMemoryOsFact(raw.fact)
  const missing_premise_ids = decodeArray(
    raw.missing_premise_ids,
    decodeExactNonEmptyString,
  )
  if (
    fact === null
    || fact.current
    || fact.basis.kind !== 'derived'
    || missing_premise_ids === null
    || missing_premise_ids.length === 0
    || new Set(missing_premise_ids).size !== missing_premise_ids.length
    || missing_premise_ids.some((value, index) => {
      const previous = missing_premise_ids[index - 1]
      return previous !== undefined && previous >= value
    })
    || missing_premise_ids.some(premiseId => !isMemoryOsMemoryId(premiseId))
  ) return null
  return { fact, missing_premise_ids }
}

function decodeMemoryOsUpdateSource(raw: unknown): MemoryOsUpdateSource | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['kind', 'trace_id'])) {
    return null
  }
  const kind = decodeExactNonEmptyString(raw.kind)
  const trace_id = decodeExactNonEmptyString(raw.trace_id)
  if (
    (kind !== 'librarian'
      && kind !== 'explicit_write'
      && kind !== 'explicit_retract')
    || trace_id === null
  ) return null
  return { kind, trace_id }
}

function memoryOsFactPayloadEqual(left: MemoryOsFact, right: MemoryOsFact): boolean {
  return left.memory_id === right.memory_id
    && left.claim === right.claim
    && left.category.tag === right.category.tag
    && left.first_seen === right.first_seen
    && JSON.stringify(left.basis) === JSON.stringify(right.basis)
}

function memoryOsSupportClosure(facts: readonly MemoryOsFact[]): Set<string> {
  type PendingRule = { readonly target: string; remaining: number }
  const dependents = new Map<string, PendingRule[]>()
  for (const fact of facts) {
    if (fact.basis.kind !== 'derived') continue
    for (const derivation of fact.basis.derivations) {
      const rule: PendingRule = {
        target: fact.memory_id,
        remaining: derivation.premise_ids.length,
      }
      for (const premiseId of derivation.premise_ids) {
        const rules = dependents.get(premiseId) ?? []
        rules.push(rule)
        dependents.set(premiseId, rules)
      }
    }
  }
  const supported = new Set<string>()
  const pending: string[] = []
  const activate = (memoryId: string): void => {
    if (supported.has(memoryId)) return
    supported.add(memoryId)
    pending.push(memoryId)
  }
  for (const fact of facts) {
    if (fact.basis.kind === 'observed') activate(fact.memory_id)
  }
  for (let cursor = 0; cursor < pending.length; cursor += 1) {
    const memoryId = pending[cursor]
    if (memoryId === undefined) continue
    for (const rule of dependents.get(memoryId) ?? []) {
      rule.remaining -= 1
      if (rule.remaining === 0) activate(rule.target)
    }
  }
  return supported
}

function decodeMemoryOsCounts(raw: unknown): {
  shown: number
  current: number
} | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['shown', 'current', 'items'])) {
    return null
  }
  const shown = decodeNonNegativeSafeInteger(raw.shown)
  const current = decodeNonNegativeSafeInteger(raw.current)
  if (shown === null || current === null) return null
  return {
    shown,
    current,
  }
}

function decodeMemoryOsSnapshot(raw: unknown): MemoryOsTurnRecordSnapshot | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'keeper',
    'snapshot_store',
    'recall_enabled',
    'revision',
    'updated_at',
    'update_source',
    'read_errors',
    'facts',
    'change',
  ])) return null
  const keeper = decodeExactNonEmptyString(raw.keeper)
  const snapshot_store = decodeExactNonEmptyString(raw.snapshot_store)
  const recall_enabled = asBoolean(raw.recall_enabled)
  const revision = decodeNonNegativeSafeInteger(raw.revision)
  const updated_at = decodeNullableNumber(raw.updated_at)
  const update_source = raw.update_source === null
    ? null
    : decodeMemoryOsUpdateSource(raw.update_source)
  const read_errors = decodeArray(raw.read_errors, (item) => {
    if (!isRecord(item) || !hasExactKeys(item, ['scope', 'error'])) return null
    const scope = decodeExactNonEmptyString(item.scope)
    const error = decodeExactNonEmptyString(item.error)
    return scope === null || error === null ? null : { scope, error }
  })
  const factsRaw = isRecord(raw.facts) ? raw.facts : null
  const changeRaw = isRecord(raw.change) ? raw.change : null
  const facts = decodeMemoryOsCounts(raw.facts)
  if (
    keeper === null
    || snapshot_store === null
    || recall_enabled == null
    || revision === null
    || updated_at === undefined
    || (raw.update_source !== null && update_source === null)
    || read_errors === null
    || !factsRaw
    || !changeRaw
    || !facts
    || !hasExactKeys(changeRaw, ['added', 'removed', 'retained', 'invalidated'])
  ) {
    return null
  }
  const decodeFacts = (value: unknown): MemoryOsFact[] | null =>
    decodeArray(value, decodeMemoryOsFact)
  const factItems = decodeFacts(factsRaw.items)
  const added = decodeFacts(changeRaw.added)
  const removed = decodeFacts(changeRaw.removed)
  const retained = decodeNonNegativeSafeInteger(changeRaw.retained)
  const invalidated = decodeArray(
    changeRaw.invalidated,
    decodeMemoryOsSupportInvalidation,
  )
  const currentIds = new Set(factItems?.map(fact => fact.memory_id) ?? [])
  const currentById = new Map(
    (factItems ?? []).map(fact => [fact.memory_id, fact] as const),
  )
  const addedAreExactCurrent = (added ?? []).every(fact => {
    const current = currentById.get(fact.memory_id)
    return current !== undefined && memoryOsFactPayloadEqual(fact, current)
  })
  const removedAreNotExactCurrent = (removed ?? []).every(fact => {
    const current = currentById.get(fact.memory_id)
    return current === undefined || !memoryOsFactPayloadEqual(fact, current)
  })
  const supportClosure = memoryOsSupportClosure(factItems ?? [])
  const invalidationsAreExact = (invalidated ?? []).every(invalidation => {
    const derivations = invalidation.fact.basis.kind === 'derived'
      ? invalidation.fact.basis.derivations
      : []
    const anySupported = derivations.some(derivation =>
      derivation.premise_ids.every(premiseId => currentIds.has(premiseId)))
    const missing = [...new Set(derivations.flatMap(derivation =>
      derivation.premise_ids.filter(premiseId => !currentIds.has(premiseId))))]
      .sort()
    return !currentIds.has(invalidation.fact.memory_id)
      && !anySupported
      && missing.length === invalidation.missing_premise_ids.length
      && missing.every((premiseId, index) =>
        premiseId === invalidation.missing_premise_ids[index])
  })
  if (
    factItems === null
    || added === null
    || removed === null
    || invalidated === null
    || factItems.length !== facts.shown
    || facts.current !== facts.shown
    || factItems.some(fact => !fact.current)
    || supportClosure.size !== factItems.length
    || added.some(fact => !fact.current)
    || removed.some(fact => fact.current)
    || retained === null
    || retained + added.length !== facts.shown
    || !addedAreExactCurrent
    || !removedAreNotExactCurrent
    || new Set(added.map(fact => fact.memory_id)).size !== added.length
    || new Set(removed.map(fact => fact.memory_id)).size !== removed.length
    || new Set(invalidated.map(item => item.fact.memory_id)).size !== invalidated.length
    || !invalidationsAreExact
    || (revision === 0
      && (updated_at !== null
        || update_source !== null
        || facts.shown !== 0
        || added.length !== 0
        || removed.length !== 0
        || invalidated.length !== 0
        || retained !== 0))
    || (revision > 0
      && (updated_at === null || update_source === null))
  ) return null
  return {
    keeper,
    snapshot_store,
    recall_enabled,
    revision,
    updated_at,
    update_source,
    read_errors,
    facts: {
      ...facts,
      items: factItems,
    },
    change: {
      added,
      removed,
      retained,
      invalidated,
    },
  }
}

function decodeTurnRecordsResponse(raw: unknown): TurnRecordsResponse | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'keeper',
    'count',
    'skipped_rows',
    'source',
    'producer',
    'durable_store',
    'dashboard_surface',
    'freshness_slo_s',
    'live_turn_in_progress',
    'live_turn_started_at_unix',
    'live_turn_last_progress_at_unix',
    'latest_ts_unix',
    'latest_ts_iso',
    'latest_age_s',
    'health',
    'stale_reason',
    'memory_os',
    'entries',
  ])) return null
  const keeper = decodeExactNonEmptyString(raw.keeper)
  const count = decodeNonNegativeSafeInteger(raw.count)
  const skipped_rows = decodeNonNegativeSafeInteger(raw.skipped_rows)
  const source = raw.source === 'turn_record' ? raw.source : null
  const producer = raw.producer === 'keeper_agent_run.run_turn|keeper_turn_record_writer'
    ? raw.producer
    : null
  const durable_store = decodeExactNonEmptyString(raw.durable_store)
  const dashboard_surface = raw.dashboard_surface === '/api/v1/keepers/:name/turn-records'
    ? raw.dashboard_surface
    : null
  const freshness_slo_s = asNumber(raw.freshness_slo_s)
  const live_turn_in_progress = asBoolean(raw.live_turn_in_progress)
  const live_turn_started_at_unix = decodeNullableNumber(raw.live_turn_started_at_unix)
  const live_turn_last_progress_at_unix = decodeNullableNumber(raw.live_turn_last_progress_at_unix)
  const latest_ts_unix = decodeNullableNumber(raw.latest_ts_unix)
  const latest_ts_iso = decodeNullableString(raw.latest_ts_iso)
  const latest_age_s = decodeNullableNumber(raw.latest_age_s)
  const health =
    raw.health === 'empty'
    || raw.health === 'incompatible'
    || raw.health === 'stale'
    || raw.health === 'ok'
    || raw.health === 'live'
      ? raw.health
      : null
  const stale_reason =
    raw.stale_reason === null
    || raw.stale_reason === 'no_entries'
    || raw.stale_reason === 'incompatible_rows'
    || raw.stale_reason === 'freshness_slo_exceeded'
      ? raw.stale_reason
      : undefined
  const memory_os = decodeMemoryOsSnapshot(raw.memory_os)
  const entries = decodeArray(raw.entries, decodeTurnRecordRow)
  const latestRecordTs = entries === null || entries.length === 0
    ? null
    : Math.max(...entries.map(row => row.record.ts))
  const expectedLatestTsIso = latest_ts_unix === null || latest_ts_unix === undefined
    ? latest_ts_unix
    : wholeSecondIsoOfUnixSeconds(latest_ts_unix)
  if (
    keeper === null
    || count === null
    || skipped_rows === null
    || source === null
    || producer === null
    || durable_store === null
    || dashboard_surface === null
    || freshness_slo_s == null
    || freshness_slo_s <= 0
    || live_turn_in_progress == null
    || live_turn_started_at_unix === undefined
    || live_turn_last_progress_at_unix === undefined
    || live_turn_in_progress !== (live_turn_started_at_unix !== null)
    || live_turn_in_progress !== (live_turn_last_progress_at_unix !== null)
    || latest_ts_unix === undefined
    || latest_ts_iso === undefined
    || latest_age_s === undefined
    || (latest_age_s !== null && latest_age_s < 0)
    || health === null
    || stale_reason === undefined
    || memory_os === null
    || memory_os.keeper !== keeper
    || entries === null
    || count !== entries.length
    || entries.some(row => row.record.keeper !== keeper)
    // 'live' says nothing about the row count: a keeper's first turn reports it
    // with no entries yet, and a long-running turn reports it with the previous
    // turns' rows present.
    || (health !== 'live'
      && (entries.length === 0) !== (health === 'empty' || health === 'incompatible'))
    || latest_ts_unix !== latestRecordTs
    || latest_ts_iso !== expectedLatestTsIso
    || (health === 'empty'
      && (latest_ts_unix !== null
        || latest_ts_iso !== null
        || latest_age_s !== null
        || skipped_rows !== 0
        || stale_reason !== 'no_entries'))
    || (health === 'incompatible'
      && (latest_ts_unix !== null
        || latest_ts_iso !== null
        || latest_age_s !== null
        || skipped_rows === 0
        || stale_reason !== 'incompatible_rows'))
    || (health === 'stale'
      && (latest_ts_unix === null
        || latest_ts_iso === null
        || latest_age_s === null
        || latest_age_s <= freshness_slo_s
        || stale_reason !== 'freshness_slo_exceeded'))
    || (health === 'ok'
      && (latest_ts_unix === null
        || latest_ts_iso === null
        || latest_age_s === null
        || latest_age_s > freshness_slo_s
        || stale_reason !== null))
    // No age constraint: that is what 'live' means. It does require that a turn
    // really is running, and carries no stale reason.
    || (health === 'live' && (!live_turn_in_progress || stale_reason !== null))
  ) return null
  return {
    source,
    producer,
    durable_store,
    dashboard_surface,
    freshness_slo_s,
    live_turn_in_progress,
    live_turn_started_at_unix,
    live_turn_last_progress_at_unix,
    latest_ts_unix,
    latest_ts_iso,
    latest_age_s,
    health,
    stale_reason,
    keeper,
    count,
    skipped_rows,
    memory_os,
    entries,
  }
}

function limitQueryString(limit?: number): string {
  const params = new URLSearchParams()
  if (limit != null) params.set('limit', String(limit))
  const query = params.toString()
  return query ? `?${query}` : ''
}

export async function fetchKeeperTurnRecords(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<TurnRecordsResponse> {
  const params = limitQueryString(limit)
  await ensureDevToken()
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/turn-records${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeTurnRecordsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper turn record payload')
    return decoded
  })
}

// ── Keeper turn transcript (RFC-0233 §7) ────────────────
// The operator request + keeper response for one turn, joined server-side
// on the turn_ref "<trace_id>#<absolute_turn>". Lazily fetched by the turn
// inspector so the transcript (which can be large) never bloats the
// turn-records list. Content is the same load-time redacted view the chat
// history endpoint serves (RFC-0132); `found` is false when no persisted
// row carries the requested turn_ref, in which case the inspector renders
// explicit absence rather than a fabricated transcript.

export type TurnTranscriptLine = {
  role: string
  content: string
  ts?: number
  // Writer-declared row kind; present (e.g. 'transport_failure') only on
  // non-utterance assistant rows so the inspector can mark a failed reply
  // distinctly rather than quoting it as the keeper's own words.
  kind?: string
}

export type TurnTranscript = {
  keeper: string
  turn_ref: string
  found: boolean
  source: string
  user: TurnTranscriptLine[]
  assistant: TurnTranscriptLine[]
}

function decodeTurnTranscriptLine(raw: unknown): TurnTranscriptLine | null {
  if (!isRecord(raw)) return null
  const role = asString(raw.role)
  if (!role) return null
  return {
    role,
    content: asString(raw.content) ?? '',
    ts: asNumber(raw.ts),
    kind: asString(raw.kind),
  }
}

function decodeTurnTranscript(raw: unknown): TurnTranscript | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const turn_ref = asString(raw.turn_ref)
  if (!keeper || !turn_ref) return null
  const decodeLines = (value: unknown): TurnTranscriptLine[] =>
    asRecordArray(value)
      .map(decodeTurnTranscriptLine)
      .filter((line): line is TurnTranscriptLine => line !== null)
  return {
    keeper,
    turn_ref,
    found: asBoolean(raw.found, false) ?? false,
    source: asString(raw.source) ?? 'keeper_chat_store',
    user: decodeLines(raw.user),
    assistant: decodeLines(raw.assistant),
  }
}

export function fetchKeeperTurnTranscript(
  name: string,
  turnRef: string,
  opts?: AbortableRequestOptions,
): Promise<TurnTranscript> {
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/turn-transcript?turn_ref=${encodeURIComponent(turnRef)}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeTurnTranscript(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper turn transcript payload')
    return decoded
  })
}
