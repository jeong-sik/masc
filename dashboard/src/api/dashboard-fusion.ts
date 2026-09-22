// MASC Dashboard — Fusion run registry fetcher + decoder, and the typed
// fusion config read/write.
// Extracted from dashboard.ts (domain split). Public symbols are re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { isRecord, asInt, asString } from '../components/common/normalize'
import { ApiRequestError, get, post, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import { decodeCommittedRuntimeTomlConfig, type CommittedRuntimeTomlConfig } from './dashboard-runtime'

/** Status of a tracked fusion deliberation, mirroring the backend
    Fusion_run_registry.status_label vocabulary: a run is `running`, or finished
    `completed` (judge ok) / `failed` (denied / sink-failed / aborted). */
export type FusionRunStatusLabel = 'running' | 'completed' | 'failed'

/** How a run reduced its panel, mirroring the backend
    Fusion_types.fusion_topology_to_string vocabulary. */
export type FusionTopologyLabel =
  | 'simple'
  | 'refine'
  | 'conditional'
  | 'judge_of_judges'
  | 'staged_judge_of_judges'

const FUSION_TOPOLOGIES: readonly FusionTopologyLabel[] = [
  'simple',
  'refine',
  'conditional',
  'judge_of_judges',
  'staged_judge_of_judges',
]

/** One row of the fusion run registry from GET /api/v1/dashboard/fusion-runs.
    The registry tracks what the board-post view cannot: an in-progress
    deliberation has no board post yet, so only the registry shows it as
    `running`. Distinct from `FusionRunView` (board-meta-derived detail). */
export interface FusionRunRecord {
  runId: string
  keeper: string
  preset: string
  // The deliberation shape this run executed. The registry is the only place
  // that survives delivery (the obligation record carrying it is removed once
  // the result lands), so a completed run's topology is readable only here.
  // The decoder requires the topology emitted by the current registry.
  topology: FusionTopologyLabel
  startedAt: number // unix seconds
  status: FusionRunStatusLabel
  // Failure attribution, present only on `failed` rows. The backend emits both
  // as additive fields (Fusion_run_registry.run_to_yojson): `error` is the human
  // failure text, `failure_code` the closed machine tag (timeout / provider_error
  // / …). Absent on running/completed rows.
  error?: string
  failureCode?: string
}

export interface DashboardFusionRunsResponse {
  runs: FusionRunRecord[]
  count: number
  generatedAt: string
  replay: FusionReplay
  historicalEvidence: FusionHistoricalEvidence[]
}

export type FusionReplay =
  | { status: 'not_replayed' | 'absent' }
  | { status: 'complete' | 'incomplete'; linesRead: number; malformedLines: number; droppedRunning: number }

export interface FusionHistoricalEvidence {
  runId: string
  postId: string
  title: string
  createdAt: number
}

function nonnegativeNumber(value: unknown, field: string, integer = false): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0
      || (integer && !Number.isInteger(value))) throw new Error(`Invalid Fusion ${field}`)
  return value
}

function parseFusionReplay(raw: unknown): FusionReplay {
  if (!isRecord(raw)) throw new Error('Invalid Fusion replay observation')
  switch (raw.status) {
    case 'not_replayed': case 'absent': return { status: raw.status }
    case 'complete': case 'incomplete': return {
      status: raw.status,
      linesRead: nonnegativeNumber(raw.lines_read, 'replay.lines_read', true),
      malformedLines: nonnegativeNumber(raw.malformed_lines, 'replay.malformed_lines', true),
      droppedRunning: nonnegativeNumber(raw.dropped_running, 'replay.dropped_running', true),
    }
    default: throw new Error('Unknown Fusion replay status')
  }
}

function parseHistoricalEvidence(raw: unknown): FusionHistoricalEvidence[] {
  if (!Array.isArray(raw)) throw new Error('Invalid Fusion historical evidence list')
  return raw.map(row => {
    if (!isRecord(row) || typeof row.run_id !== 'string' || !row.run_id.trim()
        || typeof row.post_id !== 'string' || !row.post_id.trim() || typeof row.title !== 'string') {
      throw new Error('Fusion historical evidence requires exact run and Board post identities')
    }
    return { runId: row.run_id, postId: row.post_id, title: row.title,
      createdAt: nonnegativeNumber(row.created_at, 'historical publication time') }
  })
}

function requiredRunString(value: unknown, field: string): string {
  if (typeof value !== 'string') throw new Error(`Invalid Fusion ${field}: expected a string`)
  return value
}

function parseFusionRun(raw: unknown, index: number): FusionRunRecord {
  const context = `runs[${index}]`
  if (!isRecord(raw)) throw new Error(`Invalid Fusion ${context}: expected an object`)
  const runId = requiredRunString(raw.run_id, `${context}.run_id`)
  if (!runId.trim()) throw new Error(`Invalid Fusion ${context}.run_id: empty identity`)
  const keeper = requiredRunString(raw.keeper, `${context}.keeper`)
  const preset = requiredRunString(raw.preset, `${context}.preset`)
  const topology = requiredRunString(raw.topology, `${context}.topology`)
  if (!(FUSION_TOPOLOGIES as readonly string[]).includes(topology)) throw new Error(`Unknown Fusion ${context}.topology: ${topology}`)
  const startedAt = nonnegativeNumber(raw.started_at, `${context}.started_at`)
  const status = raw.status
  if (status !== 'running' && status !== 'completed' && status !== 'failed') {
    throw new Error(`Unknown Fusion ${context}.status: ${String(status)}`)
  }
  const error = status === 'failed' ? requiredRunString(raw.error, `${context}.error`) : undefined
  const failureCode = status === 'failed' ? requiredRunString(raw.failure_code, `${context}.failure_code`) : undefined
  if (status !== 'failed' && (raw.error != null || raw.failure_code != null)) {
    throw new Error(`Invalid Fusion ${context}: only failed runs may carry failure attribution`)
  }
  return { runId, keeper, preset, topology: topology as FusionTopologyLabel, startedAt, status, error, failureCode }
}

export function parseFusionRunsResponse(raw: unknown): DashboardFusionRunsResponse {
  if (!isRecord(raw)) throw new Error('Invalid Fusion response: expected an object')
  if (!Array.isArray(raw.runs)) throw new Error('Invalid Fusion runs: expected an array')
  const runs = raw.runs.map(parseFusionRun)
  const count = nonnegativeNumber(raw.count, 'count', true)
  if (count !== runs.length) throw new Error(`Invalid Fusion count: ${count} does not match ${runs.length} rows`)
  if (new Set(runs.map(run => run.runId)).size !== runs.length) throw new Error('Invalid Fusion runs: duplicate run_id')
  return {
    runs,
    count,
    generatedAt: requiredRunString(raw.generated_at, 'generated_at'),
    replay: parseFusionReplay(raw.replay),
    historicalEvidence: parseHistoricalEvidence(raw.historical_evidence),
  }
}

export async function fetchFusionRuns(
  opts?: AbortableRequestOptions,
): Promise<DashboardFusionRunsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/fusion-runs', { signal: opts?.signal })
  return parseFusionRunsResponse(raw)
}

// ── Typed fusion config (RFC-0306 §3.1, RFC fusion-seat-routes §2.5) ────────
//
// GET /api/v1/runtime/config/fusion serves the *parsed* [fusion] policy, which
// is the same value the tool executes against, together with the revision of
// the runtime.toml it was parsed from. POST to the same path applies one typed
// operation (settings / upsert / delete / rename) against that revision: the
// server re-reads the file under its config lock and refuses the write with
// `configuration_changed` when the file moved on since the read, so a client
// never overwrites an edit it has not seen.

export interface FusionJudgeSpecView {
  readonly model: string
  readonly label: string
  readonly systemPrompt: string
  readonly webTools: boolean
  readonly maxOutputTokens: number | null
  readonly timeoutS: number | null
}

export interface FusionPanelGroupView {
  readonly models: readonly string[]
  readonly label: string
  readonly systemPrompt: string
  readonly webTools: boolean
  readonly maxOutputTokens: number | null
  readonly timeoutS: number | null
}

export interface FusionPresetConfigView {
  readonly name: string
  readonly panels: readonly FusionPanelGroupView[]
  readonly judge: string
  readonly judgeSystemPrompt: string
  readonly judgeMaxOutputTokens: number | null
  readonly judgeTimeoutS: number | null
  /** First-pass judges (RFC-0283). Two or more make the judge-of-judges
      topologies runnable; the `judge` above is then the meta reducer. */
  readonly judges: readonly FusionJudgeSpecView[]
  readonly minAnswered: number
}

export interface FusionConfigView {
  readonly enabled: boolean
  readonly defaultPreset: string
  readonly stagedJudgeGroupSize: number
  readonly presets: readonly FusionPresetConfigView[]
}

/** The config plus the revision of the runtime.toml it came from. A write
    sends the revision back as `expected_revision`; the config and the revision
    come from one read on the server, so the revision names exactly the text
    this config was parsed from. */
export interface FusionConfigSnapshot extends FusionConfigView {
  readonly sourceRevision: string
}

// The backend emits `null` for an unset optional rather than omitting the key,
// so absence and "explicitly none" arrive the same way and both mean "the
// runtime/provider value applies". Kept as null instead of a fabricated
// default: showing `0` or the provider's number would claim the preset said
// something it did not.
function asOptionalNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function parsePanelGroup(raw: unknown): FusionPanelGroupView {
  const row = isRecord(raw) ? raw : {}
  return {
    models: Array.isArray(row.models)
      ? row.models.filter((model): model is string => typeof model === 'string')
      : [],
    label: asString(row.label) ?? '',
    systemPrompt: asString(row.system_prompt) ?? '',
    webTools: row.web_tools === true,
    maxOutputTokens: asOptionalNumber(row.max_output_tokens),
    timeoutS: asOptionalNumber(row.timeout_s),
  }
}

function parseJudgeSpec(raw: unknown): FusionJudgeSpecView {
  const row = isRecord(raw) ? raw : {}
  return {
    model: asString(row.model) ?? '',
    label: asString(row.label) ?? '',
    systemPrompt: asString(row.system_prompt) ?? '',
    webTools: row.web_tools === true,
    maxOutputTokens: asOptionalNumber(row.max_output_tokens),
    timeoutS: asOptionalNumber(row.timeout_s),
  }
}

export function parseFusionConfigResponse(raw: unknown): FusionConfigSnapshot {
  const root = isRecord(raw) ? raw : {}
  // The revision is the write precondition. Unlike the config fields, which
  // fall back to the backend defaults, a missing revision cannot be replaced by
  // anything: a fabricated one would let a write bypass the conflict check.
  const sourceRevision = root.source_revision
  if (typeof sourceRevision !== 'string' || sourceRevision.trim() === '') {
    throw new Error('Invalid Fusion config: source_revision must be a non-empty string')
  }
  const config = isRecord(root.config) ? root.config : {}
  const presets = (Array.isArray(config.presets) ? config.presets : []).map(entry => {
    const row = isRecord(entry) ? entry : {}
    return {
      name: asString(row.name) ?? '',
      panels: (Array.isArray(row.panels) ? row.panels : []).map(parsePanelGroup),
      judge: asString(row.judge) ?? '',
      judgeSystemPrompt: asString(row.judge_system_prompt) ?? '',
      judgeMaxOutputTokens: asOptionalNumber(row.judge_max_output_tokens),
      judgeTimeoutS: asOptionalNumber(row.judge_timeout_s),
      judges: (Array.isArray(row.judges) ? row.judges : []).map(parseJudgeSpec),
      minAnswered: asInt(row.min_answered) ?? 1,
    }
  })
  return {
    enabled: config.enabled === true,
    defaultPreset: asString(config.default_preset) ?? '',
    stagedJudgeGroupSize: asInt(config.staged_judge_group_size) ?? 3,
    presets,
    sourceRevision,
  }
}

export async function fetchFusionConfig(
  opts?: AbortableRequestOptions,
): Promise<FusionConfigSnapshot> {
  const raw = await get<unknown>('/api/v1/runtime/config/fusion', { signal: opts?.signal })
  return parseFusionConfigResponse(raw)
}

// ── Typed fusion config write ───────────────────────────────────────────────
//
// The wire shape is decoded on the server by Fusion_config_json.preset_of_yojson
// with an exact key check: an unknown key (a camelCase leak, say) or a missing
// key is a 400. These interfaces are that contract spelled out on this side,
// and presetToWire is the only place a view becomes wire JSON.

interface FusionJudgeSpecWire {
  readonly model: string
  readonly label: string
  readonly system_prompt: string
  readonly web_tools: boolean
  readonly max_output_tokens: number | null
  readonly timeout_s: number | null
}

interface FusionPanelGroupWire {
  readonly models: readonly string[]
  readonly label: string
  readonly system_prompt: string
  readonly web_tools: boolean
  readonly max_output_tokens: number | null
  readonly timeout_s: number | null
}

export interface FusionPresetWire {
  readonly name: string
  readonly panels: readonly FusionPanelGroupWire[]
  readonly judge: string
  readonly judge_system_prompt: string
  readonly judge_max_output_tokens: number | null
  readonly judge_timeout_s: number | null
  readonly judges: readonly FusionJudgeSpecWire[]
  readonly min_answered: number
}

function panelGroupToWire(group: FusionPanelGroupView): FusionPanelGroupWire {
  return {
    models: [...group.models],
    label: group.label,
    system_prompt: group.systemPrompt,
    web_tools: group.webTools,
    max_output_tokens: group.maxOutputTokens,
    timeout_s: group.timeoutS,
  }
}

function judgeSpecToWire(judge: FusionJudgeSpecView): FusionJudgeSpecWire {
  return {
    model: judge.model,
    label: judge.label,
    system_prompt: judge.systemPrompt,
    web_tools: judge.webTools,
    max_output_tokens: judge.maxOutputTokens,
    timeout_s: judge.timeoutS,
  }
}

export function presetToWire(preset: FusionPresetConfigView): FusionPresetWire {
  return {
    name: preset.name,
    panels: preset.panels.map(panelGroupToWire),
    judge: preset.judge,
    judge_system_prompt: preset.judgeSystemPrompt,
    judge_max_output_tokens: preset.judgeMaxOutputTokens,
    judge_timeout_s: preset.judgeTimeoutS,
    judges: preset.judges.map(judgeSpecToWire),
    min_answered: preset.minAnswered,
  }
}

/** One edit of the [fusion] table, mirroring Fusion_config_edit.operation. */
export type FusionConfigEditOperation =
  | {
      readonly kind: 'set_settings'
      readonly enabled: boolean
      readonly defaultPreset: string
      readonly stagedJudgeGroupSize: number
    }
  | { readonly kind: 'upsert_preset'; readonly preset: FusionPresetConfigView }
  | { readonly kind: 'delete_preset'; readonly name: string }
  | { readonly kind: 'rename_preset'; readonly from: string; readonly to: string }

export type FusionConfigEditOperationWire =
  | {
      readonly kind: 'set_settings'
      readonly enabled: boolean
      readonly default_preset: string
      readonly staged_judge_group_size: number
    }
  | { readonly kind: 'upsert_preset'; readonly preset: FusionPresetWire }
  | { readonly kind: 'delete_preset'; readonly name: string }
  | { readonly kind: 'rename_preset'; readonly from: string; readonly to: string }

export function operationToWire(operation: FusionConfigEditOperation): FusionConfigEditOperationWire {
  switch (operation.kind) {
    case 'set_settings':
      return {
        kind: 'set_settings',
        enabled: operation.enabled,
        default_preset: operation.defaultPreset,
        staged_judge_group_size: operation.stagedJudgeGroupSize,
      }
    case 'upsert_preset':
      return { kind: 'upsert_preset', preset: presetToWire(operation.preset) }
    case 'delete_preset':
      return { kind: 'delete_preset', name: operation.name }
    case 'rename_preset':
      return { kind: 'rename_preset', from: operation.from, to: operation.to }
  }
}

/** A refused write, mirroring Fusion_config_edit.error_to_yojson. `message` is
    the server's sentence for a person; the detail fields name what it is about. */
export type FusionConfigEditFailure =
  | { readonly code: 'configuration_unavailable'; readonly message: string }
  | { readonly code: 'configuration_changed'; readonly message: string }
  | {
      readonly code: 'preset_invalid'
      readonly message: string
      readonly preset: string
      readonly reason: string
    }
  | {
      readonly code: 'route_unresolved'
      readonly message: string
      readonly preset: string
      readonly route: string
      readonly reason: string
    }
  | { readonly code: 'name_invalid'; readonly message: string; readonly preset: string }
  | { readonly code: 'default_preset_deleted'; readonly message: string; readonly preset: string }
  // The line-surgical TOML writer could not address what the edit names: the
  // [fusion] table or the preset table is written as dotted keys, an inline
  // table or a scalar rather than as a header with its keys below it. Every
  // operation can answer this, `set_settings` included, and the message names
  // which table and says to edit the raw runtime.toml instead.
  | { readonly code: 'edit_refused'; readonly message: string }
  | { readonly code: 'fusion_invalid'; readonly message: string; readonly messages: readonly string[] }
  | { readonly code: 'configuration_rejected'; readonly message: string }

export class FusionConfigEditError extends Error {
  readonly failure: FusionConfigEditFailure
  readonly status: number | undefined
  constructor(failure: FusionConfigEditFailure, status: number | undefined) {
    super(failure.message)
    this.name = 'FusionConfigEditError'
    this.failure = failure
    this.status = status
  }
}

function requiredString(row: Record<string, unknown>, key: string): string | null {
  const value = row[key]
  return typeof value === 'string' ? value : null
}

/** Reads the `{ok: false, error: {code, message, ...}}` body of a refused
    write. Returns null for any other body, so the caller keeps the transport
    error (and its raw body) instead of inventing a failure. */
export function parseFusionConfigEditError(raw: unknown): FusionConfigEditFailure | null {
  if (!isRecord(raw) || !isRecord(raw.error)) return null
  const error = raw.error
  const code = requiredString(error, 'code')
  const message = requiredString(error, 'message')
  if (code === null || message === null) return null
  switch (code) {
    case 'configuration_unavailable':
      return { code: 'configuration_unavailable', message }
    case 'configuration_changed':
      return { code: 'configuration_changed', message }
    case 'edit_refused':
      return { code: 'edit_refused', message }
    case 'configuration_rejected':
      return { code: 'configuration_rejected', message }
    case 'preset_invalid': {
      const preset = requiredString(error, 'preset')
      const reason = requiredString(error, 'reason')
      return preset === null || reason === null ? null : { code: 'preset_invalid', message, preset, reason }
    }
    case 'route_unresolved': {
      const preset = requiredString(error, 'preset')
      const route = requiredString(error, 'route')
      const reason = requiredString(error, 'reason')
      return preset === null || route === null || reason === null
        ? null
        : { code: 'route_unresolved', message, preset, route, reason }
    }
    case 'name_invalid': {
      const preset = requiredString(error, 'preset')
      return preset === null ? null : { code: 'name_invalid', message, preset }
    }
    case 'default_preset_deleted': {
      const preset = requiredString(error, 'preset')
      return preset === null ? null : { code: 'default_preset_deleted', message, preset }
    }
    case 'fusion_invalid': {
      if (!Array.isArray(error.messages)) return null
      const messages = error.messages.filter((entry): entry is string => typeof entry === 'string')
      return messages.length === error.messages.length ? { code: 'fusion_invalid', message, messages } : null
    }
    default:
      return null
  }
}

/** POST /api/v1/runtime/config/fusion. Resolves with the same commit receipt the
    raw runtime.toml save returns. Rejects with FusionConfigEditError when the
    server refused the edit with a typed failure (409 configuration_changed
    among them), and with the transport error otherwise. */
export async function applyFusionConfigEdit(
  expectedRevision: string,
  operation: FusionConfigEditOperation,
): Promise<CommittedRuntimeTomlConfig> {
  await ensureDevToken()
  try {
    const raw = await post<unknown>('/api/v1/runtime/config/fusion', {
      expected_revision: expectedRevision,
      operation: operationToWire(operation),
    })
    return decodeCommittedRuntimeTomlConfig(raw)
  } catch (error) {
    if (error instanceof ApiRequestError) {
      const failure = parseFusionConfigEditError(error.responseData)
      if (failure !== null) throw new FusionConfigEditError(failure, error.status)
    }
    throw error
  }
}

/** Which topologies this preset can actually run, given its judge roster and
    the deployment's staged group size. The tool advertises all five, but
    judge-of-judges needs >= 2 first-pass judges and the staged form needs the
    roster to divide into at least two full groups — so a preset with no
    `judges` fails those two calls every time. The UI uses this to say that
    before an operator picks one. */
export function runnableTopologies(
  preset: FusionPresetConfigView,
  stagedGroupSize: number,
): readonly FusionTopologyLabel[] {
  const base: FusionTopologyLabel[] = ['simple', 'refine', 'conditional']
  const judges = preset.judges.length
  if (judges >= 2) base.push('judge_of_judges')
  if (stagedGroupSize >= 2 && judges >= stagedGroupSize * 2 && judges % stagedGroupSize === 0) {
    base.push('staged_judge_of_judges')
  }
  return base
}
