// MASC Dashboard — Keeper config (structured read-only view + mutations).
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post } from './core'
import { isRecord, asBoolean, asInt, asNullableString, asNumber, asStringArray, asRecordArray } from '../components/common/normalize'
import { ensureDevToken } from './dev-token'
import { asKeeperRuntimeBlockerClass } from '../lib/runtime-blocker-class'
import type { KeeperConfig, KeeperFeatureStatus, KeeperHookSlot } from '../types'

function asLooseBoolean(value: unknown, fallback = false): boolean {
  const booleanValue = asBoolean(value)
  if (booleanValue !== undefined) return booleanValue
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase()
    if (normalized === 'true') return true
    if (normalized === 'false') return false
  }
  return fallback
}

function asLooseNullableBoolean(value: unknown): boolean | null {
  const booleanValue = asBoolean(value)
  if (booleanValue !== undefined) return booleanValue
  if (typeof value !== 'string') return null
  return asLooseBoolean(value)
}

function asLooseNumber(value: unknown): number | undefined {
  const direct = asNumber(value)
  if (direct !== undefined) return direct
  if (typeof value !== 'string') return undefined
  const parsed = Number.parseFloat(value.trim())
  return Number.isFinite(parsed) ? parsed : undefined
}

function asLooseNullableNumber(value: unknown): number | null {
  return asLooseNumber(value) ?? null
}

function normalizeStringList(value: unknown): string[] {
  const array = asStringArray(value)
  if (array.length > 0) return array
  const single = asNullableString(value)
  return single ? [single] : []
}

function normalizeKeeperFeatureStatus(value: unknown): KeeperFeatureStatus {
  const status = asNullableString(value)
  switch (status) {
    case 'wired':
    case 'source_only':
    case 'unwired':
      return status
    default:
      return 'unwired'
  }
}

function normalizeKeeperHookSlot(raw: unknown): KeeperHookSlot | null {
  if (!isRecord(raw)) return null
  return {
    active: asLooseBoolean(raw.active),
    source: asNullableString(raw.source) ?? 'unknown',
    gates: normalizeStringList(raw.gates),
    effects: normalizeStringList(raw.effects),
    features: normalizeStringList(raw.features),
  }
}

function normalizeKeeperHookSlots(raw: unknown): Record<string, KeeperHookSlot> {
  if (!isRecord(raw)) return {}
  const slots: Record<string, KeeperHookSlot> = {}
  for (const [name, value] of Object.entries(raw)) {
    const slot = normalizeKeeperHookSlot(value)
    if (slot) slots[name] = slot
  }
  return slots
}

function normalizeKeeperConfigActiveGoals(raw: unknown): KeeperConfig['workspace']['active_goals'] {
  return asRecordArray(raw)
    .map((item) => {
      const id = asNullableString(item.id)
      const title = asNullableString(item.title)
      if (!id || !title) return null
      return { id, title }
    })
    .filter((item): item is KeeperConfig['workspace']['active_goals'][number] => item !== null)
}

function dedupeStringList(values: readonly string[]): string[] {
  return Array.from(new Set(values.filter(value => value.trim() !== '').map(value => value.trim())))
}

function collectRawFieldPaths(raw: unknown, prefix = ''): string[] {
  if (!isRecord(raw)) return []
  const paths: string[] = []
  for (const [key, value] of Object.entries(raw)) {
    if (prefix === '' && key === 'field_presence') continue
    const path = prefix === '' ? key : `${prefix}.${key}`
    paths.push(path)
    paths.push(...collectRawFieldPaths(value, path))
  }
  return paths
}

function normalizeKeeperConfigFieldPresence(data: Record<string, unknown>): KeeperConfig['field_presence'] {
  const raw = isRecord(data.field_presence) ? data.field_presence : null
  const presentPaths = raw
    ? normalizeStringList(raw.present_paths)
    : collectRawFieldPaths(data)
  return {
    schema: raw
      ? asNullableString(raw.schema) ?? 'keeper.config.field_presence.v1'
      : 'keeper.config.field_presence.client-derived.v1',
    producer: raw
      ? asNullableString(raw.producer) ?? 'unknown'
      : 'dashboard-keeper-config.normalizer',
    present_paths: dedupeStringList(presentPaths),
  }
}

function normalizePromptBlock(raw: unknown, fallbackKey: string): { key: string; source: string; text: string } {
  if (!isRecord(raw)) {
    return {
      key: fallbackKey,
      source: 'unknown',
      text: '',
    }
  }
  return {
    key: asNullableString(raw.key) ?? fallbackKey,
    source: asNullableString(raw.source) ?? 'unknown',
    text: asNullableString(raw.text) ?? '',
  }
}

function normalizeDefaultSourceKind(value: unknown): KeeperConfig['sources']['default_source_kind'] {
  const sourceKind = asNullableString(value)
  switch (sourceKind) {
    case 'toml':
    case 'persona':
      return sourceKind
    default:
      return null
  }
}

function normalizePerProviderTimeoutMode(
  raw: unknown,
  perProviderTimeoutSec: number | null,
): KeeperConfig['execution']['per_provider_timeout_mode'] {
  return asNullableString(raw) === 'override' || perProviderTimeoutSec != null
    ? 'override'
    : 'turn_budget_default'
}

function normalizeKeeperConfig(raw: unknown, requestedName: string): KeeperConfig {
  const data = isRecord(raw) ? raw : {}
  const prompt = isRecord(data.prompt) ? data.prompt : {}
  const promptBlocks = isRecord(prompt.system_prompt_blocks) ? prompt.system_prompt_blocks : {}
  const execution = isRecord(data.execution) ? data.execution : {}
  const compaction = isRecord(data.compaction) ? data.compaction : {}
  const proactive = isRecord(data.proactive) ? data.proactive : {}
  const drift = isRecord(data.drift) ? data.drift : {}
  const handoff = isRecord(data.handoff) ? data.handoff : {}
  const hooks = isRecord(data.hooks) ? data.hooks : null
  const runtime = isRecord(data.runtime) ? data.runtime : {}
  const runtimeTrust = isRecord(data.runtime_trust) ? data.runtime_trust : null
  const workspace = isRecord(data.workspace) ? data.workspace : {}
  const sources = isRecord(data.sources) ? data.sources : {}
  const metrics = isRecord(data.metrics) ? data.metrics : {}
  const limits = isRecord(data.limits) ? data.limits : {}
  const perProviderTimeoutSec = asLooseNullableNumber(execution.per_provider_timeout_sec)
  const lastLatencyMs = asInt(metrics.last_latency_ms)

  return {
    name: asNullableString(data.name) ?? requestedName,
    active_goal_ids: normalizeStringList(data.active_goal_ids),
    autoboot_enabled: asLooseBoolean(data.autoboot_enabled, true),
    max_context_override: asInt(data.max_context_override) ?? null,
    limits: {
      min_context_override_tokens: asInt(limits.min_context_override_tokens) ?? null,
      max_context_override_tokens: asInt(limits.max_context_override_tokens) ?? null,
    },
    sandbox_profile: asNullableString(data.sandbox_profile) ?? '(unknown sandbox_profile)',
    network_mode: asNullableString(data.network_mode) ?? '(unknown network_mode)',
    sandbox_last_error: asNullableString(data.sandbox_last_error),
    allowed_paths: normalizeStringList(data.allowed_paths),
    effective_allowed_paths: normalizeStringList(data.effective_allowed_paths),
    prompt: {
      goal: asNullableString(prompt.goal) ?? '',
      instructions: asNullableString(prompt.instructions) ?? '',
      system_prompt_blocks: {
        constitution: normalizePromptBlock(promptBlocks.constitution, 'keeper.constitution'),
        world: normalizePromptBlock(promptBlocks.world, 'keeper.world'),
        capabilities: normalizePromptBlock(promptBlocks.capabilities, 'keeper.capabilities'),
      },
      effective_system_prompt: asNullableString(prompt.effective_system_prompt) ?? '',
      unified_system_prompt: asNullableString(prompt.unified_system_prompt) ?? '',
      unified_user_message_preview:
        asNullableString(prompt.unified_user_message_preview) ?? '',
    },
    execution: {
      models: normalizeStringList(execution.models),
      active_model: '',
      active_model_label: null,
      last_model_used_label: null,
      per_provider_timeout_sec: perProviderTimeoutSec,
      per_provider_timeout_mode: normalizePerProviderTimeoutMode(
        execution.per_provider_timeout_mode,
        perProviderTimeoutSec,
      ),
      verify: asLooseBoolean(execution.verify),
      selected_runtime_id: asNullableString(execution.selected_runtime_id) ?? '',
      selected_runtime_canonical:
        asNullableString(execution.selected_runtime_canonical)
        ?? asNullableString(execution.selected_runtime_id)
        ?? '',
      runtime_options: normalizeStringList(execution.runtime_options),
    },
    compaction: {
      profile: asNullableString(compaction.profile) ?? '(unknown compaction profile)',
      ratio_gate: asLooseNumber(compaction.ratio_gate) ?? 0.85,
      message_gate: asInt(compaction.message_gate) ?? 0,
      token_gate: asInt(compaction.token_gate) ?? 0,
      cooldown_sec: asInt(compaction.cooldown_sec) ?? 0,
    },
    proactive: {
      enabled: asLooseBoolean(proactive.enabled),
    },
    drift: {
      status: normalizeKeeperFeatureStatus(drift.status),
      enabled: asLooseNullableBoolean(drift.enabled),
      min_turn_gap: asInt(drift.min_turn_gap) ?? null,
      count_total: asInt(drift.count_total) ?? null,
      last_reason: asNullableString(drift.last_reason),
    },
    handoff: {
      auto: asLooseBoolean(handoff.auto),
      threshold: asLooseNumber(handoff.threshold) ?? 0.85,
      cooldown_sec: asInt(handoff.cooldown_sec) ?? 0,
    },
    hooks: hooks
      ? {
          slots: normalizeKeeperHookSlots(hooks.slots),
          deny_list: normalizeStringList(hooks.deny_list),
          // deny_list_count is derived (deny_list.length); not stored.
          cost_budget: {
            max_cost_usd: asLooseNullableNumber(isRecord(hooks.cost_budget) ? hooks.cost_budget.max_cost_usd : undefined),
            active: asLooseBoolean(isRecord(hooks.cost_budget) ? hooks.cost_budget.active : undefined),
          },
        }
      : undefined,
    runtime: {
      paused: asLooseBoolean(runtime.paused),
      registered: asLooseBoolean(runtime.registered),
      keepalive_running: asLooseBoolean(runtime.keepalive_running),
      registry_state: asNullableString(runtime.registry_state),
      fiber_health: asNullableString(runtime.fiber_health) ?? 'unknown',
      runtime_blocker_class: asKeeperRuntimeBlockerClass(runtime.runtime_blocker_class),
      active_model_label: null,
      last_model_used_label: null,
      runtime_blocker_summary: asNullableString(runtime.runtime_blocker_summary),
    },
    runtime_trust: runtimeTrust,
    workspace: {
      mention_targets: normalizeStringList(workspace.mention_targets),
      bound_workspace_ids: normalizeStringList(workspace.bound_workspace_ids),
      active_goal_ids: normalizeStringList(workspace.active_goal_ids),
      active_goals: normalizeKeeperConfigActiveGoals(workspace.active_goals),
      active_goal_count: asInt(workspace.active_goal_count) ?? 0,
      missing_active_goal_ids: normalizeStringList(workspace.missing_active_goal_ids),
    },
    sources: {
      live_meta_path: asNullableString(sources.live_meta_path) ?? '',
      default_manifest_path: asNullableString(sources.default_manifest_path),
      default_source_kind: normalizeDefaultSourceKind(sources.default_source_kind),
      precedence: normalizeStringList(sources.precedence),
      has_live_override: asLooseBoolean(sources.has_live_override),
      override_fields: normalizeStringList(sources.override_fields),
    },
    metrics: {
      generation: asInt(metrics.generation) ?? 0,
      total_turns: asInt(metrics.total_turns) ?? 0,
      total_input_tokens: asInt(metrics.total_input_tokens) ?? 0,
      total_output_tokens: asInt(metrics.total_output_tokens) ?? 0,
      total_tokens: asInt(metrics.total_tokens) ?? 0,
      total_cost_usd: asLooseNumber(metrics.total_cost_usd) ?? 0,
      last_model_used: '',
      last_input_tokens: asInt(metrics.last_input_tokens) ?? 0,
      last_output_tokens: asInt(metrics.last_output_tokens) ?? 0,
      last_total_tokens: asInt(metrics.last_total_tokens) ?? 0,
      last_latency_ms: lastLatencyMs != null && lastLatencyMs > 0 ? lastLatencyMs : null,
      last_total_tokens_per_sec: asLooseNullableNumber(metrics.last_total_tokens_per_sec),
      last_output_tokens_per_sec: asLooseNullableNumber(metrics.last_output_tokens_per_sec),
      compaction_count: asInt(metrics.compaction_count) ?? 0,
    },
    field_presence: normalizeKeeperConfigFieldPresence(data),
  }
}

// --- Keeper config (structured read-only view) ---

export function fetchKeeperConfig(name: string): Promise<KeeperConfig> {
  return get<unknown>(`/api/v1/keepers/${encodeURIComponent(name)}/config`)
    .then(raw => normalizeKeeperConfig(raw, name))
}

export type SandboxProfile = 'local' | 'docker'
export type SandboxNetworkMode = 'none' | 'inherit'

export type KeeperConfigUpdatePayload = {
  runtime_id?: string
  active_goal_ids?: string[]
  mention_targets?: string[]
  autoboot_enabled?: boolean
  max_context_override?: number | null
  allowed_paths?: string[]
  // Sandbox
  sandbox_profile?: SandboxProfile
  network_mode?: SandboxNetworkMode
  // Prompt fields
  goal?: string
  instructions?: string
  // Proactive
  proactive_enabled?: boolean
  // Compaction
  compaction_profile?: string
  compaction_ratio_gate?: number
  compaction_message_gate?: number
  compaction_token_gate?: number
  compaction_cooldown_sec?: number
  // Handoff
  auto_handoff?: boolean
  handoff_threshold?: number
  handoff_cooldown_sec?: number
}

export async function patchKeeperConfig(
  name: string,
  payload: KeeperConfigUpdatePayload,
): Promise<KeeperConfig> {
  await ensureDevToken()
  return post<unknown>(
    `/api/v1/keepers/${encodeURIComponent(name)}/config`,
    payload,
  ).then(raw => normalizeKeeperConfig(raw, name))
}
