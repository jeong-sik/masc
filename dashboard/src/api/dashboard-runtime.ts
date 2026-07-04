// MASC Dashboard — Runtime providers / model metrics / runtime.toml config.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post, type AbortableRequestOptions } from './core'
import { isRecord, asBoolean, asNumber, asNullableString, asRecordArray, asString, asStringArray } from '../components/common/normalize'
import { ensureDevToken } from './dev-token'
import type { RuntimeDefaultsResponse } from './schemas/runtime-defaults'

interface DashboardRuntimeProviderDiscovery {
  healthy?: boolean
  discovered_model?: string | null
  ctx_size?: number | null
  total_slots?: number | null
  busy_slots?: number | null
  idle_slots?: number | null
}

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
  requires_per_keeper_bridging_for_bound_actor_tools?: boolean
  identity_runtime_mcp_header_keys: string[]
  argv_prompt_preflight?: boolean
  uses_anthropic_caching?: boolean
  max_turns_per_attempt?: number | null
  tolerates_bound_actor_fallback?: boolean
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
  supports_extended_thinking?: boolean
  supports_reasoning_budget?: boolean
  thinking_control_format?: string | null
  supports_image_input?: boolean
  supports_audio_input?: boolean
  supports_video_input?: boolean
  supports_multimodal_inputs?: boolean
  supports_response_format_json?: boolean
  supports_structured_output?: boolean
  supports_native_streaming?: boolean
  supports_caching?: boolean
  supports_prompt_caching?: boolean
  prompt_cache_alignment?: number | null
  supports_top_k?: boolean
  supports_min_p?: boolean
  supports_seed?: boolean
  emits_usage_tokens?: boolean
  supports_computer_use?: boolean
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
  capabilities?: DashboardRuntimeDeclaredModelCapabilities | null
  match_prefixes: string[]
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
  capabilities_declared?: boolean
  supports_multimodal_inputs?: boolean
  supports_image_input?: boolean
  supports_reasoning_budget?: boolean
  thinking_control_format?: string | null
  effective_capabilities?: DashboardRuntimeEffectiveCapabilities | null
  parameter_policy?: DashboardRuntimeParameterPolicy | null
  request_config?: DashboardRuntimeRequestConfig | null
  declared_spec?: DashboardRuntimeDeclaredSpec | null
  model_count?: number | null
  models: string[]
  source?: string | null
  endpoint_url?: string | null
  note?: string | null
  discovery?: DashboardRuntimeProviderDiscovery | null
}

export interface DashboardRuntimeAssignment {
  keeper: string
  runtime_id: string
  matches_default?: boolean
}

export interface DashboardRuntimeAssignmentGovernance {
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
  librarian_runtime_id?: string | null
  warnings: string[]
  assigned_runtimes: string[]
  assignments: DashboardRuntimeAssignment[]
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
  assignment_governance?: DashboardRuntimeAssignmentGovernance | null
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
   * legacy rows before OAS started emitting inference_timings).
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
  fallback_count?: number | null
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
    requires_per_keeper_bridging_for_bound_actor_tools:
      asBoolean(raw.requires_per_keeper_bridging_for_bound_actor_tools),
    identity_runtime_mcp_header_keys: asStringArray(raw.identity_runtime_mcp_header_keys),
    argv_prompt_preflight: asBoolean(raw.argv_prompt_preflight),
    uses_anthropic_caching: asBoolean(raw.uses_anthropic_caching),
    max_turns_per_attempt: asNumber(raw.max_turns_per_attempt) ?? null,
    tolerates_bound_actor_fallback: asBoolean(raw.tolerates_bound_actor_fallback),
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
    supports_extended_thinking: asBoolean(raw.supports_extended_thinking),
    supports_reasoning_budget: asBoolean(raw.supports_reasoning_budget),
    thinking_control_format: asNullableString(raw.thinking_control_format),
    supports_image_input: asBoolean(raw.supports_image_input),
    supports_audio_input: asBoolean(raw.supports_audio_input),
    supports_video_input: asBoolean(raw.supports_video_input),
    supports_multimodal_inputs: asBoolean(raw.supports_multimodal_inputs),
    supports_response_format_json: asBoolean(raw.supports_response_format_json),
    supports_structured_output: asBoolean(raw.supports_structured_output),
    supports_native_streaming: asBoolean(raw.supports_native_streaming),
    supports_caching: asBoolean(raw.supports_caching),
    supports_prompt_caching: asBoolean(raw.supports_prompt_caching),
    prompt_cache_alignment: asNumber(raw.prompt_cache_alignment) ?? null,
    supports_top_k: asBoolean(raw.supports_top_k),
    supports_min_p: asBoolean(raw.supports_min_p),
    supports_seed: asBoolean(raw.supports_seed),
    emits_usage_tokens: asBoolean(raw.emits_usage_tokens),
    supports_computer_use: asBoolean(raw.supports_computer_use),
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
    capabilities: decodeRuntimeDeclaredModelCapabilities(raw.capabilities),
    match_prefixes: asStringArray(raw.match_prefixes),
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
    supports_computer_use: asBoolean(raw.supports_computer_use),
    supports_code_execution: asBoolean(raw.supports_code_execution),
    emits_usage_tokens: asBoolean(raw.emits_usage_tokens),
    supported_models: decodeNullableStringArray(raw.supported_models),
  }
}

function decodeRuntimeProviderDiscovery(raw: unknown): DashboardRuntimeProviderDiscovery | null {
  if (!isRecord(raw)) return null
  return {
    healthy: asBoolean(raw.healthy),
    discovered_model: null,
    ctx_size: asNumber(raw.ctx_size) ?? null,
    total_slots: asNumber(raw.total_slots) ?? null,
    busy_slots: asNumber(raw.busy_slots) ?? null,
    idle_slots: asNumber(raw.idle_slots) ?? null,
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
    capabilities_declared: asBoolean(raw.capabilities_declared),
    supports_multimodal_inputs: asBoolean(raw.supports_multimodal_inputs),
    supports_image_input: asBoolean(raw.supports_image_input),
    supports_reasoning_budget: asBoolean(raw.supports_reasoning_budget),
    thinking_control_format: asNullableString(raw.thinking_control_format),
    effective_capabilities: decodeRuntimeEffectiveCapabilities(raw.effective_capabilities),
    parameter_policy: decodeRuntimeParameterPolicy(raw.parameter_policy),
    request_config: decodeRuntimeRequestConfig(raw.request_config),
    declared_spec: decodeRuntimeDeclaredSpec(raw.declared_spec),
    model_count: asNumber(raw.model_count) ?? null,
    models: asStringArray(raw.models),
    source: asNullableString(raw.source),
    endpoint_url: asNullableString(raw.endpoint_url),
    note: asNullableString(raw.note),
    discovery: decodeRuntimeProviderDiscovery(raw.discovery),
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

function decodeRuntimeAssignmentGovernance(raw: unknown): DashboardRuntimeAssignmentGovernance | null {
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
    librarian_runtime_id: asNullableString(raw.librarian_runtime_id),
    warnings: asStringArray(raw.warnings),
    assigned_runtimes: asStringArray(raw.assigned_runtimes),
    assignments: asRecordArray(raw.assignments)
      .map(decodeRuntimeAssignment)
      .filter((item): item is DashboardRuntimeAssignment => item !== null),
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
    assignment_governance: decodeRuntimeAssignmentGovernance(raw.assignment_governance),
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
    fallback_count: asNumber(raw.fallback_count) ?? null,
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
  reloaded: boolean
  message?: string | null
  reason?: string | null
  issues?: unknown
}

function normalizeRuntimeTomlConfig(raw: unknown): RuntimeTomlConfig {
  const record = isRecord(raw) ? raw : {}
  return {
    ok: asBoolean(record.ok) ?? true,
    path: asNullableString(record.path),
    file_name: asString(record.file_name) ?? 'runtime.toml',
    source_text: asString(record.source_text, ''),
    reloaded: asBoolean(record.reloaded) ?? false,
    message: asNullableString(record.message),
    reason: asNullableString(record.reason),
    issues: record.issues,
  }
}

export async function fetchRuntimeTomlConfig(): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return get<unknown>('/api/v1/runtime/config/raw').then(normalizeRuntimeTomlConfig)
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

export async function saveRuntimeTomlConfig(sourceText: string): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return post<unknown>('/api/v1/runtime/config/raw', {
    source_text: sourceText,
  }).then(normalizeRuntimeTomlConfig)
}

export type RuntimeRoutingLane = 'default' | 'librarian' | 'structured_judge' | 'cross_verifier'

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
