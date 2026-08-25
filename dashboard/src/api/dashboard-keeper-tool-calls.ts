// MASC Dashboard — keeper tool call log (full I/O).
// Extracted from dashboard.ts. Public symbols re-exported from dashboard.ts.

import { isRecord, asBoolean, asNumber, asRecordArray, asString, asStringArray } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'
import { decodeTelemetryFreshnessMetadata, type TelemetryFreshnessMetadata } from './dashboard-shared'

// Output is either an inline string (legacy / small payload) or a
// normalized blob descriptor — see lib/keeper_tool_call_log.ml
// `blob_aware_output_json`. The renderer must accept both shapes.
export type ToolCallOutputBlob = {
  _blob: {
    sha256: string
    bytes: number
    mime: string
    preview: string
  }
}

export type ToolCallDisposition = 'completed' | 'deferred' | 'failed'
export type ToolCallCompositionExecution = 'inline' | 'async'

// Recorded execution evidence — written per row by lib/keeper_tool_call_log.ml.
// The jsonl row is the wire truth: nested nullable fields persist as explicit
// nulls (e.g. runtime_contract.task_id), optional top-level fields as absent.

export type ToolCallPathResolution = {
  read_implicit_cwd?: boolean
  read_explicit_cwd_supported?: boolean
  read_basis?: string
  discover_before_read?: string
  execute_path_basis?: string
  masc_state_basis?: string
}

// Sandbox/runtime contract the call executed under. Identity fields that
// duplicate the top-level row (keeper_name, trace_id, session_id, task_id,
// goal_ids, keeper_turn_id, sandbox_profile) are not repeated here.
export type ToolCallRuntimeContract = {
  agent_name?: string
  generation?: number
  sandbox_root?: string
  allowed_paths?: string[]
  path_resolution?: ToolCallPathResolution
  network_mode?: string
  runtime_profile?: string
}

// What the call targeted. The server derives this once at record time by
// parsing the redacted input (lib/keeper/keeper_runtime_contract.ml
// action_radius_json), so every consumer reads the same value. target_kind is
// "path" for a file target and "directory" for a cwd or repo_path — Execute
// rows used to report their cwd as "path" and there was no way to tell the two
// apart (masc#29013). tool_name / success / duration_ms duplicate the
// top-level row and are not repeated here.
export type ToolCallActionRadius = {
  action_key?: string
  target_kind?: string
  target_path?: string
  observed_paths?: string[]
  error?: string
}

// How the call was routed: descriptor identity plus executor/backend receipt.
// status is projected to a string from either wire shape (bare "ok" or a
// record like {kind:"exit",code:0}).
export type ToolCallRouteEvidence = {
  descriptor_id?: string
  capability_id?: string
  executor?: string
  backend?: string
  runtime_handler?: string
  readonly?: boolean
  receipt_labels?: Record<string, string>
  status?: string
}

export type ToolCallEntry = {
  ts: number
  keeper: string
  tool: string
  input: unknown
  output: string | ToolCallOutputBlob
  success: boolean
  duration_ms: number | null
  model?: string
  trace_id?: string
  session_id?: string
  turn?: number
  keeper_turn_id?: number
  task_id?: string
  lane?: string
  // Which turn made the call: a submitted operation's turn ('direct') or the
  // keeper's own autonomous cycle. Both carry the same trace_id, so without
  // this an operator reading the inspector cannot tell a submission's calls
  // from work the keeper started on its own. Absent on rows written outside
  // a keeper turn (runtime MCP) and on pre-#28977 logs.
  turn_kind?: string
  // RFC-0233: canonical execution identity minted at dispatch (absent on pre-PR-1 rows)
  execution_id?: string
  result_bytes?: number
  truncated_to?: number
  // RFC-0233 PR-2: provider call id (agent-core-event join key). Equals the chat tool
  // row's tool_call_id for the same execution, so the chat ToolCallBubble can
  // join this entry's output onto the transcript. Absent when the call carried
  // no provider id (synthesised tc-<position> rows) or on pre-PR-2 logs.
  tool_use_id?: string
  // Agent Core model-tool occurrence slot. Together with turn it scopes provider ids
  // that may be blank or repeated.
  planned_index?: number
  // Agent Core's actual batch assignment. These are schedule truth, not timing inference.
  batch_index?: number
  batch_size?: number
  execution_mode?: 'serial' | 'concurrent'
  // Typed nested-composition identity. These fields are emitted directly by
  // the executor observer; the dashboard never reconstructs them from names.
  disposition?: ToolCallDisposition
  composition_tool?: string
  composition_run_id?: string
  composition_node_id?: string
  composition_execution?: ToolCallCompositionExecution
  parent_tool_use_id?: string
  // Goal id(s) this call was attributed to (conditional on the row carrying
  // them), for goal-scoped drill-down alongside task_id/turn.
  goal_ids?: string[]
  // Recorded execution evidence. runtime_contract and action_radius are
  // written on every row. route_evidence is omitted only when the writer had
  // neither descriptor fields nor route-shaped output — an unresolved
  // descriptor can still yield a row carrying just status/tool_name (see
  // lib/keeper_tool_call_log_route_evidence.ml).
  runtime_contract?: ToolCallRuntimeContract
  action_radius?: ToolCallActionRadius
  route_evidence?: ToolCallRouteEvidence
  // Model invocation parameters for this call's turn.
  thinking_enabled?: boolean
  thinking_budget?: number
  tool_choice?: string
  prompt_fingerprint?: string
  // Which file the tool's definition was read from, relative to the masc
  // directory: 'tools/<name>.toml' for a shipped descriptor,
  // 'skills/<name>/SKILL.md' for a composition built from a skill. Derived by
  // the server from the tool name, so it is present on rows written before
  // the projection existed. Absent means the tool is a built-in that ships no
  // file — distinct from a file the reader failed to find.
  definition_source?: string
}

export type ToolCallsResponse = TelemetryFreshnessMetadata & {
  keeper: string
  count: number
  entries: ToolCallEntry[]
}

function decodeToolCallOutput(raw: unknown): string | ToolCallOutputBlob {
  if (typeof raw === 'string') return raw
  if (
    isRecord(raw) &&
    isRecord(raw._blob) &&
    typeof raw._blob.sha256 === 'string' &&
    typeof raw._blob.bytes === 'number' &&
    typeof raw._blob.mime === 'string' &&
    typeof raw._blob.preview === 'string'
  ) {
    return {
      _blob: {
        sha256: raw._blob.sha256,
        bytes: raw._blob.bytes,
        mime: raw._blob.mime,
        preview: raw._blob.preview,
      },
    }
  }
  return ''
}

// receipt_labels is a flat string→string projection on the wire; non-string
// values are dropped rather than coerced.
function asStringRecord(value: unknown): Record<string, string> | undefined {
  if (!isRecord(value)) return undefined
  const out: Record<string, string> = {}
  for (const [key, entryValue] of Object.entries(value)) {
    if (typeof entryValue === 'string') out[key] = entryValue
  }
  return out
}

function decodePathResolution(raw: unknown): ToolCallPathResolution | undefined {
  if (!isRecord(raw)) return undefined
  return {
    read_implicit_cwd: asBoolean(raw.read_implicit_cwd),
    read_explicit_cwd_supported: asBoolean(raw.read_explicit_cwd_supported),
    read_basis: asString(raw.read_basis),
    discover_before_read: asString(raw.discover_before_read),
    execute_path_basis: asString(raw.execute_path_basis),
    masc_state_basis: asString(raw.masc_state_basis),
  }
}

function decodeRuntimeContract(raw: unknown): ToolCallRuntimeContract | undefined {
  if (!isRecord(raw)) return undefined
  return {
    agent_name: asString(raw.agent_name),
    generation: asNumber(raw.generation),
    sandbox_root: asString(raw.sandbox_root),
    allowed_paths: asStringArray(raw.allowed_paths),
    path_resolution: decodePathResolution(raw.path_resolution),
    network_mode: asString(raw.network_mode),
    runtime_profile: asString(raw.runtime_profile),
  }
}

function decodeActionRadius(raw: unknown): ToolCallActionRadius | undefined {
  if (!isRecord(raw)) return undefined
  return {
    action_key: asString(raw.action_key),
    target_kind: asString(raw.target_kind),
    target_path: asString(raw.target_path),
    observed_paths: asStringArray(raw.observed_paths),
    error: asString(raw.error),
  }
}

function decodeRouteStatus(raw: unknown): string | undefined {
  if (typeof raw === 'string') return asString(raw)
  if (!isRecord(raw)) return undefined
  const kind = asString(raw.kind)
  if (kind === undefined) return undefined
  const code = asNumber(raw.code)
  return code !== undefined ? `${kind} ${code}` : kind
}

function decodeRouteEvidence(raw: unknown): ToolCallRouteEvidence | undefined {
  if (!isRecord(raw)) return undefined
  return {
    descriptor_id: asString(raw.descriptor_id),
    capability_id: asString(raw.capability_id),
    executor: asString(raw.executor),
    backend: asString(raw.backend),
    runtime_handler: asString(raw.runtime_handler),
    readonly: asBoolean(raw.readonly),
    receipt_labels: asStringRecord(raw.receipt_labels),
    status: decodeRouteStatus(raw.status),
  }
}

function decodeToolCallEntry(raw: unknown): ToolCallEntry | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const tool = asString(raw.tool)
  if (!keeper || !tool) return null
  return {
    ts: asNumber(raw.ts, 0),
    keeper,
    tool,
    input: raw.input,
    output: decodeToolCallOutput(raw.output),
    success: asBoolean(raw.success, false),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    model: asString(raw.model),
    trace_id: asString(raw.trace_id),
    session_id: asString(raw.session_id),
    turn: asNumber(raw.turn),
    keeper_turn_id: asNumber(raw.keeper_turn_id),
    task_id: asString(raw.task_id),
    lane: asString(raw.lane),
    turn_kind: asString(raw.turn_kind),
    execution_id: asString(raw.execution_id),
    result_bytes: asNumber(raw.result_bytes),
    truncated_to: asNumber(raw.truncated_to),
    tool_use_id: typeof raw.tool_use_id === 'string' ? raw.tool_use_id : undefined,
    planned_index: asNumber(raw.planned_index),
    batch_index: asNumber(raw.batch_index),
    batch_size: asNumber(raw.batch_size),
    execution_mode:
      raw.execution_mode === 'serial' || raw.execution_mode === 'concurrent'
        ? raw.execution_mode
        : undefined,
    disposition:
      raw.disposition === 'completed' ||
      raw.disposition === 'deferred' ||
      raw.disposition === 'failed'
        ? raw.disposition
        : undefined,
    composition_tool: asString(raw.composition_tool),
    composition_run_id: asString(raw.composition_run_id),
    composition_node_id: asString(raw.composition_node_id),
    composition_execution:
      raw.composition_execution === 'inline' || raw.composition_execution === 'async'
        ? raw.composition_execution
        : undefined,
    parent_tool_use_id:
      typeof raw.parent_tool_use_id === 'string' ? raw.parent_tool_use_id : undefined,
    goal_ids: asStringArray(raw.goal_ids),
    runtime_contract: decodeRuntimeContract(raw.runtime_contract),
    action_radius: decodeActionRadius(raw.action_radius),
    route_evidence: decodeRouteEvidence(raw.route_evidence),
    thinking_enabled: asBoolean(raw.thinking_enabled),
    thinking_budget: asNumber(raw.thinking_budget),
    tool_choice: asString(raw.tool_choice),
    prompt_fingerprint: asString(raw.prompt_fingerprint),
    definition_source: asString(raw.definition_source),
  }
}

function decodeToolCallsResponse(raw: unknown): ToolCallsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    count: asNumber(raw.count, 0),
    entries: asRecordArray(raw.entries)
      .map(decodeToolCallEntry)
      .filter((entry): entry is ToolCallEntry => entry !== null),
  }
}

export function fetchKeeperToolCalls(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<ToolCallsResponse> {
  const params = limit != null ? `?limit=${limit}` : ''
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/tool-calls${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeToolCallsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper tool call payload')
    return decoded
  })
}
