import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardRuntimeProviderSnapshot,
  RuntimeTomlEditorProtocol,
} from '../api/dashboard'
import { RuntimeEnvironmentEditor } from './runtime-environment-editor'
import { keepers } from '../store'
import type { Keeper } from '../types/core'

const runtimeCatalogMock = vi.hoisted(() => ({
  state: {
    value: { status: 'idle' } as
      | { status: 'idle' }
      | { status: 'loading' }
      | { status: 'error'; message: string }
      | { status: 'loaded'; data: unknown[] },
  },
  loadRuntimeCatalog: vi.fn(),
}))

const providerProtocols: RuntimeTomlEditorProtocol[] = [
  {
    protocol: 'openai-compatible-http',
    transport: 'endpoint',
    semantics: 'http_provider',
    credential_policy: 'optional',
    requires_non_interactive: false,
    provider_fields: [],
    required_provider_fields: [],
  },
]

vi.mock('../lib/runtime-catalog-resource', () => ({
  findRuntimeCatalogEntry: (
    catalog: readonly { runtime_id?: string | null; provider?: string | null }[],
    runtimeId: string,
  ) => {
    const needle = runtimeId.trim()
    if (needle === '') return null
    return catalog.find(item =>
      [item.runtime_id, item.provider].some(id => id?.trim() === needle),
    ) ?? null
  },
  loadRuntimeCatalog: runtimeCatalogMock.loadRuntimeCatalog,
  runtimeCatalogState: runtimeCatalogMock.state,
}))

afterEach(() => {
  runtimeCatalogMock.state.value = { status: 'idle' }
  runtimeCatalogMock.loadRuntimeCatalog.mockReset()
  keepers.value = []
})

// Regression for the live ~/.masc/config/runtime.toml shape: keeper names
// under [runtime.assignments] are quoted TOML keys. The parser fix lives in
// runtime-toml-config.test.ts; this covers the component actually renders
// the resulting assignments as pinned (not silently defaulted) and grouped.
const sourceTextWithQuotedAssignments = `[runtime]
default = "ollama_cloud.minimax-m3"

[providers.ollama_cloud]
display-name = "Ollama Cloud"
protocol = "openai-compatible-http"
endpoint = "https://ollama.example/v1"

[models.minimax-m3]
api-name = "minimax-m3"
max-context = 128000
tools-support = true
streaming = true

[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"
max-context = 128000
tools-support = true
streaming = true

[ollama_cloud.minimax-m3]

[ollama_cloud.deepseek-v4-flash]

[runtime.assignments]
"nick0cave" = "ollama_cloud.deepseek-v4-flash"
`

const sourceTextWithDefaultPinnedAssignment = sourceTextWithQuotedAssignments.replace(
  '"nick0cave" = "ollama_cloud.deepseek-v4-flash"',
  '"nick0cave" = "ollama_cloud.minimax-m3"',
)

function mountEditor(
  container: HTMLElement,
  options: {
    sourceText?: string
    onAssignmentChange?: (keeperName: string, runtimeId: string | null) => void
  } = {},
) {
  render(
    html`<${RuntimeEnvironmentEditor}
      sourceText=${options.sourceText ?? sourceTextWithQuotedAssignments}
      providerProtocols=${providerProtocols}
      section="assignments"
      onRoutingChange=${() => {}}
      onAssignmentChange=${options.onAssignmentChange ?? (() => {})}
      onBindingFieldChange=${() => {}}
    />`,
    container,
  )
}

describe('RuntimeEnvironmentEditor assignments section', () => {
  it('groups a keeper with an explicit quoted-key assignment as pinned, not default 폴백', () => {
    const fixtureKeepers: Keeper[] = [
      { name: 'nick0cave', status: 'idle' },
      { name: 'issue_king', status: 'idle' },
    ]
    keepers.value = fixtureKeepers

    const container = document.createElement('div')
    mountEditor(container)

    const summary = container.querySelector('[data-testid="runtime-assignments-summary"]')
    expect(summary?.textContent).toContain('고정 1개')
    expect(summary?.textContent).toContain('default 폴백 1개')

    const pinnedGroup = container.querySelector('[data-testid="runtime-assignments-group-pinned"]')
    expect(pinnedGroup?.textContent).toContain('nick0cave')
    expect(pinnedGroup?.textContent).toContain('고정')

    const fallbackGroup = container.querySelector('[data-testid="runtime-assignments-group-fallback"]')
    expect(fallbackGroup?.textContent).toContain('issue_king')
    expect(fallbackGroup?.textContent).toContain('default 폴백')

    render(null, container)
  })

  it('keeps an explicit assignment pinned even when it matches the current default', () => {
    const fixtureKeepers: Keeper[] = [
      { name: 'nick0cave', status: 'idle' },
      { name: 'issue_king', status: 'idle' },
    ]
    keepers.value = fixtureKeepers

    const container = document.createElement('div')
    mountEditor(container, { sourceText: sourceTextWithDefaultPinnedAssignment })

    const summary = container.querySelector('[data-testid="runtime-assignments-summary"]')
    expect(summary?.textContent).toContain('고정 1개')
    expect(summary?.textContent).toContain('default 폴백 1개')

    const pinnedGroup = container.querySelector('[data-testid="runtime-assignments-group-pinned"]')
    expect(pinnedGroup?.textContent).toContain('nick0cave')
    expect(pinnedGroup?.textContent).toContain('고정')
    expect(pinnedGroup?.textContent).toContain('default와 같음')

    const fallbackGroup = container.querySelector('[data-testid="runtime-assignments-group-fallback"]')
    expect(fallbackGroup?.textContent).not.toContain('nick0cave')

    render(null, container)
  })

  it('uses explicit controls for pinning and clearing runtime assignments', () => {
    keepers.value = [
      { name: 'nick0cave', status: 'idle' },
      { name: 'issue_king', status: 'idle' },
    ]
    const onAssignmentChange = vi.fn()

    const container = document.createElement('div')
    mountEditor(container, { onAssignmentChange })

    fireEvent.click(
      container.querySelector(
        '[data-testid="runtime-assignment-issue_king-pin-current"]',
      ) as HTMLButtonElement,
    )
    expect(onAssignmentChange).toHaveBeenLastCalledWith(
      'issue_king',
      'ollama_cloud.minimax-m3',
    )

    fireEvent.change(
      container.querySelector('[aria-label="issue_king 런타임 배정"]') as HTMLSelectElement,
      { target: { value: 'ollama_cloud.deepseek-v4-flash' } },
    )
    expect(onAssignmentChange).toHaveBeenLastCalledWith(
      'issue_king',
      'ollama_cloud.deepseek-v4-flash',
    )

    fireEvent.click(
      container.querySelector(
        '[data-testid="runtime-assignment-nick0cave-clear"]',
      ) as HTMLButtonElement,
    )
    expect(onAssignmentChange).toHaveBeenLastCalledWith('nick0cave', null)

    render(null, container)
  })
})

const sourceWithCapabilities = `[runtime]
default = "ollama_cloud.minimax-m3"

[providers.ollama_cloud]
display-name = "Ollama Cloud"
protocol = "openai-compatible-http"
endpoint = "https://ollama.example/v1"

[models.minimax-m3]
api-name = "minimax-m3"
max-context = 524288
tools-support = true
thinking-support = true
streaming = true

[models.minimax-m3.capabilities]
supports-tool-choice = true
supports-response-format-json = true
supports-structured-output = true
supports-multimodal-inputs = true
thinking-control-format = "reasoning-effort"

[models.flash-nojson]
api-name = "deepseek-v4-flash"
max-context = 1048576
tools-support = true
thinking-support = true
streaming = true

[models.flash-nojson.capabilities]
supports-response-format-json = false
supports-structured-output = false
thinking-control-format = "reasoning-effort"

[ollama_cloud.minimax-m3]
price-input = 0.14
price-output = 0.28

[ollama_cloud.flash-nojson]
`

function mountSection(
  container: HTMLElement,
  section: 'models' | 'routing' | 'bindings',
  sourceText = sourceWithCapabilities,
) {
  render(
    html`<${RuntimeEnvironmentEditor}
      sourceText=${sourceText}
      providerProtocols=${providerProtocols}
      section=${section}
      onRoutingChange=${() => {}}
      onAssignmentChange=${() => {}}
      onBindingFieldChange=${() => {}}
    />`,
    container,
  )
}

describe('RuntimeEnvironmentEditor capability projection', () => {
  it('renders model capability chips from the [models.<id>.capabilities] section', () => {
    const container = document.createElement('div')
    mountSection(container, 'models')

    const text = container.querySelector('[data-testid="runtime-section-models"]')?.textContent ?? ''
    expect(text).toContain('tool-choice')
    expect(text).toContain('json')
    expect(text).toContain('structured')
    expect(text).toContain('multimodal')
    // No effort/thinking-control-format chip: the models list has no runtime
    // binding to resolve a catalog entry against, and the raw
    // thinking-control-format key is inert (Agent Core never reads it — masc #21521).
    expect(text).not.toContain('effort:')

    render(null, container)
  })

  it('shows per-M binding price in the binding sub-line, without the raw-TOML effort mode', () => {
    const container = document.createElement('div')
    mountSection(container, 'bindings')

    const text = container.querySelector('[data-testid="runtime-section-bindings"]')?.textContent ?? ''
    expect(text).toContain('$0.14/$0.28 per M')
    // The raw-TOML thinking-control-format projection is gone from the
    // sub-line (it was inert and duplicated the catalog "effective" row
    // rendered by <RuntimeBindingCatalogSpec> just below).
    expect(text).not.toContain('effort reasoning-effort')

    render(null, container)
  })

  it('shows the exact runtime catalog spec for a binding id', async () => {
    const catalogEntry: DashboardRuntimeProviderSnapshot = {
      provider: 'ollama_cloud.minimax-m3',
      runtime_id: 'ollama_cloud.minimax-m3',
      provider_id: 'ollama_cloud',
      provider_display_name: 'Ollama Cloud',
      model_id: 'minimax-m3',
      model_api_name: 'minimax-m3-api',
      model_count: 1,
      max_context: 524288,
      capabilities_declared: true,
      supports_response_format_json: true,
      supports_structured_output: true,
      supports_multimodal_inputs: true,
      source: 'agent-core-provider-config-model',
      models: ['minimax-m3-api'],
      effective_capabilities: {
        source: 'agent-core-provider-config-model',
        max_context_tokens: 524288,
        max_output_tokens: 65536,
        supports_tools: true,
        supports_tool_choice: true,
        supports_required_tool_choice: true,
        supports_named_tool_choice: true,
        supports_parallel_tool_calls: true,
        supports_response_format_json: true,
        supports_structured_output: true,
        supports_reasoning: true,
        accepted_reasoning_efforts: ['low', 'medium'],
        thinking_control_format: 'reasoning-effort',
        ignored_sampling_parameters: ['temperature'],
        supported_models: ['minimax-m3-api'],
      },
      request_config: {
        source: 'agent-core-provider-config-model',
        provider_kind: 'openai_compat',
        request_path_targets_responses_api: true,
        enable_thinking: true,
        resolved_reasoning_effort: 'medium',
        response_format: { kind: 'json_schema', has_schema: true },
      },
      declared_spec: {
        source: 'runtime.toml',
        provider: {
          protocol: 'openai-compatible-http',
          api_format: 'chat-completions',
          transport: 'http',
          auth_kind: 'env',
        },
        model: {
          api_name: 'minimax-m3-api',
          max_context: 524288,
          tools_support: true,
          thinking_support: true,
          streaming: true,
          capabilities: {
            thinking_control_format: 'reasoning-effort',
            supports_response_format_json: true,
            supports_structured_output: true,
          },
        },
        binding: {
          provider_id: 'ollama_cloud',
          model_id: 'minimax-m3',
          is_default: true,
          price_input: 0.14,
          price_output: 0.28,
        },
      },
      parameter_policy: {
        reasoning_toggle_wire: 'responses.reasoning',
        reasoning_replay_policy: 'preserve',
        requires_reasoning_replay_on_tool_call: true,
        ignored_sampling_params: ['temperature'],
        always_ignored_sampling_params: ['top_k'],
      },
    }
    runtimeCatalogMock.state.value = { status: 'loaded', data: [catalogEntry] }

    const container = document.createElement('div')
    mountSection(container, 'bindings')

    await waitFor(() => expect(runtimeCatalogMock.loadRuntimeCatalog).toHaveBeenCalledTimes(1))
    const spec = container.querySelector(
      '[data-testid="runtime-binding-ollama_cloud.minimax-m3-catalog-spec"]',
    )
    const text = spec?.textContent ?? ''

    expect(text).toContain('runtime catalog')
    expect(text).toContain('ollama_cloud.minimax-m3')
    expect(text).toContain('provider')
    expect(text).toContain('Ollama Cloud')
    expect(text).toContain('model')
    expect(text).toContain('minimax-m3-api')
    expect(text).toContain('source:agent-core-provider-config-model')
    expect(text).toContain('kind:openai_compat')
    expect(text).toContain('responses-api')
    expect(text).toContain('api:chat-completions')
    expect(text).toContain('wire:responses.reasoning')
    expect(text).toContain('tool-call-replay:required')

    render(null, container)
  })
})
