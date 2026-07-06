import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperConfig } from '../types'
import type { KeeperConfigLoadStatus } from './keeper-detail-source'

// Mutable test state, hoisted so the mock factories below can close over it.
const refs = vi.hoisted(() => ({
  config: null as unknown,
  status: 'loaded' as string,
  patch: vi.fn(),
  providers: vi.fn(),
  applied: vi.fn(),
  load: vi.fn(),
}))

// Only [patchKeeperConfig] is exercised; the other two satisfy keeper-config-panel's
// real module-level imports when [vi.importActual] loads it below.
vi.mock('../api/dashboard', () => ({
  patchKeeperConfig: refs.patch,
  fetchRuntimeProviders: refs.providers,
  fetchKeeperConfig: vi.fn(),
  fetchDashboardGoalsTree: vi.fn(),
}))

// Keep the real [InlineSelectRow] (via ...actual); override the shared-config
// accessors so each test drives the loaded config directly.
vi.mock('./keeper-config-panel', async () => {
  const actual = await vi.importActual<typeof import('./keeper-config-panel')>('./keeper-config-panel')
  return {
    ...actual,
    peekLoadedKeeperConfig: (_name: string) => refs.config as KeeperConfig | null,
    peekKeeperConfigLoadStatus: (_name: string) => refs.status as KeeperConfigLoadStatus,
    loadKeeperConfig: refs.load,
    applyKeeperConfigUpdate: refs.applied,
  }
})

vi.mock('./common/toast', () => ({ showToast: vi.fn() }))

import { KeeperRuntimeModelEditor, canEditRuntime, uniqueNonEmpty } from './keeper-runtime-model-editor'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

// Partial config carrying only the fields the editor reads. The single cast is
// confined to this helper; the component never sees an untyped value.
function makeConfig(
  execution: Partial<KeeperConfig['execution']> = {},
  sources: Partial<KeeperConfig['sources']> = {},
): KeeperConfig {
  return {
    execution: {
      selected_runtime_id: 'a.one',
      selected_runtime_canonical: 'a.one',
      runtime_options: ['a.one', 'b.two'],
      ...execution,
    },
    sources: {
      default_source_kind: 'toml',
      default_manifest_path: '/tmp/config/keepers/echo.toml',
      ...sources,
    },
  } as unknown as KeeperConfig
}

function makeRuntimeProvider(runtimeId: string, providerName: string, modelName: string) {
  return {
    provider: runtimeId,
    runtime_id: runtimeId,
    provider_id: runtimeId.split('.')[0],
    provider_display_name: providerName,
    model_id: runtimeId.split('.')[1],
    model_api_name: modelName,
    protocol: 'openai-http',
    transport: 'http',
    runtime_kind: 'cloud',
    auth_kind: 'env',
    status: 'configured',
    available: true,
    max_context: 128000,
    tools_support: true,
    thinking_support: true,
    streaming: true,
    capabilities_declared: true,
    max_output_tokens: 8192,
    supports_tool_choice: true,
    supports_required_tool_choice: true,
    supports_named_tool_choice: true,
    supports_parallel_tool_calls: true,
    supports_extended_thinking: true,
    supports_multimodal_inputs: true,
    supports_image_input: true,
    supports_audio_input: false,
    supports_video_input: false,
    supports_reasoning_budget: true,
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
    supports_computer_use: false,
    supports_code_execution: true,
    source: 'runtime.toml',
    effective_capabilities: {
      source: 'oas-provider-config-model',
      max_context_tokens: 128000,
      max_output_tokens: 8192,
      supports_tools: true,
      supports_tool_choice: true,
      supports_required_tool_choice: true,
      supports_named_tool_choice: true,
      supports_parallel_tool_calls: true,
      supports_runtime_mcp_tools: true,
      supports_runtime_tool_events: true,
      assistant_tool_content_format: 'empty-string',
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
      task: 'chat',
      supports_native_streaming: true,
      supports_system_prompt: true,
      supports_caching: true,
      supports_prompt_caching: true,
      prompt_cache_alignment: 1024,
      supports_top_k: true,
      supports_min_p: true,
      supports_seed: true,
      supports_seed_with_images: true,
      ignored_sampling_parameters: ['temperature', 'top_p'],
      supports_computer_use: false,
      supports_code_execution: true,
      emits_usage_tokens: true,
      supported_models: ['claude'],
    },
    parameter_policy: {
      reasoning_toggle_wire: 'responses.reasoning',
      reasoning_replay_policy: 'preserve',
      requires_reasoning_replay_on_tool_call: true,
      ignored_sampling_params: ['top_k'],
      always_ignored_sampling_params: ['min_p'],
    },
    request_config: {
      source: 'runtime.toml',
      provider_kind: 'cloud',
      request_path: '/v1/responses',
      request_path_targets_responses_api: true,
      max_tokens: 8192,
      max_context: 128000,
      temperature: 0.2,
      top_p: 0.9,
      top_k: 40,
      min_p: 0.05,
      has_system_prompt: true,
      enable_thinking: true,
      preserve_thinking: true,
      thinking_budget: 4096,
      resolved_reasoning_effort: 'high',
      tool_stream: true,
      tool_choice: { kind: 'required', name: 'inspect' },
      response_format: { kind: 'json_schema', has_schema: true },
      has_output_schema: true,
      cache_system_prompt: true,
      seed: 7,
      connect_timeout_s: 30,
    },
    declared_spec: {
      source: 'runtime.toml',
      provider: {
        id: runtimeId.split('.')[0],
        display_name: providerName,
        protocol: 'openai-compatible-http',
        api_format: 'chat-completions',
        transport: 'http',
        auth_kind: 'env:RUNTIME_API_KEY',
        is_non_interactive: true,
        has_capabilities: true,
        behavior_capabilities: {
          supports_inline_tools: true,
          requires_per_keeper_bridging_for_bound_actor_tools: true,
          identity_runtime_mcp_header_keys: ['x-masc-keeper'],
          argv_prompt_preflight: false,
          uses_anthropic_caching: false,
          max_turns_per_attempt: null,
          tolerates_bound_actor_fallback: false,
        },
        custom_header_count: 1,
        connect_timeout_s: 30,
      },
      model: {
        id: runtimeId.split('.')[1],
        api_name: modelName,
        tools_support: true,
        max_context: 128000,
        thinking_support: true,
        preserve_thinking: true,
        max_thinking_budget: 4096,
        streaming: true,
        temperature: 0.2,
        capabilities: {
          source: 'runtime.toml',
          supports_tool_choice: true,
          supports_required_tool_choice: true,
          supports_named_tool_choice: true,
          supports_parallel_tool_calls: true,
          supports_extended_thinking: true,
          supports_reasoning_budget: true,
          thinking_control_format: 'chat-template-kwargs',
          supports_response_format_json: true,
          supports_structured_output: true,
          supports_multimodal_inputs: true,
          supports_image_input: true,
          supports_audio_input: true,
          supports_video_input: false,
          supports_native_streaming: true,
          supports_system_prompt: true,
          supports_caching: true,
          supports_prompt_caching: true,
          prompt_cache_alignment: 1024,
          supports_top_k: true,
          supports_min_p: true,
          supports_seed: true,
          supports_seed_with_images: true,
          supports_code_execution: true,
        },
        match_prefixes: [`${modelName}-`],
      },
      binding: {
        provider_id: runtimeId.split('.')[0],
        model_id: runtimeId.split('.')[1],
        is_default: true,
        max_concurrent: 4,
        price_input: 0.1,
        price_output: 0.2,
        keep_alive: '30m',
        num_ctx: 131072,
      },
    },
    models: [modelName],
    endpoint_url: 'https://runtime.example/v1',
  }
}

describe('uniqueNonEmpty', () => {
  it('drops empties and dedupes, preserving first-seen order', () => {
    expect(uniqueNonEmpty(['a.one', '', '  ', 'b.two', 'a.one', ' b.two '])).toEqual(['a.one', 'b.two'])
  })

  it('returns [] for all-empty input', () => {
    expect(uniqueNonEmpty(['', '   '])).toEqual([])
  })
})

describe('canEditRuntime', () => {
  it('is true only for a toml source with a manifest path', () => {
    expect(canEditRuntime(makeConfig({}, { default_source_kind: 'toml', default_manifest_path: '/x.toml' }))).toBe(true)
  })

  it('is false for a persona source', () => {
    expect(canEditRuntime(makeConfig({}, { default_source_kind: 'persona', default_manifest_path: '/x.toml' }))).toBe(false)
  })

  it('is false when the toml manifest path is missing', () => {
    expect(canEditRuntime(makeConfig({}, { default_source_kind: 'toml', default_manifest_path: null }))).toBe(false)
  })
})

describe('KeeperRuntimeModelEditor', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    refs.config = null
    refs.status = 'loaded'
    refs.patch.mockReset()
    refs.providers.mockReset()
    refs.providers.mockResolvedValue({
      providers: [
        makeRuntimeProvider('a.one', 'Provider A', 'claude'),
        makeRuntimeProvider('b.two', 'Provider B', 'model-b'),
      ],
    })
    refs.applied.mockReset()
    refs.load.mockReset()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders an editable model selector for a toml-sourced keeper', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one', runtime_options: ['a.one', 'b.two'] })
    render(html`<${KeeperRuntimeModelEditor} keeperName="editable-keeper" />`, container)
    await flush()

    expect(container.textContent).toContain('런타임')
    expect(container.textContent).toContain('a.one')
    const select = container.querySelector('select[aria-label="runtime"]') as HTMLSelectElement | null
    expect(select).not.toBeNull()
    expect(select!.value).toBe('a.one')
    await flush()
    expect(container.textContent).toContain('Provider A')
    expect(container.textContent).toContain('claude')
    expect(container.textContent).toContain('caps:declared')
    expect(container.textContent).toContain('source:oas-provider-config-model')
    expect(container.textContent).toContain('input:multimodal,image,audio')
    expect(container.textContent).toContain('wire:chat-template-kwargs')
    expect(container.textContent).toContain('reasoning-stream:delta-reasoning-field:reasoning_content')
    expect(container.textContent).toContain('format:json,schema')
    expect(container.textContent).toContain('prompt-cache@1024')
    expect(container.textContent).toContain('declared')
    expect(container.textContent).toContain('api:chat-completions')
    expect(container.textContent).toContain('behavior:inline-tools,keeper-bridge')
    expect(container.textContent).toContain('match:claude-')
    expect(container.textContent).toContain('concurrency:4')
    expect(container.textContent).toContain('wire:responses.reasoning')
    expect(container.textContent).toContain('tool-call-replay:required')
    expect(container.textContent).toContain('responses-api')
    expect(container.textContent).toContain('budget:4096')
  })

  it('patches runtime_id with the selected runtime and updates shared config', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one', runtime_options: ['a.one', 'b.two'] })
    refs.patch.mockResolvedValueOnce(makeConfig({ selected_runtime_id: 'b.two', runtime_options: ['a.one', 'b.two'] }))

    render(html`<${KeeperRuntimeModelEditor} keeperName="patch-keeper" />`, container)
    await flush()

    const select = container.querySelector('select[aria-label="runtime"]') as HTMLSelectElement
    select.value = 'b.two'
    select.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(b => b.textContent?.includes('저장'))
    expect(saveButton).toBeTruthy()
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(refs.patch).toHaveBeenCalledWith('patch-keeper', { runtime_id: 'b.two' })
    expect(refs.applied).toHaveBeenCalledTimes(1)
  })

  it('does not patch when the selection equals the current value', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one', runtime_options: ['a.one', 'b.two'] })
    render(html`<${KeeperRuntimeModelEditor} keeperName="noop-keeper" />`, container)
    await flush()

    // No selection change → save button is disabled and patch is never called.
    const saveButton = Array.from(container.querySelectorAll('button')).find(b => b.textContent?.includes('저장'))
    expect((saveButton as HTMLButtonElement).disabled).toBe(true)
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    expect(refs.patch).not.toHaveBeenCalled()
  })

  it('shows an actionable read-only hint for a non-toml keeper', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' }, { default_source_kind: 'persona', default_manifest_path: null })
    render(html`<${KeeperRuntimeModelEditor} keeperName="persona-keeper" />`, container)
    await flush()

    expect(container.querySelector('select[aria-label="runtime"]')).toBeNull()
    expect(container.textContent).toContain('편집 가능한 TOML 소스가 아니')
    // Hint names the runtime assignment surface so the operator can unlock editing.
    expect(container.textContent).toContain('runtime.toml')
    expect(container.textContent).toContain('[runtime.assignments]')
    expect(container.textContent).toContain('caps:declared')
    expect(container.textContent).toContain('api:chat-completions')
    expect(container.textContent).toContain('behavior:inline-tools,keeper-bridge')
    expect(container.textContent).toContain('responses-api')
  })

  it('clears a pending selection when the viewed keeper changes', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one', runtime_options: ['a.one', 'b.two'] })
    render(html`<${KeeperRuntimeModelEditor} keeperName="keeper-alpha" />`, container)
    await flush()

    const select = container.querySelector('select[aria-label="runtime"]') as HTMLSelectElement
    select.value = 'b.two'
    select.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    expect((container.querySelector('select[aria-label="runtime"]') as HTMLSelectElement).value).toBe('b.two')

    // Navigate to a different keeper: the stale pending 'b.two' must not leak.
    refs.config = makeConfig({ selected_runtime_id: 'c.three', runtime_options: ['c.three', 'b.two'] })
    render(html`<${KeeperRuntimeModelEditor} keeperName="keeper-beta" />`, container)
    await flush()

    expect((container.querySelector('select[aria-label="runtime"]') as HTMLSelectElement).value).toBe('c.three')
  })

  it('renders a loading state until the config is available', async () => {
    refs.config = null
    refs.status = 'loading'
    render(html`<${KeeperRuntimeModelEditor} keeperName="loading-keeper" />`, container)
    await flush()
    expect(container.textContent).toContain('불러오는 중')
  })
})
