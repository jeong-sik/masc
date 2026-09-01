import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { shellAuthSummary, tasks } from '../../store'
import { fetchRuntimeProviders } from '../../api/dashboard'
import { KeeperWorkspaceRail, runtimeRawSpecOpen } from './keeper-workspace-rail'
import { selectedTask } from '../goals/task-detail-selection'
import type { Keeper, Task } from '../../types'
import type { KeeperRuntimeLensConfigDriftAxis } from '../../api/keeper-runtime-trace'
import type { DashboardKeeperWaitingInventory } from '../../api'
import { keeperWaitingInventoryStates } from '../../keeper-waiting-inventory-store'
import { resetRuntimeCatalog } from '../../lib/runtime-catalog-resource'

// The recent-tool-calls section now lazy-loads via fetchKeeperToolCalls (rather
// than rendering keeper.recent_tool_names). Stub it so these rail tests never hit
// the network; its rendering is covered directly in keeper-workspace-tool-calls.test.ts.
vi.mock('../../api/dashboard', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api/dashboard')>()
  return {
    ...actual,
    fetchKeeperToolCalls: vi.fn().mockResolvedValue({
      keeper: 'masc-improver',
      count: 0,
      source: 'tool_call_io',
      entries: [],
    }),
    fetchRuntimeProviders: vi.fn().mockResolvedValue({ providers: [] }),
    fetchKeeperTurnRecords: vi.fn().mockResolvedValue({
      keeper: 'masc-improver',
      count: 1,
      skipped_rows: 0,
      source: 'turn_record',
      producer: 'keeper_agent_run.run_turn|keeper_turn_record_writer',
      durable_store: '.masc/keepers/masc-improver/turn-records',
      dashboard_surface: '/api/v1/keepers/:name/turn-records',
      freshness_slo_s: 300,
      latest_ts_unix: 1_782_444_590,
      latest_ts_iso: '2026-06-26T03:03:10Z',
      latest_age_s: 3,
      health: 'ok',
      stale_reason: null,
      coverage_gaps: [],
      memory_os: {
        keeper: 'masc-improver',
        snapshot_store: '.masc/keepers/masc-improver.memory-current.json',
        recall_enabled: true,
        revision: 0,
        updated_at: null,
        update_source: null,
        read_errors: [],
        facts: { shown: 0, current: 0, items: [] },
        change: { added: [], removed: [], retained: 0, invalidated: [] },
      },
      entries: [
        {
          record: {
            execution_ids: ['exec-cmp'],
            keeper: 'masc-improver',
            agent_name: 'keeper-masc-improver-agent',
            generation: 1,
            turn_kind: 'autonomous',
            raw_trace_run_ref: null,
            trace_id: 'trace-cmp',
            absolute_turn: 12,
            turn_ref: 'trace-cmp#12',
            blocks: [
              { block: 'keeper_instructions', bytes: 2048, digest: 'keeper-instructions-digest-aaaaaaaa' },
              { block: 'dynamic_context', bytes: 1024, digest: 'dynamic-digest-bbbbbbbb' },
              { block: 'memory_os_recall', bytes: 512, digest: 'memory-digest-cccccccc' },
            ],
            input_components: [],
            request_runtime_profile: null,
            request_body_bytes: null,
            runtime_profile: 'agent-core-seoul-1',
            selected_model: 'gpt-5.4',
            finish_reason: 'completed',
            input_tokens: 33000,
            output_tokens: 120,
            context_window: 200000,
            ts: 1_782_444_590,
          },
          diff_vs_prev: {
            added: [],
            removed: [],
            changed: [
              {
                prev: { block: 'dynamic_context', bytes: 900, digest: 'old-dynamic' },
                next: { block: 'dynamic_context', bytes: 1024, digest: 'dynamic-digest-bbbbbbbb' },
              },
            ],
          },
        },
      ],
    }),
  }
})

vi.mock('../../router', () => ({
  navigate: vi.fn(),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
  showActionToast: vi.fn(),
}))

function mkKeeper(partial: Partial<Keeper>): Keeper {
  return { name: 'masc-improver', status: 'running', ...partial } as Keeper
}
function mkTask(partial: Partial<Task>): Task {
  return { id: 'T-0', title: 'task', ...partial } as Task
}

// The runtime card follows the design's collapsed-by-default disclosure
// (rails.jsx RailRuntime): click `.rtc-head` to open `.rtc-detail`.
function openRuntimeDetail(container: Element): void {
  const head = container.querySelector('.rtc-head') as HTMLButtonElement | null
  if (head) fireEvent.click(head)
}

beforeEach(() => {
  selectedTask.value = null
  tasks.value = [
    mkTask({ id: 'T-4412', title: '세그먼트 리텐션 대시보드', status: 'in_progress', assignee: 'masc-improver' }),
    mkTask({ id: 'T-9999', title: '남의 태스크', status: 'todo', assignee: 'someone-else' }),
  ]
})

afterEach(() => {
  cleanup()
  tasks.value = []
  selectedTask.value = null
  shellAuthSummary.value = null
  keeperWaitingInventoryStates.value = {}
  runtimeRawSpecOpen.value = false
  vi.clearAllMocks()
  vi.useRealTimers()
  resetRuntimeCatalog()
})

describe('KeeperWorkspaceRail', () => {
  const keeper = mkKeeper({
    active_model_label: 'sonnet-4.6',
    runtime_canonical: 'agentCore·seoul-1',
    context_ratio: 0.62,
    context_tokens: 124000,
    context_max: 200000,
    recent_tool_names: ['masc_amplitude_query', 'masc_board_metrics'],
  })

  it('renders the runtime vitals (throughput section removed)', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    openRuntimeDetail(container)
    // The 처리량 (throughput) section was removed from the keeper rail as
    // low-signal in the detail view; the 런타임 section keeps its vitals.
    expect(container.textContent).not.toContain('처리량')
    expect(container.textContent).toContain('런타임')
    expect(container.textContent).not.toContain('sonnet-4.6')
    expect(container.querySelector('.rtc-model')?.textContent).toContain('—')
    expect(container.textContent).toContain('agentCore·seoul-1')
  })

  function mkDrift(partial: Partial<KeeperRuntimeLensConfigDriftAxis>): KeeperRuntimeLensConfigDriftAxis {
    return {
      present: true,
      status: 'drift',
      error: null,
      has_live_override: true,
      runtime_override: true,
      override_fields: ['model.runtime_id'],
      default_runtime_id: 'agentCore·tokyo-2',
      live_runtime_id: 'agentCore·seoul-1',
      active_config_root: null,
      active_config_root_source: null,
      default_manifest_path: null,
      ...partial,
    }
  }

  it('surfaces a pending runtime assignment (assigned ≠ live) in the runtime card', () => {
    const { container, getByTestId } = render(
      html`<${KeeperWorkspaceRail} keeper=${keeper} runtimeDrift=${mkDrift({})} />`,
    )
    // Live runtime stays as the card's primary id; the pending assignment is
    // shown as a distinct drift line so a saved-but-not-adopted runtime is
    // visible instead of looking like the save did nothing.
    expect(container.textContent).toContain('agentCore·seoul-1')
    const drift = getByTestId('runtime-drift')
    expect(drift.textContent).toContain('지정됨')
    expect(drift.textContent).toContain('agentCore·tokyo-2')
  })

  it('does not render the drift line when assigned and live runtimes match', () => {
    const noDrift = mkDrift({ runtime_override: false, default_runtime_id: 'agentCore·seoul-1' })
    const { container } = render(
      html`<${KeeperWorkspaceRail} keeper=${keeper} runtimeDrift=${noDrift} />`,
    )
    expect(container.querySelector('[data-testid="runtime-drift"]')).toBeNull()
  })

  it('does not render the drift line when no runtime trace is available', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.querySelector('[data-testid="runtime-drift"]')).toBeNull()
  })

  it('no longer renders the Selected-runtime top card (removed from the rail)', () => {
    const k = mkKeeper({ status: 'offline', lifecycle_phase: 'Paused' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    // The top card duplicated the 런타임/컨텍스트 sections below it. Its inline
    // lifecycle actions (pause/resume/wakeup/boot) are not lost — they remain in
    // the roster row menu + keeper action panel.
    expect(container.querySelector('.kw-fleet-aside')).toBeNull()
    expect(container.querySelector('.kw-fleet-aside-state')).toBeNull()
    expect(container.querySelector('.kw-fleet-actions')).toBeNull()
    expect(container.querySelector('.kw-fleet-chat')).toBeNull()
    expect(container.textContent).not.toContain('대화 콘솔 열기')
  })

  it('shows the model line as missing when no model was reported', () => {
    const k = mkKeeper({ runtime_canonical: 'runpod_gemma' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)
    expect(container.textContent).toContain('런타임')
    expect(container.textContent).toContain('runpod_gemma')
    // v2 always renders the model cell; when no model is reported it falls back
    // to an em-dash rather than omitting the line.
    expect(container.querySelector('.rtc-model')).not.toBeNull()
    expect(container.querySelector('.rtc-model')?.textContent).toContain('—')
  })

  it('shows catalog loading without claiming the runtime is missing', async () => {
    vi.mocked(fetchRuntimeProviders).mockReturnValueOnce(new Promise(() => {}))

    const k = mkKeeper({ runtime_canonical: 'ollama_cloud.pending' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)

    await waitFor(() => {
      expect(container.querySelector('[data-effort-status="loading"]')).not.toBeNull()
    })
    expect(container.textContent).toContain('카탈로그 로딩 중')
    expect(container.textContent).not.toContain('카탈로그 미등재')
  })

  it('shows catalog failure without claiming the runtime is missing', async () => {
    vi.mocked(fetchRuntimeProviders).mockRejectedValueOnce(new Error('catalog unavailable'))

    const k = mkKeeper({ runtime_canonical: 'ollama_cloud.failed' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)

    await waitFor(() => {
      expect(container.querySelector('[data-effort-status="error"]')).not.toBeNull()
    })
    const effort = container.querySelector('[data-effort-status="error"]')
    expect(effort?.textContent).toContain('카탈로그 조회 실패')
    expect(effort?.getAttribute('title')).toBe('catalog unavailable')
    expect(container.textContent).not.toContain('카탈로그 미등재')
  })

  it('shows catalog missing only after a loaded catalog has no runtime entry', async () => {
    vi.mocked(fetchRuntimeProviders).mockResolvedValueOnce({ providers: [] } as Awaited<ReturnType<typeof fetchRuntimeProviders>>)

    const k = mkKeeper({ runtime_canonical: 'ollama_cloud.unregistered' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)

    await waitFor(() => {
      expect(container.querySelector('[data-effort-status="missing"]')).not.toBeNull()
    })
    expect(container.textContent).toContain('카탈로그 미등재')
  })

  it('renders multimodal and effort adjustability from the runtime catalog capabilities', async () => {
    vi.mocked(fetchRuntimeProviders).mockResolvedValueOnce({
      providers: [
        {
          provider: 'ollama_cloud.minimax-m3',
          runtime_id: 'ollama_cloud.minimax-m3',
          model_api_name: 'minimax-m3',
          max_context: 524288,
          tools_support: true,
          thinking_support: true,
          streaming: true,
          supports_multimodal_inputs: false,
          supports_image_input: false,
          supports_audio_input: true,
          supports_video_input: false,
          supports_reasoning_budget: true,
          thinking_control_format: 'reasoning-effort',
          parameter_policy: {
            reasoning_toggle_wire: 'chat_template_kwargs',
            reasoning_replay_policy: 'preserve_always',
            requires_reasoning_replay_on_tool_call: true,
            ignored_sampling_params: ['temperature', 'top_p'],
            always_ignored_sampling_params: ['temperature'],
          },
          request_config: {
            source: 'agent-core-provider-config',
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
            clear_thinking: false,
            resolved_reasoning_effort: 'high',
            glm_clear_thinking: false,
            glm_replay_reasoning: false,
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
            source: 'agent-core-provider-config-model',
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
            supports_response_format_json: true,
            supports_structured_output: true,
            supports_multimodal_inputs: true,
            supports_image_input: true,
            supports_audio_input: true,
            supports_video_input: false,
            supports_reasoning: true,
            supports_extended_thinking: true,
            supports_reasoning_budget: true,
            accepted_reasoning_efforts: ['low', 'medium', 'high'],
            thinking_control_format: 'chat-template-kwargs',
            preserve_thinking_control_format: 'always-preserved',
            reasoning_output_format: 'split-reasoning-fields',
            reasoning_streaming_format: {
              kind: 'delta-reasoning-field',
              field: 'reasoning_content',
            },
            reasoning_replay_override: 'preserve-always',
            supports_native_streaming: true,
            supports_system_prompt: true,
            supports_caching: true,
            supports_prompt_caching: true,
            prompt_cache_alignment: 1024,
            supports_top_k: true,
            supports_min_p: true,
            supports_seed: true,
            supports_seed_with_images: true,
            ignored_sampling_parameters: ['temperature', 'top_p', 'presence_penalty', 'frequency_penalty'],
            supports_code_execution: true,
            emits_usage_tokens: true,
            modality_priority: 'visual-first',
            task: 'transcription',
            supported_models: ['minimax-m3'],
          },
          declared_spec: {
            source: 'runtime.toml',
            provider: {
              id: 'ollama_cloud',
              display_name: 'Ollama Cloud',
              protocol: 'openai-compatible-http',
              api_format: 'chat-completions',
              transport: 'http',
              auth_kind: 'env:OLLAMA_API_KEY',
              is_non_interactive: true,
              has_capabilities: true,
              behavior_capabilities: {
                supports_inline_tools: true,
                argv_prompt_preflight: true,
                uses_anthropic_caching: true,
              },
              custom_header_count: 1,
              connect_timeout_s: 120,
            },
            model: {
              id: 'minimax-m3',
              api_name: 'minimax-m3',
              tools_support: true,
              max_context: 524288,
              thinking_support: true,
              preserve_thinking: false,
              max_thinking_budget: 32768,
              streaming: true,
              temperature: 0.65,
              top_p: 0.91,
              top_k: 42,
              min_p: 0.07,
              capabilities: {
                source: 'runtime.toml',
                max_output_tokens: 65536,
                supports_tool_choice: true,
                supports_required_tool_choice: true,
                supports_named_tool_choice: true,
                supports_parallel_tool_calls: true,
                supports_extended_thinking: true,
                supports_reasoning_budget: true,
                thinking_control_format: 'reasoning-effort',
                supports_image_input: false,
                supports_audio_input: false,
                supports_video_input: false,
                supports_multimodal_inputs: true,
                supports_response_format_json: true,
                supports_structured_output: true,
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
              },
            },
            binding: {
              provider_id: 'ollama_cloud',
              model_id: 'minimax-m3',
              is_default: true,
              max_concurrent: 4,
              price_input: 0.1,
              price_output: 0.2,
              keep_alive: '30m',
              num_ctx: 131072,
            },
          },
          models: ['minimax-m3'],
        },
      ],
    } as unknown as Awaited<ReturnType<typeof fetchRuntimeProviders>>)

    const k = mkKeeper({ runtime_canonical: 'ollama_cloud.minimax-m3' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)

    await waitFor(() => {
      expect(container.querySelector('[data-effort-mode="chat-template-kwargs"]')).not.toBeNull()
    })

    const multimodalFlag = Array.from(container.querySelectorAll('.rtc-flag')).find(node =>
      node.textContent?.includes('multimodal'),
    )
    expect(multimodalFlag).not.toBeUndefined()
    expect(multimodalFlag?.className).toContain('on')

    // The effort row sources effective_capabilities.thinking_control_format
    // ('chat-template-kwargs'), NOT the top-level entry.thinking_control_format
    // ('reasoning-effort', set above) — that top-level field mirrors
    // runtime.toml's hand-maintained, wire-inert capabilities block.
    const effort = container.querySelector('[data-effort-mode="chat-template-kwargs"]')
    expect(effort?.textContent).toContain('chat-template-kwargs')
    expect(effort?.textContent).not.toContain('reasoning-effort')
    expect(effort?.textContent).toContain('조정 가능')
    expect(effort?.textContent).toContain('(low, medium, high)')

    // Raw catalog rows are collapsed by default — only the curated block shows.
    expect(container.textContent).not.toContain('params')
    expect(container.textContent).not.toContain('declared')
    const rawToggle = container.querySelector('[data-testid="runtime-raw-toggle"]') as HTMLButtonElement
    expect(rawToggle).not.toBeNull()
    expect(rawToggle.getAttribute('aria-expanded')).toBe('false')

    fireEvent.click(rawToggle)
    await waitFor(() => {
      expect(container.textContent).toContain('params')
    })
    expect(
      container.querySelector('[data-testid="runtime-raw-toggle"]')?.getAttribute('aria-expanded'),
    ).toBe('true')

    // Raw rows render via the shared lib/runtime-provider-summary formatters
    // (colon-separated tokens) — the rail no longer ships its own copies.
    expect(container.textContent).toContain('wire:chat_template_kwargs · replay:preserve_always')
    expect(container.textContent).toContain('request')
    expect(container.textContent).toContain(
      'kind:openai_compat · source:agent-core-provider-config · path:/chat/completions · out:65536 · ctx:131072',
    )
    expect(container.textContent).toContain('system-prompt')
    expect(container.textContent).toContain('tool:required')
    expect(container.textContent).toContain('declared')
    expect(container.textContent).toContain('api:chat-completions · protocol:openai-compatible-http')
    expect(container.textContent).toContain('transport:http')
    expect(container.textContent).toContain('headers:1')
    expect(container.textContent).toContain('temp:0.65')
    expect(container.textContent).toContain('sampling-config:top_p:0.91,top_k:42,min_p:0.07')
    expect(container.textContent).toContain('budget:32768')
    expect(container.textContent).toContain('behavior:inline-tools,argv-preflight,anthropic-cache')
    expect(container.textContent).toContain(
      'controls:tool-choice,required,named,parallel,extended-thinking,reasoning-budget,system-prompt,cache,prompt-cache@1024,seed+images,usage,code-exec',
    )
    expect(container.textContent).toContain('source:agent-core-provider-config-model')
    expect(container.textContent).toContain('ctx:131072 · out:65536 · tools · tool-choice+required+named+parallel')
    expect(container.textContent).toContain('ignored:temperature,top_p,presence_penalty,frequency_penalty')
    expect(container.textContent).toContain('input:multimodal,image,audio')
    expect(container.textContent).toContain('modality:visual-first')
    expect(container.textContent).toContain('tool-content:null')
    expect(container.textContent).toContain('extended-thinking')
    expect(container.textContent).toContain('reasoning-budget')
    expect(container.textContent).toContain('effort:low,medium,high')
    expect(container.textContent).toContain('wire:chat-template-kwargs')
    expect(container.textContent).toContain('preserve:always-preserved')
    expect(container.textContent).toContain('reasoning-stream:delta-reasoning-field:reasoning_content')
    expect(container.textContent).toContain('task:transcription · native-stream')
    // the "no catalog entry" stub is replaced once the catalog reports capabilities
    expect(container.textContent).not.toContain('카탈로그 미등재')
  })

  it('renders undeclared runtime capabilities as unknown, not disabled', async () => {
    vi.mocked(fetchRuntimeProviders).mockResolvedValueOnce({
      providers: [
        {
          provider: 'runpod.gemma',
          runtime_id: 'runpod.gemma',
          model_api_name: 'gemma',
          tools_support: true,
          thinking_support: false,
          streaming: true,
          capabilities_declared: false,
          supports_multimodal_inputs: false,
          supports_image_input: false,
          supports_audio_input: false,
          supports_video_input: false,
          supports_reasoning_budget: false,
          thinking_control_format: 'none',
          models: ['gemma'],
        },
      ],
    } as unknown as Awaited<ReturnType<typeof fetchRuntimeProviders>>)

    const k = mkKeeper({ runtime_canonical: 'runpod.gemma' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)

    await waitFor(() => {
      expect(container.textContent).toContain('gemma')
    })

    const multimodalFlag = Array.from(container.querySelectorAll('.rtc-flag')).find(node =>
      node.textContent?.includes('multimodal'),
    )
    expect(multimodalFlag).not.toBeUndefined()
    expect(multimodalFlag?.textContent).toContain('—')
    // unknown renders with the dedicated 'na' class, not a false 'off' claim
    expect(multimodalFlag?.className).toContain('na')
    expect(multimodalFlag?.className).not.toContain('off')
    // effort is likewise unknown, not the definitive "effort 제어 없음" claim that
    // the top-level thinking_control_format ('none', still set above to prove
    // it is ignored) would otherwise imply. The catalog entry exists, but its
    // Agent Core-derived effective capabilities were not projected.
    expect(container.textContent).toContain('유효 capability 미수신')
    expect(container.querySelector('[data-effort-status="unknown"]')).not.toBeNull()
    expect(container.textContent).not.toContain('카탈로그 미등재')
    expect(container.textContent).not.toContain('effort 제어 없음')
  })

  it('renders a missing effective thinking-control format as unknown', async () => {
    vi.mocked(fetchRuntimeProviders).mockResolvedValueOnce({
      providers: [
        {
          provider: 'ollama_cloud.unknown-wire',
          runtime_id: 'ollama_cloud.unknown-wire',
          model_api_name: 'unknown-wire',
          tools_support: true,
          thinking_support: true,
          streaming: true,
          effective_capabilities: {
            supports_reasoning: true,
            supports_reasoning_budget: false,
            accepted_reasoning_efforts: null,
            thinking_control_format: null,
            ignored_sampling_parameters: [],
            supported_models: ['unknown-wire'],
          },
          models: ['unknown-wire'],
        },
      ],
    } as unknown as Awaited<ReturnType<typeof fetchRuntimeProviders>>)

    const k = mkKeeper({ runtime_canonical: 'ollama_cloud.unknown-wire' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)

    await waitFor(() => {
      expect(container.querySelector('[data-effort-status="unknown"]')).not.toBeNull()
    })
    expect(container.textContent).toContain('thinking control 형식 미수신')
    expect(container.textContent).not.toContain('effort 제어 없음')
  })

  it('renders the effort row from effective_capabilities even when capabilities_declared is false', async () => {
    // capabilities_declared gates the runtime.toml-derived multimodal flag,
    // NOT the effort row (fix design: "no capabilities_declared gating for
    // effort"). The Agent Core catalog can know a model's reasoning wire even when
    // MASC's runtime.toml never declared a [models.<id>.capabilities] block
    // for it — the two sources are independent.
    vi.mocked(fetchRuntimeProviders).mockResolvedValueOnce({
      providers: [
        {
          provider: 'ollama_cloud.deepseek-v3-1',
          runtime_id: 'ollama_cloud.deepseek-v3-1',
          model_api_name: 'deepseek-v3-1',
          tools_support: true,
          thinking_support: true,
          streaming: true,
          capabilities_declared: false,
          effective_capabilities: {
            source: 'agent-core-provider-config-model',
            supports_reasoning: true,
            supports_reasoning_budget: false,
            accepted_reasoning_efforts: null,
            thinking_control_format: 'ollama-think',
            ignored_sampling_parameters: [],
            supported_models: ['deepseek-v3-1'],
          },
          models: ['deepseek-v3-1'],
        },
      ],
    } as unknown as Awaited<ReturnType<typeof fetchRuntimeProviders>>)

    const k = mkKeeper({ runtime_canonical: 'ollama_cloud.deepseek-v3-1' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)

    await waitFor(() => {
      expect(container.querySelector('[data-effort-mode="ollama-think"]')).not.toBeNull()
    })

    // multimodal is unknown (gated by capabilities_declared === false) ...
    const multimodalFlag = Array.from(container.querySelectorAll('.rtc-flag')).find(node =>
      node.textContent?.includes('multimodal'),
    )
    expect(multimodalFlag?.className).toContain('na')

    // ... but effort is known and fixed (no reasoning-budget, no accepted list).
    const effort = container.querySelector('[data-effort-mode="ollama-think"]')
    expect(effort?.textContent).toContain('ollama-think')
    expect(effort?.textContent).toContain('고정')
    expect(container.textContent).not.toContain('카탈로그 미등재')
  })

  it('renders the context-window occupancy percent', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    const meter = container.querySelector('.meter') as HTMLElement | null

    expect(container.textContent).toContain('컨텍스트')
    // The "윈도우 사용량" label was removed as redundant under "컨텍스트".
    expect(container.textContent).not.toContain('윈도우 사용량')
    expect(container.textContent).toContain('62%')
    expect(container.textContent).toContain('124.0k')
    // Design's ctx-usage row (rails.jsx): leading "마지막 턴 input" label,
    // volt-accented value, trailing "마지막 턴 · 창 크기" label.
    expect(container.querySelector('.ctx-usage .ctx-usage-k')?.textContent).toBe('마지막 턴 input')
    expect(container.textContent).toContain('마지막 턴 · 창 크기')
    // ...and the design's typed not_observed line for live occupancy.
    expect(container.querySelector('.ctx-notobs')).not.toBeNull()
    expect(meter).not.toBeNull()
    expect(meter?.getAttribute('role')).toBe('meter')
    expect(meter?.getAttribute('aria-label')).toBe('마지막 완료 요청의 컨텍스트 윈도우 사용률')
    expect(meter?.getAttribute('aria-valuenow')).toBe('62')
  })

  it('lists only the keeper-owned tasks', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.textContent).toContain('T-4412')
    expect(container.textContent).not.toContain('T-9999')
  })

  it('renders owned task status in the top row and title on its own line', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    // v2 renames .kw-tasktag → .tasktag and .kw-tasktag-row → .tasktag-top.
    const tag = container.querySelector('.tasktag') as HTMLElement | null
    expect(tag).not.toBeNull()
    const row = tag?.querySelector('.tasktag-top')
    expect(row).not.toBeNull()
    expect(row?.textContent).toContain('T-4412')
    expect(row?.textContent).toContain('in_progress')
    // Title lives outside the top row on its own .ttl line.
    expect(row?.textContent).not.toContain('세그먼트 리텐션 대시보드')
    expect(tag?.querySelector('.ttl')?.textContent).toContain('세그먼트 리텐션 대시보드')
  })

  it('does not render the throughput card (removed from the keeper rail)', () => {
    const k = mkKeeper({
      metrics_series: [{ wall_tokens_per_second: 10 }, { wall_tokens_per_second: 64 }] as unknown as Keeper['metrics_series'],
    })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.querySelector('.tps-card')).toBeNull()
    expect(container.querySelector('.tps-spark')).toBeNull()
    expect(container.textContent).not.toContain('처리량')
  })

  it('opens the shared task detail overlay without leaving the keeper route', () => {
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    fireEvent.click(getByRole('button', { name: /태스크 열기: T-4412/ }))
    expect(selectedTask.value?.id).toBe('T-4412')
  })

  it('does not duplicate awaiting-verification tasks in the attention section', () => {
    tasks.value = [
      mkTask({ id: 'T-review', title: '검증할 태스크', status: 'awaiting_verification', assignee: 'masc-improver' }),
    ]
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.textContent).not.toContain('검증 대기 1건')
    expect(container.textContent).toContain('T-review')
  })

  it('renders the attention section from live blocked-task signal', () => {
    const k = mkKeeper({ blocked_task_count: 2 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('주의')
    expect(container.textContent).toContain('차단된 태스크 2건')
  })

  it('omits the attention section when there is nothing to surface', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.textContent).not.toContain('차단된 태스크')
  })

  it('uses explicit attention reason text instead of a vague maintenance label', () => {
    const k = mkKeeper({ needs_attention: true, attention_reason: 'approval_pending', next_human_action: 'resolve_approval' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('approval_pending · resolve_approval')
    expect(container.textContent).not.toContain('점검이 필요합니다')
  })

  it('labels unqualified attention flags as missing cause data', () => {
    const k = mkKeeper({ needs_attention: true })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('runtime_attention.needs_attention=true · 원인/조치 미수신')
    expect(container.textContent).not.toContain('점검이 필요합니다')
  })

  it('renders context metrics as missing when only a zero default exists', () => {
    const k = mkKeeper({ context_ratio: 0 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    // v2 collapses the missing-context state into a single "윈도우 사용률 미측정"
    // empty card (.ctx-empty); no fake usage meter and no usage percentage.
    expect(container.textContent).toContain('윈도우 사용률 미측정')
    expect(container.querySelector('.ctx-empty')).not.toBeNull()
    expect(container.textContent).not.toContain('윈도우 사용량')
    expect(container.querySelector('.meter')).toBeNull()
  })

  it('shows token-only context without a fake window percentage', () => {
    const k = mkKeeper({ context_ratio: 0, context_tokens: 37800 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('윈도우 사용률 미측정')
    expect(container.textContent).toContain('37.8k')
    expect(container.textContent).not.toContain('윈도우 사용량')
    expect(container.querySelector('.meter')).toBeNull()
  })

  it('names the typed absence reason from the projection', () => {
    const k = mkKeeper({
      context_ratio: 0,
      context_metrics_unavailable: { kind: 'not_observed', reason: 'turn_record_without_usage' },
    })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('턴 레코드 기준 측정 불가')
    expect(container.textContent).toContain('turn_record_without_usage')
  })

  it('renders measurement provenance for a turn_record-sourced context', () => {
    const k = mkKeeper({
      context_ratio: 0.5,
      context_tokens: 100887,
      context_max: 200000,
      context_source: 'turn_record',
      context: {
        source: 'turn_record',
        context_ratio: 0.5,
        context_tokens: 100887,
        context_max: 200000,
        observed_at: new Date(Date.now() - 120000).toISOString(),
        turn_ref: 'trace-1785189111911-00004#3337',
        absolute_turn: 3337,
        request_body_bytes: 402408,
      },
    })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    const provenance = container.querySelector('[data-testid="ctx-provenance"]')
    expect(provenance).not.toBeNull()
    expect(provenance?.textContent).toContain('T3337')
    expect(provenance?.textContent).toContain('마지막 완료 요청')
    expect(provenance?.textContent).not.toContain('요청 본문')
    expect(provenance?.textContent).not.toContain('393KB')
    expect(provenance?.textContent).not.toContain('직렬화 UTF-8 바이트')
    expect(provenance?.textContent).not.toContain('다음 입력에 함께 실리는 상비 페이로드')
  })

  it('renders no provenance line for a non-turn_record source', () => {
    const k = mkKeeper({
      context_ratio: 0.5,
      context_tokens: 100887,
      context_max: 200000,
      context_source: 'keeper_context_status',
    })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.querySelector('[data-testid="ctx-provenance"]')).toBeNull()
  })

  it('opens the memory inspector overlay from the context rail', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    const btn = Array.from(container.querySelectorAll('.cmp-open')).find(
      el => el.textContent?.includes('메모리 보기'),
    ) as HTMLElement | undefined
    expect(btn).toBeTruthy()
    fireEvent.click(btn as HTMLElement)
    expect(container.querySelector('.turn-overlay')).toBeTruthy()
    expect(container.textContent).toContain('Keeper 메모리')
  })

  it('shows the empty state when no tasks are owned', () => {
    tasks.value = []
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.textContent).toContain('할당된 태스크 없음')
  })

  it('renders the design rtc-spec rows from catalog max context/output only', async () => {
    vi.mocked(fetchRuntimeProviders).mockResolvedValueOnce({
      providers: [
        {
          provider: 'ollama_cloud.spec',
          runtime_id: 'ollama_cloud.spec',
          model_api_name: 'spec-model',
          max_context: 131072,
          max_output_tokens: 65536,
          temperature: 0.65,
          top_p: 0.91,
          tools_support: true,
          thinking_support: true,
          streaming: true,
          models: ['spec-model'],
        },
      ],
    } as unknown as Awaited<ReturnType<typeof fetchRuntimeProviders>>)

    const k = mkKeeper({ runtime_canonical: 'ollama_cloud.spec' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)

    await waitFor(() => {
      expect(container.querySelector('.rtc-spec')?.textContent).toContain('최대 컨텍스트')
    })
    const specs = Array.from(container.querySelectorAll('.rtc-spec')).map(node => node.textContent)
    expect(specs[0]).toContain('최대 출력')
    // Sampling row renders only catalog-declared fields — never the design's
    // hardcoded mock (`temp 0.3 · top_p 0.95 · max_tokens 4,096`).
    expect(specs[1]).toContain('샘플링 temp 0.65 · top_p 0.91')
    expect(container.textContent).not.toContain('temp 0.3')
  })

  it('renders rtc-spec placeholders instead of inventing context/output limits', () => {
    const k = mkKeeper({ runtime_canonical: 'runpod_gemma' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    openRuntimeDetail(container)
    const spec = container.querySelector('.rtc-spec')
    expect(spec?.textContent).toContain('최대 컨텍스트 — · 최대 출력 —')
    expect(container.textContent).not.toContain('샘플링')
  })

  it('renders the heartbeat line from the keepalive interval and last heartbeat', () => {
    const k = mkKeeper({
      keeper_keepalive_interval_s: 60,
      last_heartbeat: new Date(Date.now() - 15_000).toISOString(),
    })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    const hb = container.querySelector('.rail-hb')
    expect(hb).not.toBeNull()
    expect(hb?.textContent).toContain('heartbeat 60s')
    expect(hb?.textContent).toContain('다음 wake ~45s')
    expect(hb?.querySelector('.rail-hb-note')?.textContent).toBe('poll')
  })

  it('omits the heartbeat line when no keepalive interval is reported', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.querySelector('.rail-hb')).toBeNull()
  })

  it('marks heartbeat observation errors instead of substituting a stale ETA', () => {
    const k = mkKeeper({
      keeper_keepalive_interval_s: 60,
      last_heartbeat: new Date(Date.now() - 15_000).toISOString(),
      heartbeat_observation_error: 'ledger unreadable',
    })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    const hb = container.querySelector('.rail-hb')
    expect(hb?.textContent).toContain('다음 wake ~—')
    expect(hb?.querySelector('.rail-hb-note')?.textContent).toBe('관측 오류')
    expect(hb?.getAttribute('title')).toBe('ledger unreadable')
  })

  it('renders the drain card with owned tasks while Draining', () => {
    const k = mkKeeper({ lifecycle_phase: 'Draining' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    const card = container.querySelector('.drain-card')
    expect(card).not.toBeNull()
    expect(card?.getAttribute('data-phase')).toBe('Draining')
    expect(container.querySelector('.drain-badge')?.textContent).toBe('Draining')
    expect(container.querySelector('.drain-count')?.textContent).toContain('1건 비우는 중')
    expect(container.querySelector('.drain-t-id')?.textContent).toBe('T-4412')
    expect(container.querySelector('.drain-t-title')?.textContent).toContain('세그먼트 리텐션')
    expect(container.querySelector('.drain-t-state')?.textContent).toBe('in_progress')
    expect(container.textContent).not.toContain('T-9999')
  })

  it('lists queued stimuli from the waiting inventory while Draining', () => {
    const inventory = {
      schema: 'masc.dashboard.keeper_waiting_inventory.v3',
      source: 'server_keeper_waiting_inventory',
      keepers: [
        {
          keeper_name: 'masc-improver',
          state: 'waiting',
          waiting_count: 1,
          waiting_count_truncated: false,
          sources: { event_queue_pending: 1 },
          truncated_sources: {},
          waiting_on: [
            {
              source: 'event_queue_pending',
              waiting_on: 'board_mention',
              what: 'board mention 대기',
              wake_producer: 'board watcher',
              since: 1_800_000_000,
              since_iso: '2027-01-15T00:00:00Z',
              next_action: 'drain',
            },
          ],
        },
      ],
    } as unknown as DashboardKeeperWaitingInventory
    keeperWaitingInventoryStates.value = {
      'masc-improver': { inventory, ready: true, loading: false, error: null },
    }
    const k = mkKeeper({ lifecycle_phase: 'Draining' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.querySelector('.drain-eventq-h')?.textContent).toBe('대기 자극 flush')
    const ev = container.querySelector('.drain-ev')
    expect(ev?.querySelector('.drain-ev-kind')?.textContent).toBe('board_mention')
    expect(ev?.querySelector('.drain-ev-from')?.textContent).toBe('board watcher')
    expect(ev?.querySelector('.drain-ev-at')?.textContent).not.toBe('—')
  })

  it('does not render the drain card for a running keeper', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.querySelector('.drain-card')).toBeNull()
  })
})
