import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperConfig, KeeperHookSlot } from '../types'
import { ApiRequestError } from '../api/core'
import {
  buildRuntimePayload,
  configDurabilityWarningMessage,
  coerceNetworkMode,
  coerceSandboxProfile,
  filterHookSlots,
  hookSlotDetails,
  initRuntimeDraftFromConfig,
  rebaseRuntimeDraftOnFreshConfig,
  KCF_TAB_IDS,
  keeperConfigControlContractStatus,
  keeperConfigControlInventory,
  keeperConfigFailureRequiresAuthoritativeReload,
  keeperRuntimeConfigCanWrite,
  keeperRuntimeConfigWriteUnsupportedReason,
  parseMaxContextOverrideDraft,
  type HookSlotEntry,
  type RuntimeDraft,
} from './keeper-config-panel'

void vi

describe('keeper config save failure authority', () => {
  it('reloads committed runtime-sync failures and reconciliation uncertainty', () => {
    expect(keeperConfigFailureRequiresAuthoritativeReload(new ApiRequestError({
      method: 'POST',
      path: '/api/v1/keepers/keeper-sangsu/config',
      status: 503,
      errorCode: 'keeper_runtime_sync_failed',
      configApplied: true,
      runtimeSync: false,
    }))).toBe(true)
    expect(keeperConfigFailureRequiresAuthoritativeReload(new ApiRequestError({
      method: 'POST',
      path: '/api/v1/keepers/keeper-sangsu/config',
      status: 503,
      errorCode: 'keeper_manifest_reconciliation_required',
      configApplicationState: 'indeterminate',
      authoritativeReloadRequired: true,
    }))).toBe(true)
    expect(keeperConfigFailureRequiresAuthoritativeReload(new ApiRequestError({
      method: 'POST',
      path: '/api/v1/keepers/keeper-sangsu/config',
      status: 503,
      errorCode: 'keeper_config_composite_reconciliation_required',
      configApplicationState: 'indeterminate',
      authoritativeReloadRequired: true,
    }))).toBe(true)
  })

  it('names runtime authority in config durability warnings', () => {
    const message = configDurabilityWarningMessage('Keeper 설정은', [{
      code: 'runtime_config_parent_sync_unconfirmed',
      detail: 'runtime parent fsync failed',
    }])
    expect(message).toContain('config durability')
    expect(message).toContain('runtime_config_parent_sync_unconfirmed')
    expect(message).not.toContain('manifest durability')
  })
})

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
    config_revision: {
      manifest: { state: 'sha256', value: 'a'.repeat(64) },
      runtime_assignment: { state: 'runtime_config_missing' },
    },
    autoboot_enabled: true,
    max_context_override: null,
    sandbox_profile: 'local',
    network_mode: 'inherit',
    keeper_last_error: null,
    sandbox_roots: ['/tmp/workspace'],
    prompt: {
      instructions: 'Prefer direct remediation',
      system_prompt_blocks: {
        system: { key: 'keeper', source: 'file', text: 'system text' },
      },
      effective_system_prompt: 'full prompt',
      assembled_system_prompt: 'assembled prompt',
      unified_user_message_preview: 'world state',
    },
    execution: {
      models: ['llama:test-balanced'],
      active_model: 'llama:test-balanced',
      verify: true,
      selected_runtime_id: 'tier-group.keeper_unified',
      selected_runtime_canonical: 'tier-group.keeper_unified',
      runtime_options: ['tier-group.keeper_unified', 'tier.resilient_breaker'],
    },
    proactive: {
      enabled: true,
    },
    hooks: {
      scope: 'keeper_runtime_composite',
      slots: {},
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
    },
    sources: {
      live_meta_path: '/tmp/.masc/keepers/keeper-sangsu/live.json',
      default_manifest_path: '/tmp/config/keepers/default.toml',
      default_source_kind: 'toml',
      precedence: ['live_meta', 'keeper_config'],
      has_live_override: true,
      override_fields: ['prompt.instructions'],
      override_field_sources: [],
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
    },
    ...overrides,
    skills: overrides.skills ?? { names: null },
  }
}

describe('filterHookSlots', () => {
  const entries: HookSlotEntry[] = [
    ['pre_tool_call', makeSlot({ source: 'builtin', gates: ['typed_input', 'path_scope'] })],
    ['post_turn', makeSlot({ source: 'override', effects: ['handoff_auto'] })],
    ['snapshot_observer', makeSlot({ source: 'keeper', features: ['snapshot'] })],
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
    const result = filterHookSlots(entries, 'keeper')
    expect(result.map(([name]) => name)).toEqual(['snapshot_observer'])
  })

  it('matches by gates entry', () => {
    const result = filterHookSlots(entries, 'typed_input')
    expect(result.map(([name]) => name)).toEqual(['pre_tool_call'])
  })

  it('matches by effects entry', () => {
    const result = filterHookSlots(entries, 'handoff_auto')
    expect(result.map(([name]) => name)).toEqual(['post_turn'])
  })

  it('matches by features entry', () => {
    const result = filterHookSlots(entries, 'snapshot')
    expect(result.map(([name]) => name)).toEqual(['snapshot_observer'])
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
      ['pre_tool_use', makeSlot({ gates: ['policy_gate'], features: ['tool_start_timing'] })],
    ]
    expect(filterHookSlots(coexist, 'tool_start_timing')).toHaveLength(1)
    expect(filterHookSlots(coexist, 'policy_gate')).toHaveLength(1)
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
  it('coerceSandboxProfile maps every known profile, falls back to local otherwise', () => {
    expect(coerceSandboxProfile('docker')).toBe('docker')
    expect(coerceSandboxProfile('local')).toBe('local')
    expect(coerceSandboxProfile('something_else')).toBe('local')
    expect(coerceSandboxProfile(undefined)).toBe('local')
    expect(coerceSandboxProfile('')).toBe('local')
  })

  // The fallback used to swallow every name the panel had not been taught,
  // so a keeper declaring microvm was shown -- and saved back -- as running
  // on the host. A profile that exists must survive the round trip; only a
  // genuinely absent value becomes local.
  it('coerceSandboxProfile keeps microvm rather than dropping it to local', () => {
    expect(coerceSandboxProfile('microvm')).toBe('microvm')
  })

  it('coerceNetworkMode maps none, falls back to inherit otherwise', () => {
    expect(coerceNetworkMode('none')).toBe('none')
    expect(coerceNetworkMode('inherit')).toBe('inherit')
    expect(coerceNetworkMode('host')).toBe('inherit')
    expect(coerceNetworkMode(undefined)).toBe('inherit')
  })

})

describe('keeperRuntimeConfigCanWrite', () => {
  it('allows writes for a TOML-backed keeper manifest', () => {
    const base = makeKeeperConfig()
    expect(keeperRuntimeConfigCanWrite(base)).toBe(true)
    expect(keeperRuntimeConfigWriteUnsupportedReason(base)).toBeNull()
  })

  it('allows config without a manifest path when a valid Keeper name is present', () => {
    const base = makeKeeperConfig()
    const c = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: null,
        default_manifest_path: '/tmp/config/keepers/default.toml',
      },
    })

    expect(keeperRuntimeConfigCanWrite(c)).toBe(true)
    expect(keeperRuntimeConfigWriteUnsupportedReason(c)).toBeNull()
  })

  it('rejects config without a valid keeper name', () => {
    const c = makeKeeperConfig({
      name: '',
    })

    expect(keeperRuntimeConfigCanWrite(c)).toBe(false)
    expect(keeperRuntimeConfigWriteUnsupportedReason(c)).toContain('유효한 키퍼 이름')
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
    const promptOnly = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: null,
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

    const runtimeAssignment = findItem('runtime', promptOnly, 'kcf-runtime-assignment')
    expect(runtimeAssignment.kind).toBe('live-write')
  })

  it('reports missing optional config fields without treating present nulls as absent', () => {
    const c = makeKeeperConfig({ hooks: undefined })

    const hookSlots = findItem('hooks', c, 'kcf-hooks-slots')
    const hookStatus = keeperConfigControlContractStatus(hookSlots.contracts, c)
    expect(hookStatus.kind).toBe('missing-config-field')
    expect(hookStatus.missingConfigFields).toEqual(['hooks.scope', 'hooks.slots'])

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

    expect(c.hooks?.scope).toBe('keeper_runtime_composite')
    expect(hookStatus.kind).toBe('missing-config-field')
    expect(hookStatus.missingConfigFields).toEqual(['hooks.scope'])
  })

  it('keeps lifecycle directives live when runtime manifest writes are unsupported', () => {
    const base = makeKeeperConfig()
    const promptOnly = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: null,
        default_manifest_path: null,
      },
    })

    expect(findItem('policy', promptOnly, 'kcf-policy-proactive').kind).toBe('live-write')
    expect(findItem('health', promptOnly, 'kcf-health-directives').kind).toBe('live-write')
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
    config_revision: {
      manifest: { state: 'missing' },
      runtime_assignment: { state: 'runtime_config_missing' },
    },
    autoboot_enabled: true,
    max_context_override: null,
    sandbox_profile: 'local',
    network_mode: 'inherit',
    sandbox_roots: [],
    prompt: {} as KeeperConfig['prompt'],
    execution: {} as KeeperConfig['execution'],
    proactive: {
      enabled: false,
    } as KeeperConfig['proactive'],
    skills: { names: null },
    runtime: {} as KeeperConfig['runtime'],
    workspace: {
      mention_targets: [],
      bound_workspace_ids: [],
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

  it('uses the declarative proactive value when live meta has drifted', () => {
    const base = makeKeeperConfigForSandbox()
    const c = makeKeeperConfigForSandbox({
      proactive: { enabled: true },
      sources: {
        ...base.sources,
        override_field_sources: [{
          field: 'proactive.enabled',
          source: 'live_meta',
          live_source: 'runtime_overlay',
          default_source: 'toml',
          default_source_kind: 'toml',
          default_manifest_path: '/tmp/config/keepers/rtprobe.toml',
          default_manifest_exists: true,
          default_missing: false,
          default_value: false,
          live_value: true,
        }],
      },
    })

    expect(initRuntimeDraftFromConfig(c).proactive_enabled).toBe(false)
    expect(buildRuntimePayload({
      ...initRuntimeDraftFromConfig(c),
      proactive_enabled: true,
    }, c)).toEqual({ proactive_enabled: true })
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

describe('rebaseRuntimeDraftOnFreshConfig — conflict rebase', () => {
  const seen = makeKeeperConfigForSandbox({
    workspace: {
      mention_targets: ['old-target'],
      bound_workspace_ids: [],
    },
  })
  const fresh = makeKeeperConfigForSandbox({
    // The other writer changed this field; the user never touched it.
    workspace: {
      mention_targets: ['remote-writer-change'],
      bound_workspace_ids: [],
    },
  })

  it('keeps the user-edited field and adopts remote changes on untouched fields', () => {
    const draft = {
      ...initRuntimeDraftFromConfig(seen),
      // The user edited only the runtime id.
      runtime_id: 'user-runtime',
    }
    const rebased = rebaseRuntimeDraftOnFreshConfig(draft, seen, fresh)
    expect(rebased.runtime_id).toBe('user-runtime')
    // NOT the stale base value: the untouched field follows the fresh config,
    // so a re-save cannot silently revert the other writer's change.
    expect(rebased.mention_targets_text).toBe('remote-writer-change')
  })

  it('preserves a skill-selection mode change', () => {
    const draft = {
      ...initRuntimeDraftFromConfig(seen),
      skill_selection: { mode: 'names' as const, names_text: 'a\nb' },
    }
    const rebased = rebaseRuntimeDraftOnFreshConfig(draft, seen, fresh)
    expect(rebased.skill_selection).toEqual({ mode: 'names', names_text: 'a\nb' })
  })

  it('returns the fresh draft untouched when the user changed nothing', () => {
    const draft = initRuntimeDraftFromConfig(seen)
    const rebased = rebaseRuntimeDraftOnFreshConfig(draft, seen, fresh)
    expect(rebased).toEqual(initRuntimeDraftFromConfig(fresh))
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

  it('normalizes line-based runtime list drafts through one path', () => {
    const c = makeKeeperConfigForSandbox({
      workspace: {
        mention_targets: ['sangsu'],
        bound_workspace_ids: [],
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      mention_targets_text: 'alpha\n beta \nalpha\n',
    }), c)

    expect(payload.mention_targets).toEqual(['alpha', 'beta'])
  })

  it('emits explicit empty mention targets when the draft is cleared', () => {
    const c = makeKeeperConfigForSandbox({
      workspace: {
        mention_targets: ['sangsu'],
        bound_workspace_ids: [],
      },
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      mention_targets_text: '',
    }), c)

    expect(payload.mention_targets).toEqual([])
  })

  it('emits autoboot and max_context_override edits', () => {
    const c = makeKeeperConfigForSandbox({
      autoboot_enabled: true,
      max_context_override: null,
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      autoboot_enabled: false,
      max_context_override: '64000',
    }), c)
    expect(payload.autoboot_enabled).toBe(false)
    expect(payload.max_context_override).toBe(64000)
  })

  it('emits null to clear max_context_override when draft is zero', () => {
    const c = makeKeeperConfigForSandbox({ max_context_override: 64000 })
    const payload = buildRuntimePayload(draftFrom(c, {
      max_context_override: '0',
    }), c)
    expect(payload.max_context_override).toBeNull()
  })

  it('preserves an explicit positive max_context_override before PATCH', () => {
    const c = makeKeeperConfigForSandbox({
      max_context_override: null,
    })
    const payload = buildRuntimePayload(draftFrom(c, {
      max_context_override: '128001',
    }), c)
    expect(payload.max_context_override).toBe(128_001)
  })

  it('rejects negative, fractional, and unsafe-integer override drafts without rewriting', () => {
    expect(parseMaxContextOverrideDraft('')).toMatchObject({ ok: false })
    expect(parseMaxContextOverrideDraft('01')).toMatchObject({ ok: false })
    expect(parseMaxContextOverrideDraft('-1')).toMatchObject({ ok: false })
    expect(parseMaxContextOverrideDraft('3.9')).toMatchObject({ ok: false })
    expect(parseMaxContextOverrideDraft('9007199254740993')).toMatchObject({ ok: false })
    expect(parseMaxContextOverrideDraft('128001')).toEqual({ ok: true, value: 128_001 })
    expect(parseMaxContextOverrideDraft('0')).toEqual({ ok: true, value: null })
  })

  it('preserves all, exact names, and explicit none as distinct Skill patches', () => {
    const inherited = makeKeeperConfigForSandbox({ skills: { names: null } })
    expect(buildRuntimePayload(draftFrom(inherited), inherited).skills).toBeUndefined()
    expect(buildRuntimePayload(draftFrom(inherited, {
      skill_selection: { mode: 'names', names_text: 'ocaml-coding\nproof-harness' },
    }), inherited).skills).toEqual({ names: ['ocaml-coding', 'proof-harness'] })
    expect(buildRuntimePayload(draftFrom(inherited, {
      skill_selection: { mode: 'names', names_text: '' },
    }), inherited).skills).toEqual({ names: [] })

    const selected = makeKeeperConfigForSandbox({
      skills: { names: ['ocaml-coding'] },
    })
    expect(buildRuntimePayload(draftFrom(selected, {
      skill_selection: { mode: 'all', prior_names_text: 'ocaml-coding' },
    }), selected).skills).toEqual({})
    expect(buildRuntimePayload(draftFrom(selected), selected).skills).toBeUndefined()
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
          priority: 2,
          metric: null,
          target_value: null,
          due_date: null,
          tasks: [],
          task_count: 0,
          task_done_count: 0,
          timeline_events: [],
          children: [],
          child_count: 0,
          last_activity_at: '',
          stagnation_seconds: 0,
          linked_keeper_names: [],
          pending_approval_count: 0,
          created_at: '',
          updated_at: '',
        },
      ],
      summary: {
        total_goals: 1,
        phase_counts: { executing: 1 },
        total_tasks: 0,
        done_tasks: 0,
        pending_approvals: 0,
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
            source: 'agent-core-provider-config',
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
                argv_prompt_preflight: true,
                uses_anthropic_caching: false,
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
    pauseKeeper: vi.fn(async () => ({ ok: true, action: 'pause', name: 'keeper-sangsu' })),
    resumeKeeper: vi.fn(async () => ({ ok: true, action: 'resume', name: 'keeper-sangsu' })),
    wakeKeeper: vi.fn(async () => ({ ok: true, action: 'wakeup', name: 'keeper-sangsu' })),
  }
})

vi.mock('../api/dashboard', () => ({
  fetchRuntimeProfiles: mocks.fetchRuntimeProfiles,
  fetchDashboardGoalsTree: mocks.fetchDashboardGoalsTree,
  fetchKeeperConfig: mocks.fetchKeeperConfig,
  fetchRuntimeProviders: mocks.fetchRuntimeProviders,
  patchKeeperConfig: mocks.patchKeeperConfig,
  updateKeeperRuntime: mocks.updateKeeperRuntime,
}))

vi.mock('../api/keeper', () => ({
  pauseKeeper: mocks.pauseKeeper,
  resumeKeeper: mocks.resumeKeeper,
  wakeKeeper: mocks.wakeKeeper,
}))

vi.mock('../store', () => ({
  keepers: storeMocks.keepers,
  refreshKeeperRuntimeStatus: mocks.refreshKeeperRuntimeStatus,
}))

vi.mock('./common/toast', () => ({
  showToast: mocks.showToast,
}))

const githubIdentityMocks = vi.hoisted(() => ({
  fetchKeeperGithubIdentity: vi.fn(async () => ({
    ok: true as const,
    keeper: 'keeper-sangsu',
    hostname: 'github.com',
    config_dir: '/tmp/base/.masc/keepers/keeper-sangsu/github-cli',
    projected_token_env_names: [],
    stored: { authenticated: true, login: 'masc-sangsu-bot', error: null },
    effective: { authenticated: false, login: null, error: null },
    effective_probe_scope: 'host_process_credential_only' as const,
    checked_at_unix: 1786000000,
  })),
  streamKeeperGithubLogin: vi.fn(async () => undefined),
}))

// The panel reads the fleet-roster row (koreanName / sandbox_target /
// created_at) for its top bar and identity tab. A plain value holder is enough:
// tests assign `storeMocks.keepers.value = [...]` before render.
const storeMocks = vi.hoisted(() => ({
  keepers: { value: [] as Array<Record<string, unknown>> },
}))

vi.mock('../api/dashboard-keeper-github', () => ({
  fetchKeeperGithubIdentity: githubIdentityMocks.fetchKeeperGithubIdentity,
  streamKeeperGithubLogin: githubIdentityMocks.streamKeeperGithubLogin,
}))

import {
  KeeperConfigPanel,
  keeperConfigSubscriptionCountsForTests,
  loadKeeperConfig,
  resetKeeperConfig,
} from './keeper-config-panel'
import { resetRuntimeCatalog } from '../lib/runtime-catalog-resource'

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
    mocks.pauseKeeper.mockClear()
    mocks.resumeKeeper.mockClear()
    mocks.wakeKeeper.mockClear()
    githubIdentityMocks.fetchKeeperGithubIdentity.mockClear()
    githubIdentityMocks.streamKeeperGithubLogin.mockClear()
    storeMocks.keepers.value = []
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetKeeperConfig()
    resetRuntimeCatalog()
  })

  it('exposes the keeper GitHub CLI identity under the 권한·샌드박스 tab', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    // The identity tab is active by default; the GitHub account card must not
    // leak outside its owning tab.
    expect(container.textContent).not.toContain('GitHub CLI 계정')

    selectKcfTab(container, '권한·샌드박스')
    await flush()
    await flush()

    expect(container.textContent).toContain('GitHub CLI 계정')
    expect(container.textContent).toContain('호스트 자격 증명 확인')
    expect(githubIdentityMocks.fetchKeeperGithubIdentity).toHaveBeenCalledWith(
      'keeper-sangsu',
      'github.com',
      expect.any(AbortSignal),
    )
    await flush()
    expect(container.textContent).toContain('@masc-sangsu-bot')
    expect(container.textContent).toContain('연결 안 됨')
  })

  it('separates editable prompt controls from read-only runtime metadata', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(1)
    expect(mocks.fetchRuntimeProfiles).not.toHaveBeenCalled()

    // identity tab (default): edit-scope callout + source provenance.
    expect(container.textContent).toContain('편집 가능 범위')
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
    expect(container.textContent).toContain('source:agent-core-provider-config-model')
    expect(container.textContent).toContain('request')
    expect(container.textContent).toContain('think:on')
    expect(container.textContent).toContain('policy')
    expect(container.textContent).toContain('wire:chat_template_kwargs')
    expect(container.textContent).toContain('활성 런타임')

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
    // collapsed by default; its authoritative scope and slots are hidden until
    // the operator expands it.
    selectKcfTab(container, '훅')
    await flush()
    const archToggle = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('전역 런타임 아키텍처'),
    )
    expect(archToggle).toBeTruthy()
    archToggle?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    expect(container.textContent).toContain('keeper_runtime_composite')
    expect(container.textContent).toContain('활성 슬롯 수')

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
    expect(textareas[0]?.value).toContain('Prefer direct remediation')
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

  it('allows runtime config assignment writes when Keeper name is valid without a manifest path', async () => {
    const base = makeKeeperConfig()
    const promptOnlyConfig = makeKeeperConfig({
      sources: {
        ...base.sources,
        default_source_kind: null,
        default_manifest_path: null,
      },
    })
    mocks.fetchKeeperConfig.mockResolvedValueOnce(promptOnlyConfig)

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '런타임')
    await flush()
    expect(container.querySelector('[data-testid="keeper-config-control-ledger"]')?.textContent)
      .toContain('Control backing')
    expect(container.querySelector('[data-control-id="kcf-runtime-assignment"]')?.getAttribute('data-control-kind'))
      .toBe('live-write')
    expect(container.querySelector('[data-testid="keeper-runtime-write-unsupported"]')).toBeNull()
    expect(container.querySelector('select[aria-label="runtime_id"]')).not.toBeNull()
    expect(container.querySelector('input[aria-label="컨텍스트 오버라이드"]')).not.toBeNull()
    expect(container.textContent).toContain('tier-group.keeper_unified')

    selectKcfTab(container, '실행 정책')
    await flush()
    expect(container.querySelector('input[aria-label="토큰 게이트"]')).toBeNull()
    expect(container.querySelector('button[aria-label="자동 부팅"]')).not.toBeNull()
    selectKcfTab(container, '권한·샌드박스')
    await flush()
    expect(container.querySelector('select[aria-label="sandbox_profile"]')).not.toBeNull()
    expect(container.querySelector('select[aria-label="network_mode"]')).not.toBeNull()
    expect(container.querySelector('textarea[aria-label="mention_targets"]')).not.toBeNull()
    expect(container.textContent).toContain('/tmp/workspace')

    const runtimeSave = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
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
      .toBe('hooks.scope | hooks.slots')
    expect(hookRow?.textContent).toContain('missing 2 config fields')

    const hookFilter = container.querySelector('[data-control-id="kcf-hooks-filter"]')
    expect(hookFilter?.getAttribute('data-control-contract-status')).toBe('ok')
    expect(hookFilter?.getAttribute('data-control-missing-config-fields')).toBe('')
  })

  it('refreshes shared keeper surfaces after prompt save', async () => {
    const updated = makeKeeperConfig({
      prompt: {
        ...makeKeeperConfig().prompt,
        instructions: 'Ship refreshed keeper surfaces',
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

    const instructions = container.querySelector('textarea') as HTMLTextAreaElement | null
    expect(instructions).not.toBeNull()
    instructions!.value = 'Ship refreshed keeper surfaces'
    instructions!.dispatchEvent(new Event('input', { bubbles: true }))
    instructions!.dispatchEvent(new FocusEvent('blur', { bubbles: true }))
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
      expect.objectContaining({ instructions: 'Ship refreshed keeper surfaces' }),
      makeKeeperConfig().config_revision,
    )
    expect(mocks.refreshKeeperRuntimeStatus).toHaveBeenCalledTimes(1)
    expect(mocks.refreshKeeperRuntimeStatus).toHaveBeenCalledWith({ force: true })
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
      button.textContent?.includes('Keeper 설정 저장'),
    )
    saveButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.patchKeeperConfig).toHaveBeenCalledWith(
      'keeper-sangsu',
      expect.objectContaining({
        runtime_id: 'tier.resilient_breaker',
      }),
      makeKeeperConfig().config_revision,
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
      button.textContent?.includes('Keeper 설정 저장'),
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
      makeKeeperConfig().config_revision,
    )
  })

  it('patches mention targets without re-emitting retired compaction gates', async () => {
    const base = makeKeeperConfig()
    mocks.patchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        workspace: {
          ...base.workspace,
          mention_targets: ['alpha', 'beta'],
        },
      }),
    )

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '권한·샌드박스')
    await flush()
    const mentionTargets = container.querySelector('textarea[aria-label="mention_targets"]') as HTMLTextAreaElement | null
    expect(mentionTargets).not.toBeNull()
    mentionTargets!.value = 'alpha\n beta \nalpha\n'
    mentionTargets!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
    )
    saveButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.patchKeeperConfig).toHaveBeenCalledWith(
      'keeper-sangsu',
      {
        mention_targets: ['alpha', 'beta'],
      },
      makeKeeperConfig().config_revision,
    )
  })

  it('patches autoboot and max-context override from the dashboard panel', async () => {
    mocks.patchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({
        autoboot_enabled: false,
        max_context_override: 64000,
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
    const autoboot = container.querySelector('button[aria-label="자동 부팅"]') as HTMLButtonElement | null
    expect(autoboot).not.toBeNull()
    autoboot!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
    )
    saveButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.patchKeeperConfig).toHaveBeenCalledWith(
      'keeper-sangsu',
      expect.objectContaining({
        autoboot_enabled: false,
        max_context_override: 64000,
      }),
      makeKeeperConfig().config_revision,
    )
  })

  it('patches exact Keeper Skill names from the policy tab', async () => {
    mocks.patchKeeperConfig.mockResolvedValueOnce(
      makeKeeperConfig({ skills: { names: ['ocaml-coding', 'proof-harness'] } }),
    )

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()
    const mode = container.querySelector('select[aria-label="Skill 선택 방식"]') as HTMLSelectElement | null
    expect(mode?.value).toBe('all')
    mode!.value = 'names'
    mode!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()

    const names = container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement | null
    expect(names).not.toBeNull()
    names!.value = 'ocaml-coding\n proof-harness \nocaml-coding'
    names!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    mode!.value = 'all'
    mode!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    expect(container.querySelector('textarea[aria-label="Skill 이름"]')).toBeNull()
    mode!.value = 'names'
    mode!.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    expect((container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement).value)
      .toBe('ocaml-coding\n proof-harness \nocaml-coding')

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
    )
    expect(saveButton).toBeDefined()
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.patchKeeperConfig).toHaveBeenCalledWith(
      'keeper-sangsu',
      { skills: { names: ['ocaml-coding', 'proof-harness'] } },
      makeKeeperConfig().config_revision,
    )
    expect(mocks.refreshKeeperRuntimeStatus).toHaveBeenCalledWith({ force: true })
  })

  it('saves explicit none and then clears back to all Skills', async () => {
    const selected = makeKeeperConfig({
      skills: { names: ['ocaml-coding', 'future-skill'] },
    })
    mocks.fetchKeeperConfig.mockResolvedValueOnce(selected)
    mocks.patchKeeperConfig
      .mockResolvedValueOnce(makeKeeperConfig({ skills: { names: [] } }))
      .mockResolvedValueOnce(makeKeeperConfig({ skills: { names: null } }))

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()
    selectKcfTab(container, '실행 정책')
    await flush()

    const names = container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement
    names.value = ''
    names.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    let saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
    )
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()
    expect(mocks.patchKeeperConfig).toHaveBeenNthCalledWith(
      1,
      'keeper-sangsu',
      { skills: { names: [] } },
      selected.config_revision,
    )

    const mode = container.querySelector('select[aria-label="Skill 선택 방식"]') as HTMLSelectElement
    mode.value = 'all'
    mode.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
    )
    saveButton!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()
    expect(mocks.patchKeeperConfig).toHaveBeenNthCalledWith(
      2,
      'keeper-sangsu',
      { skills: {} },
      makeKeeperConfig({ skills: { names: [] } }).config_revision,
    )
  })

  it('edits proactive policy from TOML truth when live meta has drifted', async () => {
    const base = makeKeeperConfig()
    const drifted = makeKeeperConfig({
      proactive: { enabled: true },
      sources: {
        ...base.sources,
        override_fields: ['proactive.enabled'],
        override_field_sources: [{
          field: 'proactive.enabled',
          source: 'live_meta',
          live_source: 'runtime_overlay',
          default_source: 'toml',
          default_source_kind: 'toml',
          default_manifest_path: '/tmp/config/keepers/rtprobe.toml',
          default_manifest_exists: true,
          default_missing: false,
          default_value: false,
          live_value: true,
        }],
      },
    })
    mocks.fetchKeeperConfig.mockResolvedValueOnce(drifted)
    mocks.patchKeeperConfig.mockResolvedValueOnce(makeKeeperConfig({
      proactive: { enabled: true },
    }))

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    expect(container.textContent).toContain('프로액티브 설정 드리프트')
    expect(container.textContent).toContain('TOML OFF / live meta ON')

    selectKcfTab(container, '실행 정책')
    await flush()
    const proactive = container.querySelector('button[aria-label="프로액티브 활성"]') as HTMLButtonElement | null
    expect(proactive?.getAttribute('aria-checked')).toBe('false')
    expect(container.textContent).toContain('TOML OFF / live meta ON')

    proactive?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    expect(proactive?.getAttribute('aria-checked')).toBe('true')

    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
    )
    saveButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    await flush()

    expect(mocks.patchKeeperConfig).toHaveBeenCalledWith(
      'keeper-sangsu',
      { proactive_enabled: true },
      drifted.config_revision,
    )
  })

  it('blocks an invalid max-context override instead of silently clearing it', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '런타임')
    await flush()
    const maxContext = container.querySelector('input[aria-label="컨텍스트 오버라이드"]') as HTMLInputElement | null
    expect(maxContext).not.toBeNull()
    maxContext!.value = '-1'
    maxContext!.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    expect(container.textContent).toContain('양의 정수만 허용 (0 = 해제)')
    const saveButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
    )
    expect(saveButton?.disabled).toBe(true)
    expect(mocks.patchKeeperConfig).not.toHaveBeenCalled()
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

  it('does not let a late Keeper A save overwrite Keeper B Skill edits', async () => {
    let resolveKeeperA: ((value: KeeperConfig) => void) | undefined
    const keeperASave = new Promise<KeeperConfig>(resolve => {
      resolveKeeperA = resolve
    })
    const configA = makeKeeperConfig({ name: 'keeper-a', skills: { names: null } })
    const configB = makeKeeperConfig({ name: 'keeper-b', skills: { names: null } })
    mocks.fetchKeeperConfig.mockResolvedValueOnce(configA)
    mocks.patchKeeperConfig.mockReturnValueOnce(keeperASave)

    render(html`<${KeeperConfigPanel} keeperName="keeper-a" />`, container)
    await flush()
    await flush()
    selectKcfTab(container, '실행 정책')
    await flush()
    let mode = container.querySelector('select[aria-label="Skill 선택 방식"]') as HTMLSelectElement
    mode.value = 'names'
    mode.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    let names = container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement
    names.value = 'keeper-a-skill'
    names.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    const saveA = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'),
    )
    saveA!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    mocks.fetchKeeperConfig.mockResolvedValueOnce(configB)
    render(html`<${KeeperConfigPanel} keeperName="keeper-b" />`, container)
    await flush()
    await flush()
    selectKcfTab(container, '실행 정책')
    await flush()
    mode = container.querySelector('select[aria-label="Skill 선택 방식"]') as HTMLSelectElement
    mode.value = 'names'
    mode.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    names = container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement
    names.value = 'keeper-b-skill'
    names.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()

    resolveKeeperA?.(makeKeeperConfig({
      name: 'keeper-a',
      skills: { names: ['keeper-a-skill'] },
    }))
    await flush()
    await flush()

    expect((container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement).value)
      .toBe('keeper-b-skill')
  })

  it('fences a stale save when the same Keeper panel is closed and reopened', async () => {
    let rejectOldSave: ((reason: unknown) => void) | undefined
    let resolveNewSave: ((value: KeeperConfig) => void) | undefined
    const oldSave = new Promise<KeeperConfig>((_resolve, reject) => {
      rejectOldSave = reject
    })
    const newSave = new Promise<KeeperConfig>(resolve => {
      resolveNewSave = resolve
    })
    const config = makeKeeperConfig({ skills: { names: null } })
    mocks.fetchKeeperConfig
      .mockResolvedValueOnce(config)
      .mockResolvedValueOnce(config)
    mocks.patchKeeperConfig
      .mockReturnValueOnce(oldSave)
      .mockReturnValueOnce(newSave)

    const beginSkillSave = async (name: string) => {
      selectKcfTab(container, '실행 정책')
      await flush()
      const mode = container.querySelector('select[aria-label="Skill 선택 방식"]') as HTMLSelectElement
      mode.value = 'names'
      mode.dispatchEvent(new Event('change', { bubbles: true }))
      await flush()
      const names = container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement
      names.value = name
      names.dispatchEvent(new Event('input', { bubbles: true }))
      await flush()
      const save = Array.from(container.querySelectorAll('button')).find(button =>
        button.textContent?.includes('Keeper 설정 저장'),
      )
      save!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await flush()
    }

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()
    await beginSkillSave('old-skill')

    render(null, container)
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()
    await beginSkillSave('new-skill')

    resolveNewSave?.(makeKeeperConfig({
      config_revision: {
        manifest: { state: 'sha256', value: 'b'.repeat(64) },
        runtime_assignment: { state: 'runtime_config_missing' },
      },
      skills: { names: ['new-skill'] },
    }))
    await flush()
    await flush()
    rejectOldSave?.(new ApiRequestError({
      method: 'POST',
      path: '/api/v1/keepers/keeper-sangsu/config',
      status: 409,
      errorCode: 'keeper_config_revision_conflict',
    }))
    await flush()
    await flush()
    expect((container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement).value)
      .toBe('new-skill')
    expect(mocks.patchKeeperConfig).toHaveBeenCalledTimes(2)
    expect(mocks.patchKeeperConfig).toHaveBeenNthCalledWith(
      1,
      'keeper-sangsu',
      { skills: { names: ['old-skill'] } },
      config.config_revision,
    )
    expect(mocks.patchKeeperConfig).toHaveBeenNthCalledWith(
      2,
      'keeper-sangsu',
      { skills: { names: ['new-skill'] } },
      config.config_revision,
    )
    expect(mocks.showToast).not.toHaveBeenCalledWith(
      expect.stringContaining('다른 화면에서 변경'),
      'warning',
    )
  })

  it('keeps the user edit and reloads authority when the current owner hits a revision conflict', async () => {
    const config = makeKeeperConfig({ name: 'keeper-sangsu', skills: { names: null } })
    const fresh = makeKeeperConfig({
      name: 'keeper-sangsu',
      skills: { names: ['remote-skill'] },
      config_revision: {
        manifest: { state: 'sha256', value: 'b'.repeat(64) },
        runtime_assignment: { state: 'runtime_config_missing' },
      },
    })
    mocks.fetchKeeperConfig.mockResolvedValueOnce(config)
    mocks.fetchKeeperConfig.mockResolvedValueOnce(fresh)
    let rejectSave: ((error: ApiRequestError) => void) | undefined
    mocks.patchKeeperConfig.mockReturnValueOnce(new Promise<KeeperConfig>((_, reject) => {
      rejectSave = reject
    }))

    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()
    selectKcfTab(container, '실행 정책')
    await flush()
    const mode = container.querySelector('select[aria-label="Skill 선택 방식"]') as HTMLSelectElement
    mode.value = 'names'
    mode.dispatchEvent(new Event('change', { bubbles: true }))
    await flush()
    const names = container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement
    names.value = 'my-skill'
    names.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    const save = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('Keeper 설정 저장'))
    save!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()
    rejectSave?.(new ApiRequestError({
      method: 'POST',
      path: '/api/v1/keepers/keeper-sangsu/config',
      status: 409,
      errorCode: 'keeper_config_revision_conflict',
    }))
    await flush()
    await flush()

    // The 409 path reloads the authority but must keep the user's edit
    // (rebased onto the fresh config), not discard it.
    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(2)
    expect((container.querySelector('textarea[aria-label="Skill 이름"]') as HTMLTextAreaElement).value)
      .toBe('my-skill')
    expect(mocks.showToast).toHaveBeenCalledWith(
      expect.stringContaining('편집한 내용은 남겨뒀으니'),
      'warning',
    )
  })
})

// keeper-v2 design vocabulary (prototypes/keeper-v2/keeper-config.jsx +
// organisms-5.jsx parity): top-bar kr/sandbox badges, avatar block, 표시 이름
// field, 파생 사실, fallback chain, kcf-dead removal note, kcf-paths editor,
// set-link navigation. Every assertion reads a live signal — the roster row
// (storeMocks.keepers) or the loaded KeeperConfig — never a static mock.
describe('KeeperConfigPanel — keeper-v2 design blocks', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetKeeperConfig()
    resetRuntimeCatalog()
    mocks.fetchKeeperConfig.mockClear()
    mocks.fetchRuntimeProviders.mockClear()
    storeMocks.keepers.value = []
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetKeeperConfig()
    storeMocks.keepers.value = []
  })

  it('renders koreanName + sandbox badges in the top bar from the roster row', async () => {
    storeMocks.keepers.value = [{
      name: 'keeper-sangsu',
      koreanName: '상수',
      sandbox_target: '/workspace/keepers/keeper-sangsu',
      created_at: '2026-01-04T00:00:00Z',
    }]
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    expect(container.querySelector('.kcf-top-kr')?.textContent).toBe('상수')
    const sandbox = container.querySelector('.kcf-top-sandbox')
    expect(sandbox?.textContent).toContain('/workspace/keepers/keeper-sangsu')
  })

  it('omits kr/sandbox badges when the roster row has none', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    expect(container.querySelector('.kcf-top-kr')).toBeNull()
    expect(container.querySelector('.kcf-top-sandbox')).toBeNull()
  })

  it('identity tab renders the avatar block, read-only 표시 이름 field, and 파생 사실', async () => {
    storeMocks.keepers.value = [{
      name: 'keeper-sangsu',
      koreanName: '상수',
      sandbox_target: '/workspace/keepers/keeper-sangsu',
      created_at: '2026-01-04T00:00:00Z',
    }]
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    // Avatar: sigil preview is live (kSlot/kSigil derivation); the portrait
    // picker renders disabled with the design's 기획 badge (no avatar API).
    const upload = container.querySelector('.kav-portraits .kav-por.kav-upload') as HTMLButtonElement | null
    expect(upload).toBeTruthy()
    expect(upload?.disabled).toBe(true)
    expect(container.querySelector('.kav .kcf-plan')?.textContent).toContain('기획')

    // 표시 이름: real display name, read-only (no rename writer).
    const nameInput = container.querySelector('.kcf-idrow .kcf-field input.kcf-input') as HTMLInputElement | null
    expect(nameInput).toBeTruthy()
    expect(nameInput?.readOnly).toBe(true)
    expect(nameInput?.value).toBe('상수')

    // 파생 사실: sandbox target + creation time + runtime profile, all live.
    const facts = container.querySelector('.kcf-facts')
    expect(facts?.textContent).toContain('/workspace/keepers/keeper-sangsu')
    expect(facts?.textContent).toContain('2026-01-04T00:00:00Z')
    expect(container.textContent).toContain('tier-group.keeper_unified')
  })

  it('policy tab carries the kcf-dead removal note for deleted handoff', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '실행 정책')
    await flush()

    const dead = container.querySelectorAll('.kcf-dead')
    expect(dead.length).toBe(1)
    expect(container.textContent).toContain('Handoff_triggered')
  })

  it('runtime tab renders the fallback candidate chain from runtime_options', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '런타임')
    await flush()

    const items = Array.from(container.querySelectorAll('.kcf-chain-item')).map(el => el.textContent)
    expect(items).toEqual(['tier-group.keeper_unified', 'tier.resilient_breaker'])
  })

  it('access tab shows the sandbox roots as a read-only line', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '권한·샌드박스')
    await flush()

    expect(container.querySelector('.kcf-paths textarea')).toBeNull()
    expect(container.querySelector('.kcf-path-eff')?.textContent).toContain('/tmp/workspace')
  })

  it('hooks tab links external-effect calls to the Gate queue via set-link', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '훅')
    await flush()

    const link = container.querySelector('.kc-inh-note .set-link')
    expect(link?.textContent).toContain('Gate 큐')
  })

  it('prompt tab routes global prompt editing through the design set-link', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    selectKcfTab(container, '프롬프트')
    await flush()

    const link = container.querySelector('[data-testid="kcf-prompt-global-edit-link"]')
    expect(link?.classList.contains('set-link')).toBe(true)
  })
})
