import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperConfig } from '../types'
import type { KeeperConfigLoadStatus } from './keeper-config-state'

// Mutable test state, hoisted so the mock factories below can close over it.
const refs = vi.hoisted(() => ({
  config: null as unknown,
  status: 'loaded' as string,
  providers: vi.fn(),
  resolved: vi.fn(),
  load: vi.fn(),
  // Spy for the deep-link tab focus. The card is read-only; it no longer writes
  // runtime_id — it only opens the config modal pre-focused on the 런타임 tab.
  focusTab: vi.fn(),
}))

// [patchKeeperConfig] is no longer exercised by this card (the write path moved to
// the config modal), but keeper-config-panel — loaded below via [vi.importActual] —
// still imports it at module scope, so the mock must provide it.
vi.mock('../api/dashboard', () => ({
  patchKeeperConfig: vi.fn(),
  fetchRuntimeProviders: refs.providers,
  fetchRuntimeResolved: refs.resolved,
  fetchKeeperConfig: vi.fn(),
  fetchDashboardGoalsTree: vi.fn(),
}))

// Keep the real keeper-config-panel (via ...actual) so [keeperRuntimeConfigCanWrite]
// gates on the driven config; override the shared-config accessors and the tab
// focus so each test drives state directly and can assert the deep-link target.
vi.mock('./keeper-config-panel', async () => {
  const actual = await vi.importActual<typeof import('./keeper-config-panel')>('./keeper-config-panel')
  return {
    ...actual,
    peekLoadedKeeperConfig: (_name: string) => refs.config as KeeperConfig | null,
    peekKeeperConfigLoadStatus: (_name: string) => refs.status as KeeperConfigLoadStatus,
    loadKeeperConfig: refs.load,
    focusKeeperConfigTab: refs.focusTab,
  }
})

vi.mock('./common/toast', () => ({ showToast: vi.fn() }))

import { KeeperRuntimeModelEditor } from './keeper-runtime-model-editor'
import { resetRuntimeResolved } from '../lib/runtime-resolved-resource'
import type { RuntimeResolvedResponse } from '../api/dashboard'
import { resetRuntimeCatalog } from '../lib/runtime-catalog-resource'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

// Partial config carrying only the fields the card reads. The single cast is
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
          argv_prompt_preflight: false,
          uses_anthropic_caching: false,
          max_turns_per_attempt: null,
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

// Minimal RuntimeResolvedResponse fixture — only [assignments] drives the
// badge under test here; the other fields are exercised by
// runtime-resolved.ts's own schema tests.
function makeRuntimeResolved(
  overrides: Partial<RuntimeResolvedResponse> = {},
): RuntimeResolvedResponse {
  return {
    config_path: '/cfg/runtime.toml',
    default_runtime: null,
    runtimes: [],
    lanes: [],
    assignments: [],
    ...overrides,
  }
}

describe('KeeperRuntimeModelEditor (read-only card)', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    resetRuntimeCatalog()
    container = document.createElement('div')
    document.body.appendChild(container)
    refs.config = null
    refs.status = 'loaded'
    refs.providers.mockReset()
    refs.providers.mockResolvedValue({
      providers: [
        makeRuntimeProvider('a.one', 'Provider A', 'claude'),
        makeRuntimeProvider('b.two', 'Provider B', 'model-b'),
      ],
    })
    refs.resolved.mockReset()
    refs.resolved.mockResolvedValue(makeRuntimeResolved())
    resetRuntimeResolved()
    refs.load.mockReset()
    refs.focusTab.mockReset()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetRuntimeCatalog()
    resetRuntimeResolved()
  })

  it('renders the current runtime + catalog summary read-only, with no editable <select>', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    render(
      html`<${KeeperRuntimeModelEditor} keeperName="editable-keeper" onOpenRuntimeConfig=${vi.fn()} />`,
      container,
    )
    await flush()
    await flush()

    // Regression guard: the duplicate write UI (a runtime <select> that patched
    // runtime_id) must be gone. The config modal now owns the single write path.
    expect(container.querySelector('select[aria-label="runtime"]')).toBeNull()
    expect(Array.from(container.querySelectorAll('button')).some(b => b.textContent?.includes('저장'))).toBe(false)

    // Still surfaces the current assignment + read-only catalog facts.
    expect(container.textContent).toContain('런타임')
    expect(container.textContent).toContain('a.one')
    expect(container.textContent).toContain('Provider A')
    expect(container.textContent).toContain('claude')
    expect(container.textContent).toContain('caps:declared')
    expect(container.textContent).toContain('api:chat-completions')
  })

  it('sources the reasoning-budget pill from effective_capabilities, not the top-level snapshot field', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    const base = makeRuntimeProvider('a.one', 'Provider A', 'claude')
    refs.providers.mockReset()
    refs.providers.mockResolvedValue({
      providers: [
        {
          ...base,
          // Top-level field says "off" — this is the runtime.toml-mirrored,
          // wire-inert value. If the pill still read it, this test would fail.
          supports_reasoning_budget: false,
          effective_capabilities: {
            ...base.effective_capabilities,
            supports_reasoning_budget: true,
          },
        },
        makeRuntimeProvider('b.two', 'Provider B', 'model-b'),
      ],
    })
    render(
      html`<${KeeperRuntimeModelEditor} keeperName="editable-keeper" onOpenRuntimeConfig=${vi.fn()} />`,
      container,
    )
    await flush()
    await flush()

    const pill = Array.from(container.querySelectorAll('span')).find(node =>
      node.textContent?.trim().startsWith('reasoning-budget'),
    )
    expect(pill?.textContent).toContain('reasoning-budget on')
  })

  it('renders a missing effective capability as unknown instead of off', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    const base = makeRuntimeProvider('a.one', 'Provider A', 'claude')
    refs.providers.mockReset()
    refs.providers.mockResolvedValue({
      providers: [
        {
          ...base,
          supports_reasoning_budget: false,
          effective_capabilities: null,
        },
      ],
    })

    render(
      html`<${KeeperRuntimeModelEditor} keeperName="unknown-capability-keeper" />`,
      container,
    )
    await flush()
    await flush()

    const pill = Array.from(container.querySelectorAll('span')).find(node =>
      node.textContent?.trim().startsWith('reasoning-budget'),
    )
    expect(pill?.getAttribute('data-capability-state')).toBe('unknown')
    expect(pill?.textContent).toContain('reasoning-budget unknown')
    expect(pill?.textContent).not.toContain('reasoning-budget off')
  })

  it('deep-links to the 설정 런타임 tab: focuses runtime then invokes onOpenRuntimeConfig', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    const onOpen = vi.fn()
    render(
      html`<${KeeperRuntimeModelEditor} keeperName="deeplink-keeper" onOpenRuntimeConfig=${onOpen} />`,
      container,
    )
    await flush()

    const link = Array.from(container.querySelectorAll('button')).find(b =>
      b.textContent?.includes('설정에서 변경'),
    )
    expect(link).toBeTruthy()
    link!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    // The card owns the tab target (런타임) and delegates opening to the host.
    expect(refs.focusTab).toHaveBeenCalledWith('runtime')
    expect(onOpen).toHaveBeenCalledTimes(1)
  })

  it('hides the deep-link when no host wires onOpenRuntimeConfig (still read-only)', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    render(html`<${KeeperRuntimeModelEditor} keeperName="unwired-keeper" />`, container)
    await flush()

    expect(Array.from(container.querySelectorAll('button')).some(b =>
      b.textContent?.includes('설정에서 변경'),
    )).toBe(false)
    // Content is still there — the card degrades to pure display.
    expect(container.textContent).toContain('a.one')
    expect(container.querySelector('select[aria-label="runtime"]')).toBeNull()
  })

  it('shows an actionable read-only hint (no deep-link) for a non-toml keeper', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' }, { default_source_kind: 'persona', default_manifest_path: null })
    render(
      html`<${KeeperRuntimeModelEditor} keeperName="persona-keeper" onOpenRuntimeConfig=${vi.fn()} />`,
      container,
    )
    await flush()

    expect(container.querySelector('select[aria-label="runtime"]')).toBeNull()
    // Non-toml sources cannot be written from the config modal either, so the
    // card explains the runtime.toml path instead of deep-linking.
    expect(container.textContent).toContain('편집 가능한 TOML 소스가 아니')
    expect(container.textContent).toContain('runtime.toml')
    expect(container.textContent).toContain('[runtime.assignments]')
    expect(Array.from(container.querySelectorAll('button')).some(b =>
      b.textContent?.includes('설정에서 변경'),
    )).toBe(false)
    // Catalog facts still render for observability.
    expect(container.textContent).toContain('caps:declared')
    expect(container.textContent).toContain('api:chat-completions')
  })

  it('renders a loading state until the config is available', async () => {
    refs.config = null
    refs.status = 'loading'
    render(html`<${KeeperRuntimeModelEditor} keeperName="loading-keeper" />`, container)
    await flush()
    expect(container.textContent).toContain('불러오는 중')
  })

  // The settings→routing "Keeper assignments" panel used to be the only place
  // showing whether a keeper's runtime came from an explicit
  // [runtime.assignments] entry or the [runtime].default rider. Deleting that
  // panel must not lose the fact — this card now surfaces it via
  // GET /api/v1/runtime/resolved (assignments), read-only.
  it('shows an explicit assignment_source badge for a keeper with a [runtime.assignments] entry', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    refs.resolved.mockResolvedValue(makeRuntimeResolved({
      assignments: [
        { keeper: 'explicit-keeper', assignment_source: 'explicit', resolved: { kind: 'single_runtime', id: 'a.one' } },
      ],
    }))
    render(
      html`<${KeeperRuntimeModelEditor} keeperName="explicit-keeper" onOpenRuntimeConfig=${vi.fn()} />`,
      container,
    )
    await flush()
    await flush()

    const badge = container.querySelector('[data-testid="keeper-runtime-assignment-source"]')
    expect(badge?.textContent?.trim()).toBe('explicit → a.one')
    expect(badge?.getAttribute('data-assignment-source')).toBe('explicit')
    expect(badge?.getAttribute('data-assignment-target-kind')).toBe('single_runtime')
  })

  it('shows a default assignment_source badge for a keeper riding [runtime].default with no explicit entry', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    refs.resolved.mockResolvedValue(makeRuntimeResolved({
      assignments: [
        { keeper: 'default-rider', assignment_source: 'default', resolved: { kind: 'single_runtime', id: 'a.one' } },
      ],
    }))
    render(
      html`<${KeeperRuntimeModelEditor} keeperName="default-rider" onOpenRuntimeConfig=${vi.fn()} />`,
      container,
    )
    await flush()
    await flush()

    const badge = container.querySelector('[data-testid="keeper-runtime-assignment-source"]')
    expect(badge?.textContent?.trim()).toBe('default → a.one')
  })

  it('surfaces a missing assignment projection instead of hiding it', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    refs.resolved.mockResolvedValue(makeRuntimeResolved({ assignments: [] }))
    render(
      html`<${KeeperRuntimeModelEditor} keeperName="unlisted-keeper" onOpenRuntimeConfig=${vi.fn()} />`,
      container,
    )
    await flush()
    await flush()

    expect(container.querySelector('[data-testid="keeper-runtime-assignment-source"]')).toBeNull()
    expect(container.querySelector('[data-testid="keeper-runtime-assignment-missing"]')?.textContent)
      .toContain('assignment projection에 Keeper가 없습니다')
  })

  it('surfaces a runtime-resolved fetch error instead of rendering an absent badge', async () => {
    refs.config = makeConfig({ selected_runtime_id: 'a.one' })
    refs.resolved.mockRejectedValue(new Error('runtime resolved unavailable'))
    render(
      html`<${KeeperRuntimeModelEditor} keeperName="error-keeper" onOpenRuntimeConfig=${vi.fn()} />`,
      container,
    )
    await flush()
    await flush()

    expect(container.querySelector('[data-testid="keeper-runtime-assignment-error"]')?.textContent)
      .toContain('runtime resolved unavailable')
  })
})
