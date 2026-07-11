import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperConfig, KeeperHookSlot } from '../types'
import {
  buildRuntimePayload,
  coerceNetworkMode,
  coerceSandboxProfile,
  filterHookSlots,
  hookSlotDetails,
  initRuntimeDraftFromConfig,
  KCF_TAB_IDS,
  keeperConfigControlContractStatus,
  keeperConfigControlInventory,
  keeperRuntimeConfigCanWrite,
  keeperRuntimeConfigWriteUnsupportedReason,
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
    autoboot_enabled: true,
    max_context_override: null,
    limits: {
      min_context_override_tokens: 64_000,
      max_context_override_tokens: 1_000_000,
    },
    sandbox_profile: 'local',
    network_mode: 'inherit',
    sandbox_last_error: null,
    allowed_paths: ['/tmp/workspace'],
    effective_allowed_paths: ['/tmp/workspace'],
    prompt: {
      goal: 'Ship stable keeper ops',
      instructions: 'Prefer direct remediation',
      system_prompt_blocks: {
        constitution: { key: 'keeper.constitution', source: 'file', text: 'constitution text' },
        world: { key: 'keeper.world', source: 'override', text: 'world text' },
        capabilities: { key: 'keeper.capabilities', source: 'file', text: 'capabilities text' },
      },
      effective_system_prompt: 'full prompt',
      unified_system_prompt: 'unified prompt',
      unified_user_message_preview: 'world state',
    },
    execution: {
      models: ['llama:test-balanced'],
      active_model: 'llama:test-balanced',
      per_provider_timeout_sec: null,
      per_provider_timeout_mode: 'turn_budget_default',
      verify: true,
      selected_runtime_id: 'tier-group.keeper_unified',
      selected_runtime_canonical: 'tier-group.keeper_unified',
      runtime_options: ['tier-group.keeper_unified', 'tier.resilient_breaker'],
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
    },
    workspace: {
      mention_targets: ['sangsu'],
      bound_workspace_ids: ['default'],
      active_goal_ids: ['goal-runtime'],
      active_goals: [
        { id: 'goal-runtime', title: 'Ship runtime clarity' },
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
    },
    tools: {
      tool_access: ['tool_read_file'],
      resolved_allowlist: ['tool_read_file'],
      tool_denylist: ['Execute'],
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

  // Regression: the live normalizer (normalizeKeeperHookSlot) fills absent
  // categories with `[]`, NOT `undefined`. The old
  // `slot.gates ?? slot.effects ?? slot.features` chain stopped at the empty
  // `gates` array, so an effects-/features-only slot was unfilterable. These
  // fixtures use the production shape (empty arrays) to lock the fix in.
  it('matches effects/features tags on production-shaped slots (empty [] categories)', () => {
    const live: HookSlotEntry[] = [
      ['after_turn', makeSlot({ gates: [], effects: ['cost_event'], features: [] })],
      ['before_turn', makeSlot({ gates: [], effects: [], features: ['utf8_guard'] })],
    ]
    expect(filterHookSlots(live, 'cost_event')).toHaveLength(1)
    expect(filterHookSlots(live, 'utf8_guard')).toHaveLength(1)
  })

  it('matches a feature on a slot that also carries gates (categories coexist)', () => {
    const coexist: HookSlotEntry[] = [
      ['pre_tool_use', makeSlot({ gates: ['keeper_deny_list'], features: ['cost_telemetry_threshold'] })],
    ]
    // The cost-telemetry feature must remain searchable even though gates is non-empty.
    expect(filterHookSlots(coexist, 'cost_telemetry_threshold')).toHaveLength(1)
    expect(filterHookSlots(coexist, 'keeper_deny_list')).toHaveLength(1)
  })
})

describe('hookSlotDetails', () => {
  it('concatenates gates, effects and features in that order', () => {
    expect(
      hookSlotDetails(makeSlot({ gates: ['g1'], effects: ['e1'], features: ['f1'] })),
    ).toEqual(['g1', 'e1', 'f1'])
  })

  it('returns the lone populated category for single-category slots', () => {
    expect(hookSlotDetails(makeSlot({ gates: [], effects: ['cost_event'], features: [] }))).toEqual([
      'cost_event',
    ])
  })

  it('returns [] when no category is present (undefined-safe)', () => {
    expect(hookSlotDetails(makeSlot({ source: 'not_registered' }))).toEqual([])
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

})

describe('keeperRuntimeConfigCanWrite', () => {
  it('allows writes only for a TOML-backed keeper manifest', () => {
    const base = makeKeeperConfig()
    expect(keeperRuntimeConfigCanWrite(base)).toBe(true)
    expect(keeperRuntimeConfigWriteUnsupportedReason(base)).toBeNull()
  })

  it('rejects persona-backed config even when a path-like value is present', () => {
    const base = makeKeeperConfig()
    const c = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: 'persona',
        default_manifest_path: '/tmp/config/keepers/default.toml',
      },
    })

    expect(keeperRuntimeConfigCanWrite(c)).toBe(false)
    expect(keeperRuntimeConfigWriteUnsupportedReason(c)).toContain('현재 기본 소스: persona')
  })

  it('rejects TOML config without a manifest path', () => {
    const base = makeKeeperConfig()
    const c = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: 'toml',
        default_manifest_path: null,
      },
    })

    expect(keeperRuntimeConfigCanWrite(c)).toBe(false)
    expect(keeperRuntimeConfigWriteUnsupportedReason(c)).toContain('기본 매니페스트 경로')
  })
})

describe('keeperConfigControlInventory', () => {
  function findItem(tab: (typeof KCF_TAB_IDS)[number], c: KeeperConfig, id: string) {
    const item = keeperConfigControlInventory(tab, c).find((entry) => entry.id === id)
    if (!item) throw new Error(`inventory item missing: ${id}`)
    return item
  }

  it('backs every tab with at least one uniquely identified row', () => {
    const c = makeKeeperConfig()
    const ids = new Set<string>()
    for (const tab of KCF_TAB_IDS) {
      const rows = keeperConfigControlInventory(tab, c)
      expect(rows.length).toBeGreaterThan(0)
      for (const row of rows) {
        expect(row.tab).toBe(tab)
        expect(ids.has(row.id)).toBe(false)
        ids.add(row.id)
      }
    }
  })

  it('ties every ledger row to structured field, api, local-state, or unsupported contracts', () => {
    const c = makeKeeperConfig()
    for (const tab of KCF_TAB_IDS) {
      for (const row of keeperConfigControlInventory(tab, c)) {
        expect(row.contracts.length, row.id).toBeGreaterThan(0)
        const contractKinds = row.contracts.map(contract => contract.kind)
        if (row.kind === 'browser-local') {
          expect(contractKinds, row.id).toContain('browser-state')
          expect(contractKinds, row.id).not.toContain('keeper-config-field')
        } else if (row.kind === 'unsupported') {
          expect(contractKinds, row.id).toContain('unsupported')
        } else {
          expect(
            contractKinds.includes('api') || contractKinds.includes('keeper-config-field'),
            row.id,
          ).toBe(true)
        }
      }
    }
  })

  it('records exact api contracts for controls that are easy to drift from their source text', () => {
    const c = makeKeeperConfig()

    expect(findItem('runtime', c, 'kcf-runtime-catalog').contracts).toContainEqual({
      kind: 'api',
      method: 'GET',
      endpoint: '/api/v1/providers',
    })
    expect(findItem('policy', c, 'kcf-policy-tool-policy').contracts).toContainEqual({
      kind: 'api',
      method: 'POST',
      endpoint: '/api/v1/keepers/:name/tools',
      operation: 'set_policy',
    })
    expect(findItem('goals', c, 'kcf-goals-catalog-filter').contracts).toContainEqual({
      kind: 'api',
      method: 'GET',
      endpoint: '/api/v1/dashboard/goals',
    })
    expect(findItem('health', c, 'kcf-health-directives').contracts).toContainEqual({
      kind: 'api',
      method: 'POST',
      endpoint: '/api/v1/keepers/:name/directive',
      operation: 'pause/resume/wakeup',
    })
  })

  it('classifies runtime-backed controls from the manifest writer guard', () => {
    const toml = makeKeeperConfig()
    const base = makeKeeperConfig()
    const persona = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: 'persona',
        default_manifest_path: null,
      },
    })

    const runtimeWrite = findItem('runtime', toml, 'kcf-runtime-assignment')
    expect(runtimeWrite.kind).toBe('live-write')
    expect(runtimeWrite.action).toContain('PATCH /api/v1/keepers/:name/config runtime_id')
    expect(runtimeWrite.contracts).toContainEqual({
      kind: 'keeper-config-field',
      path: 'execution.selected_runtime_id',
    })
    expect(runtimeWrite.contracts).toContainEqual({
      kind: 'api',
      method: 'PATCH',
      endpoint: '/api/v1/keepers/:name/config',
      operation: 'runtime_id',
    })

    const runtimeUnsupported = findItem('runtime', persona, 'kcf-runtime-assignment')
    expect(runtimeUnsupported.kind).toBe('unsupported')
    expect(runtimeUnsupported.action).toContain('현재 기본 소스: persona')
    expect(runtimeUnsupported.contracts).toContainEqual({
      kind: 'unsupported',
      reason: expect.stringContaining('현재 기본 소스: persona'),
    })
  })

  it('reports missing optional config fields without treating present nulls as absent', () => {
    const c = makeKeeperConfig({ hooks: undefined })

    const hookSlots = findItem('hooks', c, 'kcf-hooks-slots')
    const hookStatus = keeperConfigControlContractStatus(hookSlots.contracts, c)
    expect(hookStatus.kind).toBe('missing-config-field')
    expect(hookStatus.missingConfigFields).toEqual(['hooks.slots', 'hooks.deny_list', 'hooks.cost_budget'])

    const contextOverride = findItem('runtime', c, 'kcf-runtime-context-override')
    const contextStatus = keeperConfigControlContractStatus(contextOverride.contracts, c)
    expect(contextStatus.kind).toBe('ok')
  })

  it('uses backend field-presence proof instead of normalized defaults for contract gaps', () => {
    const c = makeKeeperConfig({
      field_presence: {
        schema: 'keeper.config.field_presence.v1',
        producer: 'dashboard_http_keeper_snapshot',
        present_paths: ['hooks', 'hooks.slots'],
      },
    })

    const hookSlots = findItem('hooks', c, 'kcf-hooks-slots')
    const hookStatus = keeperConfigControlContractStatus(hookSlots.contracts, c)

    expect(c.hooks?.deny_list).toEqual([])
    expect(hookStatus.kind).toBe('missing-config-field')
    expect(hookStatus.missingConfigFields).toEqual(['hooks.deny_list', 'hooks.cost_budget'])
  })

  it('keeps separate API writers live even when runtime manifest writes are unsupported', () => {
    const base = makeKeeperConfig()
    const persona = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: 'persona',
        default_manifest_path: null,
      },
    })

    expect(findItem('policy', persona, 'kcf-policy-continuity').kind).toBe('unsupported')
    expect(findItem('policy', persona, 'kcf-policy-tool-policy').kind).toBe('live-write')
    expect(findItem('health', persona, 'kcf-health-directives').kind).toBe('live-write')
  })

  it('marks hooks as read-only global state plus browser-local filtering, not a fake editor', () => {
    const c = makeKeeperConfig()
    expect(findItem('hooks', c, 'kcf-hooks-slots').kind).toBe('live-read')
    expect(findItem('hooks', c, 'kcf-hooks-filter').kind).toBe('browser-local')
    expect(findItem('hooks', c, 'kcf-hooks-editing').kind).toBe('unsupported')
  })
})

function makeKeeperConfigForSandbox(overrides: Partial<KeeperConfig> = {}): KeeperConfig {
  const base: KeeperConfig = {
    name: 'test-keeper',
    active_goal_ids: [],
    autoboot_enabled: true,
    max_context_override: null,
    limits: {
      min_context_override_tokens: 64_000,
      max_context_override_tokens: 1_000_000,
    },
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
    workspace: {
      mention_targets: [],
      bound_workspace_ids: [],
      active_goal_ids: [],
      active_goals: [],
      active_goal_count: 0,
      missing_active_goal_ids: [],
    },
    tools: {
      tool_access: [],
      resolved_allowlist: [],
      tool_denylist: [],
      active_masc_tool_count: 0,
      active_keeper_tool_count: 0,
      total_active: 0,
    },
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

  it('preserves runtime_id from config', () => {
    const c = makeKeeperConfigForSandbox({
      execution: {
        selected_runtime_id: 'runpod_mtp.qwen36-35b-a3b-mtp',
      } as KeeperConfig['execution'],
    })
    const draft = initRuntimeDraftFromConfig(c)
    expect(draft.runtime_id).toBe('runpod_mtp.qwen36-35b-a3b-mtp')
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

  it('omits compaction_token_gate when unchanged but emits it when edited', () => {
    const c = makeKeeperConfigForSandbox({})
    // Unchanged draft → not in payload.
    expect(buildRuntimePayload(draftFrom(c), c).compaction_token_gate).toBeUndefined()
    // Editing the token gate (now reachable via the InlineNumberRow) → emitted.
    const edited = buildRuntimePayload(
      draftFrom(c, { compaction_token_gate: c.compaction.token_gate + 4096 }),
      c,
    )
    expect(edited.compaction_token_gate).toBe(c.compaction.token_gate + 4096)
  })

  it('emits runtime_id when selected runtime changes', () => {
    const c = makeKeeperConfigForSandbox({
      execution: {
        selected_runtime_id: 'tier-group.keeper_unified',
      } as KeeperConfig['execution'],
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      runtime_id: 'runpod_mtp.qwen36-35b-a3b-mtp',
    }), c)
    expect(payload.runtime_id).toBe('runpod_mtp.qwen36-35b-a3b-mtp')
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

  it('emits all three when switching to hardened+none+workspace in one save', () => {
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
      workspace: {
        mention_targets: [],
        bound_workspace_ids: [],
        active_goal_ids: ['goal-a'],
        active_goals: [{ id: 'goal-a', title: 'Goal A' }],
        active_goal_count: 1,
        missing_active_goal_ids: [],
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      active_goal_ids: ['goal-b', 'goal-c'],
    }), c)
    expect(payload.active_goal_ids).toEqual(['goal-b', 'goal-c'])
  })

  it('normalizes line-based runtime list drafts through one path', () => {
    const c = makeKeeperConfigForSandbox({
      allowed_paths: ['workspace/masc'],
      workspace: {
        mention_targets: ['sangsu'],
        bound_workspace_ids: [],
        active_goal_ids: [],
        active_goals: [],
        active_goal_count: 0,
        missing_active_goal_ids: [],
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      allowed_paths_text: 'workspace/masc\n workspace/oas \nworkspace/oas\n',
      mention_targets_text: 'alpha\n beta \nalpha\n',
    }), c)

    expect(payload.allowed_paths).toEqual(['workspace/masc', 'workspace/oas'])
    expect(payload.mention_targets).toEqual(['alpha', 'beta'])
  })

  it('emits explicit empty mention targets when the draft is cleared', () => {
    const c = makeKeeperConfigForSandbox({
      workspace: {
        mention_targets: ['sangsu'],
        bound_workspace_ids: [],
        active_goal_ids: [],
        active_goals: [],
        active_goal_count: 0,
        missing_active_goal_ids: [],
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      mention_targets_text: '',
    }), c)

    expect(payload.mention_targets).toEqual([])
  })

  it('emits compaction_token_gate when the token gate changes', () => {
    const c = makeKeeperConfigForSandbox({
      compaction: {
        profile: 'balanced',
        ratio_gate: 0.8,
        message_gate: 0,
        token_gate: 24000,
        cooldown_sec: 0,
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      compaction_token_gate: 32000,
    }), c)
    expect(payload.compaction_token_gate).toBe(32000)
  })

  it('emits compaction_profile, autoboot, and max_context_override edits', () => {
    const c = makeKeeperConfigForSandbox({
      autoboot_enabled: true,
      max_context_override: null,
      compaction: {
        profile: 'balanced',
        ratio_gate: 0.8,
        message_gate: 0,
        token_gate: 24000,
        cooldown_sec: 0,
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      autoboot_enabled: false,
      max_context_override: 64000,
      compaction_profile: 'conservative',
    }), c)
    expect(payload.autoboot_enabled).toBe(false)
    expect(payload.max_context_override).toBe(64000)
    expect(payload.compaction_profile).toBe('conservative')
  })

  it('emits null to clear max_context_override when draft is zero', () => {
    const c = makeKeeperConfigForSandbox({ max_context_override: 64000 })
    const payload = buildRuntimePayload(draftFrom(c, {
      max_context_override: 0,
    }), c)
    expect(payload.max_context_override).toBeNull()
  })

  it('clamps max_context_override to the backend keeper bound before PATCH', () => {
    const c = makeKeeperConfigForSandbox({
      max_context_override: null,
      limits: {
        min_context_override_tokens: 64_000,
        max_context_override_tokens: 128_000,
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      max_context_override: 128_001,
    }), c)
    expect(payload.max_context_override).toBe(128_000)
  })
})

const mocks = vi.hoisted(() => {
  const goalFixtureOkColor = '#4ade80'
  return {
    goalFixtureOkColor,
    fetchKeeperConfig: vi.fn(async () => makeKeeperConfig()),
    fetchDashboardGoalsTree: vi.fn(async () => ({
      tree: [
        {
          id: 'goal-runtime',
          title: 'Ship runtime clarity',
          status: 'active',
          status_color: goalFixtureOkColor,
          phase: 'executing',
          phase_color: goalFixtureOkColor,
          health: 'on_track',
          health_color: goalFixtureOkColor,
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
    fetchRuntimeProfiles: vi.fn(async () => ({
      profiles: ['tier-group.keeper_unified', 'tier.resilient_breaker'],
      invalid_profiles: [
        {
          name: 'tier.broken_profile',
          errors: ['missing models'],
        },
      ],
    })),
    fetchRuntimeProviders: vi.fn(async () => ({
      updated_at: '2026-07-05T00:00:00Z',
      summary: {
        providers: 1,
        runtimes: 1,
        local_models: 0,
        cloud_models: 1,
        cli_models: 0,
        default_runtime_id: 'tier-group.keeper_unified',
      },
      providers: [
        {
          provider: 'tier-group.keeper_unified',
          runtime_id: 'tier-group.keeper_unified',
          provider_id: 'runpod_mtp',
          provider_display_name: 'RunPod MTP',
          model_id: 'qwen',
          model_api_name: 'Qwen/Qwen3-32B',
          models: ['Qwen/Qwen3-32B'],
          status: 'configured',
          available: true,
          source: 'runtime.toml',
          supports_multimodal_inputs: true,
          supports_image_input: true,
          supports_audio_input: true,
          supports_video_input: false,
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
            has_model_capabilities_override: true,
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
                uses_anthropic_caching: false,
                max_turns_per_attempt: 3,
                tolerates_bound_actor_fallback: true,
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
    })),
    patchKeeperConfig: vi.fn(),
    refreshKeeperRuntimeStatus: vi.fn(async () => undefined),
    showToast: vi.fn(),
    updateKeeperRuntime: vi.fn(async () => ({ ok: true })),
    setKeeperToolPolicy: vi.fn(async () => makeKeeperConfig()),
    fetchDashboardTools: vi.fn(async () => ({
      tool_inventory: {
        count: 3,
        tools: [
          { name: 'tool_read_file', description: 'Read a file', category: 'read', enabled_in_current_mode: true, direct_call_allowed: true, doc_refs: [], prompt_hints: [], surfaces: [], visibility: 'public', lifecycle: 'stable', implementationStatus: 'implemented', tier: 'core' },
          { name: 'masc_status', description: 'Read workspace status', category: 'coordination', enabled_in_current_mode: true, direct_call_allowed: true, doc_refs: [], prompt_hints: [], surfaces: [], visibility: 'public', lifecycle: 'stable', implementationStatus: 'implemented', tier: 'core' },
          { name: 'Execute', description: 'Run a shell command', category: 'write', enabled_in_current_mode: true, direct_call_allowed: true, doc_refs: [], prompt_hints: [], surfaces: [], visibility: 'public', lifecycle: 'stable', implementationStatus: 'implemented', tier: 'core' },
        ],
      },
    })),
    pauseKeeper: vi.fn(async () => ({ ok: true, action: 'pause', name: 'keeper-sangsu' })),
    resumeKeeper: vi.fn(async () => ({ ok: true, action: 'resume', name: 'keeper-sangsu' })),
    wakeKeeper: vi.fn(async () => ({ ok: true, action: 'wakeup', name: 'keeper-sangsu' })),
    // access tab surfaces the GitHub App panel, which reads secret_projection
    // from the keeper composite; no existing config in the default fixture.
    fetchKeeperComposite: vi.fn(async () => ({ secret_projection: null })),
  }
})

vi.mock('../api/dashboard', () => ({
  fetchRuntimeProfiles: mocks.fetchRuntimeProfiles,
  fetchDashboardGoalsTree: mocks.fetchDashboardGoalsTree,
  fetchKeeperConfig: mocks.fetchKeeperConfig,
  fetchRuntimeProviders: mocks.fetchRuntimeProviders,
  patchKeeperConfig: mocks.patchKeeperConfig,
  updateKeeperRuntime: mocks.updateKeeperRuntime,
  setKeeperToolPolicy: mocks.setKeeperToolPolicy,
  fetchDashboardTools: mocks.fetchDashboardTools,
}))

vi.mock('../api/keeper', () => ({
  pauseKeeper: mocks.pauseKeeper,
  resumeKeeper: mocks.resumeKeeper,
  wakeKeeper: mocks.wakeKeeper,
  fetchKeeperComposite: mocks.fetchKeeperComposite,
}))

vi.mock('../store', () => ({
  refreshKeeperRuntimeStatus: mocks.refreshKeeperRuntimeStatus,
}))

vi.mock('./common/toast', () => ({
  showToast: mocks.showToast,
}))

import {
  KeeperConfigPanel,
  buildKcfAssemblySegments,
  filterGoalOptions,
  keeperConfigSubscriptionCountsForTests,
  loadKeeperConfig,
  resetKeeperConfig,
} from './keeper-config-panel'
import { resetRuntimeCatalog } from '../lib/runtime-catalog-resource'
import type { GoalTreeNode } from '../types'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

// The panel renders the config field set behind an 8-tab left rail (.kcf-tab).
// Each field now lives under exactly one tab, so DOM assertions must first
// activate the tab that owns the field. Match by the tab's visible label.
function selectKcfTab(container: HTMLElement, label: string): void {
  const tab = Array.from(container.querySelectorAll('button[role="tab"]')).find((button) =>
    button.textContent?.includes(label),
  )
  if (!tab) throw new Error(`kcf tab not found: ${label}`)
  tab.dispatchEvent(new MouseEvent('click', { bubbles: true }))
}

describe('KeeperConfigPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetKeeperConfig()
    resetRuntimeCatalog()
    mocks.fetchKeeperConfig.mockClear()
    mocks.fetchDashboardGoalsTree.mockClear()
    mocks.fetchRuntimeProfiles.mockClear()
    mocks.fetchRuntimeProviders.mockClear()
    mocks.patchKeeperConfig.mockClear()
    mocks.refreshKeeperRuntimeStatus.mockReset()
    mocks.refreshKeeperRuntimeStatus.mockResolvedValue(undefined)
    mocks.showToast.mockClear()
    mocks.updateKeeperRuntime.mockClear()
    mocks.setKeeperToolPolicy.mockClear()
    mocks.fetchDashboardTools.mockClear()
    mocks.pauseKeeper.mockClear()
    mocks.resumeKeeper.mockClear()
    mocks.wakeKeeper.mockClear()
    mocks.fetchKeeperComposite.mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetKeeperConfig()
    resetRuntimeCatalog()
  })

  it('surfaces the GitHub App credentials panel under the access tab', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    // The credentials panel is scoped to the access tab, so the default
    // (identity) tab must not render it.
    expect(container.querySelector('[data-testid="keeper-github-app-config-panel"]')).toBeNull()

    // 권한·샌드박스 (access) is where operators look for credentials; the panel
    // is surfaced here in addition to the monitoring detail's 진단/운영 copy.
    selectKcfTab(container, '권한·샌드박스')
    await flush()
    expect(container.querySelector('[data-testid="keeper-github-app-config-panel"]')).not.toBeNull()
    expect(container.textContent).toContain('GitHub App 자격증명')
    // The panel's initial projection is loaded from the keeper composite.
    expect(mocks.fetchKeeperComposite).toHaveBeenCalledWith('keeper-sangsu', expect.anything())
  })

  it('separates editable prompt controls from read-only runtime metadata', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(1)
    expect(mocks.fetchDashboardGoalsTree).toHaveBeenCalledTimes(1)
    expect(mocks.fetchRuntimeProfiles).not.toHaveBeenCalled()

    // identity tab (default): edit-scope callout + source provenance.
    expect(container.textContent).toContain('편집 가능 범위')
    expect(container.textContent).toContain('runtime.toml')
    expect(container.textContent).toContain('[runtime.assignments]')
    expect(container.textContent).toContain('/tmp/config/keepers/default.toml')
    expect(container.textContent).toContain('/tmp/.masc/keepers/keeper-sangsu/live.json')

    // runtime tab: runtime selection summary + execution metadata.
    selectKcfTab(container, '런타임')
    await flush()
    expect(container.textContent).toContain('Runtime 선택')
    expect(container.textContent).toContain('tier-group.keeper_unified')
    expect(container.textContent).toContain('Runtime catalog spec')
    expect(container.textContent).toContain('RunPod MTP')
    expect(container.textContent).toContain('Qwen/Qwen3-32B')
    expect(container.textContent).toContain('effective')
    expect(container.textContent).toContain('source:oas-provider-config-model')
    expect(container.textContent).toContain('request')
    expect(container.textContent).toContain('think:on')
    expect(container.textContent).toContain('policy')
    expect(container.textContent).toContain('wire:chat_template_kwargs')
    expect(container.textContent).toContain('활성 런타임')

    // goals tab: assigned goal-store bindings.
    selectKcfTab(container, '목표')
    await flush()
    expect(container.textContent).toContain('active_goal_ids')
    expect(container.textContent).toContain('Ship runtime clarity')

    // health tab: runtime liveness / registry diagnostics.
    selectKcfTab(container, '상태·진단')
    await flush()
    expect(container.textContent).toContain('레지스트리 상태')
    expect(container.textContent).toContain('running')
    expect(container.textContent).toContain('자동 부팅 설정')
    expect(container.textContent).toContain('레지스트리 등록')
    expect(container.textContent).toContain('실행 주의')
    expect(container.textContent).not.toContain('자동 부팅 등록')

    // hooks tab: the "전역 런타임 아키텍처" block is keeper-agnostic and
    // collapsed by default; its content (deny list / destructive tools / cost
    // budget) is hidden until the operator expands it.
    selectKcfTab(container, '훅')
    await flush()
    expect(container.textContent).not.toContain('dynamic_boundary (Tool_dispatch.is_destructive)')
    const archToggle = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('전역 런타임 아키텍처'),
    )
    expect(archToggle).toBeTruthy()
    archToggle?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    expect(container.textContent).toContain('dynamic_boundary (Tool_dispatch.is_destructive)')

    // prompt tab: editable prompt controls.
    selectKcfTab(container, '프롬프트')
    await flush()
    // The global system-prompt blocks (world/capabilities) are read-only here;
    // a deep-link routes their editing to the canonical Settings › Prompts.
    const globalEditLink = container.querySelector('[data-testid="kcf-prompt-global-edit-link"]')
    expect(globalEditLink).not.toBeNull()
    expect(globalEditLink?.textContent).toContain('설정 › 프롬프트')
    const editButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('편집'),
    )
    editButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    const textareas = Array.from(container.querySelectorAll('textarea'))
    expect(textareas.length).toBeGreaterThan(0)
    expect(textareas[0]?.value).toContain('Ship stable keeper ops')
  })

  it('surfaces execution attention separately from healthy lifecycle state', async () => {
    mocks.fetchKeeperConfig.mockResolvedValueOnce(makeKeeperConfig({
      runtime: {
        paused: false,
        registered: true,
        keepalive_running: true,
        registry_state: 'running',
        fiber_health: 'alive',
      },
      runtime_trust: {
        disposition: 'Blocked',
        disposition_reason: 'completion_contract_result:passive_only',
        needs_attention: true,
        attention_reason: 'completion_contract_result:passive_only',
        next_human_action: null,
        execution: {
          completion_contract_result: 'passive_only',
          latest_receipt_at: '2026-06-28T10:56:23Z',
        },
        latest_receipt: {
          current_task_id: 'task-1537',
        },
      } as KeeperConfig['runtime_trust'],
    }))

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '상태·진단')
    await flush()

    expect(container.textContent).toContain('킵얼라이브 실행')
    expect(container.textContent).toContain('파이버 상태')
    expect(container.textContent).toContain('alive')
    expect(container.textContent).toContain('실행 주의')
    expect(container.textContent).toContain('ON · completion_contract_result:passive_only')
    expect(container.textContent).toContain('완료 계약')
    expect(container.textContent).toContain('passive_only')
    expect(container.textContent).toContain('작업 scope')
    expect(container.textContent).toContain('task-1537')
  })

  it('runs lifecycle directives from the health tab and refreshes the config snapshot', async () => {
    mocks.fetchKeeperConfig
      .mockResolvedValueOnce(makeKeeperConfig({
        autoboot_enabled: false,
        runtime: {
          paused: false,
          registered: false,
          keepalive_running: false,
          registry_state: 'missing',
          fiber_health: 'dead',
        },
      }))
      .mockResolvedValueOnce(makeKeeperConfig({
        autoboot_enabled: false,
        runtime: {
          paused: false,
          registered: true,
          keepalive_running: true,
          registry_state: 'running',
          fiber_health: 'alive',
        },
      }))

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '상태·진단')
    await flush()
    expect(container.textContent).toContain('missing')
    expect(container.textContent).toContain('자동 부팅 설정')
    expect(container.textContent).toContain('레지스트리 등록')

    const resumeButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('재개·등록'),
    )
    expect(resumeButton).toBeTruthy()
    resumeButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()
    await flush()

    expect(mocks.resumeKeeper).toHaveBeenCalledWith('keeper-sangsu')
    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(2)
    expect(container.textContent).toContain('running')
    expect(container.textContent).toContain('alive')
  })

  it('unsubscribes shared keeper config handlers on unmount', async () => {
    expect(keeperConfigSubscriptionCountsForTests()).toEqual({ reset: 0, update: 0 })

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()

    expect(keeperConfigSubscriptionCountsForTests()).toEqual({ reset: 1, update: 1 })

    render(null, container)
    await flush()

    expect(keeperConfigSubscriptionCountsForTests()).toEqual({ reset: 0, update: 0 })
  })

  it('renders the compaction token gate as an editable number input (not a read-only row)', async () => {
    // Regression guard for the ConfigRow → InlineNumberRow swap: a read-only
    // ConfigRow renders no <input>, so asserting the input exists verifies the
    // actual render change (buildRuntimePayload alone passed before the swap).
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()

    const tokenGateInput = container.querySelector(
      'input[aria-label="토큰 게이트"]',
    ) as HTMLInputElement | null
    expect(tokenGateInput).not.toBeNull()
    expect(tokenGateInput!.type).toBe('number')
    // Value reflects the loaded config (makeKeeperConfig compaction.token_gate = 24000).
    expect(tokenGateInput!.value).toBe('24000')
  })

  it('keeps runtime config controls read-only when the keeper is not manifest-backed', async () => {
    const base = makeKeeperConfig()
    const personaConfig = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: 'persona',
        default_manifest_path: null,
      },
    })
    mocks.fetchKeeperConfig.mockResolvedValueOnce(personaConfig)
    mocks.setKeeperToolPolicy.mockResolvedValueOnce(personaConfig)

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '런타임')
    await flush()
    expect(container.querySelector('[data-testid="keeper-config-control-ledger"]')?.textContent)
      .toContain('Control backing')
    expect(container.querySelector('[data-control-id="kcf-runtime-assignment"]')?.getAttribute('data-control-kind'))
      .toBe('unsupported')
    expect(container.querySelector('[data-testid="keeper-runtime-write-unsupported"]')).not.toBeNull()
    expect(container.textContent).toContain('현재 기본 소스: persona')
    expect(container.querySelector('select[aria-label="runtime_id"]')).toBeNull()
    expect(container.querySelector('input[aria-label="컨텍스트 오버라이드"]')).toBeNull()
    expect(container.textContent).toContain('tier-group.keeper_unified')

    selectKcfTab(container, '실행 정책')
    await flush()
    expect(container.querySelector('select[aria-label="compaction_profile"]')).toBeNull()
    expect(container.querySelector('input[aria-label="토큰 게이트"]')).toBeNull()
    expect(container.querySelector('button[aria-label="자동 부팅"]')).toBeNull()
    expect(container.querySelector('textarea[aria-label="tool_access"]')).not.toBeNull()
    const denylist = container.querySelector('textarea[aria-label="tool_denylist"]') as HTMLTextAreaElement | null
    expect(denylist).not.toBeNull()
    denylist!.value = 'Execute\nDangerTool'
    denylist!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    const policySave = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('정책 저장'),
    )
    policySave?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()
    expect(mocks.setKeeperToolPolicy).toHaveBeenCalledWith('keeper-sangsu', {
      tool_access: ['tool_read_file'],
      deny: ['Execute', 'DangerTool'],
    })

    selectKcfTab(container, '권한·샌드박스')
    await flush()
    expect(container.querySelector('select[aria-label="sandbox_profile"]')).toBeNull()
    expect(container.querySelector('select[aria-label="network_mode"]')).toBeNull()
    expect(container.querySelector('textarea[aria-label="allowed_paths"]')).toBeNull()
    expect(container.querySelector('textarea[aria-label="mention_targets"]')).toBeNull()
    expect(container.textContent).toContain('allowed_paths')
    expect(container.textContent).toContain('/tmp/workspace')

    selectKcfTab(container, '목표')
    await flush()
    expect(container.querySelector('input[aria-label="goal 검색"]')).toBeNull()
    expect(container.querySelectorAll('.kcf-goal').length).toBe(0)
    expect(container.textContent).toContain('goal-runtime')
    expect(container.textContent).toContain('읽기 전용')

    const runtimeSave = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('런타임 설정 저장'),
    )
    expect(runtimeSave).toBeUndefined()
    expect(mocks.patchKeeperConfig).not.toHaveBeenCalled()
  })

  it('surfaces missing config-field contracts in the rendered ledger', async () => {
    const noHooksConfig = makeKeeperConfig({ hooks: undefined })
    mocks.fetchKeeperConfig.mockResolvedValueOnce(noHooksConfig)

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '훅')
    await flush()

    const hookRow = container.querySelector('[data-control-id="kcf-hooks-slots"]')
    expect(hookRow?.getAttribute('data-control-contract-status')).toBe('missing-config-field')
    expect(hookRow?.getAttribute('data-control-missing-config-fields'))
      .toBe('hooks.slots | hooks.deny_list | hooks.cost_budget')
    expect(hookRow?.textContent).toContain('missing 3 config fields')

    const hookFilter = container.querySelector('[data-control-id="kcf-hooks-filter"]')
    expect(hookFilter?.getAttribute('data-control-contract-status')).toBe('ok')
    expect(hookFilter?.getAttribute('data-control-missing-config-fields')).toBe('')
  })

  it('saves the tool denylist via set_policy, echoing current tool_access and deduping entries', async () => {
    mocks.setKeeperToolPolicy.mockClear()
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()

    const denylist = container.querySelector(
      'textarea[aria-label="tool_denylist"]',
    ) as HTMLTextAreaElement | null
    expect(denylist).not.toBeNull()
    expect(denylist!.value).toBe('Execute') // reflects loaded tool_denylist

    // Operator edits: add a tool, with a blank line and a duplicate.
    denylist!.value = 'Execute\nmcp__masc__masc_board_delete\nExecute\n'
    denylist!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('정책 저장'),
    )
    expect(saveButton).toBeTruthy()
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    // set_policy overwrites tool_access AND deny atomically, so the editor
    // echoes the current tool_access unchanged (preserving the configured
    // allowlist record); the deny list is trimmed + deduped.
    expect(mocks.setKeeperToolPolicy).toHaveBeenCalledWith('keeper-sangsu', {
      tool_access: ['tool_read_file'],
      deny: ['Execute', 'mcp__masc__masc_board_delete'],
    })
  })

  it('echoes an empty tool_access allowlist unchanged (never fabricates access)', async () => {
    mocks.setKeeperToolPolicy.mockClear()
    const base = makeKeeperConfig()
    mocks.fetchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({ tools: { ...base.tools, tool_access: [] } }),
    )
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()

    const denylist = container.querySelector(
      'textarea[aria-label="tool_denylist"]',
    ) as HTMLTextAreaElement | null
    expect(denylist).not.toBeNull()
    denylist!.value = 'Execute\nDangerTool'
    denylist!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('정책 저장'),
    )
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    // An empty allowlist round-trips as []; the editor must not substitute a
    // non-empty set. (Runtime gates on the denylist, not tool_access, so [] here
    // means "all candidates", which the operator's config already chose.)
    expect(mocks.setKeeperToolPolicy).toHaveBeenCalledWith('keeper-sangsu', {
      tool_access: [],
      deny: ['Execute', 'DangerTool'],
    })
  })

  it('saves edited tool_access and denylist together via set_policy', async () => {
    mocks.setKeeperToolPolicy.mockClear()
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()

    const toolAccess = container.querySelector(
      'textarea[aria-label="tool_access"]',
    ) as HTMLTextAreaElement | null
    const denylist = container.querySelector(
      'textarea[aria-label="tool_denylist"]',
    ) as HTMLTextAreaElement | null
    expect(toolAccess).not.toBeNull()
    expect(denylist).not.toBeNull()

    toolAccess!.value = 'tool_read_file\nmasc_status\ntool_read_file\n'
    toolAccess!.dispatchEvent(new Event('input', { bubbles: true }))
    denylist!.value = 'Execute\nDangerTool\nExecute\n'
    denylist!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('정책 저장'),
    )
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.setKeeperToolPolicy).toHaveBeenCalledWith('keeper-sangsu', {
      tool_access: ['tool_read_file', 'masc_status'],
      deny: ['Execute', 'DangerTool'],
    })
    expect(mocks.refreshKeeperRuntimeStatus).toHaveBeenCalledTimes(1)
    expect(mocks.refreshKeeperRuntimeStatus).toHaveBeenCalledWith({ force: true })
  })

  it('refreshes shared keeper surfaces after prompt save', async () => {
    const updated = makeKeeperConfig({
      prompt: {
        ...makeKeeperConfig().prompt,
        goal: 'Ship refreshed keeper surfaces',
      },
    })
    mocks.patchKeeperConfig.mockResolvedValueOnce(updated)

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '프롬프트')
    await flush()
    const editButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('편집하기'),
    )
    expect(editButton).toBeDefined()
    editButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    const goal = container.querySelector('textarea') as HTMLTextAreaElement | null
    expect(goal).not.toBeNull()
    goal!.value = 'Ship refreshed keeper surfaces'
    goal!.dispatchEvent(new Event('input', { bubbles: true }))
    goal!.dispatchEvent(new FocusEvent('blur', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.trim() === '저장',
    )
    expect(saveButton).toBeDefined()
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.patchKeeperConfig).toHaveBeenCalledWith(
      'keeper-sangsu',
      expect.objectContaining({ goal: 'Ship refreshed keeper surfaces' }),
    )
    expect(mocks.refreshKeeperRuntimeStatus).toHaveBeenCalledTimes(1)
    expect(mocks.refreshKeeperRuntimeStatus).toHaveBeenCalledWith({ force: true })
  })

  it('surfaces post-save refresh failure without turning the save into failure', async () => {
    mocks.refreshKeeperRuntimeStatus.mockRejectedValueOnce(new Error('runtime projection unavailable'))

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()
    selectKcfTab(container, '실행 정책')
    await flush()

    const toolAccess = container.querySelector(
      'textarea[aria-label="tool_access"]',
    ) as HTMLTextAreaElement | null
    expect(toolAccess).not.toBeNull()
    toolAccess!.value = 'tool_read_file\nmasc_status'
    toolAccess!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('정책 저장'),
    )
    expect(saveButton).toBeDefined()
    expect(saveButton!.hasAttribute('disabled')).toBe(false)
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.setKeeperToolPolicy).toHaveBeenCalledTimes(1)
    expect(mocks.showToast).toHaveBeenCalledWith('도구 정책 저장 완료', 'success')
    expect(mocks.showToast).toHaveBeenCalledWith('runtime projection unavailable', 'warning')
  })

  it('patches runtime_id from the dashboard panel', async () => {
    mocks.patchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        execution: {
          ...makeKeeperConfig().execution,
          selected_runtime_id: 'tier.resilient_breaker',
          selected_runtime_canonical: 'tier.resilient_breaker',
        },
      }),
    )

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '런타임')
    await flush()

    const runtimeSelect = container.querySelector('select[aria-label="runtime_id"]') as HTMLSelectElement | null
    expect(runtimeSelect).not.toBeNull()
    runtimeSelect!.value = 'tier.resilient_breaker'
    runtimeSelect!.dispatchEvent(new Event('change', { bubbles: true }))
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
        runtime_id: 'tier.resilient_breaker',
      }),
    )
    expect(container.textContent).toContain('runtime_id')
    expect(container.textContent).toContain('tier-group.keeper_unified')
    expect(container.textContent).toContain('선택은 runtime.toml [runtime.assignments] 에서 관리됩니다.')
    expect(mocks.updateKeeperRuntime).not.toHaveBeenCalled()
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

    selectKcfTab(container, '권한·샌드박스')
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

  it('patches mention targets and compaction token gate from the dashboard panel', async () => {
    const base = makeKeeperConfig()
    mocks.patchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        workspace: {
          ...base.workspace,
          mention_targets: ['alpha', 'beta'],
        },
        compaction: {
          ...base.compaction,
          token_gate: 32000,
        },
      }),
    )

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    // mention_targets lives in the access tab; the runtime draft is a shared
    // signal, so editing it there persists when we switch to the policy tab.
    selectKcfTab(container, '권한·샌드박스')
    await flush()
    const mentionTargets = container.querySelector('textarea[aria-label="mention_targets"]') as HTMLTextAreaElement | null
    expect(mentionTargets).not.toBeNull()
    mentionTargets!.value = 'alpha\n beta \nalpha\n'
    mentionTargets!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()
    const tokenGate = container.querySelector('input[aria-label="토큰 게이트"]') as HTMLInputElement | null
    expect(tokenGate).not.toBeNull()
    tokenGate!.value = '32000'
    tokenGate!.dispatchEvent(new Event('input', { bubbles: true }))
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
        mention_targets: ['alpha', 'beta'],
        compaction_token_gate: 32000,
      }),
    )
  })

  it('patches compaction profile, autoboot, and max-context override from the dashboard panel', async () => {
    const base = makeKeeperConfig()
    mocks.patchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        autoboot_enabled: false,
        max_context_override: 64000,
        compaction: {
          ...base.compaction,
          profile: 'conservative',
        },
      }),
    )

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '런타임')
    await flush()
    const maxContext = container.querySelector('input[aria-label="컨텍스트 오버라이드"]') as HTMLInputElement | null
    expect(maxContext).not.toBeNull()
    maxContext!.value = '64000'
    maxContext!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()
    const compactionProfile = container.querySelector('select[aria-label="compaction_profile"]') as HTMLSelectElement | null
    expect(compactionProfile).not.toBeNull()
    compactionProfile!.value = 'conservative'
    compactionProfile!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    const autoboot = container.querySelector('button[aria-label="자동 부팅"]') as HTMLButtonElement | null
    expect(autoboot).not.toBeNull()
    autoboot!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
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
        autoboot_enabled: false,
        max_context_override: 64000,
        compaction_profile: 'conservative',
      }),
    )
  })

  it('shows the sandbox preflight guide when docker is selected', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '권한·샌드박스')
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

  it('filters the goals catalogue by the search input and shows an empty state', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '목표')
    await flush()

    const search = container.querySelector('input[aria-label="goal 검색"]') as HTMLInputElement | null
    expect(search).not.toBeNull()
    // default fixture goal (goal-runtime · Ship runtime clarity) is shown
    expect(container.querySelectorAll('.kcf-goal').length).toBe(1)

    // non-matching query → empty state + "0 표시"
    search!.value = 'zzz-no-match'
    search!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    expect(container.querySelectorAll('.kcf-goal').length).toBe(0)
    expect(container.textContent).toContain('검색 결과 없음')
    expect(container.textContent).toContain('0 표시')

    // matching id substring → goal reappears, counter updates
    search!.value = 'goal-runtime'
    search!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    expect(container.querySelectorAll('.kcf-goal').length).toBe(1)
    expect(container.textContent).toContain('1 표시')
  })

  it('renders the keeper-scoped prompt assembly trace with an override win badge', async () => {
    // Real server override_fields are dot-namespaced (prompt.goal); mark only goal.
    const base = makeKeeperConfig()
    mocks.fetchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        sources: { ...base.sources, override_fields: ['prompt.goal'], has_live_override: true },
      }),
    )
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '프롬프트')
    await flush()

    expect(container.textContent).toContain('조립 추적')
    expect(container.querySelector('.kasm')).not.toBeNull()
    // 3 base blocks + goal + instructions + goals = 6 segments
    expect(container.querySelectorAll('.kasm-seg').length).toBe(6)
    // only prompt.goal is overridden → exactly one win badge
    const winBadges = container.querySelectorAll('.kasm-seg-win')
    expect(winBadges.length).toBe(1)
    expect(winBadges[0]!.textContent).toContain('매니페스트 덮어씀')
  })

  it('renders the per-tool grid from the live registry and toggles tool_access via set_policy', async () => {
    mocks.setKeeperToolPolicy.mockClear()
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()
    await flush() // tool inventory resolves

    // grid derived from the 3 live-registry tools, with the real category badge
    expect(container.querySelectorAll('.kcf-tool').length).toBe(3)
    expect(container.textContent).toContain('coordination')

    // tool_read_file is in tool_access → its switch is on; masc_status is off
    const readToggle = container.querySelector('button[aria-label^="tool_read_file"]') as HTMLButtonElement
    expect(readToggle.getAttribute('aria-checked')).toBe('true')
    const statusToggle = container.querySelector('button[aria-label^="masc_status"]') as HTMLButtonElement
    expect(statusToggle.getAttribute('aria-checked')).toBe('false')

    // toggling masc_status ON rewrites the shared tool_access draft (textarea view)
    statusToggle.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    const accessTa = container.querySelector('textarea[aria-label="tool_access"]') as HTMLTextAreaElement
    expect(accessTa.value.split('\n')).toEqual(['tool_read_file', 'masc_status'])

    // save routes through the existing set_policy path with the updated allowlist
    const saveButton = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('정책 저장'),
    )
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()
    expect(mocks.setKeeperToolPolicy).toHaveBeenCalledWith('keeper-sangsu', {
      tool_access: ['tool_read_file', 'masc_status'],
      deny: ['Execute'],
    })
  })

  it('preserves an empty tool_access as all-candidates — grid is read-only, toggle is a no-op', async () => {
    mocks.setKeeperToolPolicy.mockClear()
    const base = makeKeeperConfig()
    mocks.fetchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({ tools: { ...base.tools, tool_access: [] } }),
    )
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()
    await flush() // tool inventory resolves

    // empty tool_access = all candidates: banner shown, every tool ON (not all-off),
    // and every toggle disabled so it cannot silently narrow [] to one explicit tool.
    expect(container.querySelector('[data-testid="tool-all-candidates-note"]')).not.toBeNull()
    const toggles = Array.from(container.querySelectorAll('.kcf-tool-toggle')) as HTMLButtonElement[]
    expect(toggles.length).toBe(3)
    expect(toggles.every((t) => t.getAttribute('aria-checked') === 'true')).toBe(true)
    expect(toggles.every((t) => t.disabled)).toBe(true)

    // a click on the read-only grid must not mutate the draft (stays empty → [])
    toggles[0]!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    const accessTa = container.querySelector('textarea[aria-label="tool_access"]') as HTMLTextAreaElement
    expect(accessTa.value).toBe('')

    // and the save button stays disabled because nothing changed (no accidental narrow)
    const saveButton = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('정책 저장'),
    ) as HTMLButtonElement
    expect(saveButton.disabled).toBe(true)
  })

  it('resets runtime draft when switching from keeper A to keeper B to prevent stale settings leakage', async () => {
    const configA = makeKeeperConfig({
      name: 'keeper-a',
      execution: {
        selected_runtime_id: 'ollama_cloud.deepseek-v4-flash',
        runtime_options: ['ollama_cloud.deepseek-v4-flash', 'ollama_cloud.qwen-2.5-coder'],
        selected_runtime_canonical: 'ollama_cloud.deepseek-v4-flash',
        models: ['ollama_cloud.deepseek-v4-flash'],
      } as any,
    })
    const configB = makeKeeperConfig({
      name: 'keeper-b',
      execution: {
        selected_runtime_id: 'ollama_cloud.qwen-2.5-coder',
        runtime_options: ['ollama_cloud.deepseek-v4-flash', 'ollama_cloud.qwen-2.5-coder'],
        selected_runtime_canonical: 'ollama_cloud.qwen-2.5-coder',
        models: ['ollama_cloud.qwen-2.5-coder'],
      } as any,
    })

    mocks.fetchKeeperConfig.mockResolvedValueOnce(configA)
    render(html`<${KeeperConfigPanel} keeperName="keeper-a" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '런타임')
    await flush()

    const select = container.querySelector('select[aria-label="runtime_id"]') as HTMLSelectElement
    expect(select.value).toBe('ollama_cloud.deepseek-v4-flash')

    select.value = 'ollama_cloud.qwen-2.5-coder'
    select.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    mocks.fetchKeeperConfig.mockResolvedValueOnce(configB)
    render(html`<${KeeperConfigPanel} keeperName="keeper-b" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '런타임')
    await flush()

    const finalSelect = container.querySelector('select[aria-label="runtime_id"]') as HTMLSelectElement
    expect(finalSelect.value).toBe('ollama_cloud.qwen-2.5-coder')

    const saveButton = Array.from(container.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('저장'),
    ) as HTMLButtonElement
    if (saveButton) {
      expect(saveButton.disabled).toBe(true)
    }
  })
})

describe('filterGoalOptions', () => {
  const goals = [
    { id: 'goal-alpha', title: 'Stabilize runtime' },
    { id: 'goal-beta', title: 'Improve dashboard' },
  ] as unknown as GoalTreeNode[]

  it('returns all goals for an empty or whitespace query', () => {
    expect(filterGoalOptions(goals, '')).toHaveLength(2)
    expect(filterGoalOptions(goals, '   ')).toHaveLength(2)
  })

  it('matches title or id case-insensitively', () => {
    expect(filterGoalOptions(goals, 'RUNTIME').map((g) => g.id)).toEqual(['goal-alpha'])
    expect(filterGoalOptions(goals, 'beta').map((g) => g.id)).toEqual(['goal-beta'])
    expect(filterGoalOptions(goals, 'dashboard').map((g) => g.id)).toEqual(['goal-beta'])
    expect(filterGoalOptions(goals, 'zzz')).toHaveLength(0)
  })
})

describe('buildKcfAssemblySegments', () => {
  it('builds base + manifest/override + goals segments from real config provenance', () => {
    const base = makeKeeperConfig()
    const c = makeKeeperConfig({
      sources: { ...base.sources, override_fields: ['prompt.instructions'] },
    })
    const segs = buildKcfAssemblySegments(c)
    expect(segs.map((s) => s.src)).toEqual(['base', 'base', 'base', 'manifest', 'override', 'goals'])
    const goalSeg = segs.find((s) => s.field.includes('objective'))
    const instrSeg = segs.find((s) => s.field.includes('instructions'))
    expect(goalSeg?.win).toBe(false)
    expect(instrSeg?.win).toBe(true)
    expect(instrSeg?.src).toBe('override')
  })

  it('omits empty prompt fields and the goals segment when there are no active goals', () => {
    const base = makeKeeperConfig()
    const c = makeKeeperConfig({
      prompt: { ...base.prompt, goal: '', instructions: '' },
      workspace: { ...base.workspace, active_goals: [] },
    })
    const segs = buildKcfAssemblySegments(c)
    expect(segs.map((s) => s.field)).toEqual(['헌법', '세계관', '능력'])
    expect(segs.every((s) => s.src === 'base')).toBe(true)
  })
})
