// MASC Dashboard — Keeper turn records / transcript (RFC-0233).
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, type AbortableRequestOptions } from './core'
import { isRecord, asBoolean, asNumber, asNullableString, asString, asStringArray, asRecordArray } from '../components/common/normalize'
import { decodeTelemetryFreshnessMetadata, type TelemetryFreshnessMetadata } from './dashboard-shared'

// Accepts either a string array or a single string; mirrors the keeper-config
// normalizeStringList (duplicated here to keep this domain self-contained).
function normalizeStringList(value: unknown): string[] {
  const array = asStringArray(value)
  if (array.length > 0) return array
  const single = asNullableString(value)
  return single ? [single] : []
}


export type TurnBlock = {
  block: string
  bytes: number
  digest: string
}

export type TurnRecordEntry = {
  execution_ids: string[]
  keeper: string
  trace_id: string
  absolute_turn: number
  blocks: TurnBlock[]
  runtime_profile: string
  // RFC-0233 §2.3 — grounded from the backend turn record (boundary-redacted
  // model label + keeper stop reason). Absent (undefined) on error turns and
  // pre-grounding rows; the inspector renders absence, never a fabricated value.
  model?: string
  finish_reason?: string
  temperature?: number
  top_p?: number
  max_tokens?: number
  thinking_budget?: number
  enable_thinking?: boolean
  input_tokens?: number
  output_tokens?: number
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
  created_at_iso: string | null
  valid_until: number | null
  valid_until_iso: string | null
  current: boolean
  terminal_marker: string | null
  claim_count: number
  summary: string
}

// RFC-keeper-memory-panel-real-data §4a: the librarian taxonomy as a closed TS union mirroring the OCaml
// `category` sum (keeper_memory_os_types.ml — category_to_string is the wire SSOT).
// The wire carries a string token; it is parsed once at this decode boundary into
// a tagged value. An out-of-vocabulary token becomes { tag: 'unknown', raw } — the
// same drift-absorbing arm the backend's `Unknown of string` defines — so a
// renamed/typo'd category surfaces as a typed unknown the panel can flag, never a
// silent miscategorization. This is exact-membership parse-don't-validate, not a
// substring/prefix classifier.
export type MemoryOsFactCategoryTag =
  | 'code_change'
  | 'fact'
  | 'preference'
  | 'blocker'
  | 'goal'
  | 'constraint'
  | 'ephemeral'
  | 'validated_approach'
  | 'lesson'
export type MemoryOsFactCategory =
  | { readonly tag: MemoryOsFactCategoryTag }
  | { readonly tag: 'unknown'; readonly raw: string }

// SSOT token list — must stay byte-identical to the known arms of
// category_of_string/category_to_string. A drift-guard test pins this set.
const MEMORY_OS_FACT_CATEGORY_TAGS: readonly MemoryOsFactCategoryTag[] = [
  'code_change',
  'fact',
  'preference',
  'blocker',
  'goal',
  'constraint',
  'ephemeral',
  'validated_approach',
  'lesson',
]

export function parseMemoryOsFactCategory(raw: string): MemoryOsFactCategory {
  // Mirror category_of_string: trim + lowercase, then exact membership.
  const token = raw.trim().toLowerCase()
  const known = MEMORY_OS_FACT_CATEGORY_TAGS.find(tag => tag === token)
  return known ? { tag: known } : { tag: 'unknown', raw }
}

// RFC-0285 §3.1 claim_kind — closed vocabulary, no Unknown arm on the backend.
// Mirrors claim_kind_of_string: an unrecognized/absent token yields undefined,
// the backend's own None degrade to the durable path.
export type MemoryOsClaimKind = 'self_observation' | 'external_state' | 'durable_knowledge'
const MEMORY_OS_CLAIM_KINDS: readonly MemoryOsClaimKind[] = [
  'self_observation',
  'external_state',
  'durable_knowledge',
]
export function parseMemoryOsClaimKind(raw: string): MemoryOsClaimKind | undefined {
  const token = raw.trim().toLowerCase()
  return MEMORY_OS_CLAIM_KINDS.find(kind => kind === token)
}

// RFC-0259 §3.2(b) external_ref — closed kind set; mirrors external_ref_kind_of_string.
export type MemoryOsExternalRefKind = 'pr' | 'issue' | 'task'
const MEMORY_OS_EXTERNAL_REF_KINDS: readonly MemoryOsExternalRefKind[] = ['pr', 'issue', 'task']
export type MemoryOsExternalRef = {
  readonly kind: MemoryOsExternalRefKind
  readonly id: string
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
  readonly first_seen_iso: string | null
  // last_verified_at else first_seen — the shared staleness anchor (reference_time).
  readonly reference_time: number
  readonly valid_until: number | null
  readonly valid_until_iso: string | null
  readonly last_verified_at: number | null
  readonly current: boolean
  readonly external_ref: MemoryOsExternalRef | null
  readonly claim_kind: MemoryOsClaimKind | null
}

export type MemoryOsTurnRecordSnapshot = {
  schema: string
  keeper: string
  source: string
  producer: string
  facts_store: string
  episodes_store: string
  recall_enabled: boolean
  now: number | null
  now_iso: string | null
  read_errors: { scope: string; error: string }[]
  episodes: {
    tail_limit: number
    shown: number
    current: number
    expired: number
    terminal_markers: number
    items: MemoryOsEpisodeSummary[]
  }
  facts: {
    tail_limit: number
    shown: number
    current: number
    expired: number
    // RFC-keeper-memory-panel-real-data §4a: the individual fact rows (bounded by tail_limit; `shown`
    // documents the bound so a truncated tail is visible, not silent).
    items: MemoryOsFact[]
  }
}

export type KeeperUserModelItem = {
  claim: string
  category: string
  source: 'keeper' | 'shared' | string
  observed_by: string[]
  turn: number
  first_seen: number
  first_seen_iso: string | null
  last_verified_at: number | null
  last_verified_at_iso: string | null
}

export type KeeperUserModelSnapshot = {
  schema: string
  keeper: string
  source: string
  producer: string
  facts_store: string
  shared_facts_store: string
  enabled: boolean
  now: number | null
  now_iso: string | null
  read_errors: { scope: string; error: string }[]
  source_fact_count: number
  shared_fact_count: number
  preferences: KeeperUserModelItem[]
  constraints: KeeperUserModelItem[]
}

export type TurnRecordsResponse = TelemetryFreshnessMetadata & {
  keeper: string
  count: number
  // malformed JSONL rows the server refused to decode (never repaired)
  skipped_rows: number
  memory_os: MemoryOsTurnRecordSnapshot | null
  user_model: KeeperUserModelSnapshot | null
  entries: TurnRecordRow[]
}

function decodeTurnBlock(raw: unknown): TurnBlock | null {
  if (!isRecord(raw)) return null
  const block = asString(raw.block)
  const digest = asString(raw.digest)
  const bytes = asNumber(raw.bytes)
  if (!block || !digest || bytes == null) return null
  return { block, bytes, digest }
}

function decodeTurnBlockList(raw: unknown): TurnBlock[] {
  return asRecordArray(raw)
    .map(decodeTurnBlock)
    .filter((block): block is TurnBlock => block !== null)
}

function decodeTurnRecordEntry(raw: unknown): TurnRecordEntry | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const trace_id = asString(raw.trace_id)
  const absolute_turn = asNumber(raw.absolute_turn)
  const runtime_profile = asString(raw.runtime_profile)
  const ts = asNumber(raw.ts)
  if (!keeper || !trace_id || absolute_turn == null || !runtime_profile || ts == null) {
    return null
  }
  const execution_ids = Array.isArray(raw.execution_ids)
    ? raw.execution_ids.filter((id): id is string => typeof id === 'string')
    : []
  return {
    execution_ids,
    keeper,
    trace_id,
    absolute_turn,
    blocks: decodeTurnBlockList(raw.blocks),
    runtime_profile,
    model: asString(raw.model),
    finish_reason: asString(raw.finish_reason),
    temperature: asNumber(raw.temperature),
    top_p: asNumber(raw.top_p),
    max_tokens: asNumber(raw.max_tokens),
    thinking_budget: asNumber(raw.thinking_budget),
    enable_thinking: typeof raw.enable_thinking === 'boolean' ? raw.enable_thinking : undefined,
    input_tokens: asNumber(raw.input_tokens),
    output_tokens: asNumber(raw.output_tokens),
    context_window: asNumber(raw.context_window),
    price_input_per_million: asNumber(raw.price_input_per_million),
    price_output_per_million: asNumber(raw.price_output_per_million),
    request_latency_ms: asNumber(raw.request_latency_ms),
    ttfrc_ms: asNumber(raw.ttfrc_ms),
    ts,
  }
}

function decodeTurnBlockDiff(raw: unknown): TurnBlockDiff | null {
  if (!isRecord(raw)) return null
  const changed = asRecordArray(raw.changed)
    .map((pair) => {
      const prev = decodeTurnBlock(pair.prev)
      const next = decodeTurnBlock(pair.next)
      return prev && next ? { prev, next } : null
    })
    .filter((pair): pair is { prev: TurnBlock; next: TurnBlock } => pair !== null)
  return {
    added: decodeTurnBlockList(raw.added),
    removed: decodeTurnBlockList(raw.removed),
    changed,
  }
}

function decodeTurnRecordRow(raw: unknown): TurnRecordRow | null {
  if (!isRecord(raw)) return null
  const record = decodeTurnRecordEntry(raw.record)
  if (!record) return null
  return {
    record,
    diff_vs_prev: decodeTurnBlockDiff(raw.diff_vs_prev),
  }
}

function decodeMemoryOsEpisode(raw: unknown): MemoryOsEpisodeSummary | null {
  if (!isRecord(raw)) return null
  const trace_id = asString(raw.trace_id)
  const generation = asNumber(raw.generation)
  const created_at = asNumber(raw.created_at)
  const summary = asString(raw.summary)
  if (!trace_id || generation == null || created_at == null || !summary) return null
  return {
    trace_id,
    generation,
    created_at,
    created_at_iso: asNullableString(raw.created_at_iso),
    valid_until: asNumber(raw.valid_until) ?? null,
    valid_until_iso: asNullableString(raw.valid_until_iso),
    current: asBoolean(raw.current, true) ?? true,
    terminal_marker: asNullableString(raw.terminal_marker),
    claim_count: asNumber(raw.claim_count, 0) ?? 0,
    summary,
  }
}

function decodeMemoryOsExternalRef(raw: unknown): MemoryOsExternalRef | undefined {
  if (!isRecord(raw)) return undefined
  const id = asString(raw.id)
  const kindToken = asString(raw.kind)?.trim().toLowerCase()
  if (!id || !kindToken) return undefined
  // Backward-compatible decode for older dashboard payloads: both fields are
  // required and kind must be in the closed set.
  const kind = MEMORY_OS_EXTERNAL_REF_KINDS.find(k => k === kindToken)
  return kind ? { kind, id } : undefined
}

function decodeMemoryOsFactProvenance(raw: unknown): MemoryOsFactProvenance | null {
  if (!isRecord(raw)) return null
  const trace_id = asString(raw.trace_id)
  const turn = asNumber(raw.turn)
  if (!trace_id || turn == null) return null
  return { trace_id, turn, tool_call_id: asNullableString(raw.tool_call_id) }
}

function decodeMemoryOsFact(raw: unknown): MemoryOsFact | null {
  if (!isRecord(raw)) return null
  const claim = asString(raw.claim)
  const categoryToken = asString(raw.category)
  const source = decodeMemoryOsFactProvenance(raw.source)
  const first_seen = asNumber(raw.first_seen)
  const reference_time = asNumber(raw.reference_time)
  const current = asBoolean(raw.current)
  // Required keys are exactly the always-present ones in memory_os_fact_json.
  // A row missing any of them is a contract violation — dropped here rather
  // than rendered with a guessed default (no silent fabrication).
  if (
    !claim
    || !categoryToken
    || !source
    || first_seen == null
    || reference_time == null
    || current == null
  ) {
    return null
  }
  // claim_kind is omitted by the server when None. external_ref is decoded only
  // for older payloads; current backend projections no longer emit it.
  const claimKindToken = asString(raw.claim_kind)
  return {
    claim,
    category: parseMemoryOsFactCategory(categoryToken),
    source,
    first_seen,
    first_seen_iso: asNullableString(raw.first_seen_iso),
    reference_time,
    valid_until: asNumber(raw.valid_until) ?? null,
    valid_until_iso: asNullableString(raw.valid_until_iso),
    last_verified_at: asNumber(raw.last_verified_at) ?? null,
    current,
    external_ref: decodeMemoryOsExternalRef(raw.external_ref) ?? null,
    claim_kind: claimKindToken ? (parseMemoryOsClaimKind(claimKindToken) ?? null) : null,
  }
}

function decodeMemoryOsCounts(raw: unknown): {
  tail_limit: number
  shown: number
  current: number
  expired: number
} | null {
  if (!isRecord(raw)) return null
  return {
    tail_limit: asNumber(raw.tail_limit, 0) ?? 0,
    shown: asNumber(raw.shown, 0) ?? 0,
    current: asNumber(raw.current, 0) ?? 0,
    expired: asNumber(raw.expired, 0) ?? 0,
  }
}

function decodeMemoryOsSnapshot(raw: unknown): MemoryOsTurnRecordSnapshot | null {
  if (!isRecord(raw)) return null
  const schema = asString(raw.schema)
  const keeper = asString(raw.keeper)
  const source = asString(raw.source)
  const producer = asString(raw.producer)
  const facts_store = asString(raw.facts_store)
  const episodes_store = asString(raw.episodes_store)
  const episodesRaw = isRecord(raw.episodes) ? raw.episodes : null
  const factsRaw = isRecord(raw.facts) ? raw.facts : null
  const facts = decodeMemoryOsCounts(raw.facts)
  if (!schema || !keeper || !source || !producer || !facts_store || !episodes_store || !episodesRaw || !factsRaw || !facts) {
    return null
  }
  const episodesCounts = decodeMemoryOsCounts(episodesRaw)
  if (!episodesCounts) return null
  return {
    schema,
    keeper,
    source,
    producer,
    facts_store,
    episodes_store,
    recall_enabled: asBoolean(raw.recall_enabled, true) ?? true,
    now: asNumber(raw.now) ?? null,
    now_iso: asNullableString(raw.now_iso),
    read_errors: asRecordArray(raw.read_errors)
      .map((item) => {
        const scope = asString(item.scope)
        const error = asString(item.error)
        return scope && error ? { scope, error } : null
      })
      .filter((item): item is { scope: string; error: string } => item !== null),
    episodes: {
      ...episodesCounts,
      terminal_markers: asNumber(episodesRaw.terminal_markers, 0) ?? 0,
      items: asRecordArray(episodesRaw.items)
        .map(decodeMemoryOsEpisode)
        .filter((item): item is MemoryOsEpisodeSummary => item !== null),
    },
    facts: {
      ...facts,
      items: asRecordArray(factsRaw.items)
        .map(decodeMemoryOsFact)
        .filter((item): item is MemoryOsFact => item !== null),
    },
  }
}

function decodeKeeperUserModelItem(raw: unknown): KeeperUserModelItem | null {
  if (!isRecord(raw)) return null
  const claim = asString(raw.claim)
  const category = asString(raw.category)
  const source = asString(raw.source)
  const turn = asNumber(raw.turn)
  const first_seen = asNumber(raw.first_seen)
  if (!claim || !category || !source || turn == null || first_seen == null) {
    return null
  }
  return {
    claim,
    category,
    source,
    observed_by: normalizeStringList(raw.observed_by),
    turn,
    first_seen,
    first_seen_iso: asNullableString(raw.first_seen_iso),
    last_verified_at: asNumber(raw.last_verified_at) ?? null,
    last_verified_at_iso: asNullableString(raw.last_verified_at_iso),
  }
}

function decodeKeeperUserModelSnapshot(raw: unknown): KeeperUserModelSnapshot | null {
  if (!isRecord(raw)) return null
  const schema = asString(raw.schema)
  const keeper = asString(raw.keeper)
  const source = asString(raw.source)
  const producer = asString(raw.producer)
  const facts_store = asString(raw.facts_store)
  const shared_facts_store = asString(raw.shared_facts_store)
  if (!schema || !keeper || !source || !producer || !facts_store || !shared_facts_store) {
    return null
  }
  return {
    schema,
    keeper,
    source,
    producer,
    facts_store,
    shared_facts_store,
    enabled: asBoolean(raw.enabled, true) ?? true,
    now: asNumber(raw.now) ?? null,
    now_iso: asNullableString(raw.now_iso),
    read_errors: asRecordArray(raw.read_errors)
      .map((item) => {
        const scope = asString(item.scope)
        const error = asString(item.error)
        return scope && error ? { scope, error } : null
      })
      .filter((item): item is { scope: string; error: string } => item !== null),
    source_fact_count: asNumber(raw.source_fact_count, 0) ?? 0,
    shared_fact_count: asNumber(raw.shared_fact_count, 0) ?? 0,
    preferences: asRecordArray(raw.preferences)
      .map(decodeKeeperUserModelItem)
      .filter((item): item is KeeperUserModelItem => item !== null),
    constraints: asRecordArray(raw.constraints)
      .map(decodeKeeperUserModelItem)
      .filter((item): item is KeeperUserModelItem => item !== null),
  }
}

function decodeTurnRecordsResponse(raw: unknown): TurnRecordsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    count: asNumber(raw.count, 0),
    skipped_rows: asNumber(raw.skipped_rows, 0),
    memory_os: decodeMemoryOsSnapshot(raw.memory_os),
    user_model: decodeKeeperUserModelSnapshot(raw.user_model),
    entries: asRecordArray(raw.entries)
      .map(decodeTurnRecordRow)
      .filter((row): row is TurnRecordRow => row !== null),
  }
}

export function fetchKeeperTurnRecords(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<TurnRecordsResponse> {
  const params = limit != null ? `?limit=${limit}` : ''
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
