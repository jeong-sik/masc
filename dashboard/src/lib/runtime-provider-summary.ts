import type { DashboardRuntimeProviderSnapshot } from '../api/dashboard'

function nonEmptyParts(parts: Array<string | null | undefined>): string[] {
  return parts.filter((value): value is string => Boolean(value))
}

function runtimeSnapshotPromptCache(item: DashboardRuntimeProviderSnapshot): string | null {
  if (item.supports_prompt_caching !== true) return null
  return `prompt-cache${typeof item.prompt_cache_alignment === 'number' ? `@${item.prompt_cache_alignment}` : ''}`
}

export function runtimeCatalogSnapshotFacts(item: DashboardRuntimeProviderSnapshot): string | null {
  const modelCount = typeof item.model_count === 'number'
    ? item.model_count
    : item.models.length > 0
      ? item.models.length
      : null
  const note = item.note?.trim()
  const formats = nonEmptyParts([
    item.supports_response_format_json ? 'json' : null,
    item.supports_structured_output ? 'schema' : null,
  ])
  const sampling = nonEmptyParts([
    item.supports_top_k ? 'top_k' : null,
    item.supports_min_p ? 'min_p' : null,
    item.supports_seed ? 'seed' : null,
  ])
  const controls = nonEmptyParts([
    item.supports_tool_choice ? 'tool-choice' : null,
    item.supports_required_tool_choice ? 'required' : null,
    item.supports_named_tool_choice ? 'named' : null,
    item.supports_parallel_tool_calls ? 'parallel' : null,
    item.supports_extended_thinking ? 'extended-thinking' : null,
    item.supports_native_streaming ? 'native-stream' : null,
    item.supports_system_prompt ? 'system-prompt' : null,
    item.supports_caching ? 'cache' : null,
    runtimeSnapshotPromptCache(item),
    item.supports_seed_with_images ? 'seed+images' : null,
    item.emits_usage_tokens ? 'usage' : null,
    item.supports_computer_use ? 'computer-use' : null,
    item.supports_code_execution ? 'code-exec' : null,
  ])
  const parts = nonEmptyParts([
    item.source ? `source:${item.source}` : null,
    typeof modelCount === 'number' ? `models:${modelCount}` : null,
    typeof item.max_context === 'number' ? `ctx:${item.max_context}` : null,
    typeof item.max_output_tokens === 'number' ? `out:${item.max_output_tokens}` : null,
    typeof item.temperature === 'number' ? `model-temp:${item.temperature}` : null,
    typeof item.capabilities_declared === 'boolean'
      ? `caps:${item.capabilities_declared ? 'declared' : 'missing'}`
      : null,
    formats.length > 0 ? `format:${formats.join(',')}` : null,
    sampling.length > 0 ? `sampling:${sampling.join(',')}` : null,
    typeof item.supports_multimodal_inputs === 'boolean'
      ? `multimodal:${item.supports_multimodal_inputs ? 'on' : 'off'}`
      : null,
    typeof item.supports_image_input === 'boolean' ? `image:${item.supports_image_input ? 'on' : 'off'}` : null,
    typeof item.supports_audio_input === 'boolean' ? `audio:${item.supports_audio_input ? 'on' : 'off'}` : null,
    typeof item.supports_video_input === 'boolean' ? `video:${item.supports_video_input ? 'on' : 'off'}` : null,
    typeof item.supports_reasoning_budget === 'boolean'
      ? `reasoning-budget:${item.supports_reasoning_budget ? 'on' : 'off'}`
      : null,
    controls.length > 0 ? `controls:${controls.join(',')}` : null,
    note ? `note:${note}` : null,
  ])
  return parts.length > 0 ? parts.join(' · ') : null
}

export function runtimeCatalogParameterPolicy(item: DashboardRuntimeProviderSnapshot): string | null {
  const policy = item.parameter_policy
  if (!policy) return null
  const ignored = policy.ignored_sampling_params.join(',')
  const alwaysIgnored = policy.always_ignored_sampling_params.join(',')
  const parts = nonEmptyParts([
    policy.reasoning_toggle_wire ? `wire:${policy.reasoning_toggle_wire}` : null,
    policy.reasoning_replay_policy ? `replay:${policy.reasoning_replay_policy}` : null,
    policy.requires_reasoning_replay_on_tool_call ? 'tool-call-replay:required' : null,
    ignored ? `ignore:${ignored}` : null,
    alwaysIgnored ? `always:${alwaysIgnored}` : null,
  ])
  return parts.length > 0 ? parts.join(' · ') : null
}

function runtimeCatalogRequestToolChoice(item: DashboardRuntimeProviderSnapshot): string | null {
  const choice = item.request_config?.tool_choice
  if (!choice?.kind) return null
  return choice.name ? `${choice.kind}:${choice.name}` : choice.kind
}

function runtimeCatalogRequestFormat(item: DashboardRuntimeProviderSnapshot): string | null {
  const format = item.request_config?.response_format
  if (!format?.kind) return null
  return format.has_schema ? `${format.kind}+schema` : format.kind
}

export function runtimeCatalogRequestConfig(item: DashboardRuntimeProviderSnapshot): string | null {
  const request = item.request_config
  if (!request) return null
  const sampling = nonEmptyParts([
    typeof request.temperature === 'number' ? `temp:${request.temperature}` : null,
    typeof request.top_p === 'number' ? `top_p:${request.top_p}` : null,
    typeof request.top_k === 'number' ? `top_k:${request.top_k}` : null,
    typeof request.min_p === 'number' ? `min_p:${request.min_p}` : null,
  ])
  const toolChoice = runtimeCatalogRequestToolChoice(item)
  const format = runtimeCatalogRequestFormat(item)
  const requestPath = request.request_path_targets_responses_api
    ? 'responses-api'
    : request.request_path
      ? `path:${request.request_path}`
      : null
  const parts = nonEmptyParts([
    request.provider_kind ? `kind:${request.provider_kind}` : null,
    request.source ? `source:${request.source}` : null,
    requestPath,
    typeof request.max_tokens === 'number' ? `out:${request.max_tokens}` : null,
    typeof request.max_context === 'number' ? `ctx:${request.max_context}` : null,
    sampling.length > 0 ? `sampling:${sampling.join(',')}` : null,
    request.has_system_prompt ? 'system-prompt' : null,
    typeof request.enable_thinking === 'boolean' ? `think:${request.enable_thinking ? 'on' : 'off'}` : null,
    typeof request.preserve_thinking === 'boolean' ? `preserve:${request.preserve_thinking ? 'on' : 'off'}` : null,
    typeof request.clear_thinking === 'boolean' ? `clear:${request.clear_thinking ? 'on' : 'off'}` : null,
    typeof request.thinking_budget === 'number' ? `budget:${request.thinking_budget}` : null,
    request.resolved_reasoning_effort ? `effort:${request.resolved_reasoning_effort}` : null,
    request.glm_clear_thinking ? 'glm:clear' : null,
    request.glm_replay_reasoning ? 'glm:replay' : null,
    typeof request.tool_stream === 'boolean' ? `tool-stream:${request.tool_stream ? 'on' : 'off'}` : null,
    toolChoice ? `tool:${toolChoice}` : null,
    request.disable_parallel_tool_use ? 'parallel:off' : null,
    format ? `format:${format}` : null,
    request.has_output_schema ? 'output-schema' : null,
    request.cache_system_prompt ? 'cache-system' : null,
    typeof request.supports_tool_choice_override === 'boolean'
      ? `tool-override:${request.supports_tool_choice_override ? 'on' : 'off'}`
      : null,
    typeof request.supports_structured_output_override === 'boolean'
      ? `schema-override:${request.supports_structured_output_override ? 'on' : 'off'}`
      : null,
    request.has_model_capabilities_override ? 'cap-override' : null,
    typeof request.seed === 'number' ? `seed:${request.seed}` : null,
    typeof request.internal_model_rotation_count === 'number'
      ? `rotation:${request.internal_model_rotation_count}`
      : null,
    typeof request.num_ctx === 'number' ? `num_ctx:${request.num_ctx}` : null,
    request.keep_alive ? `keep:${request.keep_alive}` : null,
    request.has_previous_response_id ? 'previous-response' : null,
    typeof request.connect_timeout_s === 'number' ? `connect:${request.connect_timeout_s}s` : null,
  ])
  return parts.length > 0 ? parts.join(' · ') : null
}

export function runtimeCatalogDeclaredSpec(item: DashboardRuntimeProviderSnapshot): string | null {
  const spec = item.declared_spec
  if (!spec) return null
  const caps = spec.model?.capabilities
  const sampling = nonEmptyParts([
    caps?.supports_top_k ? 'top_k' : null,
    caps?.supports_min_p ? 'min_p' : null,
    caps?.supports_seed ? 'seed' : null,
  ])
  const inputs = nonEmptyParts([
    caps?.supports_multimodal_inputs ? 'multimodal' : null,
    caps?.supports_image_input ? 'image' : null,
    caps?.supports_audio_input ? 'audio' : null,
    caps?.supports_video_input ? 'video' : null,
  ])
  const formats = nonEmptyParts([
    caps?.supports_response_format_json ? 'json' : null,
    caps?.supports_structured_output ? 'schema' : null,
  ])
  const behavior = spec.provider?.behavior_capabilities
  const behaviorParts = behavior
    ? nonEmptyParts([
        behavior.supports_inline_tools ? 'inline-tools' : null,
        behavior.requires_per_keeper_bridging_for_bound_actor_tools ? 'keeper-bridge' : null,
        behavior.argv_prompt_preflight ? 'argv-preflight' : null,
        behavior.uses_anthropic_caching ? 'anthropic-cache' : null,
        typeof behavior.max_turns_per_attempt === 'number' ? `max-turns:${behavior.max_turns_per_attempt}` : null,
        behavior.tolerates_bound_actor_fallback ? 'bound-fallback' : null,
        behavior.identity_runtime_mcp_header_keys.length > 0
          ? `mcp-headers:${behavior.identity_runtime_mcp_header_keys.join(',')}`
          : null,
      ])
    : []
  const controls = nonEmptyParts([
    caps?.supports_tool_choice ? 'tool-choice' : null,
    caps?.supports_required_tool_choice ? 'required' : null,
    caps?.supports_named_tool_choice ? 'named' : null,
    caps?.supports_parallel_tool_calls ? 'parallel' : null,
    caps?.supports_extended_thinking ? 'extended-thinking' : null,
    caps?.supports_reasoning_budget ? 'reasoning-budget' : null,
    caps?.supports_native_streaming ? 'native-stream' : null,
    caps?.supports_system_prompt ? 'system-prompt' : null,
    caps?.supports_caching ? 'cache' : null,
    caps?.supports_prompt_caching
      ? `prompt-cache${typeof caps.prompt_cache_alignment === 'number' ? `@${caps.prompt_cache_alignment}` : ''}`
      : null,
    caps?.supports_seed_with_images ? 'seed+images' : null,
    caps?.emits_usage_tokens ? 'usage' : null,
    caps?.supports_computer_use ? 'computer-use' : null,
    caps?.supports_code_execution ? 'code-exec' : null,
  ])
  let thinking: string | null = null
  if (typeof spec.model?.thinking_support === 'boolean') {
    thinking = spec.model.thinking_support ? 'think:on' : 'think:off'
  }
  const parts = nonEmptyParts([
    spec.provider?.api_format ? `api:${spec.provider.api_format}` : null,
    spec.provider?.protocol ? `protocol:${spec.provider.protocol}` : null,
    spec.provider?.transport ? `transport:${spec.provider.transport}` : null,
    spec.provider?.auth_kind ? `auth:${spec.provider.auth_kind}` : null,
    spec.provider?.is_non_interactive ? 'non-interactive' : null,
    typeof spec.provider?.custom_header_count === 'number' ? `headers:${spec.provider.custom_header_count}` : null,
    typeof spec.provider?.connect_timeout_s === 'number' ? `connect:${spec.provider.connect_timeout_s}s` : null,
    behaviorParts.length > 0 ? `behavior:${behaviorParts.join(',')}` : null,
    typeof spec.model?.max_context === 'number' ? `ctx:${spec.model.max_context}` : null,
    typeof spec.model?.temperature === 'number' ? `temp:${spec.model.temperature}` : null,
    typeof spec.model?.tools_support === 'boolean' ? `tools:${spec.model.tools_support ? 'on' : 'off'}` : null,
    typeof spec.model?.streaming === 'boolean' ? `stream:${spec.model.streaming ? 'on' : 'off'}` : null,
    typeof spec.model?.preserve_thinking === 'boolean'
      ? `preserve:${spec.model.preserve_thinking ? 'on' : 'off'}`
      : null,
    thinking,
    typeof spec.model?.max_thinking_budget === 'number' ? `budget:${spec.model.max_thinking_budget}` : null,
    caps?.thinking_control_format ? `wire:${caps.thinking_control_format}` : null,
    typeof caps?.max_output_tokens === 'number' ? `out:${caps.max_output_tokens}` : null,
    formats.length > 0 ? `format:${formats.join(',')}` : null,
    inputs.length > 0 ? `input:${inputs.join(',')}` : null,
    sampling.length > 0 ? `sampling:${sampling.join(',')}` : null,
    controls.length > 0 ? `controls:${controls.join(',')}` : null,
    spec.model?.match_prefixes.length ? `match:${spec.model.match_prefixes.join(',')}` : null,
    spec.binding?.is_default ? 'default' : null,
    typeof spec.binding?.max_concurrent === 'number' ? `concurrency:${spec.binding.max_concurrent}` : null,
    typeof spec.binding?.price_input === 'number' ? `price-in:${spec.binding.price_input}` : null,
    typeof spec.binding?.price_output === 'number' ? `price-out:${spec.binding.price_output}` : null,
    spec.binding?.keep_alive ? `keep:${spec.binding.keep_alive}` : null,
    typeof spec.binding?.num_ctx === 'number' ? `num_ctx:${spec.binding.num_ctx}` : null,
  ])
  return parts.length > 0 ? parts.join(' · ') : null
}

export function runtimeCatalogEffectiveCapabilities(item: DashboardRuntimeProviderSnapshot): string | null {
  const caps = item.effective_capabilities
  if (!caps) return null
  const sampling = nonEmptyParts([
    caps.supports_top_k ? 'top_k' : null,
    caps.supports_min_p ? 'min_p' : null,
    caps.supports_seed ? 'seed' : null,
  ])
  const context = typeof caps.max_context_tokens === 'number' ? `ctx:${caps.max_context_tokens}` : null
  const output = typeof caps.max_output_tokens === 'number' ? `out:${caps.max_output_tokens}` : null
  const format = nonEmptyParts([
    caps.supports_response_format_json ? 'json' : null,
    caps.supports_structured_output ? 'schema' : null,
  ])
  const toolChoice = caps.supports_tool_choice
    ? `tool-choice${nonEmptyParts([
      caps.supports_required_tool_choice ? 'required' : null,
      caps.supports_named_tool_choice ? 'named' : null,
      caps.supports_parallel_tool_calls ? 'parallel' : null,
    ]).map(flag => `+${flag}`).join('')}`
    : null
  const parts = nonEmptyParts([
    context,
    output,
    caps.supports_tools ? 'tools' : null,
    toolChoice,
    caps.supports_runtime_mcp_tools ? 'runtime-mcp-tools' : null,
    caps.supports_runtime_tool_events ? 'runtime-tool-events' : null,
    format.length > 0 ? `format:${format.join(',')}` : null,
    sampling.length > 0 ? `sampling:${sampling.join(',')}` : null,
    caps.modality_priority ? `modality:${caps.modality_priority}` : null,
    caps.assistant_tool_content_format ? `tool-content:${caps.assistant_tool_content_format}` : null,
    caps.supports_reasoning ? 'reasoning' : null,
    caps.supports_extended_thinking ? 'extended-thinking' : null,
    caps.supports_reasoning_budget ? 'reasoning-budget' : null,
    caps.accepted_reasoning_efforts && caps.accepted_reasoning_efforts.length > 0
      ? `effort:${caps.accepted_reasoning_efforts.join(',')}`
      : null,
    caps.preserve_thinking_control_format ? `preserve:${caps.preserve_thinking_control_format}` : null,
    caps.reasoning_output_format ? `reasoning-out:${caps.reasoning_output_format}` : null,
    caps.reasoning_streaming_format?.kind ? `reasoning-stream:${caps.reasoning_streaming_format.kind}` : null,
    caps.reasoning_replay_override ? `replay:${caps.reasoning_replay_override}` : null,
    caps.task ? `task:${caps.task}` : null,
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
    caps.supported_models && caps.supported_models.length > 0 ? `models:${caps.supported_models.length}` : null,
  ])
  return parts.length > 0 ? parts.join(' · ') : null
}
