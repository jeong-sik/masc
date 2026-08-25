// MASC Dashboard — Fusion run registry fetcher + decoder.
// Extracted from dashboard.ts (domain split). Public symbols are re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { isRecord, asInt, asNumber, asRecordArray, asString } from '../components/common/normalize'
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

// Unlike `status`, an unrecognized topology is not mapped onto a member of the
// enum: topology is displayed, never used to judge health, so inventing
// `simple` for an unknown value would report a shape the run did not run.
// `null` lets the UI omit the chip instead.
function asFusionTopology(value: unknown): FusionTopologyLabel | null {
  return typeof value === 'string' && (FUSION_TOPOLOGIES as readonly string[]).includes(value)
    ? (value as FusionTopologyLabel)
    : null
}

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
  // `null` for rows written before the registry tracked it.
  topology: FusionTopologyLabel | null
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
  generatedAt: string | null
}

// The backend emits a closed three-label enum, so an unrecognized value can only
// come from a protocol break. Map it to `failed` (conservative: never let a
// garbled row pose as a healthy `completed` or an active `running`) rather than
// to a convenient default — see CLAUDE.md "Unknown → Permissive Default".
function asFusionRunStatus(value: unknown): FusionRunStatusLabel {
  return value === 'running' || value === 'completed' || value === 'failed' ? value : 'failed'
}

export function parseFusionRunsResponse(raw: unknown): DashboardFusionRunsResponse {
  const root = isRecord(raw) ? raw : {}
  const runs: FusionRunRecord[] = asRecordArray(root.runs)
    .map(row => ({
      runId: asString(row.run_id) ?? '',
      keeper: asString(row.keeper) ?? '',
      preset: asString(row.preset) ?? '',
      topology: asFusionTopology(row.topology),
      startedAt: asNumber(row.started_at) ?? 0,
      status: asFusionRunStatus(row.status),
      error: asString(row.error),
      failureCode: asString(row.failure_code),
    }))
    .filter(run => run.runId.length > 0)
  return {
    runs,
    count: asInt(root.count) ?? runs.length,
    generatedAt: asString(root.generated_at) ?? null,
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
