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
    execution_scope: 'workspace',
    sandbox_profile: 'legacy_local',
    network_mode: 'inherit',
    shared_memory_scope: 'disabled',
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
      verify: true,
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
    auto_team_session: {
      status: 'source_only',
      enabled: null,
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
      room_scope: 'global',
      mention_targets: ['sangsu'],
      joined_room_ids: ['default'],
    },
    sources: {
      live_meta_path: '/tmp/.masc/keepers/keeper-sangsu/live.json',
      default_manifest_path: '/tmp/config/keepers/default.toml',
      default_source_kind: 'toml',
      precedence: ['live_meta', 'toml', 'persona'],
      has_live_override: true,
      override_fields: ['goal', 'instructions'],
    },
    tools: {
      tool_access: { kind: 'preset', preset: 'coding' },
      tool_policy_mode: 'preset',
      tool_preset: 'coding',
      tool_also_allow: ['keeper_board_post'],
      tool_custom_allowlist: [],
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
  it('coerceSandboxProfile maps docker_hardened, falls back to legacy_local otherwise', () => {
    expect(coerceSandboxProfile('docker_hardened')).toBe('docker_hardened')
    expect(coerceSandboxProfile('legacy_local')).toBe('legacy_local')
    expect(coerceSandboxProfile('something_else')).toBe('legacy_local')
    expect(coerceSandboxProfile(undefined)).toBe('legacy_local')
    expect(coerceSandboxProfile('')).toBe('legacy_local')
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
    execution_scope: 'workspace',
    sandbox_profile: 'legacy_local',
    network_mode: 'inherit',
    shared_memory_scope: 'disabled',
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
    auto_team_session: {} as KeeperConfig['auto_team_session'],
    handoff: {
      auto: false,
      threshold: 0.9,
      cooldown_sec: 0,
    } as KeeperConfig['handoff'],
    runtime: {} as KeeperConfig['runtime'],
    coordination: {} as KeeperConfig['coordination'],
    tools: {} as KeeperConfig['tools'],
    sources: {} as KeeperConfig['sources'],
    metrics: {} as KeeperConfig['metrics'],
  }
  return { ...base, ...overrides }
}

describe('initRuntimeDraftFromConfig — sandbox fields', () => {
  it('preserves sandbox fields from config', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: 'docker_hardened',
      network_mode: 'none',
      shared_memory_scope: 'room',
    })
    const draft = initRuntimeDraftFromConfig(c)
    expect(draft.sandbox_profile).toBe('docker_hardened')
    expect(draft.network_mode).toBe('none')
    expect(draft.shared_memory_scope).toBe('room')
  })

  it('defaults sandbox fields when config is missing them', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: undefined,
      network_mode: undefined,
      shared_memory_scope: undefined,
    })
    const draft = initRuntimeDraftFromConfig(c)
    expect(draft.sandbox_profile).toBe('legacy_local')
    expect(draft.network_mode).toBe('inherit')
    expect(draft.shared_memory_scope).toBe('disabled')
  })

  it('normalises unknown sandbox values via coerce helpers', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: 'weird',
      network_mode: 'host',
      shared_memory_scope: 'shared',
    })
    const draft = initRuntimeDraftFromConfig(c)
    expect(draft.sandbox_profile).toBe('legacy_local')
    expect(draft.network_mode).toBe('inherit')
    expect(draft.shared_memory_scope).toBe('disabled')
  })
})

describe('buildRuntimePayload — sandbox diffing', () => {
  function draftFrom(config: KeeperConfig, overrides: Partial<RuntimeDraft> = {}): RuntimeDraft {
    return { ...initRuntimeDraftFromConfig(config), ...overrides }
  }

  it('omits sandbox fields when unchanged', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: 'legacy_local',
      network_mode: 'inherit',
      shared_memory_scope: 'disabled',
    })
    const payload = buildRuntimePayload(draftFrom(c), c)
    expect(payload.sandbox_profile).toBeUndefined()
    expect(payload.network_mode).toBeUndefined()
    expect(payload.shared_memory_scope).toBeUndefined()
  })

  it('emits sandbox_profile when toggled on', () => {
    const c = makeKeeperConfigForSandbox({ sandbox_profile: 'legacy_local' })
    const payload = buildRuntimePayload(draftFrom(c, { sandbox_profile: 'docker_hardened' }), c)
    expect(payload.sandbox_profile).toBe('docker_hardened')
  })

  it('emits network_mode when switched to none', () => {
    const c = makeKeeperConfigForSandbox({ network_mode: 'inherit' })
    const payload = buildRuntimePayload(draftFrom(c, { network_mode: 'none' }), c)
    expect(payload.network_mode).toBe('none')
  })

  it('emits shared_memory_scope when toggled to room', () => {
    const c = makeKeeperConfigForSandbox({ shared_memory_scope: 'disabled' })
    const payload = buildRuntimePayload(draftFrom(c, { shared_memory_scope: 'room' }), c)
    expect(payload.shared_memory_scope).toBe('room')
  })

  it('emits all three when switching to hardened+none+room in one save', () => {
    const c = makeKeeperConfigForSandbox({
      sandbox_profile: 'legacy_local',
      network_mode: 'inherit',
      shared_memory_scope: 'disabled',
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      sandbox_profile: 'docker_hardened',
      network_mode: 'none',
      shared_memory_scope: 'room',
    }), c)
    expect(payload.sandbox_profile).toBe('docker_hardened')
    expect(payload.network_mode).toBe('none')
    expect(payload.shared_memory_scope).toBe('room')
  })

  it('treats unknown backend sandbox value as legacy_local for diffing', () => {
    const c = makeKeeperConfigForSandbox({ sandbox_profile: 'some_future_profile' })
    const draft = draftFrom(c)
    expect(draft.sandbox_profile).toBe('legacy_local')
    const payload = buildRuntimePayload(draft, c)
    expect(payload.sandbox_profile).toBeUndefined()
  })
})

const mocks = vi.hoisted(() => ({
  fetchKeeperConfig: vi.fn(async () => makeKeeperConfig()),
  patchKeeperConfig: vi.fn(),
}))

vi.mock('../api/dashboard', () => ({
  fetchKeeperConfig: mocks.fetchKeeperConfig,
  patchKeeperConfig: mocks.patchKeeperConfig,
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
    mocks.patchKeeperConfig.mockClear()
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
    expect(container.textContent).toContain('편집 가능 범위')
    expect(container.textContent).toContain('resolved config root의 cascade.json')
    expect(container.textContent).toContain('런타임 설정')
    expect(container.textContent).toContain('/tmp/.masc/keepers/keeper-sangsu/live.json')
    expect(container.textContent).toContain('활성 모델')
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

  it('patches sandbox runtime controls from the dashboard panel', async () => {
    mocks.patchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        sandbox_profile: 'docker_hardened',
        network_mode: 'none',
        shared_memory_scope: 'room',
      }),
    )

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    const sandboxProfile = container.querySelector('select[aria-label="sandbox_profile"]') as HTMLSelectElement | null
    const networkMode = container.querySelector('select[aria-label="network_mode"]') as HTMLSelectElement | null
    const sharedMemory = container.querySelector('select[aria-label="shared_memory_scope"]') as HTMLSelectElement | null
    expect(sandboxProfile).not.toBeNull()
    expect(networkMode).not.toBeNull()
    expect(sharedMemory).not.toBeNull()

    sandboxProfile!.value = 'docker_hardened'
    sandboxProfile!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    const hardenedNetworkMode = container.querySelector('select[aria-label="network_mode"]') as HTMLSelectElement | null
    expect(hardenedNetworkMode).not.toBeNull()
    hardenedNetworkMode!.value = 'none'
    hardenedNetworkMode!.dispatchEvent(new Event('change', { bubbles: true }))
    sharedMemory!.value = 'room'
    sharedMemory!.dispatchEvent(new Event('change', { bubbles: true }))
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
        sandbox_profile: 'docker_hardened',
        network_mode: 'none',
        shared_memory_scope: 'room',
      }),
    )
  })

  it('supports forced config refresh for already-loaded keepers', async () => {
    await loadKeeperConfig('keeper-sangsu')
    await loadKeeperConfig('keeper-sangsu')
    await loadKeeperConfig('keeper-sangsu', { force: true })

    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(2)
  })
})
