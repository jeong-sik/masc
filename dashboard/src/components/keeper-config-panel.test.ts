import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperConfig, KeeperHookSlot } from '../types'
import {
  buildRuntimePayload,
  coerceNetworkMode,
  coerceSandboxProfile,
  coerceSharedMemoryScope,
  filterHookSlots,
  initRuntimeDraftFromConfig,
  type HookSlotEntry,
  type RuntimeDraft,
} from './keeper-config-panel'

void vi

function makeSlot(overrides: Partial<KeeperHookSlot> = {}): KeeperHookSlot {
  return {
    active: true,
    source: 'default',
    ...overrides,
  }
}

function makeKeeperConfig(overrides: Partial<KeeperConfig> = {}): KeeperConfig {
  return {
    name: 'keeper-sangsu',
    active_goal_ids: ['goal-runtime'],
    sandbox_profile: 'local',
    network_mode: 'inherit',
    sandbox_last_error: null,
    effective_sandbox_image: 'ubuntu:24.04@sha256:test',
    private_workspace_root: '/tmp/project-root/.masc/playground/keeper-sangsu',
    sandbox_environment: {
      base_path: '/tmp/project-root/.masc',
      project_root: '/tmp/project-root',
      docker_playground_enabled: true,
      docker_container_name: 'keeper-playground',
      container_playground_root: '/home/keeper/playground',
      docker_image: 'ubuntu:24.04@sha256:test',
      pids_limit: 128,
      memory: '2g',
      tmpfs_size: '256m',
      seccomp_profile: null,
      require_rootless: false,
      require_userns: false,
    },
    allowed_paths: ['/tmp/workspace'],
    effective_allowed_paths: ['/tmp/workspace'],
    prompt: {
      goal: 'Ship stable keeper ops',
      short_goal: 'Diagnose agent liveness',
      mid_goal: 'Reduce restart confusion',
      long_goal: 'Keep coordination stable',
      will: 'Stay on call',
      needs: 'Accurate runtime state',
      desires: 'Clear operator feedback',
      instructions: 'Prefer direct remediation',
      system_prompt_blocks: {
        constitution: { key: 'keeper.constitution', source: 'file', text: 'constitution text' },
        world: { key: 'keeper.world', source: 'override', text: 'world text' },
        capabilities: { key: 'keeper.capabilities', source: 'file', text: 'capabilities text' },
      },
      effective_system_prompt: 'full prompt',
    },
    execution: {
      models: ['llama:test-balanced'],
      active_model: 'llama:test-balanced',
      per_provider_timeout_sec: null,
      per_provider_timeout_mode: 'turn_budget_heuristic',
      verify: true,
      selected_cascade_name: 'keeper_unified',
      selected_cascade_canonical: 'keeper_unified',
    },
    compaction: {
      profile: 'balanced',
      ratio_gate: 0.85,
      message_gate: 16,
      token_gate: 24000,
      cooldown_sec: 120,
    },
    proactive: {
      enabled: true,
      idle_sec: 900,
      cooldown_sec: 1800,
    },
    drift: {
      status: 'wired',
      enabled: true,
      min_turn_gap: 4,
      count_total: 2,
      last_reason: 'board quiet',
    },
    handoff: {
      auto: true,
      threshold: 0.85,
      cooldown_sec: 300,
    },
    hooks: {
      slots: {},
      deny_list: [],
      deny_list_count: 0,
      destructive_check_tools: ['dynamic_boundary (Tool_dispatch.is_destructive)'],
      cost_budget: {
        active: false,
      },
    },
    runtime: {
      paused: false,
      registered: true,
      keepalive_running: true,
      registry_state: 'running',
      fiber_health: 'healthy',
      presence_keepalive: true,
      presence_keepalive_sec: 30,
    },
    coordination: {
      mention_targets: ['sangsu'],
      joined_room_ids: ['default'],
      active_goal_ids: ['goal-runtime'],
      active_goals: [
        { id: 'goal-runtime', title: 'Ship runtime clarity', horizon: 'mid' },
      ],
      active_goal_count: 1,
      missing_active_goal_ids: [],
    },
    sources: {
      live_meta_path: '/tmp/.masc/keepers/keeper-sangsu/live.json',
      default_manifest_path: '/tmp/config/keepers/default.toml',
      default_source_kind: 'toml',
      precedence: ['live_meta', 'toml', 'persona'],
      has_live_override: true,
      override_fields: ['goal', 'instructions'],
      cascade_catalog_source_kind: 'toml',
      cascade_catalog_source_path: '/tmp/config/cascade.toml',
    },
    tools: {
      tool_access: { kind: 'preset', preset: 'coding' },
      resolved_allowlist: ['keeper_fs_read'],
      tool_denylist: ['keeper_bash'],
      active_masc_tool_count: 1,
      active_keeper_tool_count: 2,
      total_active: 3,
    },
    metrics: {
      generation: 3,
      total_turns: 12,
      total_input_tokens: 1200,
      total_output_tokens: 800,
      total_tokens: 2000,
      total_cost_usd: 0.12,
      last_model_used: 'llama:test-balanced',
      last_input_tokens: 120,
      last_output_tokens: 80,
      last_total_tokens: 200,
      last_latency_ms: 2400,
      last_total_tokens_per_sec: 22.4,
      last_output_tokens_per_sec: 11.2,
      compaction_count: 1,
    },
    ...overrides,
  }
}

describe('filterHookSlots', () => {
  const entries: HookSlotEntry[] = [
    ['pre_tool_call', makeSlot({ source: 'builtin', gates: ['destructive_check', 'path_scope'] })],
    ['post_turn', makeSlot({ source: 'override', effects: ['handoff_auto'] })],
    ['compaction_watcher', makeSlot({ source: 'persona', features: ['ratio_gate'] })],
    ['orphan', makeSlot({ source: 'builtin' })],
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterHookSlots(entries, '')).toBe(entries)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterHookSlots(entries, '   ')).toBe(entries)
  })

  it('matches by slot name substring (case-insensitive)', () => {
    const result = filterHookSlots(entries, 'POST')
    expect(result.map(([name]) => name)).toEqual(['post_turn'])
  })

  it('matches by source substring', () => {
    const result = filterHookSlots(entries, 'persona')
    expect(result.map(([name]) => name)).toEqual(['compaction_watcher'])
  })

  it('matches by gates entry', () => {
    const result = filterHookSlots(entries, 'destructive_check')
    expect(result.map(([name]) => name)).toEqual(['pre_tool_call'])
  })

  it('matches by effects entry', () => {
    const result = filterHookSlots(entries, 'handoff_auto')
    expect(result.map(([name]) => name)).toEqual(['post_turn'])
  })

  it('matches by features entry', () => {
    const result = filterHookSlots(entries, 'ratio_gate')
    expect(result.map(([name]) => name)).toEqual(['compaction_watcher'])
  })

  it('returns empty when nothing matches', () => {
    expect(filterHookSlots(entries, 'nonexistent-token')).toHaveLength(0)
  })

  it('trims query before matching', () => {
    expect(filterHookSlots(entries, '  orphan  ')).toHaveLength(1)
  })

  it('does not mutate the input array', () => {
    const copy = entries.slice()
    filterHookSlots(entries, 'pre_tool')
    expect(entries).toEqual(copy)
  })

  it('handles slots with missing gates/effects/features safely', () => {
    const sparse: HookSlotEntry[] = [
      ['bare', makeSlot({ source: '' })],
    ]
    expect(filterHookSlots(sparse, 'bare')).toHaveLength(1)
    expect(filterHookSlots(sparse, 'anything-else')).toHaveLength(0)
  })
})

describe('sandbox coerce helpers', () => {
  it('coerceSandboxProfile maps docker, falls back to local otherwise', () => {
    expect(coerceSandboxProfile('docker')).toBe('docker')
    expect(coerceSandboxProfile('local')).toBe('local')
    expect(coerceSandboxProfile('something_else')).toBe('local')
    expect(coerceSandboxProfile(undefined)).toBe('local')
    expect(coerceSandboxProfile('')).toBe('local')
  })

  it('coerceNetworkMode maps none, falls back to inherit otherwise', () => {
    expect(coerceNetworkMode('none')).toBe('none')
    expect(coerceNetworkMode('inherit')).toBe('inherit')
    expect(coerceNetworkMode('host')).toBe('inherit')
    expect(coerceNetworkMode(undefined)).toBe('inherit')
  })

  it('coerceSharedMemoryScope maps room, falls back to disabled otherwise', () => {
    expect(coerceSharedMemoryScope('room')).toBe('room')
    expect(coerceSharedMemoryScope('disabled')).toBe('disabled')
    expect(coerceSharedMemoryScope('unknown')).toBe('disabled')
    expect(coerceSharedMemoryScope(undefined)).toBe('disabled')
  })
})

function makeKeeperConfigForSandbox(overrides: Partial<KeeperConfig> = {}): KeeperConfig {
  const base: KeeperConfig = {
    name: 'test-keeper',
    active_goal_ids: [],
    sandbox_profile: 'local',
    network_mode: 'inherit',
    allowed_paths: [],
    effective_allowed_paths: [],
    prompt: {} as KeeperConfig['prompt'],
    execution: {} as KeeperConfig['execution'],
    compaction: {
      ratio_gate: 0.8,
      message_gate: 0,
      token_gate: 0,
      cooldown_sec: 0,
    } as KeeperConfig['compaction'],
    proactive: {
      enabled: false,
      idle_sec: 0,
      cooldown_sec: 0,
    } as KeeperConfig['proactive'],
    drift: {} as KeeperConfig['drift'],
    handoff: {
      auto: false,
      threshold: 0.9,
      cooldown_sec: 0,
    } as KeeperConfig['handoff'],
    runtime: {} as KeeperConfig['runtime'],
    coordination: {
      mention_targets: [],
      joined_room_ids: [],
      active_goal_ids: [],
      active_goals: [],
      active_goal_count: 0,
      missing_active_goal_ids: [],
    },
    tools: {} as KeeperConfig['tools'],
    sources: {} as KeeperConfig['sources'],
    metrics: {} as KeeperConfig['metrics'],
  }
  return { ...base, ...overrides }
}

describe('initRuntimeDraftFromConfig — sandbox fields', () => {
  it('preserves sandbox fields from config', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: 'docker',
      network_mode: 'none',
    })
    const draft = initRuntimeDraftFromConfig(c)
    expect(draft.sandbox_profile).toBe('docker')
    expect(draft.network_mode).toBe('none')
  })

  it('defaults sandbox fields when config is missing them', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: undefined,
      network_mode: undefined,
    })
    const draft = initRuntimeDraftFromConfig(c)
    expect(draft.sandbox_profile).toBe('local')
    expect(draft.network_mode).toBe('inherit')
  })

  it('normalises unknown sandbox values via coerce helpers', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: 'weird',
      network_mode: 'host',
    })
    const draft = initRuntimeDraftFromConfig(c)
    expect(draft.sandbox_profile).toBe('local')
    expect(draft.network_mode).toBe('inherit')
  })
})

describe('buildRuntimePayload — sandbox diffing', () => {
  function draftFrom(config: KeeperConfig, overrides: Partial<RuntimeDraft> = {}): RuntimeDraft {
    return { ...initRuntimeDraftFromConfig(config), ...overrides }
  }

  it('omits sandbox fields when unchanged', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: 'local',
      network_mode: 'inherit',
    })
    const payload = buildRuntimePayload(draftFrom(c), c)
    expect(payload.sandbox_profile).toBeUndefined()
    expect(payload.network_mode).toBeUndefined()
  })

  it('emits sandbox_profile when toggled on', () => {
    const c = makeKeeperConfigForSandbox({ sandbox_profile: 'local' })
    const payload = buildRuntimePayload(draftFrom(c, { sandbox_profile: 'docker' }), c)
    expect(payload.sandbox_profile).toBe('docker')
  })

  it('emits network_mode when switched to none', () => {
    const c = makeKeeperConfigForSandbox({ network_mode: 'inherit' })
    const payload = buildRuntimePayload(draftFrom(c, { network_mode: 'none' }), c)
    expect(payload.network_mode).toBe('none')
  })

  it('emits all three when switching to hardened+none+room in one save', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: 'local',
      network_mode: 'inherit',
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      sandbox_profile: 'docker',
      network_mode: 'none',
    }), c)
    expect(payload.sandbox_profile).toBe('docker')
    expect(payload.network_mode).toBe('none')
  })

  it('treats unknown backend sandbox value as local for diffing', () => {
    const c = makeKeeperConfigForSandbox({ sandbox_profile: 'some_future_profile' })
    const draft = draftFrom(c)
    expect(draft.sandbox_profile).toBe('local')
    const payload = buildRuntimePayload(draft, c)
    expect(payload.sandbox_profile).toBeUndefined()
  })

  it('emits active_goal_ids when goal bindings change', () => {
    const c = makeKeeperConfigForSandbox({
      active_goal_ids: ['goal-a'],
      coordination: {
        mention_targets: [],
        joined_room_ids: [],
        active_goal_ids: ['goal-a'],
        active_goals: [{ id: 'goal-a', title: 'Goal A', horizon: 'short' }],
        active_goal_count: 1,
        missing_active_goal_ids: [],
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      active_goal_ids: ['goal-b', 'goal-c'],
    }), c)
    expect(payload.active_goal_ids).toEqual(['goal-b', 'goal-c'])
  })
})

const mocks = vi.hoisted(() => ({
  fetchKeeperConfig: vi.fn(async () => makeKeeperConfig()),
  fetchDashboardGoalsTree: vi.fn(async () => ({
    tree: [
      {
        id: 'goal-runtime',
        title: 'Ship runtime clarity',
        horizon: 'mid',
        status: 'active',
        status_color: '#4ade80',
        phase: 'executing',
        phase_color: '#4ade80',
        health: 'on_track',
        health_color: '#4ade80',
        badges: [],
        status_reason: '',
        priority: 2,
        metric: null,
        target_value: null,
        due_date: null,
        parent_goal_id: null,
        convergence: 0,
        convergence_pct: 0,
        tasks: [],
        task_count: 0,
        task_done_count: 0,
        verification_summary: {
          required_votes: 0,
          approve_votes: 0,
          reject_votes: 0,
          pending_votes: 0,
          quorum_met: false,
          rejected: false,
          votes: [],
        },
        pending_verification_count: 0,
        timeline_events: [],
        children: [],
        child_count: 0,
        last_activity_at: '',
        stagnation_seconds: 0,
        linked_keeper_names: [],
        pending_approval_count: 0,
        infra_risk_count: 0,
        linkage_source: 'none',
        linkage_warning_count: 0,
        blocking_source: 'none',
        blocking_reason: '',
        created_at: '',
        updated_at: '',
      },
    ],
    summary: {
      total_goals: 1,
      active_goals: 1,
      on_track_goals: 1,
      done_goals: 0,
      paused_goals: 0,
      at_risk_goals: 0,
      blocked_goals: 0,
      total_tasks: 0,
      done_tasks: 0,
      pending_approvals: 0,
      infra_risk_count: 0,
      overall_convergence: 0,
      overall_convergence_pct: 0,
    },
  })),
  fetchCascadeProfiles: vi.fn(async () => ({
    profiles: ['keeper_unified', 'resilient_breaker'],
    invalid_profiles: [
      {
        name: 'broken_profile',
        errors: ['missing models'],
      },
    ],
  })),
  patchKeeperConfig: vi.fn(),
  updateKeeperCascade: vi.fn(async () => ({ ok: true })),
}))

vi.mock('../api/dashboard', () => ({
  fetchCascadeProfiles: mocks.fetchCascadeProfiles,
  fetchDashboardGoalsTree: mocks.fetchDashboardGoalsTree,
  fetchKeeperConfig: mocks.fetchKeeperConfig,
  patchKeeperConfig: mocks.patchKeeperConfig,
  updateKeeperCascade: mocks.updateKeeperCascade,
}))

import { KeeperConfigPanel, loadKeeperConfig, resetKeeperConfig } from './keeper-config-panel'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('KeeperConfigPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetKeeperConfig()
    mocks.fetchKeeperConfig.mockClear()
    mocks.fetchDashboardGoalsTree.mockClear()
    mocks.fetchCascadeProfiles.mockClear()
    mocks.patchKeeperConfig.mockClear()
    mocks.updateKeeperCascade.mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetKeeperConfig()
  })

  it('separates editable prompt controls from read-only runtime metadata', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(1)
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    expect(mocks.fetchCascadeProfiles).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('편집 가능 범위')
    expect(container.textContent).toContain('keeper TOML의 cascade_name')
    expect(container.textContent).toContain('Cascade 선택')
    expect(container.textContent).toContain('keeper_unified')
    expect(container.textContent).toContain('broken_profile')
    expect(container.textContent).toContain('/tmp/config/keepers/default.toml')
    expect(container.textContent).toContain('/tmp/config/cascade.toml')
    expect(container.textContent).toContain('런타임 설정')
    expect(container.textContent).toContain('active_goal_ids')
    expect(container.textContent).toContain('Ship runtime clarity')
    expect(container.textContent).toContain('/tmp/.masc/keepers/keeper-sangsu/live.json')
    expect(container.textContent).toContain('활성 런타임')
    expect(container.textContent).toContain('레지스트리 상태')
    expect(container.textContent).toContain('running')
    expect(container.textContent).toContain('dynamic_boundary (Tool_dispatch.is_destructive)')
    expect(container.textContent).toContain('/tmp/project-root')

    const editButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('편집'),
    )
    editButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    const textareas = Array.from(container.querySelectorAll('textarea'))
    expect(textareas.length).toBeGreaterThan(0)
    expect(textareas[0]?.value).toContain('Ship stable keeper ops')
  })

  it('exposes cascade selection controls directly in the config panel', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    const cascadeSelect = Array.from(container.querySelectorAll('select')).find(
      (select) => !select.getAttribute('aria-label'),
    ) as HTMLSelectElement | undefined
    expect(cascadeSelect).toBeDefined()
    expect(cascadeSelect?.value).toBe('keeper_unified')

    mocks.fetchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        execution: {
          models: ['llama:test-balanced'],
          active_model: 'llama:test-balanced',
          per_provider_timeout_sec: null,
          per_provider_timeout_mode: 'turn_budget_heuristic',
          verify: true,
          selected_cascade_name: 'resilient_breaker',
          selected_cascade_canonical: 'resilient_breaker',
        },
      }),
    )

    cascadeSelect!.value = 'resilient_breaker'
    cascadeSelect!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.updateKeeperCascade).toHaveBeenCalledWith(
      'keeper-sangsu',
      'resilient_breaker',
    )
    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(2)
  })

  it('patches sandbox runtime controls from the dashboard panel', async () => {
    mocks.patchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        sandbox_profile: 'docker',
        network_mode: 'none',
      }),
    )

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    const sandboxProfile = container.querySelector('select[aria-label="sandbox_profile"]') as HTMLSelectElement | null
    const networkMode = container.querySelector('select[aria-label="network_mode"]') as HTMLSelectElement | null
    expect(sandboxProfile).not.toBeNull()
    expect(networkMode).not.toBeNull()

    sandboxProfile!.value = 'docker'
    sandboxProfile!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    const hardenedNetworkMode = container.querySelector('select[aria-label="network_mode"]') as HTMLSelectElement | null
    expect(hardenedNetworkMode).not.toBeNull()
    hardenedNetworkMode!.value = 'none'
    hardenedNetworkMode!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('런타임 설정 저장'),
    )
    saveButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.patchKeeperConfig).toHaveBeenCalledWith(
      'keeper-sangsu',
      expect.objectContaining({
        sandbox_profile: 'docker',
        network_mode: 'none',
      }),
    )
  })

  it('shows the sandbox preflight guide when docker is selected', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    expect(container.textContent).not.toContain('Docker Sandbox 프리플라이트')

    const sandboxProfile = container.querySelector('select[aria-label="sandbox_profile"]') as HTMLSelectElement | null
    expect(sandboxProfile).not.toBeNull()

    sandboxProfile!.value = 'docker'
    sandboxProfile!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    expect(container.textContent).toContain('Docker Sandbox 프리플라이트')
  })

  it('supports forced config refresh for already-loaded keepers', async () => {
    await loadKeeperConfig('keeper-sangsu')
    await loadKeeperConfig('keeper-sangsu')
    await loadKeeperConfig('keeper-sangsu', { force: true })

    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(2)
  })
})
