// MASC Dashboard — Keeper turn records / transcript (RFC-0233).
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, type AbortableRequestOptions } from './core'
import { isRecord, asBoolean, asNumber, asNullableString, asString, asRecordArray } from '../components/common/normalize'

export type TurnBlockId =
  | 'persona'
  | 'dynamic_context'
  | 'temporal_summary'
  | 'memory_os_recall'

export type TurnBlock = {
  block: TurnBlockId
  bytes: number
  digest: string
}

export type TurnInputComponentId =
  | `prompt.${TurnBlockId}`
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

export type TurnInputComponent = {
  component: TurnInputComponentId
  bytes: number
}

export type TurnRecordEntry = {
  execution_ids: string[]
  keeper: string
  trace_id: string
  absolute_turn: number
  turn_ref: string
  blocks: TurnBlock[]
  input_components: TurnInputComponent[]
  request_runtime_profile: string | null
  request_body_bytes: number | null
  runtime_profile: string
  // RFC-0233 §2.3 — grounded from the backend turn record (boundary-redacted
  // model label + keeper stop reason). Absent (undefined) when an error turn
  // did not record them; the inspector renders absence, never a fabricated value.
  model?: string
  finish_reason?: string
  temperature?: number
  top_p?: number
  max_tokens?: number
  thinking_budget?: number
  enable_thinking?: boolean
  input_tokens?: number
  output_tokens?: number
  // #25779 made the provider cache counts durable on the turn record
  // (lib/types/turn_record.ml writes them as optional fields). A provider that
  // reports no cache usage leaves these undefined; the inspector renders
  // absence rather than a fabricated zero.
  cache_creation_input_tokens?: number
  cache_read_input_tokens?: number
  // RFC-0233 §8 — runtime model metadata. context_window is the keeper-resolved
  // effective token budget (the ctx-fill% denominator); the two prices are USD
  // per 1M tokens declared on the runtime binding. Absent (undefined) when the
  // runtime is unknown or the operator left runtime.toml unset; the inspector
  // renders "미상" (unknown) rather than a fabricated 200K / Claude $3·$15.
  context_window?: number
  price_input_per_million?: number
  price_output_per_million?: number
  // RFC-0233 §9 — wall-clock duration of the provider call (ms), sourced from
  // OAS inference_telemetry.request_latency_ms. Absent when the turn errored
  // before a response existed; the inspector renders "측정 없음" rather than a
  // fabricated duration for the response-generation phase.
  request_latency_ms?: number
  // RFC-0233 §10 — time-to-first-response-chunk (ms, wall-clock), sourced from
  // OAS inference_telemetry.ttfrc_ms. Unlike request_latency_ms (end-to-end),
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

export type MemoryOsEpisodeSummary = {
  trace_id: string
  generation: number
  created_at: number
  claim_count: number
  // Inclusive [lo, hi] absolute-turn span the episode compacted, or null when the
  // record carries none (memory_os_episode_json → Keeper_memory_os_types.episode.source_turn_range).
  source_turn_range: readonly [number, number] | null
  summary: string
}

// RFC-keeper-memory-panel-real-data §4a: the librarian taxonomy as a closed TS union mirroring the OCaml
// `category` sum (keeper_memory_os_types.ml — category_to_string is the wire SSOT).
// The wire carries a string token; it is parsed once at this decode boundary into
// a tagged value. The backend emits only the closed OCaml sum. Any other spelling
// is a contract violation and rejects the payload rather than becoming a
// compatibility arm.
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

export type MemoryOsFactProvenance = {
  readonly trace_id: string
  readonly turn: number
  readonly tool_call_id: string | null
}

// One fact row as projected by memory_os_fact_json (server_dashboard_http_keeper_api.ml).
// Carries only the structure RFC-0247 left on the record — there is no salience /
// uses / confidence field to decode because the backend has none to emit.
export type MemoryOsFact = {
  readonly claim: string
  readonly category: MemoryOsFactCategory
  readonly source: MemoryOsFactProvenance
  readonly first_seen: number
  readonly first_seen_iso: string
  // last_verified_at else first_seen — the shared staleness anchor (reference_time).
  readonly reference_time: number
  readonly last_verified_at: number | null
}

export type MemoryOsSelectionPolicy = {
  readonly keeper_scope: string
  readonly facts_source: 'Keeper_memory_os_io.read_facts_all_for_keepers_dir'
  readonly episodes_source: 'Keeper_memory_os_io.read_episodes_all_for_keepers_dir'
  readonly category_source: 'Keeper_memory_os_types.category_to_string'
  readonly recall_block: 'Keeper_memory_os_recall.render_if_enabled'
  readonly prompt_record: 'Keeper_run_tools_hooks.record_block Prompt_block_id.Memory_os_recall'
}

export type MemoryOsTurnRecordSnapshot = {
  keeper: string
  source: 'memory_os_files'
  producer: 'keeper_librarian|keeper_memory_os_recall'
  selection_policy: MemoryOsSelectionPolicy
  facts_store: string
  episodes_store: string
  recall_enabled: boolean
  read_errors: { scope: string; error: string }[]
  episodes: {
    shown: number
    items: MemoryOsEpisodeSummary[]
  }
  facts: {
    shown: number
    // RFC-keeper-memory-panel-real-data §4a: every persisted fact row.
    items: MemoryOsFact[]
  }
}

export type TurnRecordsResponse = {
  source: 'turn_record'
  producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer'
  durable_store: string
  dashboard_surface: '/api/v1/keepers/:name/turn-records'
  freshness_slo_s: number
  latest_ts_unix: number | null
  latest_ts_iso: string | null
  latest_age_s: number | null
  health: 'empty' | 'stale' | 'ok'
  stale_reason: 'no_entries' | 'freshness_slo_exceeded' | null
  keeper: string
  count: number
  // malformed JSONL rows the server refused to decode (never repaired)
  skipped_rows: number
  memory_os: MemoryOsTurnRecordSnapshot
  entries: TurnRecordRow[]
}

export type KeeperCompactionSnapshotLinks = {
  readonly receipt_path: string | null
  readonly checkpoint_path: string | null
  readonly tool_call_log_path: string | null
}

export type KeeperCompactionExactEvidence = {
  readonly before_checkpoint_bytes: number
  readonly after_checkpoint_bytes: number
  readonly before_message_count: number
  readonly after_message_count: number
  readonly summarized_message_count: number
  readonly dropped_message_count: number
  readonly before_tool_use_count: number
  readonly after_tool_use_count: number
  readonly before_tool_result_count: number
  readonly after_tool_result_count: number
}

export type KeeperCompactionReinjectionState =
  | 'not_linked'
  | 'awaiting_load'
  | 'checkpoint_not_loaded'
  | 'loaded_not_injected'
  | 'reinserted'
  | 'sequence_incomplete'
  | 'sequence_reversed'
  | 'duplicate_receipt'

export type KeeperCompactionReinjectionObservation = {
  readonly state: KeeperCompactionReinjectionState
  readonly keeper_turn_id: number | null
  readonly checkpoint_loaded_receipts: number
  readonly context_injected_receipts: number
}

export type KeeperCompactionOutcome =
  | 'checkpoint_committed'
  | 'retry_without_checkpoint'
  | 'lifecycle_cleanup_failed_without_checkpoint'

export type KeeperCompactionSnapshot = {
  readonly id: string
  readonly keeper: string
  readonly ts_iso: string
  readonly ts_unix: number | null
  readonly trace_id: string | null
  readonly keeper_turn_id: number | null
  readonly source: string
  readonly trigger: string
  readonly runtime_id: string | null
  readonly display_runtime: string
  readonly before_tokens: number | null
  readonly after_tokens: number | null
  readonly saved_tokens: number | null
  readonly compaction_id: string | null
  readonly compaction_source: string | null
  readonly compaction_outcome: KeeperCompactionOutcome | null
  readonly cause: string | null
  readonly status: string
  readonly links: KeeperCompactionSnapshotLinks
  readonly exact_evidence: KeeperCompactionExactEvidence | null
  readonly reinjection_observation: KeeperCompactionReinjectionObservation
}

export type KeeperCompactionSnapshotsResponse = {
  readonly schema: string
  readonly keeper: string
  readonly source: string
  readonly producer: string
  readonly limit: number
  readonly count: number
  readonly read_error_count: number
  readonly read_errors: { scope: string; error: string }[]
  readonly scan_truncated: boolean
  readonly items: KeeperCompactionSnapshot[]
}

const TURN_BLOCK_IDS = new Set<TurnBlockId>([
  'persona',
  'dynamic_context',
  'temporal_summary',
  'memory_os_recall',
])

function decodeTurnBlockId(raw: unknown): TurnBlockId | null {
  return typeof raw === 'string' && TURN_BLOCK_IDS.has(raw as TurnBlockId)
    ? raw as TurnBlockId
    : null
}

function decodeTurnBlock(raw: unknown): TurnBlock | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['block', 'bytes', 'digest'])) return null
  const block = decodeTurnBlockId(raw.block)
  const digest = decodeExactNonEmptyString(raw.digest)
  const bytes = asNumber(raw.bytes)
  if (
    block === null
    || digest === null
    || bytes == null
    || !Number.isSafeInteger(bytes)
    || bytes < 0
  ) return null
  return { block, bytes, digest }
}

function decodeOptionalField<T>(
  raw: Record<string, unknown>,
  key: string,
  decode: (value: unknown) => T | null,
): T | undefined | null {
  if (!Object.hasOwn(raw, key)) return undefined
  return decode(raw[key])
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

function decodeTurnBlockList(raw: unknown): TurnBlock[] | null {
  if (!Array.isArray(raw)) return null
  const blocks = raw.map(decodeTurnBlock)
  return blocks.every((block): block is TurnBlock => block !== null) ? blocks : null
}

const TURN_FIXED_INPUT_COMPONENTS = new Set<TurnInputComponentId>([
  'tool_schemas',
  'message_user',
  'message_system',
  'message_assistant_text',
  'message_thinking',
  'message_redacted_thinking',
  'message_tool_use',
  'message_tool_result',
  'message_image',
  'message_document',
  'message_audio',
])

function decodeTurnInputComponentId(raw: unknown): TurnInputComponentId | null {
  if (typeof raw !== 'string') return null
  if (TURN_FIXED_INPUT_COMPONENTS.has(raw as TurnInputComponentId)) {
    return raw as TurnInputComponentId
  }
  if (!raw.startsWith('prompt.')) return null
  const block = decodeTurnBlockId(raw.slice('prompt.'.length))
  return block === null ? null : `prompt.${block}`
}

function decodeTurnInputComponents(raw: unknown): TurnInputComponent[] | null {
  if (!Array.isArray(raw)) return null
  const components: TurnInputComponent[] = []
  for (const item of raw) {
    if (!isRecord(item) || !hasExactKeys(item, ['component', 'bytes'])) return null
    const component = decodeTurnInputComponentId(item.component)
    const bytes = decodeNonNegativeSafeInteger(item.bytes)
    if (component === null || bytes === null) return null
    components.push({ component, bytes })
  }
  return components
}

function decodeTurnRecordEntry(raw: unknown): TurnRecordEntry | null {
  if (!isRecord(raw) || !hasNoUnknownKeys(raw, [
    'execution_ids',
    'keeper',
    'trace_id',
    'absolute_turn',
    'turn_ref',
    'blocks',
    'input_components',
    'request_runtime_profile',
    'request_body_bytes',
    'runtime_profile',
    'model',
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
  const trace_id = decodeExactNonEmptyString(raw.trace_id)
  const absolute_turn = asNumber(raw.absolute_turn)
  const runtime_profile = decodeExactNonEmptyString(raw.runtime_profile)
  const ts = asNumber(raw.ts)
  const blocks = decodeTurnBlockList(raw.blocks)
  const input_components = decodeTurnInputComponents(raw.input_components)
  const request_runtime_profile =
    raw.request_runtime_profile === null
      ? null
      : decodeExactNonEmptyString(raw.request_runtime_profile)
  const request_body_bytes =
    raw.request_body_bytes === null
      ? null
      : decodeNonNegativeSafeInteger(raw.request_body_bytes)
  const turn_ref = decodeExactNonEmptyString(raw.turn_ref)
  const model = decodeOptionalField(raw, 'model', decodeExactNonEmptyString)
  const finish_reason = decodeOptionalField(raw, 'finish_reason', decodeExactNonEmptyString)
  const context_window = decodeOptionalField(raw, 'context_window', decodeNonNegativeSafeInteger)
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
    || trace_id === null
    || absolute_turn == null
    || !Number.isSafeInteger(absolute_turn)
    || absolute_turn < 0
    || runtime_profile === null
    || ts == null
    || blocks === null
    || input_components === null
    || !Object.hasOwn(raw, 'request_runtime_profile')
    || (request_runtime_profile === null && raw.request_runtime_profile !== null)
    || !Object.hasOwn(raw, 'request_body_bytes')
    || (request_body_bytes === null && raw.request_body_bytes !== null)
    || !Array.isArray(raw.execution_ids)
    || !raw.execution_ids.every((id): id is string => typeof id === 'string' && id.length > 0)
    || turn_ref === null
    || model === null
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
    || turn_ref !== `${trace_id}#${absolute_turn}`
  ) {
    return null
  }
  const execution_ids = raw.execution_ids
  return {
    execution_ids,
    keeper,
    trace_id,
    absolute_turn,
    turn_ref,
    blocks,
    input_components,
    request_runtime_profile,
    request_body_bytes,
    runtime_profile,
    model,
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
  if (!Array.isArray(raw.changed) || added === null || removed === null) return null
  const changed = raw.changed.map((value) => {
    if (!isRecord(value) || !hasExactKeys(value, ['prev', 'next'])) return null
    const prev = decodeTurnBlock(value.prev)
    const next = decodeTurnBlock(value.next)
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

function hasExactKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(raw)
  return keys.length === allowed.length && keys.every(key => allowed.includes(key))
}

function hasNoUnknownKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(raw).every(key => allowed.includes(key))
}

function decodeNullableString(raw: unknown): string | null | undefined {
  if (raw === null) return null
  return typeof raw === 'string' && raw.length > 0 ? raw : undefined
}

function decodeExactNonEmptyString(raw: unknown): string | null {
  return typeof raw === 'string' && raw.length > 0 ? raw : null
}

function decodeNullableNumber(raw: unknown): number | null | undefined {
  if (raw === null) return null
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : undefined
}

function wholeSecondIsoOfUnixSeconds(raw: number): string | null {
  const date = new Date(Math.floor(raw) * 1000)
  if (!Number.isFinite(date.getTime())) return null
  return date.toISOString().replace('.000Z', 'Z')
}

function decodeArray<T>(
  raw: unknown,
  decode: (item: unknown) => T | null,
): T[] | null {
  if (!Array.isArray(raw)) return null
  const decoded = raw.map(decode)
  return decoded.every((item): item is T => item !== null) ? decoded : null
}

function decodeMemoryOsReadError(raw: unknown): { scope: string; error: string } | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['scope', 'error'])) return null
  const scope = decodeExactNonEmptyString(raw.scope)
  const error = decodeExactNonEmptyString(raw.error)
  return scope === null || error === null ? null : { scope, error }
}

// Decode the { lo, hi } object memory_os_episode_json emits for a present range,
// or null (server sends `Null`, or the field is malformed/absent). The UI renders
// this as an inclusive absolute-turn span, so a range that cannot exist — a
// non-integer bound, a negative turn, or hi < lo — fails closed to null rather
// than displaying an impossible span. An incomplete pair also collapses to null.
function decodeSourceTurnRange(raw: unknown): readonly [number, number] | null {
  if (!isRecord(raw)) return null
  if (!hasExactKeys(raw, ['lo', 'hi'])) return null
  const lo = asNumber(raw.lo)
  const hi = asNumber(raw.hi)
  if (lo == null || hi == null) return null
  if (!Number.isSafeInteger(lo) || !Number.isSafeInteger(hi)) return null
  if (lo < 0 || hi < lo) return null
  return [lo, hi]
}

function decodeMemoryOsEpisode(raw: unknown): MemoryOsEpisodeSummary | null {
  if (!isRecord(raw)) return null
  if (!hasExactKeys(raw, [
    'trace_id',
    'generation',
    'created_at',
    'claim_count',
    'source_turn_range',
    'summary',
  ])) return null
  const trace_id = decodeExactNonEmptyString(raw.trace_id)
  const generation = asNumber(raw.generation)
  const created_at = asNumber(raw.created_at)
  const claim_count = asNumber(raw.claim_count)
  const source_turn_range = raw.source_turn_range === null
    ? null
    : decodeSourceTurnRange(raw.source_turn_range)
  const summary = decodeExactNonEmptyString(raw.summary)
  if (
    trace_id === null
    || generation == null
    || !Number.isSafeInteger(generation)
    || generation < 0
    || created_at == null
    || claim_count == null
    || !Number.isSafeInteger(claim_count)
    || claim_count < 0
    || (raw.source_turn_range !== null && source_turn_range === null)
    || summary === null
  ) return null
  return {
    trace_id,
    generation,
    created_at,
    claim_count,
    source_turn_range,
    summary,
  }
}

function decodeMemoryOsFactProvenance(raw: unknown): MemoryOsFactProvenance | null {
  if (!isRecord(raw)) return null
  if (!hasNoUnknownKeys(raw, ['trace_id', 'turn', 'tool_call_id'])) return null
  const trace_id = decodeExactNonEmptyString(raw.trace_id)
  const turn = asNumber(raw.turn)
  const has_tool_call_id = Object.hasOwn(raw, 'tool_call_id')
  const tool_call_id = has_tool_call_id
    ? decodeExactNonEmptyString(raw.tool_call_id)
    : null
  if (
    trace_id === null
    || turn == null
    || !Number.isSafeInteger(turn)
    || turn < 0
    || (has_tool_call_id && tool_call_id === null)
  ) return null
  return { trace_id, turn, tool_call_id }
}

function decodeMemoryOsFact(raw: unknown): MemoryOsFact | null {
  if (!isRecord(raw)) return null
  if (!hasExactKeys(raw, [
    'claim',
    'category',
    'source',
    'first_seen',
    'first_seen_iso',
    'reference_time',
    'last_verified_at',
  ])) return null
  const claim = decodeExactNonEmptyString(raw.claim)
  const category = typeof raw.category === 'string'
    ? parseMemoryOsFactCategory(raw.category)
    : null
  const source = decodeMemoryOsFactProvenance(raw.source)
  const first_seen = asNumber(raw.first_seen)
  const first_seen_iso = decodeExactNonEmptyString(raw.first_seen_iso)
  const reference_time = asNumber(raw.reference_time)
  const last_verified_at = decodeNullableNumber(raw.last_verified_at)
  const expected_first_seen_iso = first_seen == null
    ? null
    : wholeSecondIsoOfUnixSeconds(first_seen)
  const expected_reference_time =
    last_verified_at === undefined ? undefined : (last_verified_at ?? first_seen)
  if (
    claim === null
    || !category
    || !source
    || first_seen == null
    || first_seen_iso === null
    || expected_first_seen_iso === null
    || first_seen_iso !== expected_first_seen_iso
    || reference_time == null
    || expected_reference_time === undefined
    || reference_time !== expected_reference_time
    || last_verified_at === undefined
  ) {
    return null
  }
  return {
    claim,
    category,
    source,
    first_seen,
    first_seen_iso,
    reference_time,
    last_verified_at,
  }
}

function decodeMemoryOsSelectionPolicy(raw: unknown): MemoryOsSelectionPolicy | null {
  if (!isRecord(raw)) return null
  if (!hasExactKeys(raw, [
    'keeper_scope',
    'facts_source',
    'episodes_source',
    'category_source',
    'recall_block',
    'prompt_record',
  ])) return null
  const keeper_scope = decodeExactNonEmptyString(raw.keeper_scope)
  const facts_source =
    raw.facts_source === 'Keeper_memory_os_io.read_facts_all_for_keepers_dir'
    ? raw.facts_source
    : null
  const episodes_source =
    raw.episodes_source === 'Keeper_memory_os_io.read_episodes_all_for_keepers_dir'
    ? raw.episodes_source
    : null
  const category_source = raw.category_source === 'Keeper_memory_os_types.category_to_string'
    ? raw.category_source
    : null
  const recall_block = raw.recall_block === 'Keeper_memory_os_recall.render_if_enabled'
    ? raw.recall_block
    : null
  const prompt_record =
    raw.prompt_record === 'Keeper_run_tools_hooks.record_block Prompt_block_id.Memory_os_recall'
      ? raw.prompt_record
      : null
  if (
    keeper_scope === null
    || facts_source === null
    || episodes_source === null
    || category_source === null
    || recall_block === null
    || prompt_record === null
  ) {
    return null
  }
  return {
    keeper_scope,
    facts_source,
    episodes_source,
    category_source,
    recall_block,
    prompt_record,
  }
}

function decodeMemoryOsCount(raw: unknown): { shown: number } | null {
  if (!isRecord(raw)) return null
  if (!hasNoUnknownKeys(raw, ['shown', 'items'])) {
    return null
  }
  const shown = asNumber(raw.shown)
  if (
    shown == null
    || !Number.isSafeInteger(shown)
    || shown < 0
  ) return null
  return { shown }
}

function decodeMemoryOsSnapshot(raw: unknown): MemoryOsTurnRecordSnapshot | null {
  if (!isRecord(raw)) return null
  if (!hasExactKeys(raw, [
    'keeper',
    'source',
    'producer',
    'selection_policy',
    'facts_store',
    'episodes_store',
    'recall_enabled',
    'read_errors',
    'episodes',
    'facts',
  ])) return null
  const keeper = decodeExactNonEmptyString(raw.keeper)
  const source = raw.source === 'memory_os_files' ? raw.source : null
  const producer = raw.producer === 'keeper_librarian|keeper_memory_os_recall'
    ? raw.producer
    : null
  const selection_policy = decodeMemoryOsSelectionPolicy(raw.selection_policy)
  const facts_store = decodeExactNonEmptyString(raw.facts_store)
  const episodes_store = decodeExactNonEmptyString(raw.episodes_store)
  const recall_enabled = asBoolean(raw.recall_enabled)
  const read_errors = decodeArray(raw.read_errors, decodeMemoryOsReadError)
  const episodesRaw = isRecord(raw.episodes) ? raw.episodes : null
  const factsRaw = isRecord(raw.facts) ? raw.facts : null
  const facts = decodeMemoryOsCount(raw.facts)
  if (
    keeper === null
    || source === null
    || producer === null
    || !selection_policy
    || facts_store === null
    || episodes_store === null
    || recall_enabled == null
    || !read_errors
    || !episodesRaw
    || !factsRaw
    || !facts
  ) {
    return null
  }
  const episodesCounts = decodeMemoryOsCount(episodesRaw)
  if (!episodesCounts) return null
  if (!hasExactKeys(episodesRaw, ['shown', 'items'])) {
    return null
  }
  if (!hasExactKeys(factsRaw, ['shown', 'items'])) return null
  const episodes = decodeArray(episodesRaw.items, decodeMemoryOsEpisode)
  const factItems = decodeArray(factsRaw.items, decodeMemoryOsFact)
  if (
    !episodes
    || !factItems
  ) return null
  if (
    episodesCounts.shown !== episodes.length
    || facts.shown !== factItems.length
  ) return null
  return {
    keeper,
    source,
    producer,
    selection_policy,
    facts_store,
    episodes_store,
    recall_enabled,
    read_errors,
    episodes: {
      ...episodesCounts,
      items: episodes,
    },
    facts: {
      ...facts,
      items: factItems,
    },
  }
}

function decodeTurnRecordsResponse(raw: unknown): TurnRecordsResponse | null {
  if (!isRecord(raw)) return null
  if (!hasExactKeys(raw, [
    'keeper',
    'count',
    'skipped_rows',
    'source',
    'producer',
    'durable_store',
    'dashboard_surface',
    'freshness_slo_s',
    'latest_ts_unix',
    'latest_ts_iso',
    'latest_age_s',
    'health',
    'stale_reason',
    'memory_os',
    'entries',
  ])) return null
  const keeper = decodeExactNonEmptyString(raw.keeper)
  const memory_os = decodeMemoryOsSnapshot(raw.memory_os)
  const count = asNumber(raw.count)
  const skipped_rows = asNumber(raw.skipped_rows)
  const entries = decodeArray(raw.entries, decodeTurnRecordRow)
  const source = raw.source === 'turn_record' ? raw.source : null
  const producer = raw.producer === 'keeper_agent_run.run_turn|keeper_turn_record_writer'
    ? raw.producer
    : null
  const durable_store = decodeExactNonEmptyString(raw.durable_store)
  const dashboard_surface = raw.dashboard_surface === '/api/v1/keepers/:name/turn-records'
    ? raw.dashboard_surface
    : null
  const freshness_slo_s = asNumber(raw.freshness_slo_s)
  const latest_ts_unix = decodeNullableNumber(raw.latest_ts_unix)
  const latest_ts_iso = decodeNullableString(raw.latest_ts_iso)
  const latest_age_s = decodeNullableNumber(raw.latest_age_s)
  const health =
    raw.health === 'empty' || raw.health === 'stale' || raw.health === 'ok'
      ? raw.health
      : null
  const stale_reason =
    raw.stale_reason === null
    || raw.stale_reason === 'no_entries'
    || raw.stale_reason === 'freshness_slo_exceeded'
      ? raw.stale_reason
      : undefined
  const latestRecordTs = entries === null || entries.length === 0
    ? null
    : Math.max(...entries.map(row => row.record.ts))
  const expectedLatestTsIso = latest_ts_unix === null || latest_ts_unix === undefined
    ? latest_ts_unix
    : wholeSecondIsoOfUnixSeconds(latest_ts_unix)
  if (
    keeper === null
    || !memory_os
    || memory_os.keeper !== keeper
    || memory_os.selection_policy.keeper_scope !== keeper
    || count == null
    || !Number.isSafeInteger(count)
    || count < 0
    || skipped_rows == null
    || !Number.isSafeInteger(skipped_rows)
    || skipped_rows < 0
    || entries === null
    || count !== entries.length
    || source === null
    || producer === null
    || durable_store === null
    || dashboard_surface === null
    || freshness_slo_s == null
    || freshness_slo_s <= 0
    || latest_ts_unix === undefined
    || latest_ts_iso === undefined
    || latest_age_s === undefined
    || (latest_age_s !== null && latest_age_s < 0)
    || health === null
    || stale_reason === undefined
    || entries.some(row => row.record.keeper !== keeper)
    || (entries.length === 0) !== (health === 'empty')
    || latest_ts_unix !== latestRecordTs
    || latest_ts_iso !== expectedLatestTsIso
    || (health === 'empty'
      && (latest_ts_unix !== null
        || latest_ts_iso !== null
        || latest_age_s !== null
        || stale_reason !== 'no_entries'))
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
  ) return null
  return {
    source,
    producer,
    durable_store,
    dashboard_surface,
    freshness_slo_s,
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

function decodeKeeperCompactionSnapshotLinks(raw: unknown): KeeperCompactionSnapshotLinks {
  if (!isRecord(raw)) {
    return { receipt_path: null, checkpoint_path: null, tool_call_log_path: null }
  }
  return {
    receipt_path: asNullableString(raw.receipt_path),
    checkpoint_path: asNullableString(raw.checkpoint_path),
    tool_call_log_path: asNullableString(raw.tool_call_log_path),
  }
}

function nullableNumber(raw: unknown): number | null {
  return asNumber(raw) ?? null
}

function decodeCompactionExactEvidence(raw: unknown): KeeperCompactionExactEvidence | null | undefined {
  if (raw === null) return null
  if (!isRecord(raw)) return undefined
  const evidence = {
    before_checkpoint_bytes: asNumber(raw.before_checkpoint_bytes),
    after_checkpoint_bytes: asNumber(raw.after_checkpoint_bytes),
    before_message_count: asNumber(raw.before_message_count),
    after_message_count: asNumber(raw.after_message_count),
    summarized_message_count: asNumber(raw.summarized_message_count),
    dropped_message_count: asNumber(raw.dropped_message_count),
    before_tool_use_count: asNumber(raw.before_tool_use_count),
    after_tool_use_count: asNumber(raw.after_tool_use_count),
    before_tool_result_count: asNumber(raw.before_tool_result_count),
    after_tool_result_count: asNumber(raw.after_tool_result_count),
  }
  if (Object.values(evidence).some(value => value === undefined)) return undefined
  return evidence as KeeperCompactionExactEvidence
}

const COMPACTION_REINJECTION_STATES: readonly KeeperCompactionReinjectionState[] = [
  'not_linked',
  'awaiting_load',
  'checkpoint_not_loaded',
  'loaded_not_injected',
  'reinserted',
  'sequence_incomplete',
  'sequence_reversed',
  'duplicate_receipt',
]

function decodeCompactionReinjectionObservation(
  raw: unknown,
): KeeperCompactionReinjectionObservation | undefined {
  if (!isRecord(raw)) return undefined
  const state = asString(raw.state) as KeeperCompactionReinjectionState | undefined
  const loaded = asNumber(raw.checkpoint_loaded_receipts)
  const injected = asNumber(raw.context_injected_receipts)
  if (!state || !COMPACTION_REINJECTION_STATES.includes(state)
      || loaded === undefined || injected === undefined) return undefined
  return {
    state,
    keeper_turn_id: nullableNumber(raw.keeper_turn_id),
    checkpoint_loaded_receipts: loaded,
    context_injected_receipts: injected,
  }
}

function decodeCompactionOutcome(raw: unknown): KeeperCompactionOutcome | null | undefined {
  if (raw === null) return null
  const value = asString(raw)
  switch (value) {
    case 'checkpoint_committed':
    case 'retry_without_checkpoint':
    case 'lifecycle_cleanup_failed_without_checkpoint':
      return value
    case undefined:
    default:
      return undefined
  }
}

function compactionOutcomeContractIsValid(
  outcome: KeeperCompactionOutcome | null,
  evidence: KeeperCompactionExactEvidence | null,
  cause: string | null,
): boolean {
  switch (outcome) {
    case null:
      return evidence === null && cause === null
    case 'checkpoint_committed':
      return evidence !== null && (cause === null || Boolean(cause.trim()))
    case 'retry_without_checkpoint':
    case 'lifecycle_cleanup_failed_without_checkpoint':
      return evidence === null && Boolean(cause?.trim())
  }
}

function decodeKeeperCompactionSnapshot(raw: unknown): KeeperCompactionSnapshot | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const keeper = asString(raw.keeper)
  const ts_iso = asString(raw.ts_iso)
  const source = asString(raw.source)
  const trigger = asString(raw.trigger)
  const status = asString(raw.status)
  if (!id || !keeper || !ts_iso || !source || !trigger || !status) return null
  const runtimeId = asNullableString(raw.runtime_id)
  const compactionSource = asNullableString(raw.compaction_source)
  const exactEvidence = decodeCompactionExactEvidence(raw.exact_evidence)
  const compactionOutcome = decodeCompactionOutcome(raw.compaction_outcome)
  const cause =
    raw.cause === null ? null : asString(raw.cause)
  const reinjectionObservation =
    decodeCompactionReinjectionObservation(raw.reinjection_observation)
  if (
    exactEvidence === undefined
    || compactionOutcome === undefined
    || cause === undefined
    || reinjectionObservation === undefined
  ) return null
  if (!compactionOutcomeContractIsValid(compactionOutcome, exactEvidence, cause)) return null
  return {
    id,
    keeper,
    ts_iso,
    ts_unix: nullableNumber(raw.ts_unix),
    trace_id: asNullableString(raw.trace_id),
    keeper_turn_id: nullableNumber(raw.keeper_turn_id),
    source,
    trigger,
    runtime_id: runtimeId,
    display_runtime: asString(raw.display_runtime)?.trim() ?? '',
    before_tokens: nullableNumber(raw.before_tokens),
    after_tokens: nullableNumber(raw.after_tokens),
    saved_tokens: nullableNumber(raw.saved_tokens),
    compaction_id: asNullableString(raw.compaction_id),
    compaction_source: compactionSource,
    compaction_outcome: compactionOutcome,
    cause: cause,
    status,
    links: decodeKeeperCompactionSnapshotLinks(raw.links),
    exact_evidence: exactEvidence,
    reinjection_observation: reinjectionObservation,
  }
}

function decodeReadErrors(raw: unknown): { scope: string; error: string }[] {
  return asRecordArray(raw)
    .map((item) => {
      const scope = asString(item.scope)
      const error = asString(item.error)
      return scope && error ? { scope, error } : null
    })
    .filter((item): item is { scope: string; error: string } => item !== null)
}

function decodeKeeperCompactionSnapshotsResponse(raw: unknown): KeeperCompactionSnapshotsResponse | null {
  if (!isRecord(raw)) return null
  const schema = asString(raw.schema)
  const keeper = asString(raw.keeper)
  const source = asString(raw.source)
  const producer = asString(raw.producer)
  if (!schema || !keeper || !source || !producer) return null
  return {
    schema,
    keeper,
    source,
    producer,
    limit: asNumber(raw.limit, 0) ?? 0,
    count: asNumber(raw.count, 0) ?? 0,
    read_error_count: asNumber(raw.read_error_count, 0) ?? 0,
    read_errors: decodeReadErrors(raw.read_errors),
    scan_truncated: asBoolean(raw.scan_truncated) ?? false,
    items: asRecordArray(raw.items)
      .map(decodeKeeperCompactionSnapshot)
      .filter((item): item is KeeperCompactionSnapshot => item !== null),
  }
}

function limitQueryString(limit?: number): string {
  const params = new URLSearchParams()
  if (limit != null) params.set('limit', String(limit))
  const query = params.toString()
  return query ? `?${query}` : ''
}

export function fetchKeeperTurnRecords(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<TurnRecordsResponse> {
  const params = limitQueryString(limit)
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/turn-records${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeTurnRecordsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper turn record payload')
    return decoded
  })
}

export function fetchKeeperCompactionSnapshots(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<KeeperCompactionSnapshotsResponse> {
  const params = limitQueryString(limit)
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/compaction-snapshots${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeKeeperCompactionSnapshotsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper compaction snapshot payload')
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
