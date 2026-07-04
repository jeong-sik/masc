// @vitest-environment happy-dom
import { h } from 'preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardRuntimeProbe: vi.fn(),
  fetchRuntimeProviders: vi.fn(),
  fetchRuntimeModelMetrics: vi.fn(),
}))

vi.mock('../api/dashboard', () => apiMocks)

async function waitFor(assertion: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 20; i += 1) {
    if (assertion()) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error(`Timed out waiting for ${label}`)
}

describe('RuntimeMonitor', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.resetModules()
    apiMocks.fetchRuntimeProviders.mockReset().mockResolvedValue({
      updated_at: '2026-05-13T13:00:00Z',
      summary: {
        providers: 1,
        runtimes: 1,
        local_models: 0,
        cloud_models: 1,
        cli_models: 0,
        default_runtime_id: 'runpod_mtp.qwen',
      },
      providers: [
        {
          provider: 'runpod_mtp.qwen',
          runtime_id: 'runpod_mtp.qwen',
          provider_id: 'runpod_mtp',
          provider_display_name: 'RunPod MTP',
          model_id: 'qwen',
          model_api_name: 'Qwen/Qwen3-32B',
          protocol: 'openai-http',
          transport: 'http',
          kind: 'cloud',
          runtime_kind: 'http',
          auth_kind: 'env:RUNPOD_API_KEY',
          status: 'configured',
          available: true,
          is_default_runtime: true,
          max_context: 200000,
          tools_support: true,
          streaming: true,
          model_count: 1,
          models: ['Qwen/Qwen3-32B'],
          parameter_policy: {
            reasoning_toggle_wire: 'chat_template_kwargs',
            reasoning_replay_policy: 'preserve_always',
            requires_reasoning_replay_on_tool_call: true,
            ignored_sampling_params: ['temperature', 'top_p'],
            always_ignored_sampling_params: ['temperature'],
          },
          request_config: {
            source: 'oas-provider-config',
            provider_kind: 'openai_compat',
            request_path: '/chat/completions',
            request_path_targets_responses_api: false,
            max_tokens: 65536,
            max_context: 131072,
            temperature: null,
            top_p: null,
            top_k: 40,
            min_p: 0.05,
            has_system_prompt: true,
            enable_thinking: true,
            preserve_thinking: false,
            thinking_budget: 32768,
            clear_thinking: true,
            resolved_reasoning_effort: 'high',
            glm_clear_thinking: true,
            glm_replay_reasoning: true,
            tool_stream: true,
            tool_choice: { kind: 'required' },
            disable_parallel_tool_use: true,
            response_format: { kind: 'json_schema', has_schema: true },
            has_output_schema: true,
            cache_system_prompt: true,
            supports_tool_choice_override: true,
            supports_structured_output_override: false,
            has_model_capabilities_override: true,
            keep_alive: '30m',
            internal_model_rotation_count: 2,
            num_ctx: 131072,
            seed: 42,
            has_previous_response_id: true,
            connect_timeout_s: 120,
          },
          effective_capabilities: {
            source: 'oas-provider-config-model',
            max_context_tokens: 131072,
            max_output_tokens: 65536,
            supports_tools: true,
            supports_tool_choice: true,
            supports_required_tool_choice: true,
            supports_named_tool_choice: true,
            supports_parallel_tool_calls: true,
            supports_runtime_mcp_tools: true,
            supports_runtime_tool_events: true,
            assistant_tool_content_format: 'null',
            supports_reasoning: true,
            supports_extended_thinking: true,
            supports_reasoning_budget: true,
            accepted_reasoning_efforts: ['low', 'medium', 'high'],
            thinking_control_format: 'chat-template-kwargs',
            preserve_thinking_control_format: 'chat-template-kwargs-preserve-thinking',
            reasoning_output_format: 'split-reasoning-fields',
            reasoning_streaming_format: {
              kind: 'delta-reasoning-field',
              field: 'reasoning_content',
            },
            reasoning_replay_override: 'preserve-always',
            supports_response_format_json: true,
            supports_structured_output: true,
            supports_multimodal_inputs: true,
            supports_image_input: true,
            supports_audio_input: true,
            supports_video_input: false,
            modality_priority: 'visual-first',
            task: 'transcription',
            supports_native_streaming: true,
            supports_system_prompt: true,
            supports_caching: true,
            supports_prompt_caching: true,
            prompt_cache_alignment: 1024,
            supports_top_k: true,
            supports_min_p: true,
            supports_seed: true,
            supports_seed_with_images: true,
            supports_computer_use: true,
            supports_code_execution: true,
            emits_usage_tokens: true,
            supported_models: ['Qwen/Qwen3-32B'],
          },
          declared_spec: {
            source: 'runtime.toml',
            provider: {
              id: 'runpod_mtp',
              display_name: 'RunPod MTP',
              protocol: 'openai-compatible-http',
              api_format: 'chat-completions',
              transport: 'http',
              auth_kind: 'env:RUNPOD_API_KEY',
              is_non_interactive: true,
              has_capabilities: true,
              behavior_capabilities: {
                supports_inline_tools: true,
                requires_per_keeper_bridging_for_bound_actor_tools: true,
                identity_runtime_mcp_header_keys: ['x-masc-keeper'],
                argv_prompt_preflight: true,
                uses_anthropic_caching: true,
                max_turns_per_attempt: 3,
                tolerates_bound_actor_fallback: true,
              },
              custom_header_count: 2,
              connect_timeout_s: 120,
            },
            model: {
              id: 'qwen',
              api_name: 'Qwen/Qwen3-32B',
              tools_support: true,
              max_context: 128000,
              thinking_support: true,
              preserve_thinking: false,
              max_thinking_budget: 32768,
              streaming: true,
              temperature: 0.65,
              capabilities: {
                source: 'runtime.toml',
                max_output_tokens: 65536,
                supports_tool_choice: true,
                supports_required_tool_choice: true,
                supports_named_tool_choice: true,
                supports_parallel_tool_calls: true,
                supports_extended_thinking: true,
                supports_reasoning_budget: true,
                thinking_control_format: 'chat-template-kwargs',
                supports_image_input: true,
                supports_audio_input: true,
                supports_video_input: false,
                supports_multimodal_inputs: true,
                supports_response_format_json: true,
                supports_structured_output: true,
                supports_native_streaming: true,
                supports_system_prompt: true,
                supports_caching: true,
                supports_prompt_caching: true,
                prompt_cache_alignment: 1024,
                supports_top_k: true,
                supports_min_p: true,
                supports_seed: true,
                supports_seed_with_images: true,
                emits_usage_tokens: true,
                supports_computer_use: true,
                supports_code_execution: true,
              },
              match_prefixes: ['Qwen/'],
            },
            binding: {
              provider_id: 'runpod_mtp',
              model_id: 'qwen',
              is_default: true,
              max_concurrent: 4,
              price_input: 0.1,
              price_output: 0.2,
              keep_alive: '30m',
              num_ctx: 131072,
            },
          },
          source: 'runtime.toml',
          endpoint_url: 'https://example.invalid/v1',
          note: null,
          discovery: {
            healthy: true,
            ctx_size: 200000,
            total_slots: 4,
            busy_slots: 1,
            idle_slots: 3,
          },
        },
      ],
    })
    apiMocks.fetchRuntimeModelMetrics.mockReset().mockResolvedValue({
      window_minutes: 30,
      bucket_minutes: 5,
      total_entries: 0,
      total_error_entries: 0,
      latency_buckets: [],
      models: [],
    })
    apiMocks.fetchDashboardRuntimeProbe.mockReset().mockResolvedValue({
      generated_at: '2026-06-06T02:47:31Z',
      refreshed_at_unix: 1780714051,
      cache_ttl_sec: 30,
      cache_age_sec: 0,
      cache_hit: false,
      probe: {
        source: 'runtime.toml',
        status: 'reachable',
        checked_at: '2026-06-06T02:47:31Z',
        probe_ok: true,
        summary: {
          runtimes: 1,
          probed: 1,
          reachable: 1,
          failed: 0,
          skipped: 0,
          default_runtime_id: 'runpod_mtp.qwen',
        },
        providers: [
          {
            runtime_id: 'runpod_mtp.qwen',
            provider_id: 'runpod_mtp',
            model_api_name: 'Qwen/Qwen3-32B',
            status: 'reachable',
            reachable: true,
            http_status: 200,
            latency_ms: 42.5,
            model_count: 1,
            credential_required: true,
            auth_present: true,
            probe_url: 'https://example.invalid/v1/models',
          },
        ],
        errors: [],
      },
    })
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('shows runtime.toml binding identity on provider status cards', async () => {
    const { RuntimeMonitor } = await import('./runtime-monitor')

    render(h(RuntimeMonitor, {}), container)
    await waitFor(
      () => container.textContent?.includes('runpod_mtp.qwen') ?? false,
      'runtime binding',
    )

    expect(container.textContent).toContain('runpod_mtp.qwen')
    expect(container.textContent).toContain('runpod_mtp')
    expect(container.textContent).toContain('Qwen/Qwen3-32B')
  })

  it('separates configured inventory from live provider reachability', async () => {
    const { RuntimeMonitor } = await import('./runtime-monitor')

    render(h(RuntimeMonitor, {}), container)
    await waitFor(
      () => container.textContent?.includes('runpod_mtp.qwen') ?? false,
      'live reachability summary',
    )

    expect(container.textContent).toContain('available')
    expect(container.textContent).toContain('live reachable')
    expect(container.textContent).toContain('http · 200')
    expect(container.textContent).toContain('latency · 42.5 ms')
    expect(container.textContent).toContain('models · 1')
    expect(container.textContent).toContain('auth · present')
    expect(container.querySelector('article.v2-monitoring-card')).not.toBeNull()
  })

  it('surfaces declared and effective provider/model parameter facts', async () => {
    const { RuntimeMonitor } = await import('./runtime-monitor')

    render(h(RuntimeMonitor, {}), container)
    await waitFor(
      () => container.textContent?.includes('runpod_mtp.qwen') ?? false,
      'runtime parameter facts',
    )

    expect(container.textContent).toContain('params · wire chat_template_kwargs')
    expect(container.textContent).toContain('request · kind openai_compat')
    expect(container.textContent).toContain('preserve off')
    expect(container.textContent).toContain('glm replay')
    expect(container.textContent).toContain('tool stream on')
    expect(container.textContent).toContain('schema override off')
    expect(container.textContent).toContain('rotation 2')
    expect(container.textContent).toContain('declared · api chat-completions')
    expect(container.textContent).toContain('auth env:RUNPOD_API_KEY')
    expect(container.textContent).toContain('behavior inline-tools,keeper-bridge,argv-preflight,anthropic-cache')
    expect(container.textContent).toContain(
      'controls tool-choice,required,named,parallel,native-stream,system-prompt,cache,prompt-cache@1024,seed+images,usage,computer-use,code-exec',
    )
    expect(container.textContent).toContain('price-in 0.1')
    expect(container.textContent).toContain('effective · out 65,536')
    expect(container.textContent).toContain('runtime-mcp-tools')
    expect(container.textContent).toContain('reasoning · extended · budget · effort low,medium,high')
    expect(container.textContent).toContain('reasoning-stream delta-reasoning-field')
    expect(container.textContent).toContain('modality visual-first')
    expect(container.textContent).toContain('tool-content null')
    expect(container.textContent).toContain('preserve chat-template-kwargs-preserve-thinking')
    expect(container.textContent).toContain('task transcription')
    expect(container.textContent).toContain('seed+images')
    expect(container.textContent).toContain('code-exec')
  })

  it('renders parameter facts as structured request declared and effective rows', async () => {
    const { RuntimeMonitor } = await import('./runtime-monitor')

    render(h(RuntimeMonitor, {}), container)
    await waitFor(
      () => container.textContent?.includes('runpod_mtp.qwen') ?? false,
      'runtime parameter detail rows',
    )

    expect(container.querySelector('[aria-label="runtime parameter detail"]')).not.toBeNull()
    expect(container.textContent).toContain('policy · replay on tool call')
    expect(container.textContent).toContain('required')
    expect(container.textContent).toContain('request · source')
    expect(container.textContent).toContain('oas-provider-config')
    expect(container.textContent).toContain('request · system prompt')
    expect(container.textContent).toContain('declared provider · capabilities block')
    expect(container.textContent).toContain('declared model · capability source')
    expect(container.textContent).toContain('binding · provider.model')
    expect(container.textContent).toContain('runpod_mtp,qwen')
    expect(container.textContent).toContain('effective · source')
    expect(container.textContent).toContain('oas-provider-config-model')
    expect(container.textContent).toContain('effective · max context')
    expect(container.textContent).toContain('131,072')
    expect(container.textContent).toContain('effective · tools')
    expect(container.textContent).toContain('tools,tool-choice,required,named,parallel,runtime-mcp,runtime-events')
    expect(container.textContent).toContain('effective · reasoning')
    expect(container.textContent).toContain('reasoning,extended,budget,effort low,medium,high')
    expect(container.textContent).toContain('effective · thinking wire')
    expect(container.textContent).toContain('chat-template-kwargs')
    expect(container.textContent).toContain('effective · preserve wire')
    expect(container.textContent).toContain('chat-template-kwargs-preserve-thinking')
    expect(container.textContent).toContain('effective · modality priority')
    expect(container.textContent).toContain('visual-first')
    expect(container.textContent).toContain('effective · tool content')
    expect(container.textContent).toContain('null')
    expect(container.textContent).toContain('effective · task')
    expect(container.textContent).toContain('transcription')
  })
})
