// MASC Dashboard — Fusion run registry fetcher + decoder.
// Extracted from dashboard.ts (domain split). Public symbols are re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { isRecord, asInt, asString } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'

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

// ── Typed fusion config projection (RFC-0306 §3.1) ──────────────────────────
//
// GET /api/v1/runtime/config/fusion serves the *parsed* [fusion] policy, which
// is the same value the tool executes against. The Settings panel used to read
// preset shape by running regexes over the raw runtime.toml text instead, and
// that reader could only recover `panel` and `judge`: every other axis the
// backend already validated — per-panel and per-judge deadlines, output-token
// budgets, the first-pass judge roster — was invisible in the UI even though
// the endpoint emitted it. Worse, it declared grouped presets
// ([[fusion.presets.NAME.panels]]) unsupported, because a flat regex cannot
// represent them, while the typed projection has always carried them.
//
// Editing still goes through the line-surgical TOML writer; this is the read
// side only.

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

export function parseFusionConfigResponse(raw: unknown): FusionConfigView {
  const root = isRecord(raw) ? raw : {}
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
  }
}

export async function fetchFusionConfig(
  opts?: AbortableRequestOptions,
): Promise<FusionConfigView> {
  const raw = await get<unknown>('/api/v1/runtime/config/fusion', { signal: opts?.signal })
  return parseFusionConfigResponse(raw)
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
