import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { DashboardRuntimeDiagnostic } from '../../api/dashboard'
import { ConfigResolutionPanel, filterDiagnostics } from './config-resolution-panel'
import { resetRuntimeCatalog } from '../../lib/runtime-catalog-resource'

function diag(
  kind: string,
  message: string,
  signal?: string,
  ts = '2026-04-17T00:00:00Z',
): DashboardRuntimeDiagnostic {
  return signal === undefined ? { ts, kind, message } : { ts, kind, message, signal }
}

async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

function runtimeProvidersPayload() {
  return {
    updated_at: '2026-07-05T00:00:00Z',
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
        models: ['Qwen/Qwen3-32B'],
        status: 'configured',
        available: true,
        source: 'runtime.toml',
        parameter_policy: {
          reasoning_toggle_wire: 'chat_template_kwargs',
          reasoning_replay_policy: 'preserve_always',
          requires_reasoning_replay_on_tool_call: true,
          ignored_sampling_params: ['temperature'],
          always_ignored_sampling_params: [],
        },
        request_config: {
          source: 'oas-provider-config',
          provider_kind: 'openai_compat',
          request_path: '/chat/completions',
          request_path_targets_responses_api: false,
          enable_thinking: true,
          preserve_thinking: true,
          thinking_budget: 32768,
          glm_replay_reasoning: true,
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
              argv_prompt_preflight: false,
              uses_anthropic_caching: false,
              max_turns_per_attempt: null,
              tolerates_bound_actor_fallback: false,
            },
            custom_header_count: 1,
            connect_timeout_s: 120,
          },
          model: {
            id: 'qwen',
            api_name: 'Qwen/Qwen3-32B',
            tools_support: true,
            max_context: 128000,
            thinking_support: true,
            preserve_thinking: true,
            max_thinking_budget: 32768,
            streaming: true,
            temperature: 0.65,
            capabilities: {
              source: 'runtime.toml',
              supports_tool_choice: true,
              supports_required_tool_choice: true,
              supports_named_tool_choice: true,
              supports_parallel_tool_calls: true,
              supports_extended_thinking: true,
              supports_reasoning_budget: true,
              thinking_control_format: 'chat-template-kwargs',
              supports_multimodal_inputs: true,
              supports_image_input: true,
              supports_audio_input: true,
              supports_video_input: false,
              supports_response_format_json: true,
              supports_structured_output: true,
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
          supports_multimodal_inputs: true,
          supports_image_input: true,
          supports_audio_input: true,
          supports_video_input: false,
          ignored_sampling_parameters: ['temperature'],
        },
      },
    ],
  }
}

function nativeProbePayload() {
  return {
    generated_at: '2026-04-10T00:00:00Z',
    cache_hit: true,
    cache_age_sec: 3.2,
    probe: {
      source: 'ollama native runtime',
      effective_model: 'qwen3.5:35b-a3b-coding-nvfp4',
      server_url: 'http://127.0.0.1:11434',
      model_loaded_before_probe: true,
      model_loaded_after_probe: true,
      loaded_models_after: [{ name: 'qwen3.5:35b-a3b-coding-nvfp4' }],
      runs: [
        {
          load_duration_ms: 33.6,
          prompt_tokens_per_second: 26.1,
          generation_tokens_per_second: 65.5,
        },
      ],
      kv_cache_assessment: {
        signal: 'likely_reused',
        note: 'Prompt evaluation time dropped materially on a repeated prompt.',
        prompt_eval_duration_reduction_ratio: 0.42,
      },
      observations: ['Repeated prompt_eval_duration_ms dropped enough to suggest repeated-prefix reuse.'],
      errors: [],
      probe_ok: true,
    },
  }
}

function providerProbePayload() {
  return {
    generated_at: '2026-07-05T00:00:00Z',
    cache_hit: false,
    cache_age_sec: 0,
    probe: {
      source: 'runtime.toml',
      status: 'reachable',
      checked_at: '2026-07-05T00:00:00Z',
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
          probe_url: 'https://example.invalid/v1/models',
        },
      ],
      errors: [],
    },
  }
}

function runtimeResolutionPayload() {
  return {
    status: 'ready',
    warnings: [],
    base_path: { path: '/tmp/runtime-input', exists: true, source: 'input' },
    workspace_path: { path: '/tmp/workspace', exists: true, source: 'workspace' },
    resolved_base_path: { path: '/tmp/workspace', exists: true, source: 'resolved_base' },
    data_root: { path: '/tmp/workspace/.masc', exists: true, source: 'runtime_data' },
    prompt_markdown_dir: { path: '/tmp/shared/prompts', exists: true, source: 'prompt_registry' },
    server_repo_path: { path: '/tmp/masc', exists: true, source: 'server_binary' },
    server_repo_git_commit: 'feedbee',
    workspace_git_commit: 'cafef00d',
    resolved_base_git_commit: 'cafef00d',
    source_mismatch: false,
    server_workspace_mismatch: false,
    diagnostics: [],
    build: {
      release_version: 'dev',
      commit: 'deadbee',
      started_at: '2026-03-27T00:00:00Z',
      uptime_seconds: 42,
    },
    keeper_runtime: null,
    fleet_safety: null,
    fd_accountant: null,
    cdal: null,
  }
}

function responseForPayload(payload: unknown): Response {
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

function stubRuntimeFetch(probePayload: unknown = nativeProbePayload()): void {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockImplementation(async (input: RequestInfo | URL) => {
      const path = typeof input === 'string' ? input : input.toString()
      if (path.includes('/api/v1/providers')) return responseForPayload(runtimeProvidersPayload())
      if (path.includes('/api/v1/dashboard/runtime-probe')) return responseForPayload(probePayload)
      return responseForPayload({})
    }),
  )
}

describe('ConfigResolutionPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetRuntimeCatalog()
    stubRuntimeFetch()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetRuntimeCatalog()
    vi.unstubAllGlobals()
  })

  it('renders resolved paths, root-relative config paths, and runtime diagnostics', async () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'warn',
          warnings: ['Resolved config child is missing: keepers'],
          config_root: { path: '/tmp/runtime/config', exists: true, source: 'env' },
          prompts: { path: '/tmp/runtime/config/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/runtime/config/keepers', exists: false, source: 'env' },
          personas: { path: '/tmp/custom-personas', exists: false, source: 'invalid_env' },
        }}
        runtimeResolution=${{
          status: 'warn',
          warnings: [
            'Runtime build commit (deadbee) differs from server repo HEAD (feedbee).',
            'Server binary checkout (/tmp/masc) differs from dashboard workspace/base path (/tmp/workspace / /tmp/workspace).',
          ],
          base_path: { path: '/tmp/runtime-input', exists: true, source: 'input' },
          workspace_path: { path: '/tmp/workspace', exists: true, source: 'workspace' },
          resolved_base_path: { path: '/tmp/workspace', exists: true, source: 'resolved_base' },
          data_root: { path: '/tmp/workspace/.masc', exists: true, source: 'runtime_data' },
          prompt_markdown_dir: { path: '/tmp/shared/prompts', exists: true, source: 'prompt_registry' },
          server_repo_path: { path: '/tmp/masc', exists: true, source: 'server_binary' },
          server_repo_git_commit: 'feedbee',
          workspace_git_commit: 'cafef00d',
          resolved_base_git_commit: 'cafef00d',
          source_mismatch: true,
          server_workspace_mismatch: true,
          diagnostics: [
            {
              ts: '2026-03-27T00:00:00Z',
              kind: 'external_signal',
              signal: 'SIGTERM',
              message: 'Received SIGTERM, shutting down server.',
            },
          ],
          build: {
            release_version: 'dev',
            commit: 'deadbee',
            started_at: '2026-03-27T00:00:00Z',
            uptime_seconds: 42,
          },
          keeper_runtime: {
            bootstrap_max_active_keepers: { value: 9, source: 'toml' },
            reactive_max_idle_turns: { value: 15, source: 'toml' },
            autonomous_max_idle_turns: { value: 3, source: 'derived' },
            turn_timeout_sec: { value: 90, source: 'toml' },
            admission_wait_timeout_sec: { value: 45, source: 'derived' },
            oas_timeout_override_sec: { value: 120, source: 'env' },
            oas_timeout_per_1k: { value: 7.5, source: 'derived' },
            oas_timeout_per_turn: { value: 30, source: 'derived' },
          },
        }}
      />`,
      container,
    )

    await flush()

    expect(container.textContent).toContain('설정 경로')
    expect(container.textContent).toContain('/tmp/runtime/config')
    expect(container.textContent).toContain('env override')
    expect(container.textContent).toContain('Resolved config child is missing: keepers')
    expect(container.textContent).toContain('TOML-only')
    expect(container.textContent).toContain('repo seed not active')
    expect(container.textContent).toContain('root-relative')
    expect(container.textContent).toContain('under config root')
    expect(container.textContent).toContain('/tmp/custom-personas')
    expect(container.textContent).toContain('invalid env')
    expect(container.textContent).toContain('/tmp/workspace/.masc')
    expect(container.textContent).toContain('/tmp/shared/prompts')
    expect(container.textContent).toContain('/tmp/masc')
    expect(container.textContent).toContain('server repo head')
    expect(container.textContent).toContain('feedbee')
    expect(container.textContent).toContain('source mismatch')
    expect(container.textContent).toContain('server/workspace mismatch')
    expect(container.textContent).toContain('SIGTERM')
    expect(container.textContent).toContain('Runtime build commit (deadbee) differs from server repo HEAD (feedbee).')
    expect(container.textContent).toContain('Server binary checkout (/tmp/masc) differs from dashboard workspace/base path')
    expect(container.querySelector('.v2-lab-card')).not.toBeNull()
    expect(container.querySelector('.v2-lab-panel')).not.toBeNull()
    expect(container.querySelector('.v2-lab-action')).not.toBeNull()
    expect(container.textContent).toContain('ollama warm / kv probe')
    expect(container.textContent).toContain('kv likely reused')
    expect(container.textContent).toContain('qwen3.5:35b-a3b-coding-nvfp4')
    expect(container.textContent).toContain('keeper runtime limits')
    expect(container.textContent).toContain('Per-keeper runtime caps and timeouts. These values are not the live keeper count.')
    expect(container.textContent).toContain('bootstrap max active keepers')
    expect(container.textContent).toContain('default')
    expect(container.textContent).not.toContain('derived')
  })

  it('surfaces provider catalog spec beside provider reachability rows', async () => {
    resetRuntimeCatalog()
    stubRuntimeFetch(providerProbePayload())

    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/root-config', exists: true, source: 'env' },
          prompts: { path: '/tmp/root-config/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/root-config/keepers', exists: true, source: 'env' },
          personas: { path: '/tmp/root-config/personas', exists: true, source: 'env' },
        }}
        runtimeResolution=${runtimeResolutionPayload()}
      />`,
      container,
    )

    await flush()

    expect(container.textContent).toContain('provider reachability')
    expect(container.textContent).toContain('provider catalog')
    expect(container.textContent).toContain('1 runtime specs')
    expect(container.querySelector('[data-testid="runtime-probe-catalog-spec"]')).not.toBeNull()
    expect(container.textContent).toContain('effective')
    expect(container.textContent).toContain('source:oas-provider-config-model')
    expect(container.textContent).toContain('request')
    expect(container.textContent).toContain('think:on')
    expect(container.textContent).toContain('declared')
    expect(container.textContent).toContain('api:chat-completions')
    expect(container.textContent).toContain('policy')
    expect(container.textContent).toContain('wire:chat_template_kwargs')
  })

  it('keeps the full path on hover title and hides duplicate source badges', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/root-config', exists: true, source: 'env' },
          prompts: { path: '/tmp/root-config/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/root-config/keepers', exists: true, source: 'cwd' },
          personas: { path: '/tmp/root-config/personas', exists: true, source: 'env' },
        }}
      />`,
      container,
    )

    const cards = Array.from(container.querySelectorAll('[title]'))
    expect(cards.map(card => card.getAttribute('title'))).toContain('/tmp/root-config')
    expect(container.textContent?.match(/env override/g)?.length ?? 0).toBe(1)
    expect(container.textContent).toContain('cwd fallback')
  })

  it('does not collapse sibling paths that only share the root prefix', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/root', exists: true, source: 'env' },
          prompts: { path: '/tmp/root/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/root/keepers', exists: true, source: 'env' },
          personas: { path: '/tmp/root-extra/personas', exists: true, source: 'env' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('/tmp/root-extra/personas')
    expect(container.textContent).toContain('outside config root')
  })

  it('renders the same-as-root case without repeating the full path', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/root', exists: true, source: 'env' },
          prompts: { path: '/tmp/root/prompts', exists: true, source: 'env' },
          keepers: { path: '/tmp/root/keepers', exists: true, source: 'env' },
          personas: { path: '/tmp/root/personas', exists: true, source: 'env' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('under config root')
    expect(container.textContent).toContain('prompts')
  })

  it('treats slash root as a valid root-relative prefix', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/', exists: true, source: 'cwd' },
          prompts: { path: '/var/prompts', exists: true, source: 'cwd' },
          keepers: { path: '/opt/keepers', exists: true, source: 'cwd' },
          personas: { path: '/srv/personas', exists: true, source: 'cwd' },
        }}
      />`,
      container,
    )
    expect(container.textContent).toContain('root-relative')
  })

  it('renders local .masc source label', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/project/.masc/config', exists: true, source: 'local_masc' },
          prompts: { path: '/tmp/project/.masc/config/prompts', exists: true, source: 'local_masc' },
          keepers: { path: '/tmp/project/.masc/config/keepers', exists: true, source: 'local_masc' },
          personas: { path: '/tmp/project/.masc/config/personas', exists: true, source: 'local_masc' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('local .masc')
    expect(container.textContent).toContain('/tmp/project/.masc/config')
  })

  it('calls out repo fallback config roots separately from copied runtime roots', () => {
    render(
      html`<${ConfigResolutionPanel}
        resolution=${{
          status: 'ready',
          warnings: [],
          config_root: { path: '/tmp/project/config', exists: true, source: 'cwd' },
          prompts: { path: '/tmp/project/config/prompts', exists: true, source: 'cwd' },
          keepers: { path: '/tmp/project/config/keepers', exists: true, source: 'cwd' },
          personas: { path: '/tmp/project/config/personas', exists: true, source: 'cwd' },
        }}
      />`,
      container,
    )

    expect(container.textContent).toContain('repo config active')
    expect(container.textContent).not.toContain('repo seed not active')
  })
})

describe('filterDiagnostics', () => {
  const sample: readonly DashboardRuntimeDiagnostic[] = [
    diag('external_signal', 'Received SIGTERM, shutting down server.', 'SIGTERM'),
    diag('external_signal', 'Received SIGINT from operator.', 'SIGINT'),
    diag('config_drift', 'Runtime build commit (deadbee) differs from workspace HEAD (cafef00d).'),
    diag('keeper_heartbeat', 'keeper stale for 42s', 'heartbeat_stale'),
  ]

  it('returns the input reference when the query is empty', () => {
    expect(filterDiagnostics(sample, '')).toBe(sample)
  })

  it('returns the input reference when the query is whitespace-only', () => {
    expect(filterDiagnostics(sample, '   ')).toBe(sample)
  })

  it('trims the query before matching', () => {
    const result = filterDiagnostics(sample, '  SIGTERM  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.signal).toBe('SIGTERM')
  })

  it('matches kind case-insensitively', () => {
    const result = filterDiagnostics(sample, 'EXTERNAL_signal')
    expect(result).toHaveLength(2)
  })

  it('matches signal case-insensitively', () => {
    const result = filterDiagnostics(sample, 'sigint')
    expect(result).toHaveLength(1)
    expect(result[0]?.signal).toBe('SIGINT')
  })

  it('matches substring in the message body', () => {
    const result = filterDiagnostics(sample, 'deadbee')
    expect(result).toHaveLength(1)
    expect(result[0]?.kind).toBe('config_drift')
  })

  it('returns an empty array when nothing matches', () => {
    expect(filterDiagnostics(sample, 'no-such-term-xyz')).toEqual([])
  })

  it('skips undefined signal fields without crashing', () => {
    const result = filterDiagnostics(sample, 'heartbeat')
    // kind match ("keeper_heartbeat") + signal match ("heartbeat_stale") on the same row
    expect(result).toHaveLength(1)
    expect(result[0]?.kind).toBe('keeper_heartbeat')
  })

  it('returns an empty array when the input is empty', () => {
    expect(filterDiagnostics([], 'anything')).toEqual([])
  })

  it('does not mutate the input array', () => {
    const before = sample.map(item => ({ ...item }))
    filterDiagnostics(sample, 'sigterm')
    expect(sample).toEqual(before)
    expect(sample).toHaveLength(4)
  })
})
