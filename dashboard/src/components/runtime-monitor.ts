import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchDashboardRuntimeProbe,
  fetchRuntimeModelMetrics,
  fetchRuntimeProviders,
  type DashboardRuntimeProbeResponse,
  type DashboardRuntimeModelMetric,
  type DashboardRuntimeModelMetricsResponse,
  type DashboardRuntimeProviderProbe,
  type DashboardRuntimeProviderSnapshot,
  type DashboardRuntimeProvidersResponse,
} from '../api/dashboard'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { EmptyState } from './common/feedback-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { Select } from './common/select'
import { StatTile } from './common/stat-tile'
import { StatusChip } from './common/status-chip'
import { TextInput } from './common/input'
import { Table, type TableColumn } from './common/table'
import type { ManagedAsyncResource } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { formatCost, formatNumber, formatPct1 } from '../lib/format-number'
import { errorToString, MISSING_DATA_DASH } from '../lib/format-string'
import { formatTimeHms } from '../lib/format-time'

/**
 * Filters model metrics by case-insensitive substring match against
 * visible `top_tools[].tool` names. Empty/whitespace query
 * returns the input reference unchanged (ref-equal). No mutation.
 */
function filterModelMetrics(
  models: readonly DashboardRuntimeModelMetric[],
  query: string,
): readonly DashboardRuntimeModelMetric[] {
  const trimmed = query.trim().toLowerCase()
  if (trimmed.length === 0) return models
  return models.filter(m => {
    const tools = m.top_tools ?? []
    for (const t of tools) {
      if (t.tool.toLowerCase().includes(trimmed)) return true
    }
    return false
  })
}

/**
 * Sorts model metrics so coverage gaps and failures surface first. Order:
 * 1. coverage_status urgency (error_only → none → partial → full)
 * 2. error_count desc
 * 3. entry_count desc
 * 4. stable internal id asc
 * Returns a new array; does not mutate the input.
 */
function sortModelMetricsByUrgency(
  models: readonly DashboardRuntimeModelMetric[],
): readonly DashboardRuntimeModelMetric[] {
  return [...models].sort((a, b) => {
    const aCoverage = COVERAGE_PRIORITY[a.coverage_status ?? 'full'] ?? 3
    const bCoverage = COVERAGE_PRIORITY[b.coverage_status ?? 'full'] ?? 3
    if (aCoverage !== bCoverage) return aCoverage - bCoverage
    const ae = a.error_count ?? 0
    const be = b.error_count ?? 0
    if (ae !== be) return be - ae
    const ac = a.entry_count ?? 0
    const bc = b.entry_count ?? 0
    if (ac !== bc) return bc - ac
    return a.model_id.localeCompare(b.model_id)
  })
}

interface RuntimeData {
  providers: DashboardRuntimeProvidersResponse | null
  metrics: DashboardRuntimeModelMetricsResponse | null
  probe: DashboardRuntimeProbeResponse | null
  probeError: string | null
}

interface RuntimeParameterDetailRow {
  axis: string
  label: string
  value: string
}

const COVERAGE_PRIORITY: Record<string, number> = {
  error_only: 0,
  none: 1,
  partial: 2,
  full: 3,
}

const COVERAGE_LABELS: Record<string, string> = {
  error_only: 'error-only',
  none: 'coverage missing',
  partial: 'coverage partial',
  full: 'coverage full',
}

const COVERAGE_REASON_LABELS: Record<string, string> = {
  error_turn: 'error turn',
  missing_usage_and_inference: 'usage/inference missing',
  missing_usage: 'usage missing',
  missing_inference: 'inference missing',
  untrusted_usage: 'usage untrusted',
  text_only_unmetered: 'text-only n/a',
  unknown: 'unknown reason',
}

const COVERAGE_STAGE_LABELS: Record<string, string> = {
  oas: 'OAS',
  keeper: 'keeper',
  projection: 'projection',
  unknown: 'unknown stage',
}

async function loadRuntimeData(
  resource: ManagedAsyncResource<RuntimeData>,
  windowMinutes: number,
  forceProbe = false,
) {
  await resource.load(async (signal) => {
    const probeResult = fetchDashboardRuntimeProbe(forceProbe, { signal })
      .then(probe => ({ probe, probeError: null }))
      .catch(error => ({ probe: null, probeError: errorToString(error) }))
    const [providers, metrics, probe] = await Promise.all([
      fetchRuntimeProviders({ signal }),
      fetchRuntimeModelMetrics(windowMinutes, 5, { signal }),
      probeResult,
    ])
    return { providers, metrics, probe: probe.probe, probeError: probe.probeError }
  })
}

// Current-reachability axis: does the provider respond right now?
// Orthogonal to runtime-config-panel.ts:providerTone which scores historical
// performance (success_rate, cooldown). Both signals can be shown together
// without being duplicates.
function runtimeProviderTone(provider: DashboardRuntimeProviderSnapshot): string {
  const advertised = provider.status?.trim().toLowerCase()
  if (advertised === 'missing_auth' || advertised === 'unsupported' || advertised === 'offline') {
    return 'bad'
  }
  if (advertised === 'vertex_adc') {
    return 'warn'
  }
  if (provider.available === false) return 'bad'
  if (provider.discovery?.healthy === false) return 'warn'
  if (provider.available === true) return 'ok'
  return 'warn'
}

function runtimeStatusLabel(provider: DashboardRuntimeProviderSnapshot): string {
  const advertised = provider.status?.trim().toLowerCase()
  if (advertised === 'missing_auth') return 'missing auth'
  if (advertised === 'unsupported') return 'unsupported'
  if (advertised === 'offline') return 'offline'
  if (provider.available === true) return 'available'
  if (provider.available === false) return 'unavailable'
  return provider.discovery?.healthy === false ? 'degraded' : 'unknown'
}

function runtimeParameterPolicyText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const policy = provider.parameter_policy
  if (!policy) return null
  const parts = [
    policy.reasoning_toggle_wire ? `wire ${policy.reasoning_toggle_wire}` : null,
    policy.reasoning_replay_policy ? `replay ${policy.reasoning_replay_policy}` : null,
    policy.requires_reasoning_replay_on_tool_call ? 'tool-call replay required' : null,
    policy.ignored_sampling_params.length > 0
      ? `ignored ${policy.ignored_sampling_params.join(',')}`
      : null,
    policy.always_ignored_sampling_params.length > 0
      ? `always ignored ${policy.always_ignored_sampling_params.join(',')}`
      : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function runtimeRequestToolChoiceText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const choice = provider.request_config?.tool_choice
  if (!choice?.kind) return null
  return choice.name ? `${choice.kind}:${choice.name}` : choice.kind
}

function runtimeRequestFormatText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const format = provider.request_config?.response_format
  if (!format?.kind) return null
  return format.has_schema ? `${format.kind}+schema` : format.kind
}

function boolText(value: boolean | null | undefined): string | null {
  if (typeof value !== 'boolean') return null
  return value ? 'yes' : 'no'
}

function onOffText(value: boolean | null | undefined): string | null {
  if (typeof value !== 'boolean') return null
  return value ? 'on' : 'off'
}

function flagText(
  value: boolean | null | undefined,
  enabled: string,
  disabled?: string,
): string | null {
  if (typeof value !== 'boolean') return null
  return value ? enabled : (disabled ?? `${enabled} off`)
}

function numberText(value: number | null | undefined): string | null {
  return typeof value === 'number' ? formatNumber(value) : null
}

function textList(values: readonly (string | null | undefined)[]): string | null {
  const present = values.filter((value): value is string => Boolean(value))
  return present.length > 0 ? present.join(',') : null
}

function stringArrayText(values: readonly string[] | null | undefined): string | null {
  return values && values.length > 0 ? values.join(',') : null
}

function boolStateText(value: boolean | null | undefined, label: string): string | null {
  if (typeof value !== 'boolean') return null
  return `${label} ${value ? 'on' : 'off'}`
}

function detailRow(
  axis: string,
  label: string,
  value: string | null | undefined,
): RuntimeParameterDetailRow | null {
  const trimmed = value?.trim()
  if (!trimmed) return null
  return { axis, label, value: trimmed }
}

function runtimeRequestPathText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const request = provider.request_config
  if (!request) return null
  if (request.request_path_targets_responses_api) return 'responses-api'
  return request.request_path ?? null
}

function runtimeRequestConfigText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const request = provider.request_config
  if (!request) return null
  const sampling = [
    typeof request.temperature === 'number' ? `temp ${request.temperature}` : null,
    typeof request.top_p === 'number' ? `top_p ${request.top_p}` : null,
    typeof request.top_k === 'number' ? `top_k ${request.top_k}` : null,
    typeof request.min_p === 'number' ? `min_p ${request.min_p}` : null,
  ].filter((value): value is string => Boolean(value))
  const toolChoice = runtimeRequestToolChoiceText(provider)
  const format = runtimeRequestFormatText(provider)
  let requestPath: string | null = null
  if (request.request_path_targets_responses_api) {
    requestPath = 'responses-api'
  } else if (request.request_path) {
    requestPath = `path ${request.request_path}`
  }
  const parts = [
    request.provider_kind ? `kind ${request.provider_kind}` : null,
    request.source ? `source ${request.source}` : null,
    requestPath,
    typeof request.max_tokens === 'number' ? `out ${formatNumber(request.max_tokens)}` : null,
    typeof request.max_context === 'number' ? `ctx ${formatNumber(request.max_context)}` : null,
    sampling.length > 0 ? `sampling ${sampling.join(',')}` : null,
    request.has_system_prompt ? 'system prompt' : null,
    typeof request.enable_thinking === 'boolean' ? `think ${request.enable_thinking ? 'on' : 'off'}` : null,
    typeof request.preserve_thinking === 'boolean' ? `preserve ${request.preserve_thinking ? 'on' : 'off'}` : null,
    typeof request.clear_thinking === 'boolean' ? `clear ${request.clear_thinking ? 'on' : 'off'}` : null,
    typeof request.thinking_budget === 'number' ? `budget ${formatNumber(request.thinking_budget)}` : null,
    request.resolved_reasoning_effort ? `effort ${request.resolved_reasoning_effort}` : null,
    request.glm_clear_thinking ? 'glm clear' : null,
    request.glm_replay_reasoning ? 'glm replay' : null,
    typeof request.tool_stream === 'boolean' ? `tool stream ${request.tool_stream ? 'on' : 'off'}` : null,
    toolChoice ? `tool ${toolChoice}` : null,
    request.disable_parallel_tool_use ? 'parallel off' : null,
    format ? `format ${format}` : null,
    request.has_output_schema ? 'output schema' : null,
    request.cache_system_prompt ? 'cache system' : null,
    typeof request.supports_tool_choice_override === 'boolean'
      ? `tool override ${request.supports_tool_choice_override ? 'on' : 'off'}`
      : null,
    typeof request.supports_structured_output_override === 'boolean'
      ? `schema override ${request.supports_structured_output_override ? 'on' : 'off'}`
      : null,
    request.has_model_capabilities_override ? 'cap override' : null,
    typeof request.seed === 'number' ? `seed ${request.seed}` : null,
    typeof request.internal_model_rotation_count === 'number'
      ? `rotation ${request.internal_model_rotation_count}`
      : null,
    typeof request.num_ctx === 'number' ? `num_ctx ${formatNumber(request.num_ctx)}` : null,
    request.keep_alive ? `keep ${request.keep_alive}` : null,
    request.has_previous_response_id ? 'previous response' : null,
    typeof request.connect_timeout_s === 'number' ? `connect ${request.connect_timeout_s}s` : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function runtimeSnapshotModelCount(provider: DashboardRuntimeProviderSnapshot): number | null {
  if (typeof provider.model_count === 'number') return provider.model_count
  return provider.models.length > 0 ? provider.models.length : null
}

function runtimeProviderModelCount(
  provider: DashboardRuntimeProviderSnapshot,
  probe: DashboardRuntimeProviderProbe | null | undefined,
): number | null {
  return probe?.model_count ?? runtimeSnapshotModelCount(provider)
}

function runtimeProviderAuthText(
  provider: DashboardRuntimeProviderSnapshot,
  probe: DashboardRuntimeProviderProbe | null | undefined,
): string {
  if (probe) return runtimeProbeAuthLabel(probe)
  return provider.auth_kind ?? MISSING_DATA_DASH
}

function runtimeSnapshotPromptCache(provider: DashboardRuntimeProviderSnapshot): string | null {
  if (provider.supports_prompt_caching !== true) return null
  return `prompt-cache${typeof provider.prompt_cache_alignment === 'number' ? `@${provider.prompt_cache_alignment}` : ''}`
}

function runtimeSnapshotFactsText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const modelCount = runtimeSnapshotModelCount(provider)
  const note = provider.note?.trim()
  const formats = [
    provider.supports_response_format_json ? 'json' : null,
    provider.supports_structured_output ? 'schema' : null,
  ].filter((value): value is string => Boolean(value))
  const sampling = [
    provider.supports_top_k ? 'top_k' : null,
    provider.supports_min_p ? 'min_p' : null,
    provider.supports_seed ? 'seed' : null,
  ].filter((value): value is string => Boolean(value))
  const controls = [
    provider.supports_tool_choice ? 'tool-choice' : null,
    provider.supports_required_tool_choice ? 'required' : null,
    provider.supports_named_tool_choice ? 'named' : null,
    provider.supports_parallel_tool_calls ? 'parallel' : null,
    provider.supports_extended_thinking ? 'extended-thinking' : null,
    provider.supports_native_streaming ? 'native-stream' : null,
    provider.supports_system_prompt ? 'system-prompt' : null,
    provider.supports_caching ? 'cache' : null,
    runtimeSnapshotPromptCache(provider),
    provider.supports_seed_with_images ? 'seed+images' : null,
    provider.emits_usage_tokens ? 'usage' : null,
    provider.supports_computer_use ? 'computer-use' : null,
    provider.supports_code_execution ? 'code-exec' : null,
  ].filter((value): value is string => Boolean(value))
  return textList([
    provider.source ? `source ${provider.source}` : null,
    provider.protocol ? `protocol ${provider.protocol}` : null,
    typeof modelCount === 'number' ? `models ${formatNumber(modelCount)}` : null,
    typeof provider.max_context === 'number' ? `ctx ${formatNumber(provider.max_context)}` : null,
    typeof provider.max_output_tokens === 'number' ? `out ${formatNumber(provider.max_output_tokens)}` : null,
    typeof provider.temperature === 'number' ? `model-temp ${provider.temperature}` : null,
    typeof provider.capabilities_declared === 'boolean'
      ? `caps ${provider.capabilities_declared ? 'declared' : 'missing'}`
      : null,
    formats.length > 0 ? `format ${formats.join(',')}` : null,
    sampling.length > 0 ? `sampling ${sampling.join(',')}` : null,
    boolStateText(provider.tools_support, 'tools'),
    boolStateText(provider.thinking_support, 'thinking'),
    boolStateText(provider.streaming, 'streaming'),
    boolStateText(provider.supports_multimodal_inputs, 'multimodal'),
    boolStateText(provider.supports_image_input, 'image'),
    boolStateText(provider.supports_audio_input, 'audio'),
    boolStateText(provider.supports_video_input, 'video'),
    boolStateText(provider.supports_reasoning_budget, 'reasoning-budget'),
    provider.thinking_control_format ? `thinking-control ${provider.thinking_control_format}` : null,
    controls.length > 0 ? `controls ${controls.join(',')}` : null,
    note ? `note ${note}` : null,
  ])
}

function runtimeProviderBehaviorText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const behavior = provider.declared_spec?.provider?.behavior_capabilities
  if (!behavior) return null
  return textList([
    flagText(behavior.supports_inline_tools, 'inline-tools'),
    flagText(behavior.requires_per_keeper_bridging_for_bound_actor_tools, 'keeper-bridge'),
    flagText(behavior.argv_prompt_preflight, 'argv-preflight'),
    flagText(behavior.uses_anthropic_caching, 'anthropic-cache'),
    typeof behavior.max_turns_per_attempt === 'number' ? `max-turns ${behavior.max_turns_per_attempt}` : null,
    flagText(behavior.tolerates_bound_actor_fallback, 'bound-fallback'),
  ])
}

function runtimeDeclaredModelControlText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const caps = provider.declared_spec?.model?.capabilities
  if (!caps) return null
  return textList([
    flagText(caps.supports_tool_choice, 'tool-choice'),
    flagText(caps.supports_required_tool_choice, 'required'),
    flagText(caps.supports_named_tool_choice, 'named'),
    flagText(caps.supports_parallel_tool_calls, 'parallel'),
    flagText(caps.supports_extended_thinking, 'extended-thinking'),
    flagText(caps.supports_reasoning_budget, 'reasoning-budget'),
    flagText(caps.supports_native_streaming, 'native-stream'),
    flagText(caps.supports_system_prompt, 'system-prompt'),
    flagText(caps.supports_caching, 'cache'),
    caps.supports_prompt_caching
      ? `prompt-cache${typeof caps.prompt_cache_alignment === 'number' ? `@${caps.prompt_cache_alignment}` : ''}`
      : flagText(caps.supports_prompt_caching, 'prompt-cache'),
    flagText(caps.supports_seed_with_images, 'seed+images'),
    flagText(caps.emits_usage_tokens, 'usage'),
    flagText(caps.supports_computer_use, 'computer-use'),
    flagText(caps.supports_code_execution, 'code-exec'),
  ])
}

function runtimeDeclaredInputText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const caps = provider.declared_spec?.model?.capabilities
  if (!caps) return null
  return textList([
    flagText(caps.supports_multimodal_inputs, 'multimodal'),
    flagText(caps.supports_image_input, 'image'),
    flagText(caps.supports_audio_input, 'audio'),
    flagText(caps.supports_video_input, 'video'),
  ])
}

function runtimeEffectiveToolText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const caps = provider.effective_capabilities
  if (!caps) return null
  return textList([
    flagText(caps.supports_tools, 'tools'),
    flagText(caps.supports_tool_choice, 'tool-choice'),
    flagText(caps.supports_required_tool_choice, 'required'),
    flagText(caps.supports_named_tool_choice, 'named'),
    flagText(caps.supports_parallel_tool_calls, 'parallel'),
    flagText(caps.supports_runtime_mcp_tools, 'runtime-mcp'),
    flagText(caps.supports_runtime_tool_events, 'runtime-events'),
  ])
}

function runtimeEffectiveReasoningText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const caps = provider.effective_capabilities
  if (!caps) return null
  return textList([
    flagText(caps.supports_reasoning, 'reasoning'),
    flagText(caps.supports_extended_thinking, 'extended'),
    flagText(caps.supports_reasoning_budget, 'budget'),
    caps.accepted_reasoning_efforts && caps.accepted_reasoning_efforts.length > 0
      ? `effort ${caps.accepted_reasoning_efforts.join(',')}`
      : null,
  ])
}

function runtimeEffectiveInputText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const caps = provider.effective_capabilities
  if (!caps) return null
  return textList([
    flagText(caps.supports_multimodal_inputs, 'multimodal'),
    flagText(caps.supports_image_input, 'image'),
    flagText(caps.supports_audio_input, 'audio'),
    flagText(caps.supports_video_input, 'video'),
    caps.modality_priority ? `modality ${caps.modality_priority}` : null,
  ])
}

function runtimeEffectiveControlText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const caps = provider.effective_capabilities
  if (!caps) return null
  return textList([
    flagText(caps.supports_native_streaming, 'native-stream'),
    flagText(caps.supports_system_prompt, 'system-prompt'),
    flagText(caps.supports_caching, 'cache'),
    caps.supports_prompt_caching
      ? `prompt-cache${typeof caps.prompt_cache_alignment === 'number' ? `@${caps.prompt_cache_alignment}` : ''}`
      : flagText(caps.supports_prompt_caching, 'prompt-cache'),
    flagText(caps.supports_seed_with_images, 'seed+images'),
    flagText(caps.supports_computer_use, 'computer-use'),
    flagText(caps.supports_code_execution, 'code-exec'),
    flagText(caps.emits_usage_tokens, 'usage'),
  ])
}

function runtimeParameterDetailRows(
  provider: DashboardRuntimeProviderSnapshot,
): readonly RuntimeParameterDetailRow[] {
  const policy = provider.parameter_policy
  const request = provider.request_config
  const spec = provider.declared_spec
  const declaredModel = spec?.model
  const declaredCaps = declaredModel?.capabilities
  const binding = spec?.binding
  const caps = provider.effective_capabilities
  let replayOnToolCall: string | null = null
  if (policy) {
    replayOnToolCall = policy.requires_reasoning_replay_on_tool_call ? 'required' : 'not required'
  }
  const requestSampling = request
    ? textList([
        typeof request.temperature === 'number' ? `temp ${request.temperature}` : null,
        typeof request.top_p === 'number' ? `top_p ${request.top_p}` : null,
        typeof request.top_k === 'number' ? `top_k ${request.top_k}` : null,
        typeof request.min_p === 'number' ? `min_p ${request.min_p}` : null,
      ])
    : null
  const declaredSampling = declaredCaps
    ? textList([
        flagText(declaredCaps.supports_top_k, 'top_k'),
        flagText(declaredCaps.supports_min_p, 'min_p'),
        flagText(declaredCaps.supports_seed, 'seed'),
      ])
    : null
  const effectiveSampling = caps
    ? textList([
        flagText(caps.supports_top_k, 'top_k'),
        flagText(caps.supports_min_p, 'min_p'),
        flagText(caps.supports_seed, 'seed'),
      ])
    : null
  const declaredFormat = declaredCaps
    ? textList([
        flagText(declaredCaps.supports_response_format_json, 'json'),
        flagText(declaredCaps.supports_structured_output, 'schema'),
      ])
    : null
  const effectiveFormat = caps
    ? textList([
        flagText(caps.supports_response_format_json, 'json'),
        flagText(caps.supports_structured_output, 'schema'),
      ])
    : null
  return [
    detailRow('policy', 'reasoning wire', policy?.reasoning_toggle_wire),
    detailRow('policy', 'replay policy', policy?.reasoning_replay_policy),
    detailRow('policy', 'replay on tool call', replayOnToolCall),
    detailRow('policy', 'ignored sampling', stringArrayText(policy?.ignored_sampling_params)),
    detailRow('policy', 'always ignored', stringArrayText(policy?.always_ignored_sampling_params)),
    detailRow('request', 'source', request?.source),
    detailRow('request', 'provider kind', request?.provider_kind),
    detailRow('request', 'endpoint', runtimeRequestPathText(provider)),
    detailRow('request', 'system prompt', boolText(request?.has_system_prompt)),
    detailRow('request', 'max context', numberText(request?.max_context)),
    detailRow('request', 'max output', numberText(request?.max_tokens)),
    detailRow('request', 'sampling', requestSampling),
    detailRow('request', 'thinking', onOffText(request?.enable_thinking)),
    detailRow('request', 'preserve thinking', onOffText(request?.preserve_thinking)),
    detailRow('request', 'clear thinking', onOffText(request?.clear_thinking)),
    detailRow('request', 'thinking budget', numberText(request?.thinking_budget)),
    detailRow('request', 'reasoning effort', request?.resolved_reasoning_effort),
    detailRow('request', 'glm clear', boolText(request?.glm_clear_thinking)),
    detailRow('request', 'glm replay', boolText(request?.glm_replay_reasoning)),
    detailRow('request', 'tool stream', onOffText(request?.tool_stream)),
    detailRow('request', 'tool choice', runtimeRequestToolChoiceText(provider)),
    detailRow('request', 'parallel tool use', request?.disable_parallel_tool_use ? 'disabled' : null),
    detailRow('request', 'response format', runtimeRequestFormatText(provider)),
    detailRow('request', 'output schema', boolText(request?.has_output_schema)),
    detailRow('request', 'cache system prompt', boolText(request?.cache_system_prompt)),
    detailRow('request', 'tool choice override', onOffText(request?.supports_tool_choice_override)),
    detailRow('request', 'schema override', onOffText(request?.supports_structured_output_override)),
    detailRow('request', 'capability override', boolText(request?.has_model_capabilities_override)),
    detailRow('request', 'seed', numberText(request?.seed)),
    detailRow('request', 'rotation count', numberText(request?.internal_model_rotation_count)),
    detailRow('request', 'num_ctx', numberText(request?.num_ctx)),
    detailRow('request', 'keep alive', request?.keep_alive),
    detailRow('request', 'previous response', boolText(request?.has_previous_response_id)),
    detailRow('request', 'connect timeout', numberText(request?.connect_timeout_s)),
    detailRow('declared provider', 'source', spec?.source),
    detailRow('declared provider', 'provider', spec?.provider?.id),
    detailRow('declared provider', 'display name', spec?.provider?.display_name),
    detailRow('declared provider', 'protocol', spec?.provider?.protocol),
    detailRow('declared provider', 'api format', spec?.provider?.api_format),
    detailRow('declared provider', 'transport', spec?.provider?.transport),
    detailRow('declared provider', 'auth kind', spec?.provider?.auth_kind),
    detailRow('declared provider', 'non-interactive', boolText(spec?.provider?.is_non_interactive)),
    detailRow('declared provider', 'capabilities block', boolText(spec?.provider?.has_capabilities)),
    detailRow('declared provider', 'behavior', runtimeProviderBehaviorText(provider)),
    detailRow(
      'declared provider',
      'mcp headers',
      stringArrayText(spec?.provider?.behavior_capabilities?.identity_runtime_mcp_header_keys),
    ),
    detailRow('declared provider', 'custom headers', numberText(spec?.provider?.custom_header_count)),
    detailRow('declared provider', 'connect timeout', numberText(spec?.provider?.connect_timeout_s)),
    detailRow('declared model', 'model id', declaredModel?.id),
    detailRow('declared model', 'api name', declaredModel?.api_name),
    detailRow('declared model', 'context', numberText(declaredModel?.max_context)),
    detailRow('declared model', 'tools', onOffText(declaredModel?.tools_support)),
    detailRow('declared model', 'streaming', onOffText(declaredModel?.streaming)),
    detailRow('declared model', 'thinking', onOffText(declaredModel?.thinking_support)),
    detailRow('declared model', 'preserve thinking', onOffText(declaredModel?.preserve_thinking)),
    detailRow('declared model', 'thinking budget', numberText(declaredModel?.max_thinking_budget)),
    detailRow('declared model', 'temperature', numberText(declaredModel?.temperature)),
    detailRow('declared model', 'capability source', declaredCaps?.source),
    detailRow('declared model', 'max output', numberText(declaredCaps?.max_output_tokens)),
    detailRow('declared model', 'thinking wire', declaredCaps?.thinking_control_format),
    detailRow('declared model', 'format', declaredFormat),
    detailRow('declared model', 'sampling', declaredSampling),
    detailRow('declared model', 'inputs', runtimeDeclaredInputText(provider)),
    detailRow('declared model', 'controls', runtimeDeclaredModelControlText(provider)),
    detailRow('declared model', 'match prefixes', stringArrayText(declaredModel?.match_prefixes)),
    detailRow('binding', 'provider.model', textList([binding?.provider_id, binding?.model_id])),
    detailRow('binding', 'default', boolText(binding?.is_default)),
    detailRow('binding', 'concurrency', numberText(binding?.max_concurrent)),
    detailRow(
      'binding',
      'price',
      textList([
        typeof binding?.price_input === 'number' ? `in ${binding.price_input}` : null,
        typeof binding?.price_output === 'number' ? `out ${binding.price_output}` : null,
      ]),
    ),
    detailRow('binding', 'keep alive', binding?.keep_alive),
    detailRow('binding', 'num_ctx', numberText(binding?.num_ctx)),
    detailRow('effective', 'source', caps?.source),
    detailRow('effective', 'max context', numberText(caps?.max_context_tokens)),
    detailRow('effective', 'max output', numberText(caps?.max_output_tokens)),
    detailRow('effective', 'tools', runtimeEffectiveToolText(provider)),
    detailRow('effective', 'tool content', caps?.assistant_tool_content_format),
    detailRow('effective', 'reasoning', runtimeEffectiveReasoningText(provider)),
    detailRow('effective', 'thinking wire', caps?.thinking_control_format),
    detailRow('effective', 'preserve wire', caps?.preserve_thinking_control_format),
    detailRow('effective', 'reasoning output', caps?.reasoning_output_format),
    detailRow(
      'effective',
      'reasoning stream',
      textList([caps?.reasoning_streaming_format?.kind, caps?.reasoning_streaming_format?.field]),
    ),
    detailRow('effective', 'reasoning replay', caps?.reasoning_replay_override),
    detailRow('effective', 'format', effectiveFormat),
    detailRow('effective', 'inputs', runtimeEffectiveInputText(provider)),
    detailRow('effective', 'modality priority', caps?.modality_priority),
    detailRow('effective', 'task', caps?.task),
    detailRow('effective', 'controls', runtimeEffectiveControlText(provider)),
    detailRow('effective', 'sampling', effectiveSampling),
    detailRow('effective', 'supported models', stringArrayText(caps?.supported_models)),
  ].filter((row): row is RuntimeParameterDetailRow => row !== null)
}

function runtimeDeclaredSpecText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const spec = provider.declared_spec
  if (!spec) return null
  const declaredCaps = spec.model?.capabilities
  const declaredSampling = [
    declaredCaps?.supports_top_k ? 'top_k' : null,
    declaredCaps?.supports_min_p ? 'min_p' : null,
    declaredCaps?.supports_seed ? 'seed' : null,
  ].filter((value): value is string => Boolean(value))
  const declaredFormats = [
    declaredCaps?.supports_response_format_json ? 'json' : null,
    declaredCaps?.supports_structured_output ? 'schema' : null,
  ].filter((value): value is string => Boolean(value))
  const declaredInputs = [
    declaredCaps?.supports_multimodal_inputs ? 'multimodal' : null,
    declaredCaps?.supports_image_input ? 'image' : null,
    declaredCaps?.supports_audio_input ? 'audio' : null,
    declaredCaps?.supports_video_input ? 'video' : null,
  ].filter((value): value is string => Boolean(value))
  const providerBehavior = spec.provider?.behavior_capabilities
  const providerBehaviorParts = providerBehavior
    ? [
        providerBehavior.supports_inline_tools ? 'inline-tools' : null,
        providerBehavior.requires_per_keeper_bridging_for_bound_actor_tools ? 'keeper-bridge' : null,
        providerBehavior.argv_prompt_preflight ? 'argv-preflight' : null,
        providerBehavior.uses_anthropic_caching ? 'anthropic-cache' : null,
        typeof providerBehavior.max_turns_per_attempt === 'number'
          ? `max-turns ${providerBehavior.max_turns_per_attempt}`
          : null,
        providerBehavior.tolerates_bound_actor_fallback ? 'bound-fallback' : null,
        providerBehavior.identity_runtime_mcp_header_keys.length > 0
          ? `mcp headers ${providerBehavior.identity_runtime_mcp_header_keys.join(',')}`
          : null,
      ].filter((value): value is string => Boolean(value))
    : []
  const declaredModelControls = [
    declaredCaps?.supports_tool_choice ? 'tool-choice' : null,
    declaredCaps?.supports_required_tool_choice ? 'required' : null,
    declaredCaps?.supports_named_tool_choice ? 'named' : null,
    declaredCaps?.supports_parallel_tool_calls ? 'parallel' : null,
    declaredCaps?.supports_extended_thinking ? 'extended-thinking' : null,
    declaredCaps?.supports_reasoning_budget ? 'reasoning-budget' : null,
    declaredCaps?.supports_native_streaming ? 'native-stream' : null,
    declaredCaps?.supports_system_prompt ? 'system-prompt' : null,
    declaredCaps?.supports_caching ? 'cache' : null,
    declaredCaps?.supports_prompt_caching
      ? `prompt-cache${typeof declaredCaps.prompt_cache_alignment === 'number' ? `@${declaredCaps.prompt_cache_alignment}` : ''}`
      : null,
    declaredCaps?.supports_seed_with_images ? 'seed+images' : null,
    declaredCaps?.emits_usage_tokens ? 'usage' : null,
    declaredCaps?.supports_computer_use ? 'computer-use' : null,
    declaredCaps?.supports_code_execution ? 'code-exec' : null,
  ].filter((value): value is string => Boolean(value))
  let declaredThinking: string | null = null
  if (typeof spec.model?.thinking_support === 'boolean') {
    declaredThinking = spec.model.thinking_support ? 'think on' : 'think off'
  }
  const providerParts = [
    spec.provider?.api_format ? `api ${spec.provider.api_format}` : null,
    spec.provider?.protocol ? `protocol ${spec.provider.protocol}` : null,
    spec.provider?.transport ? `transport ${spec.provider.transport}` : null,
    spec.provider?.auth_kind ? `auth ${spec.provider.auth_kind}` : null,
    spec.provider?.is_non_interactive ? 'non-interactive' : null,
    typeof spec.provider?.custom_header_count === 'number'
      ? `headers ${spec.provider.custom_header_count}`
      : null,
    typeof spec.provider?.connect_timeout_s === 'number'
      ? `connect ${spec.provider.connect_timeout_s}s`
      : null,
    providerBehaviorParts.length > 0 ? `behavior ${providerBehaviorParts.join(',')}` : null,
  ].filter((value): value is string => Boolean(value))
  const modelParts = [
    spec.model?.api_name ? `model ${spec.model.api_name}` : null,
    typeof spec.model?.max_context === 'number' ? `ctx ${formatNumber(spec.model.max_context)}` : null,
    typeof spec.model?.temperature === 'number' ? `temp ${spec.model.temperature}` : null,
    typeof spec.model?.tools_support === 'boolean' ? `tools ${spec.model.tools_support ? 'on' : 'off'}` : null,
    typeof spec.model?.streaming === 'boolean' ? `stream ${spec.model.streaming ? 'on' : 'off'}` : null,
    declaredThinking,
    typeof spec.model?.preserve_thinking === 'boolean'
      ? `preserve ${spec.model.preserve_thinking ? 'on' : 'off'}`
      : null,
    typeof spec.model?.max_thinking_budget === 'number'
      ? `budget ${formatNumber(spec.model.max_thinking_budget)}`
      : null,
    declaredCaps?.thinking_control_format ? `wire ${declaredCaps.thinking_control_format}` : null,
    typeof declaredCaps?.max_output_tokens === 'number'
      ? `out ${formatNumber(declaredCaps.max_output_tokens)}`
      : null,
    declaredFormats.length > 0 ? `format ${declaredFormats.join(',')}` : null,
    declaredSampling.length > 0 ? `sampling ${declaredSampling.join(',')}` : null,
    declaredInputs.length > 0 ? `input ${declaredInputs.join(',')}` : null,
    declaredModelControls.length > 0 ? `controls ${declaredModelControls.join(',')}` : null,
    spec.model?.match_prefixes.length ? `match ${spec.model.match_prefixes.join(',')}` : null,
  ].filter((value): value is string => Boolean(value))
  const bindingParts = [
    spec.binding?.is_default ? 'default' : null,
    typeof spec.binding?.max_concurrent === 'number' ? `concurrency ${spec.binding.max_concurrent}` : null,
    typeof spec.binding?.price_input === 'number' ? `price-in ${spec.binding.price_input}` : null,
    typeof spec.binding?.price_output === 'number' ? `price-out ${spec.binding.price_output}` : null,
    spec.binding?.keep_alive ? `keep ${spec.binding.keep_alive}` : null,
    typeof spec.binding?.num_ctx === 'number' ? `num_ctx ${formatNumber(spec.binding.num_ctx)}` : null,
  ].filter((value): value is string => Boolean(value))
  const parts = [
    providerParts.length > 0 ? providerParts.join(',') : null,
    modelParts.length > 0 ? modelParts.join(',') : null,
    bindingParts.length > 0 ? bindingParts.join(',') : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function runtimeEffectiveCapabilitiesText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const caps = provider.effective_capabilities
  if (!caps) return null
  const sampling = [
    caps.supports_top_k ? 'top_k' : null,
    caps.supports_min_p ? 'min_p' : null,
    caps.supports_seed ? 'seed' : null,
  ].filter((value): value is string => Boolean(value))
  const modalities = [
    caps.supports_image_input ? 'image' : null,
    caps.supports_audio_input ? 'audio' : null,
    caps.supports_video_input ? 'video' : null,
  ].filter((value): value is string => Boolean(value))
  const context = typeof caps.max_context_tokens === 'number'
    ? `ctx ${formatNumber(caps.max_context_tokens)}`
    : null
  const output = typeof caps.max_output_tokens === 'number'
    ? `out ${formatNumber(caps.max_output_tokens)}`
    : null
  const tools = caps.supports_tool_choice
    ? `tool_choice${[
      caps.supports_required_tool_choice ? 'required' : null,
      caps.supports_named_tool_choice ? 'named' : null,
      caps.supports_parallel_tool_calls ? 'parallel' : null,
    ].filter((value): value is string => Boolean(value)).map(flag => `+${flag}`).join('')}`
    : null
  const formats = [
    caps.supports_response_format_json ? 'json' : null,
    caps.supports_structured_output ? 'schema' : null,
  ].filter((value): value is string => Boolean(value))
  const parts = [
    context,
    output,
    caps.supports_tools ? 'tools' : null,
    tools,
    caps.supports_runtime_mcp_tools ? 'runtime-mcp-tools' : null,
    caps.supports_runtime_tool_events ? 'runtime-tool-events' : null,
    formats.length > 0 ? `format ${formats.join(',')}` : null,
    sampling.length > 0 ? `sampling ${sampling.join(',')}` : null,
    modalities.length > 0 ? `input ${modalities.join(',')}` : null,
    caps.modality_priority ? `modality ${caps.modality_priority}` : null,
    caps.assistant_tool_content_format ? `tool-content ${caps.assistant_tool_content_format}` : null,
    caps.supports_reasoning ? 'reasoning' : null,
    caps.supports_extended_thinking ? 'extended' : null,
    caps.supports_reasoning_budget ? 'budget' : null,
    caps.accepted_reasoning_efforts && caps.accepted_reasoning_efforts.length > 0
      ? `effort ${caps.accepted_reasoning_efforts.join(',')}`
      : null,
    caps.preserve_thinking_control_format ? `preserve ${caps.preserve_thinking_control_format}` : null,
    caps.reasoning_output_format ? `reasoning-out ${caps.reasoning_output_format}` : null,
    caps.reasoning_streaming_format?.kind ? `reasoning-stream ${caps.reasoning_streaming_format.kind}` : null,
    caps.reasoning_replay_override ? `replay ${caps.reasoning_replay_override}` : null,
    caps.task ? `task ${caps.task}` : null,
    caps.supports_native_streaming ? 'native-stream' : null,
    caps.supports_system_prompt ? 'system-prompt' : null,
    caps.supports_prompt_caching
      ? `prompt-cache${typeof caps.prompt_cache_alignment === 'number' ? `@${caps.prompt_cache_alignment}` : ''}`
      : null,
    caps.supports_caching ? 'cache' : null,
    caps.supports_seed_with_images ? 'seed+images' : null,
    caps.supports_computer_use ? 'computer-use' : null,
    caps.supports_code_execution ? 'code-exec' : null,
    caps.emits_usage_tokens ? 'usage' : null,
    caps.supported_models && caps.supported_models.length > 0 ? `models ${caps.supported_models.length}` : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function providerProbeKey(probe: DashboardRuntimeProviderProbe): string | null {
  return probe.runtime_id ?? null
}

function providerRuntimeKey(provider: DashboardRuntimeProviderSnapshot): string {
  return provider.runtime_id ?? provider.provider
}

function runtimeProbeTone(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  if (!probe) return 'neutral'
  if (probe.reachable === true) return 'ok'
  if (probe.status === 'skipped_cli') return 'neutral'
  if (probe.status === 'missing_auth' || probe.status === 'auth_failed') return 'bad'
  if (probe.status === 'network_error' || probe.status === 'server_error') return 'bad'
  if (probe.reachable === false) return 'bad'
  return 'warn'
}

function runtimeProbeLabel(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  if (!probe) return 'not probed'
  switch (probe.status) {
    case 'reachable':
      return 'reachable'
    case 'missing_auth':
      return 'missing auth'
    case 'auth_failed':
      return 'auth failed'
    case 'network_error':
      return 'network error'
    case 'server_error':
      return 'server error'
    case 'endpoint_not_found':
      return 'not found'
    case 'skipped_cli':
      return 'cli skipped'
    case 'invalid_endpoint':
      return 'bad endpoint'
    default:
      return probe.status ?? 'unknown'
  }
}

function runtimeProbeAuthLabel(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  if (probe?.credential_required !== true) return 'none'
  return probe.auth_present === true ? 'present' : 'missing'
}

function runtimeProbeSummaryText(probe: DashboardRuntimeProbeResponse | null): string {
  const summary = probe?.probe?.summary
  if (!summary) return 'live probe 없음'
  return `Reachable ${summary.reachable ?? 0} · Failed ${summary.failed ?? 0} · Skipped ${summary.skipped ?? 0}`
}

function providerProbeMap(probe: DashboardRuntimeProbeResponse | null): Map<string, DashboardRuntimeProviderProbe> {
  const map = new Map<string, DashboardRuntimeProviderProbe>()
  for (const item of probe?.probe?.providers ?? []) {
    const key = providerProbeKey(item)
    if (key) map.set(key, item)
  }
  return map
}

function fmtProbeLatency(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  if (!probe || probe.latency_ms == null) return MISSING_DATA_DASH
  return `${formatNumber(probe.latency_ms, 1)} ms`
}

function fmtProbeHttpStatus(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  return probe?.http_status == null ? MISSING_DATA_DASH : String(probe.http_status)
}

function modelMetricTone(metric: DashboardRuntimeModelMetric): string {
  if ((metric.entry_count ?? 0) <= 0) return 'warn'
  const success = metric.success_count ?? metric.entry_count ?? 0
  const errors = metric.error_count ?? 0
  const total = success + errors
  if (total > 0) {
    const rate = success / total
    if (rate < 0.85) return 'bad'
    if (rate < 0.95) return 'warn'
  }
  if ((metric.fallback_count ?? 0) > 0) return 'warn'
  return 'ok'
}


function fmtSuccessRate(metric: DashboardRuntimeModelMetric): string {
  const success = metric.success_count ?? metric.entry_count ?? 0
  const errors = metric.error_count ?? 0
  const total = success + errors
  if (total === 0) return MISSING_DATA_DASH
  const pct = (success / total) * 100
  return `${pct.toFixed(1)}%`
}


function sparklineSvg(values: number[], color: string, w = 80, h = 20): string {
  if (values.length < 2) return ''
  const min = Math.min(...values)
  const max = Math.max(...values)
  const range = max - min || 1
  const points = values.map((v, i) => {
    const x = (i / (values.length - 1)) * w
    const y = h - ((v - min) / range) * (h - 2) - 1
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
  return `<svg aria-hidden="true" width="${w}" height="${h}" class="inline-block align-middle" viewBox="0 0 ${w} ${h}" xmlns="http://www.w3.org/2000/svg"><polyline fill="none" stroke="${color}" stroke-width="1.5" stroke-linejoin="round" points="${points}"/></svg>`
}

function sumNullable(values: Array<number | null | undefined>): number | null {
  let sawNumber = false
  let total = 0
  for (const value of values) {
    if (typeof value === 'number' && !Number.isNaN(value)) {
      sawNumber = true
      total += value
    }
  }
  return sawNumber ? total : null
}

function coverageStatusLabel(status?: DashboardRuntimeModelMetric['coverage_status']): string | null {
  if (!status) return null
  return COVERAGE_LABELS[status] ?? status
}

function coverageReasonLabel(reason?: string | null): string | null {
  if (!reason) return null
  return COVERAGE_REASON_LABELS[reason] ?? reason
}

function coverageStageLabel(stage?: string | null): string | null {
  if (!stage) return null
  return COVERAGE_STAGE_LABELS[stage] ?? stage
}

function metricCoverageTone(metric: DashboardRuntimeModelMetric): string {
  switch (metric.coverage_status) {
    case 'full':
      return 'ok'
    case 'partial':
      return 'warn'
    case 'none':
    case 'error_only':
      return 'bad'
    default:
      return 'warn'
  }
}

function metricMissingLabel(metric: DashboardRuntimeModelMetric): string {
  if (metric.coverage_status === 'error_only') return 'error-only'
  if (metric.primary_coverage_reason === 'text_only_unmetered') return 'n/a'
  if (metric.coverage_status === 'none') return 'missing'
  if (metric.coverage_status === 'partial') return 'partial'
  return MISSING_DATA_DASH
}

function fmtCoverageAwareNumber(
  metric: DashboardRuntimeModelMetric,
  value?: number | null,
  digits = 0,
): string {
  const formatted = formatNumber(value, digits)
  return formatted !== MISSING_DATA_DASH ? formatted : metricMissingLabel(metric)
}

function fmtCoverageAwareCost(metric: DashboardRuntimeModelMetric, value?: number | null): string {
  const formatted = formatCost(value)
  return formatted !== MISSING_DATA_DASH ? formatted : metricMissingLabel(metric)
}

function recentEntryMissingLabel(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
): string {
  // Order: most-specific to least-specific.
  // Goal: make "why is this cell empty?" observable instead of rendering an
  // opaque `--`. The `telemetry_reported`/`usage_reported` flags land earlier
  // in the response than `coverage_reason`, so they give the most direct
  // signal when the cell is empty due to missing OAS timings vs. missing
  // per-turn usage accounting.
  if (entry.outcome === 'error') return 'error-only'
  if (entry.usage_trust === 'untrusted') return 'untrusted'
  if (entry.coverage_reason === 'text_only_unmetered') return 'n/a'
  if (entry.telemetry_reported === false && entry.usage_reported === false)
    return 'no-telemetry'
  if (entry.telemetry_reported === false) return 'no-timings'
  if (entry.usage_reported === false) return 'no-usage'
  if (entry.coverage_reason) return 'missing'
  return '—'
}

function fmtRecentEntryNumber(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
  value?: number | null,
  digits = 0,
): string {
  const formatted = formatNumber(value, digits)
  return formatted !== MISSING_DATA_DASH ? formatted : recentEntryMissingLabel(entry)
}

function fmtRecentEntryCost(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
  value?: number | null,
): string {
  const formatted = formatCost(value)
  return formatted !== MISSING_DATA_DASH ? formatted : recentEntryMissingLabel(entry)
}

function fmtRecentEntryCache(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
): string {
  if (entry.cache_read_tokens == null && entry.cache_creation_tokens == null) {
    return recentEntryMissingLabel(entry)
  }
  const read = fmtRecentEntryNumber(entry, entry.cache_read_tokens)
  const creation = fmtRecentEntryNumber(entry, entry.cache_creation_tokens)
  return `${read}/${creation}`
}

function recentEntryDetail(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
): string | null {
  const parts = [
    entry.outcome?.trim(),
    entry.usage_trust === 'untrusted'
      ? [
          'usage untrusted',
          ...(entry.usage_anomaly_reasons ?? []),
        ].join(': ')
      : null,
    coverageStageLabel(entry.coverage_stage),
    coverageReasonLabel(entry.coverage_reason),
    entry.turn_lane?.trim(),
    entry.stop_reason?.trim(),
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

type RecentEntry = NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number]

const recentEntryColumns: TableColumn<RecentEntry>[] = [
  {
    key: 'time',
    header: 'time',
    render: (re) => {
      const detail = recentEntryDetail(re)
      return html`
        <div>
          <div>${re.ts_unix > 0 ? formatTimeHms(re.ts_unix) : MISSING_DATA_DASH}</div>
          ${detail ? html`<div class="text-3xs text-[var(--color-fg-muted)] mt-0.5">${detail}</div>` : null}
        </div>
      `
    },
  },
  { key: 'input_tokens', header: 'in tok', render: (re) => fmtRecentEntryNumber(re, re.input_tokens) },
  { key: 'output_tokens', header: 'out tok', render: (re) => fmtRecentEntryNumber(re, re.output_tokens) },
  { key: 'cache_tokens', header: 'cache r/w', render: fmtRecentEntryCache },
  {
    key: 'latency_ms',
    header: 'latency',
    render: (re) => re.latency_ms == null ? recentEntryMissingLabel(re) : `${formatNumber(re.latency_ms, 0)}ms`,
  },
  { key: 'prompt_tok_per_sec', header: 'prefill tok/s', render: (re) => fmtRecentEntryNumber(re, re.prompt_tok_per_sec, 1) },
  { key: 'cost_usd', header: 'cost', render: (re) => fmtRecentEntryCost(re, re.cost_usd) },
  { key: 'tools_count', header: 'tools', render: (re) => String(re.tools_count) },
]

function metricCoverageText(metric: DashboardRuntimeModelMetric): string | null {
  if (metric.coverage_status === 'full' && metric.primary_coverage_reason == null) return null
  if (metric.coverage_status === 'error_only') return 'error-only window'
  const successCount = metric.success_count ?? 0
  if (successCount <= 0) return null
  const usageCount = metric.usage_sample_count ?? 0
  const telemetryCount = metric.telemetry_sample_count ?? 0
  if (
    metric.coverage_status == null
    && usageCount >= successCount
    && telemetryCount >= successCount
  ) return null
  const parts = [
    coverageStatusLabel(metric.coverage_status),
    coverageStageLabel(metric.primary_coverage_stage),
    coverageReasonLabel(metric.primary_coverage_reason),
    `usage ${formatNumber(usageCount)}/${formatNumber(successCount)}`,
    `telemetry ${formatNumber(telemetryCount)}/${formatNumber(successCount)}`,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

export function RuntimeMonitor() {
  const resource = useManagedAsyncResource<RuntimeData>()
  const windowMinutes = useSignal(30)
  const expandedModel = useSignal<string | null>(null)
  const modelSearch = useSignal('')

  const load = (forceProbe = false) => loadRuntimeData(resource, windowMinutes.value, forceProbe)

  useEffect(() => {
    void loadRuntimeData(resource, windowMinutes.value)
    return () => {
      resource.cancel()
    }
  }, [resource, windowMinutes.value])

  const current = resource.state.value
  const providers = current.data?.providers ?? null
  const metrics = current.data?.metrics ?? null
  const probe = current.data?.probe ?? null
  const probeError = current.data?.probeError ?? null
  const providerProbes = providerProbeMap(probe)

  // filterModelMetrics was called twice per render (no-results check + the
  // sorted list) with identical args. Memoize once and reuse so it runs at most
  // once per render — only re-deriving when the metrics payload or the search
  // term changes.
  const filteredModels = useMemo(
    () => filterModelMetrics(metrics?.models ?? [], modelSearch.value),
    [metrics, modelSearch.value],
  )
  const sortedModels = useMemo(
    () => sortModelMetricsByUrgency(filteredModels),
    [filteredModels],
  )

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <${Select}
          class="px-2 py-1 text-xs"
          value=${String(windowMinutes.value)}
          ariaLabel="시간 윈도우 선택"
          options=${[
            { value: '15', label: '15분' },
            { value: '30', label: '30분' },
            { value: '60', label: '60분' },
            { value: '180', label: '180분' },
          ]}
          onInput=${(v: string) => { windowMinutes.value = Number(v) }}
        />
        <${ActionButton}
          variant="ghost"
          size="sm"
          ariaLabel="runtime snapshot 새로고침"
          onClick=${() => void load(true)}
        >새로고침<//>
        ${current.loading ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>` : null}
      </div>

      ${current.error
        ? html`<${ErrorState} message=${current.error} />`
        : null}

      ${current.loading && !providers && !metrics
        ? html`<${LoadingState}>runtime snapshot 불러오는 중...<//>`
        : null}

      <${SectionCard} label="런타임 상태">
        ${probeError
          ? html`<div class="mb-3 rounded-[var(--r-1)] border border-[var(--status-warn)] bg-[var(--status-warn)]/5 px-3 py-2 text-xs text-[var(--status-warn)]">
              live probe 실패 · ${probeError}
            </div>`
          : null}
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3 mb-4">
          <${StatTile}
            label="런타임"
            value=${String(providers?.summary?.runtimes ?? providers?.providers.length ?? 0)}
            delta=${{ direction: 'flat', text: `Providers ${providers?.summary?.providers ?? 0} · ${providers?.updated_at ?? 'updated_at 없음'}` }}
          />
          <${StatTile}
            label="로컬 런타임"
            value=${String(providers?.summary?.local_models ?? 0)}
            delta=${{ direction: 'flat', text: `Cloud ${providers?.summary?.cloud_models ?? 0} · CLI ${providers?.summary?.cli_models ?? 0}` }}
          />
          <${StatTile}
            label="Live reachability"
            value=${String(probe?.probe?.summary?.reachable ?? 0)}
            delta=${{ direction: probe?.probe?.summary?.failed ? 'down' : 'flat', text: runtimeProbeSummaryText(probe) }}
          />
        </div>
        ${providers?.config_path
          ? html`<div class="mb-3 break-all font-mono text-2xs text-[var(--color-fg-muted)]">config · ${providers.config_path}</div>`
          : null}
        <div class="flex flex-col gap-3">
          ${(providers?.providers ?? []).length > 0
              ? providers?.providers.map(provider => {
                const liveProbe = providerProbes.get(providerRuntimeKey(provider)) ?? null
                const effectiveCapabilities = runtimeEffectiveCapabilitiesText(provider)
                const parameterPolicy = runtimeParameterPolicyText(provider)
                const requestConfig = runtimeRequestConfigText(provider)
                const declaredSpec = runtimeDeclaredSpecText(provider)
                const parameterDetails = runtimeParameterDetailRows(provider)
                const snapshotFacts = runtimeSnapshotFactsText(provider)
                return html`
                <article class="v2-monitoring-card p-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]/40 backdrop-blur-sm flex flex-col gap-2">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <div class="grid gap-1">
                      <strong class="text-sm text-[var(--color-fg-primary)]">${provider.runtime_id ?? provider.provider}</strong>
                      <span class="text-xs text-[var(--color-fg-muted)]">${provider.provider_id ?? '(unknown provider)'}</span>
                    </div>
                    <div class="flex items-center gap-2 flex-wrap justify-end">
                      <${StatusChip} tone=${runtimeProviderTone(provider)}>${runtimeStatusLabel(provider)}<//>
                      <${StatusChip} tone=${runtimeProbeTone(liveProbe)} uppercase=${false}>live ${runtimeProbeLabel(liveProbe)}<//>
                    </div>
                  </div>
                  <div class="grid grid-cols-2 gap-3 text-xs text-[var(--color-fg-secondary)]">
                    <div>model · ${provider.model_api_name ?? provider.model_id ?? '-'}</div>
                    <div>default · ${provider.is_default_runtime ? 'yes' : 'no'}</div>
                    <div>transport · ${provider.runtime_kind ?? provider.transport ?? '-'}</div>
                    <div>ctx · ${formatNumber(provider.max_context)}</div>
                    <div>http · ${fmtProbeHttpStatus(liveProbe)}</div>
                    <div>latency · ${fmtProbeLatency(liveProbe)}</div>
                    <div>models · ${formatNumber(runtimeProviderModelCount(provider, liveProbe))}</div>
                    <div>auth · ${runtimeProviderAuthText(provider, liveProbe)}</div>
                  </div>
                  ${snapshotFacts
                    ? html`<div class="truncate text-2xs text-[var(--color-fg-muted)]" title=${snapshotFacts}>
                        snapshot · ${snapshotFacts}
                      </div>`
                    : null}
                  ${liveProbe?.probe_url || provider.endpoint_url
                    ? html`<div class="truncate text-2xs text-[var(--color-fg-muted)]" title=${liveProbe?.probe_url ?? provider.endpoint_url ?? ''}>
                        probe · ${liveProbe?.probe_url ?? provider.endpoint_url}
                      </div>`
                    : null}
                  ${parameterPolicy
                    ? html`<div class="truncate text-2xs text-[var(--color-fg-muted)]" title=${parameterPolicy}>
                        params · ${parameterPolicy}
                      </div>`
                    : null}
                  ${requestConfig
                    ? html`<div class="truncate text-2xs text-[var(--color-fg-muted)]" title=${requestConfig}>
                        request · ${requestConfig}
                      </div>`
                    : null}
                  ${declaredSpec
                    ? html`<div class="truncate text-2xs text-[var(--color-fg-muted)]" title=${declaredSpec}>
                        declared · ${declaredSpec}
                      </div>`
                    : null}
                  ${effectiveCapabilities
                    ? html`<div class="truncate text-2xs text-[var(--color-fg-muted)]" title=${effectiveCapabilities}>
                        effective · ${effectiveCapabilities}
                      </div>`
                    : null}
                  ${parameterDetails.length > 0
                    ? html`<div
                        class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-x-4 gap-y-1 pt-2 border-t border-[var(--color-border-default)]/50 text-2xs"
                        aria-label="runtime parameter detail"
                      >
                        ${parameterDetails.map(row => html`
                          <div class="min-w-0 flex gap-1">
                            <span class="shrink-0 text-[var(--color-fg-muted)]">${row.axis} · ${row.label}</span>
                            <span class="min-w-0 break-words text-[var(--color-fg-secondary)]" title=${row.value}>
                              ${row.value}
                            </span>
                          </div>
                        `)}
                      </div>`
                    : null}
                  ${liveProbe?.error
                    ? html`<div class="text-2xs text-[var(--status-bad)]">${liveProbe.error}</div>`
                    : null}
                  ${provider.discovery
                    ? html`<div class="grid grid-cols-2 gap-3 text-xs text-[var(--color-fg-secondary)] pt-2 border-t border-[var(--color-border-default)]/50">
                        <div>discovery · ${provider.discovery.healthy ? 'healthy' : 'degraded'}</div>
                        <div class="min-w-0 truncate" title=${provider.discovery.discovered_model ?? MISSING_DATA_DASH}>
                          discovered · ${provider.discovery.discovered_model ?? MISSING_DATA_DASH}
                        </div>
                        <div>ctx · ${formatNumber(provider.discovery.ctx_size)}</div>
                        <div>slots · ${formatNumber(provider.discovery.busy_slots)}/${formatNumber(provider.discovery.total_slots)}</div>
                        <div>idle · ${formatNumber(provider.discovery.idle_slots)}</div>
                      </div>`
                    : null}
                </article>
              `})
            : html`<${EmptyState} message="runtime snapshot이 없습니다." compact />`}
        </div>
      <//>

      <${SectionCard} label="런타임 메트릭">
        <div class="grid grid-cols-3 gap-3 mb-4">
          <${StatTile}
            label="텔레메트리 윈도우"
            value=${`${metrics?.window_minutes ?? windowMinutes.value}m`}
            delta=${{ direction: 'flat', text: `항목 ${formatNumber(metrics?.total_entries ?? 0)}` }}
          />
          <${StatTile}
            label="추적 중인 런타임"
            value=${String(metrics?.models.length ?? 0)}
            delta=${{ direction: 'flat', text: `오류 ${formatNumber(metrics?.total_error_entries ?? 0)}` }}
          />
          <${StatTile}
            label="총 비용"
            value=${formatCost(sumNullable((metrics?.models ?? []).map(m => m.total_cost_usd)))}
            delta=${{ direction: 'flat', text: `${formatNumber(metrics?.models.reduce((sum, m) => sum + (m.total_tool_calls ?? 0), 0))} tool calls` }}
          />
        </div>
        <div class="flex items-center justify-end mb-2">
          <${TextInput}
            type="search"
            ariaLabel="런타임 도구 검색"
            placeholder="도구 이름"
            class="min-w-55 flex-1 !py-1 !text-2xs"
            value=${modelSearch.value}
            onInput=${(e: Event) => { modelSearch.value = (e.target as HTMLInputElement).value }}
          />
        </div>
        ${(metrics?.models ?? []).length > 0 && filteredModels.length === 0
          ? html`<div class="text-2xs text-[var(--color-fg-muted)] mb-2">검색 결과 없음 (${metrics?.models.length ?? 0}개 중)</div>`
          : null}
        <div class="flex flex-col gap-3">
          ${(metrics?.models ?? []).length > 0
            ? sortedModels.map(metric => {
                const isFailing = (metric.error_count ?? 0) > 0
                const hasCoverageGap =
                  metric.coverage_status === 'none'
                  || metric.coverage_status === 'partial'
                  || metric.coverage_status === 'error_only'
                let articleClass = 'v2-monitoring-card p-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]/40 backdrop-blur-sm flex flex-col gap-2'
                if (isFailing) {
                  articleClass = 'v2-monitoring-card p-4 rounded-[var(--r-1)] border border-[var(--status-bad)] bg-[var(--status-bad)]/5 backdrop-blur-sm flex flex-col gap-2'
                } else if (hasCoverageGap) {
                  articleClass = 'v2-monitoring-card p-4 rounded-[var(--r-1)] border border-[var(--status-warn)] bg-[var(--status-warn)]/5 backdrop-blur-sm flex flex-col gap-2'
                }
                const runtimeLabel = metric.model_id
                const ariaLabel = isFailing
                  ? `Runtime failing: ${runtimeLabel}, ${metric.error_count ?? 0} errors out of ${metric.entry_count ?? 0}`
                  : undefined
                return html`
                <article
                  key=${metric.model_id}
                  class=${articleClass}
                  role=${isFailing ? 'alert' : undefined}
                  aria-label=${ariaLabel}
                >
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <div class="grid gap-1">
                      <strong class="text-sm text-[var(--color-fg-primary)]">${runtimeLabel}</strong>
                      <span class="text-xs text-[var(--color-fg-muted)]">entries ${formatNumber(metric.entry_count)} · fallback ${formatNumber(metric.fallback_count)}</span>
                      ${metricCoverageText(metric)
                        ? html`<span class="text-2xs ${hasCoverageGap ? 'text-[var(--status-warn)]' : 'text-[var(--color-fg-muted)]'}">${metricCoverageText(metric)}</span>`
                        : null}
                    </div>
                    <div class="flex gap-2 items-center">
                      ${metric.coverage_status
                        ? html`<${StatusChip}
                            label=${coverageStatusLabel(metric.coverage_status) ?? metric.coverage_status}
                            tone=${metricCoverageTone(metric)}
                          />`
                        : null}
                      <${StatusChip}
                        label=${`${fmtSuccessRate(metric)}`}
                        tone=${modelMetricTone(metric)}
                      />
                      ${metric.avg_tok_per_sec != null
                        ? html`<${StatusChip}
                            label=${`${formatNumber(metric.avg_tok_per_sec, 1)} tok/s wall`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.prompt_avg_tok_per_sec != null
                        ? html`<${StatusChip}
                            label=${`${formatNumber(metric.prompt_avg_tok_per_sec, 1)} tok/s prefill`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.hw_decode_avg_tok_per_sec != null
                        ? html`<${StatusChip}
                            label=${`${formatNumber(metric.hw_decode_avg_tok_per_sec, 1)} tok/s hw`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.thinking_fraction != null
                        ? html`<${StatusChip}
                            label=${`think ${formatNumber((metric.thinking_fraction ?? 0) * 100, 0)}%`}
                            tone=${(metric.thinking_fraction ?? 0) > 0.5 ? 'warn' : 'ok'}
                          />`
                        : null}
                    </div>
                  </div>
                  <div class="grid grid-cols-3 gap-3 text-xs text-[var(--color-fg-secondary)]">
                    <div>latency avg/p95 · ${fmtCoverageAwareNumber(metric, metric.avg_latency_ms, 1)} / ${fmtCoverageAwareNumber(metric, metric.p95_latency_ms, 1)} ms</div>
                    <div>wall tok/s p50/p95 · ${fmtCoverageAwareNumber(metric, metric.p50_tok_per_sec, 1)} / ${fmtCoverageAwareNumber(metric, metric.p95_tok_per_sec, 1)}</div>
                    <div>cost · ${fmtCoverageAwareCost(metric, metric.total_cost_usd)}</div>
                    <div>input/output · ${fmtCoverageAwareNumber(metric, metric.total_input_tokens)} / ${fmtCoverageAwareNumber(metric, metric.total_output_tokens)}</div>
                    <div>reasoning/cache · ${fmtCoverageAwareNumber(metric, metric.total_reasoning_tokens)} / ${fmtCoverageAwareNumber(metric, metric.total_cache_read_tokens)}</div>
                    <div>tools · ${formatNumber(metric.avg_tool_calls_per_turn, 1)}/turn (${formatNumber(metric.total_tool_calls)})</div>
                    ${metric.prompt_p50_tok_per_sec != null || metric.prompt_p95_tok_per_sec != null
                      ? html`<div class="col-span-3 text-[var(--color-fg-muted)]">prefill tok/s p50/p95 · ${formatNumber(metric.prompt_p50_tok_per_sec, 1)} / ${formatNumber(metric.prompt_p95_tok_per_sec, 1)} (prompt_eval only; complements wall + hw rows)</div>`
                      : null}
                    ${metric.hw_decode_p50_tok_per_sec != null
                      ? html`<div class="col-span-3 text-[var(--color-fg-muted)]">hw tok/s p50/p95 · ${formatNumber(metric.hw_decode_p50_tok_per_sec, 1)} / ${formatNumber(metric.hw_decode_p95_tok_per_sec, 1)} (decode-only; excludes queue/prefill/thinking)</div>`
                      : null}
                  </div>
                  ${(() => {
                    const latencySeries = (metric.buckets ?? [])
                      .map(b => b.p95_latency_ms)
                      .filter((value): value is number => typeof value === 'number' && !Number.isNaN(value))
                    const errorSeries = (metric.buckets ?? [])
                      .map(b => b.error_rate)
                      .filter((value): value is number => typeof value === 'number' && !Number.isNaN(value))
                    if (latencySeries.length < 2 || errorSeries.length < 2) return null
                    return html`<div class="flex items-center gap-4 mt-1 text-2xs text-[var(--color-fg-muted)]">
                        <span>p95 latency</span>
                        <span aria-hidden="true" dangerouslySetInnerHTML=${{ __html: sparklineSvg(latencySeries, 'var(--status-warn)', 80, 18) }}></span>
                        <span>error rate</span>
                        <span aria-hidden="true" dangerouslySetInnerHTML=${{ __html: sparklineSvg(errorSeries, 'var(--status-bad)', 80, 18) }}></span>
                      </div>`
                  })()}
                  ${(() => {
                    const cacheRead = metric.total_cache_read_tokens
                    const inputTokens = metric.total_input_tokens
                    const hasCacheNumbers =
                      typeof cacheRead === 'number' && typeof inputTokens === 'number'
                    let cacheRatio: number | null = null
                    if (hasCacheNumbers) {
                      const totalTokens = cacheRead + inputTokens
                      cacheRatio = totalTokens > 0 ? cacheRead / totalTokens : 0
                    }
                    const totalIn =
                      hasCacheNumbers
                        ? cacheRead + inputTokens
                        : null
                    return html`<div class="text-2xs text-[var(--color-fg-muted)] mt-1">
                      cost ${fmtCoverageAwareCost(metric, metric.total_cost_usd)} · cache savings ${formatPct1(cacheRatio)} (${fmtCoverageAwareNumber(metric, cacheRead)} / ${fmtCoverageAwareNumber(metric, totalIn)} tokens)
                    </div>`
                  })()}
                  ${(metric.error_count ?? 0) > 0
                    ? html`<div class="text-2xs text-[var(--status-bad)] mt-1">errors ${formatNumber(metric.error_count)} / success ${formatNumber(metric.success_count)}</div>`
                    : null}
                  ${(metric.top_tools ?? []).length > 0
                    ? html`<div class="flex flex-wrap gap-1 mt-1">
                        ${metric.top_tools?.slice(0, 5).map(t => html`
                          <span class="inline-flex items-center px-1.5 py-0.5 rounded-[var(--r-1)] text-3xs bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]">
                            ${t.tool} <span class="ml-0.5 text-[var(--color-fg-secondary)]">${t.count}</span>
                          </span>
                        `)}
                      </div>`
                    : null}
                  ${(metric.recent_entries ?? []).length > 0
                    ? html`
                      <button
                        class="v2-monitoring-action text-2xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)] mt-1 text-left"
                        onClick=${() => { expandedModel.value = expandedModel.value === metric.model_id ? null : metric.model_id }}
                      >
                        ${expandedModel.value === metric.model_id ? '▾' : '▸'} recent ${metric.recent_entries?.length ?? 0} turns
                      </button>
                      ${expandedModel.value === metric.model_id
                        ? html`<div class="mt-1 border-t border-[var(--color-border-default)]/50 pt-2">
                            <${Table}
                              columns=${recentEntryColumns}
                              rows=${metric.recent_entries ?? []}
                              getRowId=${(re: RecentEntry) => `${metric.model_id}-${re.ts_unix}`}
                            />
                          </div>`
                        : null}
                    `
                    : null}
                </article>
              `
              })
            : html`<${EmptyState} message="최근 runtime inference metrics가 없습니다." compact />`}
        </div>
      <//>
    </div>
  `
}
