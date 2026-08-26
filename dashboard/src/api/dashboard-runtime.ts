// MASC Dashboard — Runtime providers / model metrics / runtime.toml config.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post, type AbortableRequestOptions } from './core'
import { isRecord, asBoolean, asNumber, asNullableString, asRecordArray, asString, asStringArray } from '../components/common/normalize'
import { ensureDevToken } from './dev-token'
import type { RuntimeDefaultsResponse } from './schemas/runtime-defaults'
import type { RuntimeResolvedResponse } from './schemas/runtime-resolved'

export interface DashboardRuntimeParameterPolicy {
  reasoning_toggle_wire?: string | null
  reasoning_replay_policy?: string | null
  requires_reasoning_replay_on_tool_call?: boolean
  ignored_sampling_params: string[]
  always_ignored_sampling_params: string[]
}

export interface DashboardRuntimeToolChoice {
  kind?: string | null
  name?: string | null
}

export interface DashboardRuntimeResponseFormat {
  kind?: string | null
  has_schema?: boolean
}

export interface DashboardRuntimeRequestConfig {
  source?: string | null
  provider_kind?: string | null
  request_path?: string | null
  request_path_targets_responses_api?: boolean
  max_tokens?: number | null
  max_context?: number | null
  temperature?: number | null
  top_p?: number | null
  top_k?: number | null
  min_p?: number | null
  has_system_prompt?: boolean
  enable_thinking?: boolean | null
  preserve_thinking?: boolean | null
  thinking_budget?: number | null
  clear_thinking?: boolean | null
  resolved_reasoning_effort?: string | null
  glm_clear_thinking?: boolean
  glm_replay_reasoning?: boolean
  tool_stream?: boolean
  tool_choice?: DashboardRuntimeToolChoice | null
  disable_parallel_tool_use?: boolean
  response_format?: DashboardRuntimeResponseFormat | null
  has_output_schema?: boolean
  cache_system_prompt?: boolean
  supports_tool_choice_override?: boolean | null
  supports_structured_output_override?: boolean | null
  has_model_capabilities_override?: boolean
  keep_alive?: string | null
  internal_model_rotation_count?: number | null
  num_ctx?: number | null
  seed?: number | null
  has_previous_response_id?: boolean
  connect_timeout_s?: number | null
}

export interface DashboardRuntimeProviderBehaviorCapabilities {
  supports_inline_tools?: boolean
  argv_prompt_preflight?: boolean
  uses_anthropic_caching?: boolean
}

export interface DashboardRuntimeDeclaredProviderSpec {
  id?: string | null
  display_name?: string | null
  protocol?: string | null
  api_format?: string | null
  transport?: string | null
  auth_kind?: string | null
  is_non_interactive?: boolean
  has_capabilities?: boolean
  behavior_capabilities?: DashboardRuntimeProviderBehaviorCapabilities | null
  custom_header_count?: number | null
  connect_timeout_s?: number | null
}

export interface DashboardRuntimeDeclaredModelCapabilities {
  source?: string | null
  max_output_tokens?: number | null
  supports_tool_choice?: boolean
  supports_required_tool_choice?: boolean
  supports_named_tool_choice?: boolean
  supports_parallel_tool_calls?: boolean
  supports_extended_thinking?: boolean
  supports_reasoning_budget?: boolean
  thinking_control_format?: string | null
  supports_image_input?: boolean
  supports_audio_input?: boolean
  supports_video_input?: boolean
  supports_multimodal_inputs?: boolean
  supports_response_format_json?: boolean
  supports_structured_output?: boolean
  supports_system_prompt?: boolean
  supports_caching?: boolean
  supports_prompt_caching?: boolean
  prompt_cache_alignment?: number | null
  supports_top_k?: boolean
  supports_min_p?: boolean
  supports_seed?: boolean
  supports_seed_with_images?: boolean
  emits_usage_tokens?: boolean
  supports_computer_use?: boolean
  supports_code_execution?: boolean
}

export interface DashboardRuntimeDeclaredModelSpec {
  id?: string | null
  api_name?: string | null
  tools_support?: boolean
  max_context?: number | null
  thinking_support?: boolean
  preserve_thinking?: boolean | null
  max_thinking_budget?: number | null
  streaming?: boolean
  temperature?: number | null
  top_p?: number | null
  top_k?: number | null
  min_p?: number | null
  capabilities?: DashboardRuntimeDeclaredModelCapabilities | null
}

export interface DashboardRuntimeDeclaredBindingSpec {
  provider_id?: string | null
  model_id?: string | null
  is_default?: boolean
  max_concurrent?: number | null
  price_input?: number | null
  price_output?: number | null
  keep_alive?: string | null
  num_ctx?: number | null
}

export interface DashboardRuntimeDeclaredSpec {
  source?: string | null
  provider?: DashboardRuntimeDeclaredProviderSpec | null
  model?: DashboardRuntimeDeclaredModelSpec | null
  binding?: DashboardRuntimeDeclaredBindingSpec | null
}

export interface DashboardRuntimeReasoningStreamingFormat {
  kind?: string | null
  field?: string | null
}

export interface DashboardRuntimeEffectiveCapabilities {
  source?: string | null
  max_context_tokens?: number | null
  max_output_tokens?: number | null
  supports_tools?: boolean
  supports_tool_choice?: boolean
  supports_required_tool_choice?: boolean
  supports_named_tool_choice?: boolean
  supports_parallel_tool_calls?: boolean
  supports_runtime_mcp_tools?: boolean
  supports_runtime_tool_events?: boolean
  assistant_tool_content_format?: string | null
  supports_reasoning?: boolean
  supports_extended_thinking?: boolean
  supports_reasoning_budget?: boolean
  accepted_reasoning_efforts: string[] | null
  thinking_control_format?: string | null
  preserve_thinking_control_format?: string | null
  reasoning_output_format?: string | null
  reasoning_streaming_format?: DashboardRuntimeReasoningStreamingFormat | null
  reasoning_replay_override?: string | null
  supports_response_format_json?: boolean
  supports_structured_output?: boolean
  supports_multimodal_inputs?: boolean
  supports_image_input?: boolean
  supports_audio_input?: boolean
  supports_video_input?: boolean
  modality_priority?: string | null
  task?: string | null
  supports_native_streaming?: boolean
  supports_system_prompt?: boolean
  supports_caching?: boolean
  supports_prompt_caching?: boolean
  prompt_cache_alignment?: number | null
  supports_top_k?: boolean
  supports_min_p?: boolean
  supports_seed?: boolean
  supports_seed_with_images?: boolean
  ignored_sampling_parameters: string[]
  supports_computer_use?: boolean
  supports_code_execution?: boolean
  emits_usage_tokens?: boolean
  supported_models: string[] | null
}

export interface DashboardRuntimeProviderSnapshot {
  provider: string
  runtime_id?: string | null
  provider_id?: string | null
  provider_display_name?: string | null
  model_id?: string | null
  model_api_name?: string | null
  protocol?: string | null
  transport?: string | null
  kind?: string | null
  runtime_kind?: string | null
  auth_kind?: string | null
  status?: string | null
  available?: boolean
  is_default_runtime?: boolean
  max_context?: number | null
  tools_support?: boolean
  thinking_support?: boolean
  streaming?: boolean
  /** Per-model sampling temperature override ([models.<id>].temperature);
   *  null when unset (runtime keeps the fleet fallback). */
  temperature?: number | null
  /** Per-model sampling overrides from [models.<id>]; null when unset. */
  top_p?: number | null
  top_k?: number | null
  min_p?: number | null
  capabilities_declared?: boolean
  max_output_tokens?: number | null
  supports_tool_choice?: boolean
  supports_required_tool_choice?: boolean
  supports_named_tool_choice?: boolean
  supports_parallel_tool_calls?: boolean
  supports_extended_thinking?: boolean
  supports_multimodal_inputs?: boolean
  supports_image_input?: boolean
  supports_audio_input?: boolean
  supports_video_input?: boolean
  supports_reasoning_budget?: boolean
  thinking_control_format?: string | null
  supports_response_format_json?: boolean
  supports_structured_output?: boolean
  supports_system_prompt?: boolean
  supports_caching?: boolean
  supports_prompt_caching?: boolean
  prompt_cache_alignment?: number | null
  supports_top_k?: boolean
  supports_min_p?: boolean
  supports_seed?: boolean
  supports_seed_with_images?: boolean
  emits_usage_tokens?: boolean
  supports_computer_use?: boolean
  supports_code_execution?: boolean
  effective_capabilities?: DashboardRuntimeEffectiveCapabilities | null
  parameter_policy?: DashboardRuntimeParameterPolicy | null
  request_config?: DashboardRuntimeRequestConfig | null
  declared_spec?: DashboardRuntimeDeclaredSpec | null
  model_count?: number | null
  models: string[]
  source?: string | null
  endpoint_url?: string | null
  note?: string | null
}

export interface DashboardRuntimeAssignment {
  keeper: string
  runtime_id: string
  matches_default?: boolean
}

export interface DashboardRuntimeAssignmentStatus {
  schema?: string | null
  source?: string | null
  status?: string | null
  degraded: boolean
  operator_action_required: boolean
  blast_radius?: string | null
  assignment_count: number
  assigned_runtime_count: number
  default_assignment_count: number
  default_runtime_id?: string | null
  warnings: string[]
  assigned_runtimes: string[]
  assignments: DashboardRuntimeAssignment[]
}

export interface DashboardRuntimeStartupMissingCatalogModel {
  runtime_id: string
  provider_id?: string | null
  provider_label?: string | null
  model_id?: string | null
}

export interface DashboardRuntimeStartupDroppedAssignment {
  keeper_name: string
  runtime_id: string
}

export interface DashboardRuntimeStartupDroppedRoute {
  route_name: string
  runtime_id: string
}

export interface DashboardRuntimeStartupDroppedLane {
  lane_id: string
  runtime_ids: string[]
}

export interface DashboardRuntimeStartupDegradation {
  schema?: string | null
  status?: string | null
  degraded: boolean
  operator_action_required: boolean
  terminal_reason?: string | null
  message?: string | null
  config_path?: string | null
  configured_default_runtime_id?: string | null
  effective_default_runtime_id?: string | null
  missing_catalog_model_count: number
  missing_catalog_models: DashboardRuntimeStartupMissingCatalogModel[]
  disabled_runtime_ids: string[]
  dropped_assignments: DashboardRuntimeStartupDroppedAssignment[]
  dropped_routes: DashboardRuntimeStartupDroppedRoute[]
  dropped_media_failover: string[]
  dropped_lane_candidates: DashboardRuntimeStartupDroppedLane[]
  dropped_lanes: DashboardRuntimeStartupDroppedLane[]
  next_action?: string | null
}

export interface DashboardRuntimeProvidersResponse {
  updated_at?: string
  summary?: {
    providers?: number
    runtimes?: number
    local_models?: number
    cloud_models?: number
    cli_models?: number
    default_runtime_id?: string | null
  } | null
  providers: DashboardRuntimeProviderSnapshot[]
  assignment_status?: DashboardRuntimeAssignmentStatus | null
  startup_degradation?: DashboardRuntimeStartupDegradation | null
  // Resolved filesystem path of the runtime.toml the server actually loaded
  // (Runtime.config_path); answers "which config is live" in the monitor.
  config_path?: string | null
}

export interface BucketMetric {
  ts_start: number
  entry_count: number
  success_count: number
  error_count: number
  p50_latency_ms: number | null
  p95_latency_ms: number | null
  error_rate: number
  total_cost_usd: number | null
  cache_hit_ratio: number | null
}

export interface DashboardRuntimeModelMetric {
  model_id: string
  provider?: string | null
  entry_count?: number | null
  avg_tok_per_sec?: number | null
  p50_tok_per_sec?: number | null
  p95_tok_per_sec?: number | null
  prompt_avg_tok_per_sec?: number | null
  prompt_p50_tok_per_sec?: number | null
  prompt_p95_tok_per_sec?: number | null
  /**
   * Hardware decode rate (eval_count / eval_duration from Ollama) aggregated
   * across the telemetry window. Distinct from `avg_tok_per_sec` which is
   * wall-clock (includes queue wait + prefill + thinking in the denominator).
   * Null when no entry in the window carried timings (non-Ollama providers or
   * legacy rows before Agent Core started emitting inference_timings).
   */
  hw_decode_avg_tok_per_sec?: number | null
  hw_decode_p50_tok_per_sec?: number | null
  hw_decode_p95_tok_per_sec?: number | null
  max_peak_memory_gb?: number | null
  /**
   * Fraction [0.0, 1.0] of turns in the window where the model received
   * think=true. Null when no entry in the window reported thinking_enabled
   * (older rows or providers that don't expose the field).
   */
  thinking_fraction?: number | null
  avg_latency_ms?: number | null
  p50_latency_ms?: number | null
  p95_latency_ms?: number | null
  total_input_tokens?: number | null
  total_output_tokens?: number | null
  total_cache_read_tokens?: number | null
  total_cache_creation_tokens?: number | null
  total_reasoning_tokens?: number | null
  usage_sample_count?: number | null
  telemetry_sample_count?: number | null
  usage_missing_count?: number | null
  telemetry_missing_count?: number | null
  coverage_status?: 'full' | 'partial' | 'none' | 'error_only' | null
  primary_coverage_stage?: string | null
  primary_coverage_reason?: string | null
  coverage_reason_counts?: Array<{ reason: string; count: number }> | null
  success_count?: number | null
  error_count?: number | null
  total_cost_usd?: number | null
  avg_tool_calls_per_turn?: number | null
  total_tool_calls?: number | null
  top_tools?: Array<{ tool: string; count: number }> | null
  recent_entries?: Array<{
    ts_unix: number
    outcome?: string | null
    stop_reason?: string | null
    turn_lane?: string | null
    input_tokens: number | null
    output_tokens: number | null
    cache_read_tokens: number | null
    cache_creation_tokens: number | null
    latency_ms: number | null
    prompt_tok_per_sec?: number | null
    peak_memory_gb?: number | null
    cost_usd: number | null
    tools_count: number
    usage_reported?: boolean | null
    telemetry_reported?: boolean | null
    usage_trust?: string | null
    usage_anomaly_reasons?: string[] | null
    coverage_reason?: string | null
    coverage_stage?: string | null
    streaming_ttfrc_ms?: number | null
    streaming_inter_chunk_count?: number | null
    streaming_inter_chunk_avg_ms?: number | null
  }> | null
  buckets?: BucketMetric[] | null
}

export interface LatencyBucket {
  lo_ms: number
  hi_ms: number | null
  count: number
}

export interface DashboardRuntimeModelMetricsResponse {
  window_minutes?: number
  bucket_minutes?: number
  total_entries?: number
  total_error_entries?: number
  latency_buckets?: LatencyBucket[] | null
  models: DashboardRuntimeModelMetric[]
}

function decodeRuntimeParameterPolicy(raw: unknown): DashboardRuntimeParameterPolicy | null {
  if (!isRecord(raw)) return null
  return {
    reasoning_toggle_wire: asNullableString(raw.reasoning_toggle_wire),
    reasoning_replay_policy: asNullableString(raw.reasoning_replay_policy),
    requires_reasoning_replay_on_tool_call: asBoolean(raw.requires_reasoning_replay_on_tool_call),
    ignored_sampling_params: asStringArray(raw.ignored_sampling_params),
    always_ignored_sampling_params: asStringArray(raw.always_ignored_sampling_params),
  }
}

function decodeRuntimeToolChoice(raw: unknown): DashboardRuntimeToolChoice | null {
  if (!isRecord(raw)) return null
  return {
    kind: asNullableString(raw.kind),
    name: asNullableString(raw.name),
  }
}

function decodeRuntimeResponseFormat(raw: unknown): DashboardRuntimeResponseFormat | null {
  if (!isRecord(raw)) return null
  return {
    kind: asNullableString(raw.kind),
    has_schema: asBoolean(raw.has_schema),
  }
}

function decodeRuntimeRequestConfig(raw: unknown): DashboardRuntimeRequestConfig | null {
  if (!isRecord(raw)) return null
  return {
    source: asNullableString(raw.source),
    provider_kind: asNullableString(raw.provider_kind),
    request_path: asNullableString(raw.request_path),
    request_path_targets_responses_api: asBoolean(raw.request_path_targets_responses_api),
    max_tokens: asNumber(raw.max_tokens) ?? null,
    max_context: asNumber(raw.max_context) ?? null,
    temperature: asNumber(raw.temperature) ?? null,
    top_p: asNumber(raw.top_p) ?? null,
    top_k: asNumber(raw.top_k) ?? null,
    min_p: asNumber(raw.min_p) ?? null,
    has_system_prompt: asBoolean(raw.has_system_prompt),
    enable_thinking: asBoolean(raw.enable_thinking) ?? null,
    preserve_thinking: asBoolean(raw.preserve_thinking) ?? null,
    thinking_budget: asNumber(raw.thinking_budget) ?? null,
    clear_thinking: asBoolean(raw.clear_thinking) ?? null,
    resolved_reasoning_effort: asNullableString(raw.resolved_reasoning_effort),
    glm_clear_thinking: asBoolean(raw.glm_clear_thinking),
    glm_replay_reasoning: asBoolean(raw.glm_replay_reasoning),
    tool_stream: asBoolean(raw.tool_stream),
    tool_choice: decodeRuntimeToolChoice(raw.tool_choice),
    disable_parallel_tool_use: asBoolean(raw.disable_parallel_tool_use),
    response_format: decodeRuntimeResponseFormat(raw.response_format),
    has_output_schema: asBoolean(raw.has_output_schema),
    cache_system_prompt: asBoolean(raw.cache_system_prompt),
    supports_tool_choice_override: asBoolean(raw.supports_tool_choice_override) ?? null,
    supports_structured_output_override: asBoolean(raw.supports_structured_output_override) ?? null,
    has_model_capabilities_override: asBoolean(raw.has_model_capabilities_override),
    keep_alive: asNullableString(raw.keep_alive),
    internal_model_rotation_count: asNumber(raw.internal_model_rotation_count) ?? null,
    num_ctx: asNumber(raw.num_ctx) ?? null,
    seed: asNumber(raw.seed) ?? null,
    has_previous_response_id: asBoolean(raw.has_previous_response_id),
    connect_timeout_s: asNumber(raw.connect_timeout_s) ?? null,
  }
}

function decodeRuntimeProviderBehaviorCapabilities(
  raw: unknown,
): DashboardRuntimeProviderBehaviorCapabilities | null {
  if (!isRecord(raw)) return null
  return {
    supports_inline_tools: asBoolean(raw.supports_inline_tools),
    argv_prompt_preflight: asBoolean(raw.argv_prompt_preflight),
    uses_anthropic_caching: asBoolean(raw.uses_anthropic_caching),
  }
}

function decodeRuntimeDeclaredProviderSpec(raw: unknown): DashboardRuntimeDeclaredProviderSpec | null {
  if (!isRecord(raw)) return null
  return {
    id: asNullableString(raw.id),
    display_name: asNullableString(raw.display_name),
    protocol: asNullableString(raw.protocol),
    api_format: asNullableString(raw.api_format),
    transport: asNullableString(raw.transport),
    auth_kind: asNullableString(raw.auth_kind),
    is_non_interactive: asBoolean(raw.is_non_interactive),
    has_capabilities: asBoolean(raw.has_capabilities),
    behavior_capabilities: decodeRuntimeProviderBehaviorCapabilities(raw.behavior_capabilities),
    custom_header_count: asNumber(raw.custom_header_count) ?? null,
    connect_timeout_s: asNumber(raw.connect_timeout_s) ?? null,
  }
}

function decodeRuntimeDeclaredModelCapabilities(
  raw: unknown,
): DashboardRuntimeDeclaredModelCapabilities | null {
  if (!isRecord(raw)) return null
  return {
    source: asNullableString(raw.source),
    max_output_tokens: asNumber(raw.max_output_tokens) ?? null,
    supports_tool_choice: asBoolean(raw.supports_tool_choice),
    supports_required_tool_choice: asBoolean(raw.supports_required_tool_choice),
    supports_named_tool_choice: asBoolean(raw.supports_named_tool_choice),
    supports_parallel_tool_calls: asBoolean(raw.supports_parallel_tool_calls),
    supports_extended_thinking: asBoolean(raw.supports_extended_thinking),
    supports_reasoning_budget: asBoolean(raw.supports_reasoning_budget),
    thinking_control_format: asNullableString(raw.thinking_control_format),
    supports_image_input: asBoolean(raw.supports_image_input),
    supports_audio_input: asBoolean(raw.supports_audio_input),
    supports_video_input: asBoolean(raw.supports_video_input),
    supports_multimodal_inputs: asBoolean(raw.supports_multimodal_inputs),
    supports_response_format_json: asBoolean(raw.supports_response_format_json),
    supports_structured_output: asBoolean(raw.supports_structured_output),
    supports_system_prompt: asBoolean(raw.supports_system_prompt),
    supports_caching: asBoolean(raw.supports_caching),
    supports_prompt_caching: asBoolean(raw.supports_prompt_caching),
    prompt_cache_alignment: asNumber(raw.prompt_cache_alignment) ?? null,
    supports_top_k: asBoolean(raw.supports_top_k),
    supports_min_p: asBoolean(raw.supports_min_p),
    supports_seed: asBoolean(raw.supports_seed),
    supports_seed_with_images: asBoolean(raw.supports_seed_with_images),
    emits_usage_tokens: asBoolean(raw.emits_usage_tokens),
    supports_computer_use: asBoolean(raw.supports_computer_use),
    supports_code_execution: asBoolean(raw.supports_code_execution),
  }
}

function decodeRuntimeDeclaredModelSpec(raw: unknown): DashboardRuntimeDeclaredModelSpec | null {
  if (!isRecord(raw)) return null
  return {
    id: asNullableString(raw.id),
    api_name: asNullableString(raw.api_name),
    tools_support: asBoolean(raw.tools_support),
    max_context: asNumber(raw.max_context) ?? null,
    thinking_support: asBoolean(raw.thinking_support),
    preserve_thinking: asBoolean(raw.preserve_thinking) ?? null,
    max_thinking_budget: asNumber(raw.max_thinking_budget) ?? null,
    streaming: asBoolean(raw.streaming),
    temperature: asNumber(raw.temperature) ?? null,
    top_p: asNumber(raw.top_p) ?? null,
    top_k: asNumber(raw.top_k) ?? null,
    min_p: asNumber(raw.min_p) ?? null,
    capabilities: decodeRuntimeDeclaredModelCapabilities(raw.capabilities),
  }
}

function decodeRuntimeDeclaredBindingSpec(raw: unknown): DashboardRuntimeDeclaredBindingSpec | null {
  if (!isRecord(raw)) return null
  return {
    provider_id: asNullableString(raw.provider_id),
    model_id: asNullableString(raw.model_id),
    is_default: asBoolean(raw.is_default),
    max_concurrent: asNumber(raw.max_concurrent) ?? null,
    price_input: asNumber(raw.price_input) ?? null,
    price_output: asNumber(raw.price_output) ?? null,
    keep_alive: asNullableString(raw.keep_alive),
    num_ctx: asNumber(raw.num_ctx) ?? null,
  }
}

function decodeRuntimeDeclaredSpec(raw: unknown): DashboardRuntimeDeclaredSpec | null {
  if (!isRecord(raw)) return null
  return {
    source: asNullableString(raw.source),
    provider: decodeRuntimeDeclaredProviderSpec(raw.provider),
    model: decodeRuntimeDeclaredModelSpec(raw.model),
    binding: decodeRuntimeDeclaredBindingSpec(raw.binding),
  }
}

function decodeNullableStringArray(raw: unknown): string[] | null {
  return Array.isArray(raw) ? asStringArray(raw) : null
}

function decodeRuntimeReasoningStreamingFormat(
  raw: unknown,
): DashboardRuntimeReasoningStreamingFormat | null {
  if (!isRecord(raw)) return null
  return {
    kind: asNullableString(raw.kind),
    field: asNullableString(raw.field),
  }
}

function decodeRuntimeEffectiveCapabilities(raw: unknown): DashboardRuntimeEffectiveCapabilities | null {
  if (!isRecord(raw)) return null
  return {
    source: asNullableString(raw.source),
    max_context_tokens: asNumber(raw.max_context_tokens) ?? null,
    max_output_tokens: asNumber(raw.max_output_tokens) ?? null,
    supports_tools: asBoolean(raw.supports_tools),
    supports_tool_choice: asBoolean(raw.supports_tool_choice),
    supports_required_tool_choice: asBoolean(raw.supports_required_tool_choice),
    supports_named_tool_choice: asBoolean(raw.supports_named_tool_choice),
    supports_parallel_tool_calls: asBoolean(raw.supports_parallel_tool_calls),
    supports_runtime_mcp_tools: asBoolean(raw.supports_runtime_mcp_tools),
    supports_runtime_tool_events: asBoolean(raw.supports_runtime_tool_events),
    assistant_tool_content_format: asNullableString(raw.assistant_tool_content_format),
    supports_reasoning: asBoolean(raw.supports_reasoning),
    supports_extended_thinking: asBoolean(raw.supports_extended_thinking),
    supports_reasoning_budget: asBoolean(raw.supports_reasoning_budget),
    accepted_reasoning_efforts: decodeNullableStringArray(raw.accepted_reasoning_efforts),
    // Keep the server-projected wire opaque. The OCaml/Agent Core capability enum is
    // the SSOT; duplicating its variants here would drift on the next catalog
    // release and turn a received value into a false "missing" state.
    thinking_control_format: asNullableString(raw.thinking_control_format),
    preserve_thinking_control_format: asNullableString(raw.preserve_thinking_control_format),
    reasoning_output_format: asNullableString(raw.reasoning_output_format),
    reasoning_streaming_format: decodeRuntimeReasoningStreamingFormat(raw.reasoning_streaming_format),
    reasoning_replay_override: asNullableString(raw.reasoning_replay_override),
    supports_response_format_json: asBoolean(raw.supports_response_format_json),
    supports_structured_output: asBoolean(raw.supports_structured_output),
    supports_multimodal_inputs: asBoolean(raw.supports_multimodal_inputs),
    supports_image_input: asBoolean(raw.supports_image_input),
    supports_audio_input: asBoolean(raw.supports_audio_input),
    supports_video_input: asBoolean(raw.supports_video_input),
    modality_priority: asNullableString(raw.modality_priority),
    task: asNullableString(raw.task),
    supports_native_streaming: asBoolean(raw.supports_native_streaming),
    supports_system_prompt: asBoolean(raw.supports_system_prompt),
    supports_caching: asBoolean(raw.supports_caching),
    supports_prompt_caching: asBoolean(raw.supports_prompt_caching),
    prompt_cache_alignment: asNumber(raw.prompt_cache_alignment) ?? null,
    supports_top_k: asBoolean(raw.supports_top_k),
    supports_min_p: asBoolean(raw.supports_min_p),
    supports_seed: asBoolean(raw.supports_seed),
    supports_seed_with_images: asBoolean(raw.supports_seed_with_images),
    ignored_sampling_parameters: asStringArray(raw.ignored_sampling_parameters),
    supports_computer_use: asBoolean(raw.supports_computer_use),
    supports_code_execution: asBoolean(raw.supports_code_execution),
    emits_usage_tokens: asBoolean(raw.emits_usage_tokens),
    supported_models: decodeNullableStringArray(raw.supported_models),
  }
}

function decodeRuntimeProviderSnapshot(raw: unknown): DashboardRuntimeProviderSnapshot | null {
  if (!isRecord(raw)) return null
  const provider = asString(raw.provider)
  if (!provider) return null
  return {
    provider,
    runtime_id: asNullableString(raw.runtime_id),
    provider_id: asNullableString(raw.provider_id),
    provider_display_name: asNullableString(raw.provider_display_name),
    model_id: asNullableString(raw.model_id),
    model_api_name: asNullableString(raw.model_api_name),
    protocol: asNullableString(raw.protocol),
    transport: asNullableString(raw.transport),
    kind: asNullableString(raw.kind),
    runtime_kind: asNullableString(raw.runtime_kind),
    auth_kind: asNullableString(raw.auth_kind),
    status: asNullableString(raw.status),
    available: asBoolean(raw.available),
    is_default_runtime: asBoolean(raw.is_default_runtime),
    max_context: asNumber(raw.max_context) ?? null,
    tools_support: asBoolean(raw.tools_support),
    thinking_support: asBoolean(raw.thinking_support),
    streaming: asBoolean(raw.streaming),
    temperature: asNumber(raw.temperature) ?? null,
    top_p: asNumber(raw.top_p) ?? null,
    top_k: asNumber(raw.top_k) ?? null,
    min_p: asNumber(raw.min_p) ?? null,
    capabilities_declared: asBoolean(raw.capabilities_declared),
    max_output_tokens: asNumber(raw.max_output_tokens) ?? null,
    supports_tool_choice: asBoolean(raw.supports_tool_choice),
    supports_required_tool_choice: asBoolean(raw.supports_required_tool_choice),
    supports_named_tool_choice: asBoolean(raw.supports_named_tool_choice),
    supports_parallel_tool_calls: asBoolean(raw.supports_parallel_tool_calls),
    supports_extended_thinking: asBoolean(raw.supports_extended_thinking),
    supports_multimodal_inputs: asBoolean(raw.supports_multimodal_inputs),
    supports_image_input: asBoolean(raw.supports_image_input),
    supports_audio_input: asBoolean(raw.supports_audio_input),
    supports_video_input: asBoolean(raw.supports_video_input),
    supports_reasoning_budget: asBoolean(raw.supports_reasoning_budget),
    thinking_control_format: asNullableString(raw.thinking_control_format),
    supports_response_format_json: asBoolean(raw.supports_response_format_json),
    supports_structured_output: asBoolean(raw.supports_structured_output),
    supports_system_prompt: asBoolean(raw.supports_system_prompt),
    supports_caching: asBoolean(raw.supports_caching),
    supports_prompt_caching: asBoolean(raw.supports_prompt_caching),
    prompt_cache_alignment: asNumber(raw.prompt_cache_alignment) ?? null,
    supports_top_k: asBoolean(raw.supports_top_k),
    supports_min_p: asBoolean(raw.supports_min_p),
    supports_seed: asBoolean(raw.supports_seed),
    supports_seed_with_images: asBoolean(raw.supports_seed_with_images),
    emits_usage_tokens: asBoolean(raw.emits_usage_tokens),
    supports_computer_use: asBoolean(raw.supports_computer_use),
    supports_code_execution: asBoolean(raw.supports_code_execution),
    effective_capabilities: decodeRuntimeEffectiveCapabilities(raw.effective_capabilities),
    parameter_policy: decodeRuntimeParameterPolicy(raw.parameter_policy),
    request_config: decodeRuntimeRequestConfig(raw.request_config),
    declared_spec: decodeRuntimeDeclaredSpec(raw.declared_spec),
    model_count: asNumber(raw.model_count) ?? null,
    models: asStringArray(raw.models),
    source: asNullableString(raw.source),
    endpoint_url: asNullableString(raw.endpoint_url),
    note: asNullableString(raw.note),
  }
}

function decodeRuntimeAssignment(raw: unknown): DashboardRuntimeAssignment | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const runtimeId = asString(raw.runtime_id)
  if (!keeper || !runtimeId) return null
  return {
    keeper,
    runtime_id: runtimeId,
    matches_default: asBoolean(raw.matches_default),
  }
}

function decodeRuntimeAssignmentStatus(raw: unknown): DashboardRuntimeAssignmentStatus | null {
  if (!isRecord(raw)) return null
  return {
    schema: asNullableString(raw.schema),
    source: asNullableString(raw.source),
    status: asNullableString(raw.status),
    degraded: asBoolean(raw.degraded) ?? false,
    operator_action_required: asBoolean(raw.operator_action_required) ?? false,
    blast_radius: asNullableString(raw.blast_radius),
    assignment_count: asNumber(raw.assignment_count) ?? 0,
    assigned_runtime_count: asNumber(raw.assigned_runtime_count) ?? 0,
    default_assignment_count: asNumber(raw.default_assignment_count) ?? 0,
    default_runtime_id: asNullableString(raw.default_runtime_id),
    warnings: asStringArray(raw.warnings),
    assigned_runtimes: asStringArray(raw.assigned_runtimes),
    assignments: asRecordArray(raw.assignments)
      .map(decodeRuntimeAssignment)
      .filter((item): item is DashboardRuntimeAssignment => item !== null),
  }
}

function decodeRuntimeStartupMissingCatalogModel(raw: unknown): DashboardRuntimeStartupMissingCatalogModel | null {
  if (!isRecord(raw)) return null
  const runtimeId = asString(raw.runtime_id)
  if (!runtimeId) return null
  return {
    runtime_id: runtimeId,
    provider_id: asNullableString(raw.provider_id),
    provider_label: asNullableString(raw.provider_label),
    model_id: asNullableString(raw.model_id),
  }
}

function decodeRuntimeStartupDroppedAssignment(raw: unknown): DashboardRuntimeStartupDroppedAssignment | null {
  if (!isRecord(raw)) return null
  const keeperName = asString(raw.keeper_name)
  const runtimeId = asString(raw.runtime_id)
  if (!keeperName || !runtimeId) return null
  return {
    keeper_name: keeperName,
    runtime_id: runtimeId,
  }
}

function decodeRuntimeStartupDroppedRoute(raw: unknown): DashboardRuntimeStartupDroppedRoute | null {
  if (!isRecord(raw)) return null
  const routeName = asString(raw.route_name)
  const runtimeId = asString(raw.runtime_id)
  if (!routeName || !runtimeId) return null
  return {
    route_name: routeName,
    runtime_id: runtimeId,
  }
}

function decodeRuntimeStartupDroppedLane(raw: unknown): DashboardRuntimeStartupDroppedLane | null {
  if (!isRecord(raw)) return null
  const laneId = asString(raw.lane_id)
  if (!laneId) return null
  return {
    lane_id: laneId,
    runtime_ids: asStringArray(raw.runtime_ids),
  }
}

function decodeRuntimeStartupDegradation(raw: unknown): DashboardRuntimeStartupDegradation | null {
  if (!isRecord(raw)) return null
  return {
    schema: asNullableString(raw.schema),
    status: asNullableString(raw.status),
    degraded: asBoolean(raw.degraded) ?? false,
    operator_action_required: asBoolean(raw.operator_action_required) ?? false,
    terminal_reason: asNullableString(raw.terminal_reason),
    message: asNullableString(raw.message),
    config_path: asNullableString(raw.config_path),
    configured_default_runtime_id: asNullableString(raw.configured_default_runtime_id),
    effective_default_runtime_id: asNullableString(raw.effective_default_runtime_id),
    missing_catalog_model_count: asNumber(raw.missing_catalog_model_count) ?? 0,
    missing_catalog_models: asRecordArray(raw.missing_catalog_models)
      .map(decodeRuntimeStartupMissingCatalogModel)
      .filter((item): item is DashboardRuntimeStartupMissingCatalogModel => item !== null),
    disabled_runtime_ids: asStringArray(raw.disabled_runtime_ids),
    dropped_assignments: asRecordArray(raw.dropped_assignments)
      .map(decodeRuntimeStartupDroppedAssignment)
      .filter((item): item is DashboardRuntimeStartupDroppedAssignment => item !== null),
    dropped_routes: asRecordArray(raw.dropped_routes)
      .map(decodeRuntimeStartupDroppedRoute)
      .filter((item): item is DashboardRuntimeStartupDroppedRoute => item !== null),
    dropped_media_failover: asStringArray(raw.dropped_media_failover),
    dropped_lane_candidates: asRecordArray(raw.dropped_lane_candidates)
      .map(decodeRuntimeStartupDroppedLane)
      .filter((item): item is DashboardRuntimeStartupDroppedLane => item !== null),
    dropped_lanes: asRecordArray(raw.dropped_lanes)
      .map(decodeRuntimeStartupDroppedLane)
      .filter((item): item is DashboardRuntimeStartupDroppedLane => item !== null),
    next_action: asNullableString(raw.next_action),
  }
}

function decodeRuntimeProvidersResponse(raw: unknown): DashboardRuntimeProvidersResponse | null {
  if (!isRecord(raw)) return null
  const summary = isRecord(raw.summary) ? raw.summary : null
  return {
    updated_at: asString(raw.updated_at),
    summary: summary
      ? {
          providers: asNumber(summary.providers),
          runtimes: asNumber(summary.runtimes),
          local_models: asNumber(summary.local_models),
          cloud_models: asNumber(summary.cloud_models),
          cli_models: asNumber(summary.cli_models),
          default_runtime_id: asNullableString(summary.default_runtime_id),
        }
      : null,
    providers: asRecordArray(raw.providers)
      .map(decodeRuntimeProviderSnapshot)
      .filter((provider): provider is DashboardRuntimeProviderSnapshot => provider !== null),
    assignment_status: decodeRuntimeAssignmentStatus(raw.assignment_status),
    startup_degradation: decodeRuntimeStartupDegradation(raw.startup_degradation),
    config_path: asNullableString(raw.config_path),
  }
}

function decodeRuntimeModelMetric(raw: unknown): DashboardRuntimeModelMetric | null {
  if (!isRecord(raw)) return null
  const modelId = asString(raw.model_id)
  if (!modelId) return null
  return {
    model_id: modelId,
    provider: null,
    entry_count: asNumber(raw.entry_count) ?? null,
    avg_tok_per_sec: asNumber(raw.avg_tok_per_sec) ?? null,
    p50_tok_per_sec: asNumber(raw.p50_tok_per_sec) ?? null,
    p95_tok_per_sec: asNumber(raw.p95_tok_per_sec) ?? null,
    prompt_avg_tok_per_sec: asNumber(raw.prompt_avg_tok_per_sec) ?? null,
    prompt_p50_tok_per_sec: asNumber(raw.prompt_p50_tok_per_sec) ?? null,
    prompt_p95_tok_per_sec: asNumber(raw.prompt_p95_tok_per_sec) ?? null,
    hw_decode_avg_tok_per_sec: asNumber(raw.hw_decode_avg_tok_per_sec) ?? null,
    hw_decode_p50_tok_per_sec: asNumber(raw.hw_decode_p50_tok_per_sec) ?? null,
    hw_decode_p95_tok_per_sec: asNumber(raw.hw_decode_p95_tok_per_sec) ?? null,
    max_peak_memory_gb: asNumber(raw.max_peak_memory_gb) ?? null,
    thinking_fraction: asNumber(raw.thinking_fraction) ?? null,
    avg_latency_ms: asNumber(raw.avg_latency_ms) ?? null,
    p50_latency_ms: asNumber(raw.p50_latency_ms) ?? null,
    p95_latency_ms: asNumber(raw.p95_latency_ms) ?? null,
    total_input_tokens: asNumber(raw.total_input_tokens) ?? null,
    total_output_tokens: asNumber(raw.total_output_tokens) ?? null,
    total_cache_read_tokens: asNumber(raw.total_cache_read_tokens) ?? null,
    total_cache_creation_tokens: asNumber(raw.total_cache_creation_tokens) ?? null,
    total_reasoning_tokens: asNumber(raw.total_reasoning_tokens) ?? null,
    usage_sample_count: asNumber(raw.usage_sample_count) ?? null,
    telemetry_sample_count: asNumber(raw.telemetry_sample_count) ?? null,
    usage_missing_count: asNumber(raw.usage_missing_count) ?? null,
    telemetry_missing_count: asNumber(raw.telemetry_missing_count) ?? null,
    coverage_status: asNullableString(raw.coverage_status) as DashboardRuntimeModelMetric['coverage_status'],
    primary_coverage_stage: asNullableString(raw.primary_coverage_stage),
    primary_coverage_reason: asNullableString(raw.primary_coverage_reason),
    coverage_reason_counts: Array.isArray(raw.coverage_reason_counts)
      ? (raw.coverage_reason_counts as unknown[])
          .filter(isRecord)
          .map(item => ({ reason: asString(item.reason) ?? '', count: asNumber(item.count) ?? 0 }))
          .filter(item => item.reason.length > 0)
      : null,
    success_count: asNumber(raw.success_count) ?? null,
    error_count: asNumber(raw.error_count) ?? null,
    total_cost_usd: asNumber(raw.total_cost_usd) ?? null,
    avg_tool_calls_per_turn: asNumber(raw.avg_tool_calls_per_turn) ?? null,
    total_tool_calls: asNumber(raw.total_tool_calls) ?? null,
    top_tools: Array.isArray(raw.top_tools)
      ? (raw.top_tools as unknown[])
          .filter(isRecord)
          .map(t => ({ tool: asString(t.tool) ?? '', count: asNumber(t.count) ?? 0 }))
          .filter(t => t.tool.length > 0)
      : null,
    recent_entries: Array.isArray(raw.recent_entries)
      ? (raw.recent_entries as unknown[])
          .filter(isRecord)
          .map(r => ({
            ts_unix: asNumber(r.ts_unix) ?? 0,
            outcome: asNullableString(r.outcome),
            stop_reason: asNullableString(r.stop_reason),
            turn_lane: asNullableString(r.turn_lane),
            input_tokens: asNumber(r.input_tokens) ?? null,
            output_tokens: asNumber(r.output_tokens) ?? null,
            cache_read_tokens: asNumber(r.cache_read_tokens) ?? null,
            cache_creation_tokens: asNumber(r.cache_creation_tokens) ?? null,
            latency_ms: asNumber(r.latency_ms) ?? null,
            prompt_tok_per_sec: asNumber(r.prompt_tok_per_sec) ?? null,
            peak_memory_gb: asNumber(r.peak_memory_gb) ?? null,
            cost_usd: asNumber(r.cost_usd) ?? null,
            tools_count: asNumber(r.tools_count) ?? 0,
            usage_reported: asBoolean(r.usage_reported),
            telemetry_reported: asBoolean(r.telemetry_reported),
            usage_trust: asNullableString(r.usage_trust),
            usage_anomaly_reasons: Array.isArray(r.usage_anomaly_reasons)
              ? (r.usage_anomaly_reasons as unknown[])
                  .map(item => asString(item) ?? '')
                  .filter(item => item.length > 0)
              : null,
            coverage_reason: asNullableString(r.coverage_reason),
            coverage_stage: asNullableString(r.coverage_stage),
            streaming_ttfrc_ms: asNumber(r.streaming_ttfrc_ms) ?? null,
            streaming_inter_chunk_count: asNumber(r.streaming_inter_chunk_count) ?? null,
            streaming_inter_chunk_avg_ms: asNumber(r.streaming_inter_chunk_avg_ms) ?? null,
          }))
      : null,
    buckets: Array.isArray(raw.buckets)
      ? (raw.buckets as unknown[])
          .filter(isRecord)
          .map(b => ({
            ts_start: asNumber(b.ts_start) ?? 0,
            entry_count: asNumber(b.entry_count) ?? 0,
            success_count: asNumber(b.success_count) ?? 0,
            error_count: asNumber(b.error_count) ?? 0,
            p50_latency_ms: asNumber(b.p50_latency_ms) ?? null,
            p95_latency_ms: asNumber(b.p95_latency_ms) ?? null,
            error_rate: asNumber(b.error_rate) ?? 0,
            total_cost_usd: asNumber(b.total_cost_usd) ?? null,
            cache_hit_ratio: asNumber(b.cache_hit_ratio) ?? null,
          }))
      : null,
  }
}

function decodeRuntimeModelMetricsResponse(raw: unknown): DashboardRuntimeModelMetricsResponse | null {
  if (!isRecord(raw)) return null
  return {
    window_minutes: asNumber(raw.window_minutes),
    bucket_minutes: asNumber(raw.bucket_minutes),
    total_entries: asNumber(raw.total_entries),
    total_error_entries: asNumber(raw.total_error_entries),
    latency_buckets: Array.isArray(raw.latency_buckets)
      ? (raw.latency_buckets as unknown[])
          .filter(isRecord)
          .map(b => ({
            lo_ms: asNumber(b.lo) ?? 0,
            hi_ms: b.hi == null ? null : (asNumber(b.hi) ?? null),
            count: asNumber(b.n) ?? 0,
          }))
      : null,
    models: asRecordArray(raw.models)
      .map(metric => decodeRuntimeModelMetric(metric))
      .filter((metric): metric is DashboardRuntimeModelMetric => metric !== null),
  }
}

export async function fetchRuntimeProviders(opts?: AbortableRequestOptions): Promise<DashboardRuntimeProvidersResponse> {
  const raw = await get<Record<string, unknown>>('/api/v1/providers', { signal: opts?.signal })
  const decoded = decodeRuntimeProvidersResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 runtime lanes payload')
  return decoded
}

export async function fetchRuntimeModelMetrics(
  windowMinutes = 30,
  bucketMinutes = 5,
  opts?: AbortableRequestOptions,
): Promise<DashboardRuntimeModelMetricsResponse> {
  const bParam = bucketMinutes > 0 ? `&bucket_min=${bucketMinutes}` : ''
  const raw = await get<Record<string, unknown>>(`/api/v1/models/metrics?window=${windowMinutes}${bParam}`, { signal: opts?.signal })
  const decoded = decodeRuntimeModelMetricsResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 runtime model metrics payload')
  return decoded
}

// --- Runtime config (raw runtime.toml editor) ---

export interface RuntimeTomlConfig {
  ok: boolean
  path: string | null
  file_name: string
  source_text: string
  provider_protocols: RuntimeTomlEditorProtocol[]
  application?: RuntimeConfigApplication
  validation?: RuntimeConfigValidation
  keeper_setting_schema?: unknown
  keeper_settings?: RuntimeKeeperSetting[]
  message?: string | null
  reason?: string | null
  issues?: unknown
}

export interface RuntimeConfigApplicationLane {
  status: string
  requires_restart: boolean
  applied_at: string | number | null
}

export interface RuntimeConfigKeeperOverlayApplication extends RuntimeConfigApplicationLane {
  configured_count: number
  pending_keys: string[]
  applied_keys: string[]
  preempted_keys: string[]
}

export interface RuntimeConfigApplication {
  operation: string
  routing: RuntimeConfigApplicationLane
  keeper_overlay: RuntimeConfigKeeperOverlayApplication
}

export interface RuntimeConfigValidationIssue {
  key: string
  kind: string
  severity: 'error' | 'warning'
  detail: string
}

export interface RuntimeConfigValidation {
  valid: boolean
  schema_version: number
  current_schema_version: number
  forward_schema: boolean
  issues: RuntimeConfigValidationIssue[]
}

export interface RuntimeKeeperSetting {
  key: string | null
  env: string
  configured_value: string | null
  source: string
  effective_value: string | null
  effective_error: string | null
  applied_at: number | null
  reload_class: string
  requires_restart: boolean
  application_status: string
  consumers: string[]
}

export interface RuntimeConfigPreview {
  ok: boolean
  can_save: boolean
  validation: RuntimeConfigValidation
  keeper_setting_schema?: unknown
}

export type RuntimeTomlEditorTransport = 'endpoint' | 'command'
export type RuntimeTomlEditorSemantics = 'http_provider' | 'official_client'
export type RuntimeTomlEditorCredentialPolicy = 'optional' | 'forbidden' | 'file_required'

export interface RuntimeTomlEditorProtocol {
  protocol: string
  transport: RuntimeTomlEditorTransport
  semantics: RuntimeTomlEditorSemantics
  credential_policy: RuntimeTomlEditorCredentialPolicy
  requires_non_interactive: boolean
  provider_fields: string[]
  required_provider_fields: string[]
}

const RUNTIME_TOML_EDITOR_PROTOCOL_KEYS = [
  'credential_policy',
  'protocol',
  'provider_fields',
  'required_provider_fields',
  'requires_non_interactive',
  'semantics',
  'transport',
] as const

function parseRuntimeTomlEditorProtocols(raw: unknown): RuntimeTomlEditorProtocol[] {
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new Error('유효하지 않은 runtime provider protocol inventory')
  }
  const seen = new Set<string>()
  return raw.map((entry) => {
    if (!isRecord(entry)) throw new Error('유효하지 않은 runtime provider protocol entry')
    const keys = Object.keys(entry).sort()
    if (
      keys.length !== RUNTIME_TOML_EDITOR_PROTOCOL_KEYS.length
      || keys.some((key, index) => key !== RUNTIME_TOML_EDITOR_PROTOCOL_KEYS[index])
    ) {
      throw new Error('유효하지 않은 runtime provider protocol fields')
    }
    const protocol = entry.protocol
    const transport = entry.transport
    const semantics = entry.semantics
    const credentialPolicy = entry.credential_policy
    const requiresNonInteractive = entry.requires_non_interactive
    const providerFields = entry.provider_fields
    const requiredProviderFields = entry.required_provider_fields
    if (
      typeof protocol !== 'string'
      || protocol === ''
      || protocol.trim() !== protocol
      || (transport !== 'endpoint' && transport !== 'command')
      || (semantics !== 'http_provider' && semantics !== 'official_client')
      || (credentialPolicy !== 'optional'
        && credentialPolicy !== 'forbidden'
        && credentialPolicy !== 'file_required')
      || typeof requiresNonInteractive !== 'boolean'
      || !Array.isArray(providerFields)
      || providerFields.some(field => typeof field !== 'string' || field === '')
      || !Array.isArray(requiredProviderFields)
      || requiredProviderFields.some(field => typeof field !== 'string' || !providerFields.includes(field))
      || seen.has(protocol)
    ) {
      throw new Error('유효하지 않은 runtime provider protocol contract')
    }
    if (
      (semantics === 'official_client'
        && (transport !== 'command' || credentialPolicy === 'optional' || !requiresNonInteractive))
      || (semantics === 'http_provider'
        && (transport !== 'endpoint'
          || credentialPolicy !== 'optional'
          || requiresNonInteractive
          || providerFields.length > 0))
    ) {
      throw new Error('일관되지 않은 runtime provider protocol contract')
    }
    seen.add(protocol)
    return {
      protocol,
      transport,
      semantics,
      credential_policy: credentialPolicy,
      requires_non_interactive: requiresNonInteractive,
      provider_fields: [...providerFields],
      required_provider_fields: [...requiredProviderFields],
    }
  })
}

export type DashboardOfficialClientRecoveryFailure =
  | 'transient_spawn_failed'
  | 'transport_interrupted'
  | 'protocol_failed'
  | 'provider_rejected'
  | 'host_hook_failed'
  | 'state_persistence_failed'
  | 'process_restarted'

export type DashboardOfficialClientKind = 'codex' | 'claude_code' | 'antigravity'

export interface DashboardOfficialClientSettlement {
  session_id: string
  turn_id: string
}

export type DashboardOfficialClientSessionPhase =
  | { kind: 'ready' }
  | {
      kind: 'start'
      owner_epoch: string
      previous_settlement: DashboardOfficialClientSettlement | null
    }
  | {
      kind: 'active'
      owner_epoch: string
      session_id: string
      previous_settlement: DashboardOfficialClientSettlement | null
    }
  | {
      kind: 'turn_inflight'
      owner_epoch: string
      session_id: string
      turn_id: string | null
      previous_settlement: DashboardOfficialClientSettlement | null
    }
  | {
      kind: 'recovery_required'
      recovery_id: string
      failure: DashboardOfficialClientRecoveryFailure
      detail: string
      required_at: number
      owner_epoch: string
      observed_session_id: string | null
      observed_turn_id: string | null
      previous_settlement: DashboardOfficialClientSettlement | null
    }
  | {
      kind: 'settled'
      session_id: string
      turn_id: string
    }

export interface DashboardOfficialClientRecoveryResolutionRecord {
  recovery_id: string
  failure: DashboardOfficialClientRecoveryFailure
  resolution: { kind: 'retry_previous' | 'restart_fresh' }
  resolved_by: string
  resolved_at: number
}

export interface DashboardOfficialClientTransientReleaseRecord {
  failure: 'transient_spawn_failed'
  owner_epoch: string
  released_at: number
}

export interface DashboardOfficialClientSession {
  client_kind: DashboardOfficialClientKind
  runtime_id: string
  phase: DashboardOfficialClientSessionPhase
  turn_count: number
  tool_surface_sha256: string
  last_recovery_resolution: DashboardOfficialClientRecoveryResolutionRecord | null
  last_transient_release: DashboardOfficialClientTransientReleaseRecord | null
  updated_at: number
}

export interface DashboardOfficialClientSessionResponse {
  schema: 'masc.dashboard.official-client-session.v1'
  ok: true
  keeper_name: string
  session: DashboardOfficialClientSession | null
}

export type DashboardOfficialClientRecoveryApplication = 'applied' | 'replayed'

export type DashboardOfficialClientAuditReceipt =
  | { recorded: true }
  | { recorded: false; error: string }

export interface DashboardOfficialClientRecoveryResponse
  extends DashboardOfficialClientSessionResponse {
  resolution_application: DashboardOfficialClientRecoveryApplication
  audit: DashboardOfficialClientAuditReceipt
}

export type DashboardOfficialClientRecoveryDecision =
  | { resolution: 'retry_previous' }
  | { resolution: 'restart_fresh' }

export type DashboardOfficialClientLoginStatus =
  | 'ready'
  | 'invalid_config'
  | 'cli_unavailable'
  | 'login_required'
  | 'timeout'
  | 'protocol_error'
  | 'probe_contract_error'

export interface DashboardOfficialClientProbeResponse {
  schema: 'masc.dashboard.official-client-probe.v1'
  ok: true
  runtime_id: string
  client_kind: 'codex' | 'claude_code'
  configured_model: string | null
  measured_at: number
  login: {
    status: DashboardOfficialClientLoginStatus
    authenticated: boolean
    evidence_source: 'configured_executable_self_report'
    identity_verified: false
    auth_method: string | null
    subscription_type: string | null
    api_provider: string | null
    detail: string | null
  }
  client: {
    user_agent: string | null
  }
  execution: {
    status: 'not_measured'
    reason: 'login_probe_does_not_submit_model_turn'
  }
}

const OFFICIAL_CLIENT_RECOVERY_FAILURES = new Set<DashboardOfficialClientRecoveryFailure>([
  'transient_spawn_failed',
  'transport_interrupted',
  'protocol_failed',
  'provider_rejected',
  'host_hook_failed',
  'state_persistence_failed',
  'process_restarted',
])

const OFFICIAL_CLIENT_KINDS = new Set<DashboardOfficialClientKind>([
  'codex',
  'claude_code',
  'antigravity',
])

const OFFICIAL_CLIENT_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const OFFICIAL_CLIENT_SHA256 = /^[0-9a-f]{64}$/

function hasExactKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(raw)
  return keys.length === allowed.length && keys.every(key => allowed.includes(key))
}

function decodeOfficialClientUuid(raw: unknown): string | null {
  return typeof raw === 'string' && OFFICIAL_CLIENT_UUID.test(raw) ? raw : null
}

function decodeOfficialClientNonEmptyString(raw: unknown): string | null {
  return typeof raw === 'string' && raw.trim() !== '' ? raw : null
}

function decodeOfficialClientNullableString(raw: unknown): string | null | undefined {
  if (raw === null) return null
  return decodeOfficialClientNonEmptyString(raw) ?? undefined
}

const OFFICIAL_CLIENT_LOGIN_STATUSES = new Set<DashboardOfficialClientLoginStatus>([
  'ready',
  'invalid_config',
  'cli_unavailable',
  'login_required',
  'timeout',
  'protocol_error',
  'probe_contract_error',
])

function decodeOfficialClientSettlement(raw: unknown): DashboardOfficialClientSettlement | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['session_id', 'turn_id'])) return null
  const session_id = decodeOfficialClientNonEmptyString(raw.session_id)
  const turn_id = decodeOfficialClientNonEmptyString(raw.turn_id)
  return session_id && turn_id ? { session_id, turn_id } : null
}

function decodeOfficialClientNullableSettlement(
  raw: unknown,
): DashboardOfficialClientSettlement | null | undefined {
  if (raw === null) return null
  return decodeOfficialClientSettlement(raw) ?? undefined
}

function decodeOfficialClientFailure(raw: unknown): DashboardOfficialClientRecoveryFailure | null {
  return typeof raw === 'string' && OFFICIAL_CLIENT_RECOVERY_FAILURES.has(raw as DashboardOfficialClientRecoveryFailure)
    ? raw as DashboardOfficialClientRecoveryFailure
    : null
}

function decodeOfficialClientPhase(raw: unknown): DashboardOfficialClientSessionPhase | null {
  if (!isRecord(raw)) return null
  switch (raw.kind) {
    case 'ready':
      return hasExactKeys(raw, ['kind']) ? { kind: 'ready' } : null
    case 'start': {
      if (!hasExactKeys(raw, ['kind', 'owner_epoch', 'previous_settlement'])) return null
      const owner_epoch = decodeOfficialClientUuid(raw.owner_epoch)
      const previous_settlement = decodeOfficialClientNullableSettlement(raw.previous_settlement)
      return owner_epoch && previous_settlement !== undefined
        ? { kind: 'start', owner_epoch, previous_settlement }
        : null
    }
    case 'active': {
      if (!hasExactKeys(raw, ['kind', 'owner_epoch', 'session_id', 'previous_settlement'])) return null
      const owner_epoch = decodeOfficialClientUuid(raw.owner_epoch)
      const session_id = decodeOfficialClientNonEmptyString(raw.session_id)
      const previous_settlement = decodeOfficialClientNullableSettlement(raw.previous_settlement)
      return owner_epoch && session_id && previous_settlement !== undefined
        ? { kind: 'active', owner_epoch, session_id, previous_settlement }
        : null
    }
    case 'turn_inflight': {
      if (!hasExactKeys(raw, ['kind', 'owner_epoch', 'session_id', 'turn_id', 'previous_settlement'])) return null
      const owner_epoch = decodeOfficialClientUuid(raw.owner_epoch)
      const session_id = decodeOfficialClientNonEmptyString(raw.session_id)
      const turn_id = decodeOfficialClientNullableString(raw.turn_id)
      const previous_settlement = decodeOfficialClientNullableSettlement(raw.previous_settlement)
      return owner_epoch && session_id && turn_id !== undefined && previous_settlement !== undefined
        ? { kind: 'turn_inflight', owner_epoch, session_id, turn_id, previous_settlement }
        : null
    }
    case 'recovery_required': {
      if (!hasExactKeys(raw, [
        'kind',
        'recovery_id',
        'failure',
        'detail',
        'required_at',
        'owner_epoch',
        'observed_session_id',
        'observed_turn_id',
        'previous_settlement',
      ])) return null
      const recovery_id = decodeOfficialClientUuid(raw.recovery_id)
      const failure = decodeOfficialClientFailure(raw.failure)
      const detail = decodeOfficialClientNonEmptyString(raw.detail)
      const required_at = asNumber(raw.required_at)
      const owner_epoch = decodeOfficialClientUuid(raw.owner_epoch)
      const observed_session_id = decodeOfficialClientNullableString(raw.observed_session_id)
      const observed_turn_id = decodeOfficialClientNullableString(raw.observed_turn_id)
      const previous_settlement = decodeOfficialClientNullableSettlement(raw.previous_settlement)
      if (
        !recovery_id
        || !failure
        || !detail
        || required_at == null
        || !owner_epoch
        || observed_session_id === undefined
        || observed_turn_id === undefined
        || previous_settlement === undefined
        || (observed_turn_id !== null && observed_session_id === null)
      ) return null
      return {
        kind: 'recovery_required',
        recovery_id,
        failure,
        detail,
        required_at,
        owner_epoch,
        observed_session_id,
        observed_turn_id,
        previous_settlement,
      }
    }
    case 'settled': {
      if (!hasExactKeys(raw, ['kind', 'session_id', 'turn_id'])) return null
      const session_id = decodeOfficialClientNonEmptyString(raw.session_id)
      const turn_id = decodeOfficialClientNonEmptyString(raw.turn_id)
      return session_id && turn_id ? { kind: 'settled', session_id, turn_id } : null
    }
    default:
      return null
  }
}

function decodeOfficialClientTransientRelease(raw: unknown): DashboardOfficialClientTransientReleaseRecord | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ['failure', 'owner_epoch', 'released_at'])) return null
  const failure = typeof raw.failure === 'string' ? raw.failure : null
  const owner_epoch = decodeOfficialClientUuid(raw.owner_epoch)
  const released_at = asNumber(raw.released_at)
  if (failure !== 'transient_spawn_failed' || !owner_epoch || released_at == null) return null
  return { failure, owner_epoch, released_at }
}

function decodeOfficialClientResolutionRecord(raw: unknown): DashboardOfficialClientRecoveryResolutionRecord | null {
  if (
    !isRecord(raw)
    || !hasExactKeys(raw, ['failure', 'recovery_id', 'resolution', 'resolved_at', 'resolved_by'])
    || !isRecord(raw.resolution)
    || !hasExactKeys(raw.resolution, ['kind'])
  ) return null
  const recovery_id = decodeOfficialClientUuid(raw.recovery_id)
  const failure = decodeOfficialClientFailure(raw.failure)
  const resolved_by = decodeOfficialClientNonEmptyString(raw.resolved_by)
  const resolved_at = asNumber(raw.resolved_at)
  const kind = typeof raw.resolution.kind === 'string' ? raw.resolution.kind : null
  if (!recovery_id || !failure || !resolved_by || resolved_at == null) return null
  const resolution = kind === 'retry_previous' || kind === 'restart_fresh'
    ? { kind } as const
    : null
  if (!resolution) return null
  return {
    recovery_id,
    failure,
    resolution,
    resolved_by,
    resolved_at,
  }
}

function decodeOfficialClientSessionResponse(raw: unknown): DashboardOfficialClientSessionResponse | null {
  if (
    !isRecord(raw)
    || !hasExactKeys(raw, ['schema', 'ok', 'keeper_name', 'session'])
    || raw.schema !== 'masc.dashboard.official-client-session.v1'
    || raw.ok !== true
  ) return null
  const keeper_name = decodeOfficialClientNonEmptyString(raw.keeper_name)
  if (!keeper_name) return null
  if (raw.session === null) {
    return { schema: 'masc.dashboard.official-client-session.v1', ok: true, keeper_name, session: null }
  }
  if (
    !isRecord(raw.session)
    || !hasExactKeys(raw.session, [
      'client_kind',
      'runtime_id',
      'phase',
      'turn_count',
      'tool_surface_sha256',
      'last_recovery_resolution',
      'last_transient_release',
      'updated_at',
    ])
  ) return null
  const client_kind = typeof raw.session.client_kind === 'string'
    ? raw.session.client_kind
    : null
  const runtime_id = decodeOfficialClientNonEmptyString(raw.session.runtime_id)
  const phase = decodeOfficialClientPhase(raw.session.phase)
  const turn_count = asNumber(raw.session.turn_count)
  const tool_surface_sha256 = typeof raw.session.tool_surface_sha256 === 'string'
    ? raw.session.tool_surface_sha256
    : null
  const updated_at = asNumber(raw.session.updated_at)
  const last_recovery_resolution = raw.session.last_recovery_resolution === null
    ? null
    : decodeOfficialClientResolutionRecord(raw.session.last_recovery_resolution)
  const last_transient_release = raw.session.last_transient_release === null
    ? null
    : decodeOfficialClientTransientRelease(raw.session.last_transient_release)
  if (
    !client_kind
    || !OFFICIAL_CLIENT_KINDS.has(client_kind as DashboardOfficialClientKind)
    || !runtime_id
    || !phase
    || turn_count == null
    || !Number.isInteger(turn_count)
    || turn_count < 0
    || (turn_count === 0 && phase.kind !== 'ready')
    || !tool_surface_sha256
    || !OFFICIAL_CLIENT_SHA256.test(tool_surface_sha256)
    || updated_at == null
  ) return null
  if (raw.session.last_recovery_resolution !== null && !last_recovery_resolution) return null
  if (raw.session.last_transient_release !== null && !last_transient_release) return null
  return {
    schema: 'masc.dashboard.official-client-session.v1',
    ok: true,
    keeper_name,
    session: {
      client_kind: client_kind as DashboardOfficialClientKind,
      runtime_id,
      phase,
      turn_count,
      tool_surface_sha256,
      last_recovery_resolution,
      last_transient_release,
      updated_at,
    },
  }
}

function decodeOfficialClientAuditReceipt(raw: unknown): DashboardOfficialClientAuditReceipt | null {
  if (!isRecord(raw) || typeof raw.recorded !== 'boolean') return null
  if (raw.recorded) {
    return hasExactKeys(raw, ['recorded']) ? { recorded: true } : null
  }
  if (!hasExactKeys(raw, ['recorded', 'error'])) return null
  const error = decodeOfficialClientNonEmptyString(raw.error)
  return error ? { recorded: false, error } : null
}

function decodeOfficialClientRecoveryResponse(raw: unknown): DashboardOfficialClientRecoveryResponse | null {
  if (
    !isRecord(raw)
    || !hasExactKeys(raw, [
      'schema',
      'ok',
      'keeper_name',
      'session',
      'resolution_application',
      'audit',
    ])
  ) return null
  const session = decodeOfficialClientSessionResponse({
    schema: raw.schema,
    ok: raw.ok,
    keeper_name: raw.keeper_name,
    session: raw.session,
  })
  const resolution_application = raw.resolution_application === 'applied'
    || raw.resolution_application === 'replayed'
    ? raw.resolution_application
    : null
  const audit = decodeOfficialClientAuditReceipt(raw.audit)
  return session && resolution_application && audit
    ? { ...session, resolution_application, audit }
    : null
}

function decodeOfficialClientProbeResponse(raw: unknown): DashboardOfficialClientProbeResponse | null {
  if (
    !isRecord(raw)
    || !hasExactKeys(raw, [
      'schema',
      'ok',
      'runtime_id',
      'client_kind',
      'configured_model',
      'measured_at',
      'login',
      'client',
      'execution',
    ])
    || raw.schema !== 'masc.dashboard.official-client-probe.v1'
    || raw.ok !== true
  ) return null
  if (!isRecord(raw.login) || !isRecord(raw.client) || !isRecord(raw.execution)) return null
  const runtime_id = asString(raw.runtime_id)
  const client_kind = asString(raw.client_kind)
  if (raw.configured_model !== null && !asString(raw.configured_model)) return null
  const configured_model = asNullableString(raw.configured_model)
  const measured_at = asNumber(raw.measured_at)
  const status = asString(raw.login.status)
  const authenticated = asBoolean(raw.login.authenticated)
  const evidenceSource = asString(raw.login.evidence_source)
  const identityVerified = asBoolean(raw.login.identity_verified)
  if (!hasExactKeys(raw.client, ['user_agent'])) return null
  if (raw.client.user_agent !== null && !asString(raw.client.user_agent)) return null
  const user_agent = asNullableString(raw.client.user_agent)
  if (!runtime_id || (client_kind !== 'codex' && client_kind !== 'claude_code')) return null
  if (
    measured_at == null
    || measured_at < 0
    || measured_at > 8_640_000_000_000
    || authenticated == null
    || evidenceSource !== 'configured_executable_self_report'
    || identityVerified !== false
  ) return null
  if (!status || !OFFICIAL_CLIENT_LOGIN_STATUSES.has(status as DashboardOfficialClientLoginStatus)) return null
  if ((status === 'ready') !== authenticated) return null
  const ready = status === 'ready'
  const loginKeys = ready
    ? ['status', 'authenticated', 'evidence_source', 'identity_verified', 'auth_method', 'subscription_type', 'api_provider']
    : ['status', 'authenticated', 'evidence_source', 'identity_verified', 'detail']
  if (!hasExactKeys(raw.login, loginKeys)) return null
  const detail = ready ? null : asString(raw.login.detail) ?? null
  if (!ready && !detail) return null
  if (status === 'ready') {
    if (!asString(raw.login.auth_method) || !asString(raw.login.subscription_type)) return null
    if (raw.login.api_provider !== null && !asString(raw.login.api_provider)) return null
  }
  if (
    !hasExactKeys(raw.execution, ['status', 'reason'])
    ||
    raw.execution.status !== 'not_measured'
    || raw.execution.reason !== 'login_probe_does_not_submit_model_turn'
  ) return null
  return {
    schema: 'masc.dashboard.official-client-probe.v1',
    ok: true,
    runtime_id,
    client_kind,
    configured_model,
    measured_at,
    login: {
      status: status as DashboardOfficialClientLoginStatus,
      authenticated,
      evidence_source: 'configured_executable_self_report',
      identity_verified: false,
      auth_method: asNullableString(raw.login.auth_method),
      subscription_type: asNullableString(raw.login.subscription_type),
      api_provider: asNullableString(raw.login.api_provider),
      detail,
    },
    client: { user_agent },
    execution: {
      status: 'not_measured',
      reason: 'login_probe_does_not_submit_model_turn',
    },
  }
}

function normalizeRuntimeTomlConfig(raw: unknown): RuntimeTomlConfig {
  const record = isRecord(raw) ? raw : {}
  return {
    ok: asBoolean(record.ok) ?? true,
    path: asNullableString(record.path),
    file_name: asString(record.file_name) ?? 'runtime.toml',
    source_text: asString(record.source_text, ''),
    provider_protocols: parseRuntimeTomlEditorProtocols(record.provider_protocols),
    application: normalizeRuntimeConfigApplication(record.application),
    validation: normalizeRuntimeConfigValidation(record.validation),
    keeper_setting_schema: record.keeper_setting_schema,
    keeper_settings: normalizeRuntimeKeeperSettings(record.keeper_settings),
    message: asNullableString(record.message),
    reason: asNullableString(record.reason),
    issues: record.issues,
  }
}

function appliedAt(raw: unknown): string | number | null {
  return asString(raw) ?? asNumber(raw) ?? null
}

function normalizeApplicationLane(raw: unknown): RuntimeConfigApplicationLane {
  const record = isRecord(raw) ? raw : {}
  return {
    status: asString(record.status) ?? 'unknown',
    requires_restart: asBoolean(record.requires_restart) ?? false,
    applied_at: appliedAt(record.applied_at),
  }
}

function normalizeRuntimeConfigApplication(raw: unknown): RuntimeConfigApplication | undefined {
  if (!isRecord(raw)) return undefined
  const keeperOverlay = isRecord(raw.keeper_overlay) ? raw.keeper_overlay : {}
  return {
    operation: asString(raw.operation) ?? 'unknown',
    routing: normalizeApplicationLane(raw.routing),
    keeper_overlay: {
      ...normalizeApplicationLane(keeperOverlay),
      configured_count: asNumber(keeperOverlay.configured_count) ?? 0,
      pending_keys: asStringArray(keeperOverlay.pending_keys) ?? [],
      applied_keys: asStringArray(keeperOverlay.applied_keys) ?? [],
      preempted_keys: asStringArray(keeperOverlay.preempted_keys) ?? [],
    },
  }
}

function normalizeRuntimeConfigValidation(raw: unknown): RuntimeConfigValidation | undefined {
  if (!isRecord(raw)) return undefined
  const issues = Array.isArray(raw.issues)
    ? raw.issues.flatMap((issue): RuntimeConfigValidationIssue[] => {
      if (!isRecord(issue)) return []
      const severity = asString(issue.severity)
      if (severity !== 'error' && severity !== 'warning') return []
      return [{
        key: asString(issue.key) ?? '',
        kind: asString(issue.kind) ?? 'unknown',
        severity,
        detail: asString(issue.detail) ?? '',
      }]
    })
    : []
  return {
    valid: asBoolean(raw.valid) ?? false,
    schema_version: asNumber(raw.schema_version) ?? 0,
    current_schema_version: asNumber(raw.current_schema_version) ?? 0,
    forward_schema: asBoolean(raw.forward_schema) ?? false,
    issues,
  }
}

function normalizeRuntimeKeeperSettings(raw: unknown): RuntimeKeeperSetting[] | undefined {
  if (!Array.isArray(raw)) return undefined
  return raw.flatMap((value): RuntimeKeeperSetting[] => {
    if (!isRecord(value)) return []
    return [{
      key: asNullableString(value.key),
      env: asString(value.env) ?? '',
      configured_value: asNullableString(value.configured_value),
      source: asString(value.source) ?? 'unknown',
      effective_value: asNullableString(value.effective_value),
      effective_error: asNullableString(value.effective_error),
      applied_at: asNumber(value.applied_at) ?? null,
      reload_class: asString(value.reload_class) ?? 'unknown',
      requires_restart: asBoolean(value.requires_restart) ?? false,
      application_status: asString(value.application_status) ?? 'unknown',
      consumers: asStringArray(value.consumers) ?? [],
    }]
  })
}

export async function fetchRuntimeTomlConfig(): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return get<unknown>('/api/v1/runtime/config/raw').then(normalizeRuntimeTomlConfig)
}

export async function fetchOfficialClientSession(
  keeperName: string,
  opts?: AbortableRequestOptions,
): Promise<DashboardOfficialClientSessionResponse> {
  await ensureDevToken()
  const query = new URLSearchParams({ keeper_name: keeperName })
  const raw = await get<unknown>(`/api/v1/runtime/sessions/official-client?${query}`, { signal: opts?.signal })
  const decoded = decodeOfficialClientSessionResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 official-client session payload')
  return decoded
}

export async function resolveOfficialClientSession(
  keeperName: string,
  recoveryId: string,
  decision: DashboardOfficialClientRecoveryDecision,
): Promise<DashboardOfficialClientRecoveryResponse> {
  await ensureDevToken()
  const raw = await post<unknown>('/api/v1/runtime/sessions/official-client/resolve', {
    keeper_name: keeperName,
    recovery_id: recoveryId,
    ...decision,
  })
  const decoded = decodeOfficialClientRecoveryResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 official-client recovery payload')
  return decoded
}

export async function probeOfficialClientLogin(
  runtimeId: string,
): Promise<DashboardOfficialClientProbeResponse> {
  await ensureDevToken()
  const raw = await post<unknown>('/api/v1/runtime/official-client/probe', {
    runtime_id: runtimeId,
  })
  const decoded = decodeOfficialClientProbeResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 official-client probe payload')
  return decoded
}

// Structured, already-resolved runtime defaults / model routing (runtime.toml
// SSOT). Public read — no credentials, no raw TOML; the Settings surface
// consumes this instead of re-parsing TOML on the client.
export async function fetchRuntimeDefaults(
  opts?: AbortableRequestOptions,
): Promise<RuntimeDefaultsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/runtime-defaults', { signal: opts?.signal })
  const { parseRuntimeDefaultsResponse } = await import('./schemas/runtime-defaults')
  return parseRuntimeDefaultsResponse(raw)
}

// Single resolved-runtime document (bugs #14/#15/#36): effective max-context
// + source per runtime, configured lanes, and the full keeper fleet joined
// against [runtime.assignments] with the [runtime].default rider made
// explicit. Public read, same posture as fetchRuntimeDefaults.
export async function fetchRuntimeResolved(
  opts?: AbortableRequestOptions,
): Promise<RuntimeResolvedResponse> {
  const raw = await get<unknown>('/api/v1/runtime/resolved', { signal: opts?.signal })
  const { parseRuntimeResolvedResponse } = await import('./schemas/runtime-resolved')
  return parseRuntimeResolvedResponse(raw)
}

export async function saveRuntimeTomlConfig(sourceText: string): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return post<unknown>('/api/v1/runtime/config/raw', {
    source_text: sourceText,
  }).then(normalizeRuntimeTomlConfig)
}

export async function previewRuntimeTomlConfig(sourceText: string): Promise<RuntimeConfigPreview> {
  await ensureDevToken()
  const raw = await post<unknown>('/api/v1/runtime/config/raw/preview', {
    source_text: sourceText,
  })
  if (!isRecord(raw)) throw new Error('유효하지 않은 runtime config preview payload')
  const validation = normalizeRuntimeConfigValidation(raw.validation)
  if (!validation) throw new Error('유효하지 않은 runtime config validation payload')
  return {
    ok: asBoolean(raw.ok) ?? false,
    can_save: asBoolean(raw.can_save) ?? false,
    validation,
    keeper_setting_schema: raw.keeper_setting_schema,
  }
}

export type RuntimeRoutingLane =
  | 'default'

export async function patchRuntimeRouting(
  lane: RuntimeRoutingLane,
  runtimeId: string | null,
): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return post<unknown>('/api/v1/runtime/config/routing', {
    lane,
    runtime_id: runtimeId,
  }).then(normalizeRuntimeTomlConfig)
}

export async function patchRuntimeMediaFailover(
  runtimeIds: readonly string[],
): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return post<unknown>('/api/v1/runtime/config/routing', {
    lane: 'media_failover',
    runtime_ids: [...runtimeIds],
  }).then(normalizeRuntimeTomlConfig)
}

export async function patchRuntimeAssignment(
  keeperName: string,
  runtimeId: string | null,
): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return post<unknown>('/api/v1/runtime/config/assignment', {
    keeper_name: keeperName,
    runtime_id: runtimeId,
  }).then(normalizeRuntimeTomlConfig)
}
