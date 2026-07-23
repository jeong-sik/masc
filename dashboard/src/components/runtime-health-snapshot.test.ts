// @vitest-environment happy-dom
import { h } from 'preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardRuntimeProbe: vi.fn(),
  fetchRuntimeProviders: vi.fn(),
}))

vi.mock('../api/dashboard', () => apiMocks)

async function waitFor(assertion: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 30; i += 1) {
    if (assertion()) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error(`Timed out waiting for ${label}`)
}

function providerPayload(overrides: Record<string, unknown> = {}) {
  return {
    updated_at: '2026-06-06T07:24:08Z',
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
        model_api_name: 'Qwen/Qwen3-32B',
        transport: 'http',
        runtime_kind: 'http',
        status: 'configured',
        available: true,
        is_default_runtime: true,
        models: ['Qwen/Qwen3-32B'],
        endpoint_url: 'https://runpod.example/v1',
        effective_capabilities: {
          source: 'provider_config',
          max_context_tokens: 32768,
          max_output_tokens: 8192,
          supports_tools: true,
          supports_tool_choice: true,
          supports_required_tool_choice: true,
          supports_named_tool_choice: false,
          supports_parallel_tool_calls: true,
          supports_runtime_mcp_tools: true,
          supports_runtime_tool_events: true,
          supports_response_format_json: true,
          supports_structured_output: true,
          supports_top_k: true,
          supports_min_p: false,
          supports_seed: true,
          ignored_sampling_parameters: ['min_p'],
          supports_multimodal_inputs: true,
          supports_image_input: true,
          supports_audio_input: true,
          supports_video_input: false,
          modality_priority: 'visual-first',
          assistant_tool_content_format: 'content-array',
          supports_reasoning: true,
          supports_extended_thinking: true,
          supports_reasoning_budget: true,
          accepted_reasoning_efforts: ['low', 'medium', 'high'],
          thinking_control_format: 'chat-template-kwargs',
          preserve_thinking_control_format: 'chat-template-kwargs-preserve-thinking',
          reasoning_output_format: 'reasoning_content',
          reasoning_streaming_format: { kind: 'delta_field', field: 'reasoning_content' },
          reasoning_replay_override: 'provider_policy',
          task: 'code',
          supports_native_streaming: true,
          supports_system_prompt: true,
          supports_prompt_caching: true,
          prompt_cache_alignment: 1024,
          supports_caching: true,
          supports_seed_with_images: true,
          supports_computer_use: false,
          supports_code_execution: true,
          emits_usage_tokens: true,
          supported_models: ['Qwen/Qwen3-32B'],
        },
        declared_spec: {
          provider: {
            api_format: 'openai_compat',
            protocol: 'http',
            transport: 'http',
            auth_kind: 'bearer',
            is_non_interactive: true,
            custom_header_count: 1,
            connect_timeout_s: 30,
            behavior_capabilities: {
              supports_inline_tools: true,
              argv_prompt_preflight: false,
              uses_anthropic_caching: false,
            },
          },
          model: {
            max_context: 32768,
            temperature: 0.2,
            tools_support: true,
            streaming: true,
            preserve_thinking: true,
            thinking_support: true,
            max_thinking_budget: 4096,
            match_prefixes: ['Qwen/'],
            capabilities: {
              thinking_control_format: 'chat-template-kwargs',
              max_output_tokens: 8192,
              supports_response_format_json: true,
              supports_structured_output: true,
              supports_multimodal_inputs: true,
              supports_image_input: true,
              supports_audio_input: true,
              supports_video_input: false,
              supports_top_k: true,
              supports_min_p: false,
              supports_seed: true,
              supports_tool_choice: true,
              supports_required_tool_choice: true,
              supports_named_tool_choice: false,
              supports_parallel_tool_calls: true,
              supports_extended_thinking: true,
              supports_reasoning_budget: true,
              supports_native_streaming: true,
              supports_system_prompt: true,
              supports_caching: true,
              supports_prompt_caching: true,
              prompt_cache_alignment: 1024,
              supports_seed_with_images: true,
              emits_usage_tokens: true,
              supports_computer_use: false,
              supports_code_execution: true,
            },
          },
          binding: {
            is_default: true,
            max_concurrent: 2,
            price_input: 0.2,
            price_output: 0.6,
            keep_alive: '5m',
            num_ctx: 32768,
          },
        },
        request_config: {
          provider_kind: 'openai_compat',
          source: 'runtime.toml',
          request_path: '/chat/completions',
          request_path_targets_responses_api: false,
          max_tokens: 8192,
          max_context: 32768,
          temperature: 0.2,
          top_p: 0.8,
          top_k: 40,
          min_p: 0.05,
          has_system_prompt: true,
          enable_thinking: true,
          preserve_thinking: true,
          clear_thinking: false,
          thinking_budget: 4096,
          resolved_reasoning_effort: 'medium',
          glm_clear_thinking: false,
          glm_replay_reasoning: false,
          tool_stream: true,
          tool_choice: { kind: 'auto' },
          disable_parallel_tool_use: false,
          response_format: { kind: 'json_schema', has_schema: true },
          has_output_schema: true,
          cache_system_prompt: true,
          supports_tool_choice_override: true,
          supports_structured_output_override: true,
          has_model_capabilities_override: true,
          seed: 7,
          internal_model_rotation_count: 1,
          num_ctx: 32768,
          keep_alive: '5m',
          has_previous_response_id: false,
          connect_timeout_s: 30,
        },
        parameter_policy: {
          reasoning_toggle_wire: 'enable_thinking',
          reasoning_replay_policy: 'preserve',
          requires_reasoning_replay_on_tool_call: true,
          ignored_sampling_params: ['min_p'],
          always_ignored_sampling_params: ['frequency_penalty'],
        },
        ...overrides,
      },
    ],
  }
}

function probePayload(overrides: Record<string, unknown> = {}) {
  return {
    generated_at: '2026-06-06T07:24:08Z',
    cache_hit: false,
    probe: {
      source: 'runtime.toml',
      status: 'reachable',
      checked_at: '2026-06-06T07:24:08Z',
      probe_ok: true,
      server_url: 'https://runpod.example/v1',
      ps_endpoint: 'https://runpod.example/v1/models',
      generate_endpoint: 'https://runpod.example/v1/chat/completions',
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
          latency_ms: 42,
          credential_required: true,
          auth_present: true,
          probe_url: 'https://runpod.example/v1/models',
        },
      ],
      ...overrides,
    },
  }
}

describe('RuntimeHealthSnapshot', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.resetModules()
    apiMocks.fetchRuntimeProviders.mockReset().mockResolvedValue(providerPayload())
    apiMocks.fetchDashboardRuntimeProbe.mockReset().mockResolvedValue(probePayload())
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
  })

  it('surfaces live reachability, default runtime, and probe endpoints on the first screen', async () => {
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('runpod_mtp.qwen') ?? false,
      'default runtime',
    )

    expect(container.textContent).toContain('런타임 상태 체크')
    expect(container.textContent).toContain('1 reachable')
    expect(container.textContent).toContain('default runtime')
    expect(container.textContent).toContain('ready')
    expect(container.textContent).toContain('https://runpod.example/v1')
    expect(container.textContent).toContain('default runtime spec')
    expect(container.textContent).toContain('source:provider_config')
    expect(container.textContent).toContain('input:multimodal,image,audio')
    expect(container.textContent).toContain('wire:chat-template-kwargs')
    expect(container.textContent).toContain('policy')
    expect(container.textContent).toContain('provider details')
    expect(container.textContent).toContain('runtime.toml')
    expect(container.textContent).toContain('transport health')
    const endpointCards = container.querySelectorAll('[data-testid="runtime-health-endpoints"] .v2-monitoring-card')
    expect(endpointCards.length).toBeGreaterThan(0)
  })

  it('does not hide failed live probe details behind the full runtime monitor', async () => {
    apiMocks.fetchDashboardRuntimeProbe.mockResolvedValueOnce(probePayload({
      status: 'network_error',
      probe_ok: false,
      summary: {
        runtimes: 1,
        probed: 1,
        reachable: 0,
        failed: 1,
        skipped: 0,
        default_runtime_id: 'runpod_mtp.qwen',
      },
      providers: [
        {
          runtime_id: 'runpod_mtp.qwen',
          provider_id: 'runpod_mtp',
          status: 'network_error',
          reachable: false,
          credential_required: true,
          auth_present: true,
          error: 'connect ECONNREFUSED 127.0.0.1:3000',
          probe_url: 'https://runpod.example/v1/models',
        },
      ],
    }))
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('1 failing') ?? false,
      'failed probe summary',
    )

    expect(container.textContent).toContain('needs attention')
    expect(container.textContent).toContain('network_error')
    expect(container.textContent).toContain('connect ECONNREFUSED 127.0.0.1:3000')
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('runpod_mtp.qwen')
  })

  it('keeps provider config visible when the live probe request itself fails', async () => {
    apiMocks.fetchDashboardRuntimeProbe.mockRejectedValueOnce(new Error('500 Internal Server Error: Eio mutex poisoned'))
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('live probe request failed') ?? false,
      'probe request failure',
    )

    expect(container.textContent).toContain('runpod_mtp.qwen')
    expect(container.textContent).toContain('needs attention')
    expect(container.textContent).toContain('500 Internal Server Error: Eio mutex poisoned')
  })

  it('surfaces runtime assignment status warnings on the first screen', async () => {
    apiMocks.fetchRuntimeProviders.mockResolvedValueOnce({
      ...providerPayload(),
      assignment_status: {
        schema: 'masc.runtime_assignment_status.v1',
        source: 'runtime.toml',
        status: 'degraded',
        degraded: true,
        operator_action_required: true,
        blast_radius: 'single_runtime_assignment_pin',
        assignment_count: 2,
        assigned_runtime_count: 1,
        default_assignment_count: 0,
        default_runtime_id: 'runpod_mtp.qwen',
        librarian_runtime_id: null,
        warnings: ['explicit_assignments_present', 'single_runtime_assignment_pin'],
        assigned_runtimes: ['openai.gpt'],
        assignments: [
          { keeper: 'budgettest', runtime_id: 'openai.gpt', matches_default: false },
          { keeper: 'routingtest', runtime_id: 'openai.gpt', matches_default: false },
        ],
      },
    })
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('runtime assignment status') ?? false,
      'assignment status warning',
    )

    expect(container.textContent).toContain('runtime assignment review')
    expect(container.textContent).toContain('2 explicit')
    expect(container.textContent).toContain('assigned runtimes: openai.gpt')
    expect(container.textContent).toContain('single_runtime_assignment_pin')
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('runtime assignment status')
  })

  it('surfaces startup catalog degradation on the first screen', async () => {
    apiMocks.fetchRuntimeProviders.mockResolvedValueOnce({
      ...providerPayload(),
      startup_degradation: {
        schema: 'masc.runtime_startup_degradation.v1',
        status: 'degraded',
        degraded: true,
        operator_action_required: true,
        terminal_reason: 'missing_oas_catalog_models',
        message: 'runtime catalog degraded boot',
        config_path: '/tmp/masc-test/runtime.toml',
        configured_default_runtime_id: 'glm-coding.glm-5-turbo',
        effective_default_runtime_id: 'glm-coding.glm-5-turbo',
        missing_catalog_model_count: 2,
        missing_catalog_models: [
          {
            runtime_id: 'mimo.mimo-v2.5-pro',
            provider_id: 'mimo',
            provider_label: 'openai_compat',
            model_id: 'mimo-v2.5-pro',
          },
          {
            runtime_id: 'mimo.mimo-v2.5',
            provider_id: 'mimo',
            provider_label: 'openai_compat',
            model_id: 'mimo-v2.5',
          },
        ],
        disabled_runtime_ids: ['mimo.mimo-v2.5-pro', 'mimo.mimo-v2.5'],
        dropped_assignments: [],
        dropped_routes: [],
        dropped_media_failover: [],
        dropped_lane_candidates: [],
        dropped_lanes: [],
        next_action: 'Add deployment rows to oas-models-overlay.toml (or upstream OAS).',
      },
    })
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('runtime startup degraded') ?? false,
      'startup degradation warning',
    )

    expect(container.textContent).toContain('startup')
    expect(container.textContent).toContain('2 catalog gaps')
    expect(container.textContent).toContain('missing_oas_catalog_models')
    expect(container.textContent).toContain('effective default: glm-coding.glm-5-turbo')
    expect(container.textContent).toContain('disabled runtimes: mimo.mimo-v2.5-pro, mimo.mimo-v2.5')
    expect(container.textContent).toContain('missing catalog: mimo.mimo-v2.5-pro, mimo.mimo-v2.5')
    expect(container.textContent).toContain('next: Add deployment rows to oas-models-overlay.toml (or upstream OAS).')
  })

  it('uses force=1 when the operator clicks Live probe', async () => {
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => apiMocks.fetchDashboardRuntimeProbe.mock.calls[0]?.[0] === false,
      'initial unforced probe',
    )

    container.querySelector('button')?.click()
    await waitFor(
      () => apiMocks.fetchDashboardRuntimeProbe.mock.calls.length >= 2,
      'forced refresh',
    )

    expect(apiMocks.fetchDashboardRuntimeProbe.mock.calls[0]?.[0]).toBe(false)
    expect(apiMocks.fetchDashboardRuntimeProbe.mock.calls.at(-1)?.[0]).toBe(true)
  })
})
