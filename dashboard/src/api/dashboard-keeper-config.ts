// MASC Dashboard — Keeper config (structured read-only view + mutations).
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post } from './core'
import { isRecord, asBoolean, asInt, asNullableString, asNumber, asStringArray, asRecordArray, isPositiveSafeInteger } from '../components/common/normalize'
import { ensureDevToken } from './dev-token'
import { asKeeperRuntimeBlockerClass } from '../lib/runtime-blocker-class'
import type { KeeperConfig, KeeperConfigOverrideFieldSource, KeeperHookSlot, KeeperManifestRevision, KeeperRuntimeAssignmentRevision, KeeperConfigRevision, KeeperConfigRevisionState, SandboxProfile } from '../types'
import { UNKNOWN_NETWORK_MODE, UNKNOWN_SANDBOX_PROFILE } from '../types'

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

function decodeMaxContextOverride(value: unknown): number | null {
  if (value === null) return null
  if (isPositiveSafeInteger(value)) return value
  throw new Error(
    'Invalid keeper config response: max_context_override must be a positive safe integer or null',
  )
}

// 64 lowercase hex characters — the canonical stored SHA-256 spelling,
// String_util.is_lowercase_sha256_hex on the OCaml side.
const SHA256_HEX_RE = /^[0-9a-f]{64}$/

function decodeSkillNames(value: unknown): string[] | null {
  if (value === null) return null
  if (Array.isArray(value) && value.every(name => typeof name === 'string')) {
    return [...value]
  }
  throw new Error(
    'Invalid keeper config response: skills.names must be an array of strings or null',
  )
}

function decodeManifestRevision(value: unknown): KeeperManifestRevision {
  if (!isRecord(value)) {
    throw new Error('Invalid keeper config response: config_revision.manifest must be an object')
  }
  if (value.state === 'missing' && Object.keys(value).length === 1) {
    return { state: 'missing' }
  }
  if (
    value.state === 'sha256'
    && typeof value.value === 'string'
    && SHA256_HEX_RE.test(value.value)
    && Object.keys(value).length === 2
  ) {
    return { state: 'sha256', value: value.value }
  }
  const detail = value.state === 'unavailable' && typeof value.detail === 'string'
    ? `: ${value.detail}`
    : ''
  throw new Error(`Invalid keeper config response: config_revision.manifest is unavailable or malformed${detail}`)
}

function decodeRuntimeAssignmentRevision(value: unknown): KeeperRuntimeAssignmentRevision {
  if (!isRecord(value)) {
    throw new Error('Invalid keeper config response: runtime_assignment revision is malformed')
  }
  if (value.state === 'runtime_config_missing' && Object.keys(value).length === 1) {
    return { state: 'runtime_config_missing' }
  }
  if (value.state !== 'runtime_config_present' || typeof value.source_revision !== 'string'
    || !SHA256_HEX_RE.test(value.source_revision) || !isRecord(value.assignment)
    || Object.keys(value).length !== 3) {
    throw new Error('Invalid keeper config response: runtime_assignment revision is malformed')
  }
  const assignment = value.assignment
  if (assignment.state === 'missing' && Object.keys(assignment).length === 1) {
    return {
      state: 'runtime_config_present',
      source_revision: value.source_revision,
      assignment: { state: 'missing' },
    }
  }
  if (assignment.state === 'assigned' && typeof assignment.runtime_id === 'string'
    && assignment.runtime_id.trim() !== '' && Object.keys(assignment).length === 2) {
    return {
      source_revision: value.source_revision,
      state: 'runtime_config_present',
      assignment: { state: 'assigned', runtime_id: assignment.runtime_id },
    }
  }
  throw new Error('Invalid keeper config response: runtime_assignment state is malformed')
}

function decodeConfigRevision(value: unknown): KeeperConfigRevisionState {
  if (!isRecord(value) || Object.keys(value).length !== 2) {
    throw new Error('Invalid keeper config response: config_revision must be an object')
  }
  // The failure shape shares the two-key count with the success shape, so
  // the discriminator has to be read before either arm is assumed: the
  // server answers `{state:"unavailable", detail}` when it could not read
  // the revision, and that detail is what the operator needs to see.
  if (value.state === 'unavailable' && typeof value.detail === 'string') {
    return { state: 'unavailable', detail: value.detail }
  }
  return {
    manifest: decodeManifestRevision(value.manifest),
    runtime_assignment: decodeRuntimeAssignmentRevision(value.runtime_assignment),
  }
}

/** A write receipt carries the revision the write produced; an unavailable
 * revision there is a contract violation, not a state to store. */
function decodeAvailableConfigRevision(value: unknown): KeeperConfigRevision {
  const revision = decodeConfigRevision(value)
  if ('state' in revision) {
    throw new Error(
      `Invalid keeper config response: write receipt revision is unavailable: ${revision.detail}`,
    )
  }
  return revision
}

function decodeConfigWarningArray(
  value: unknown,
): NonNullable<KeeperConfig['config_transaction_warnings']> {
  if (!Array.isArray(value)) {
    throw new Error('Invalid keeper config response: config warnings must be an array')
  }
  return value.map((warning) => {
    if (
      !isRecord(warning)
      || typeof warning.code !== 'string'
      || typeof warning.detail !== 'string'
      || warning.code.trim() === ''
      || warning.detail.trim() === ''
      || Object.keys(warning).length !== 2
    ) {
      throw new Error('Invalid keeper config response: config warning must carry code and detail')
    }
    return { code: warning.code, detail: warning.detail }
  })
}

function decodeConfigWarnings(value: unknown): KeeperConfig['config_transaction_warnings'] {
  if (value === undefined) return undefined
  return decodeConfigWarningArray(value)
}

function decodeConfigWrite(value: unknown): KeeperConfig['config_write'] {
  if (value === undefined) return undefined
  if (
    !isRecord(value)
    || Object.keys(value).length !== 3
    || !Object.hasOwn(value, 'revision')
    || typeof value.applied !== 'boolean'
    || !Object.hasOwn(value, 'warnings')
  ) {
    throw new Error('Invalid keeper config response: config_write is malformed')
  }
  return {
    revision: decodeAvailableConfigRevision(value.revision),
    applied: value.applied,
    warnings: decodeConfigWarningArray(value.warnings),
  }
}

function normalizeStringList(value: unknown): string[] {
  const array = asStringArray(value)
  if (array.length > 0) return array
  const single = asNullableString(value)
  return single ? [single] : []
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
      return sourceKind
    default:
      return null
  }
}

function normalizeOverrideFieldSources(raw: unknown): KeeperConfigOverrideFieldSource[] {
  return asRecordArray(raw)
    .map((row): KeeperConfigOverrideFieldSource | null => {
      const field = asNullableString(row.field)
      if (!field) return null
      return {
        field,
        source: asNullableString(row.source),
        live_source: asNullableString(row.live_source),
        default_source: asNullableString(row.default_source),
        default_source_kind: normalizeDefaultSourceKind(row.default_source_kind),
        default_manifest_path: asNullableString(row.default_manifest_path),
        default_manifest_exists: asBoolean(row.default_manifest_exists) ?? null,
        default_missing: asBoolean(row.default_missing) ?? null,
        default_value: row.default_value,
        live_value: row.live_value,
      }
    })
    .filter((row): row is KeeperConfigOverrideFieldSource => row !== null)
}

function keeperConfigUnavailableMessage(raw: unknown): string {
  if (!isRecord(raw)) {
    throw new Error('Invalid keeper config response: config_error must be a typed object')
  }
  const keeper = asNullableString(raw.keeper)
  const keeperPath = asNullableString(raw.keeper_path)
  const kind = asNullableString(raw.kind)
  const failingPath = asNullableString(raw.failing_path)
  const detail = asNullableString(raw.detail)
  const validKind = kind === 'read_error'
    || kind === 'parse_error'
    || kind === 'profile_error'
    || kind === 'invalid_name'
  if (
    !keeper
    || !keeperPath
    || !validKind
    || !failingPath
    || !detail
    || raw.terminal_reason !== 'config_invalid'
    || raw.severity !== 'error'
    || raw.blocking !== true
    || raw.operator_action_required !== true
    || raw.next_action !== 'fix_keeper_toml_config'
  ) {
    throw new Error('Invalid keeper config response: config_error must be a typed object')
  }
  return `Keeper config unavailable for ${keeper}: ${kind} at ${failingPath}: ${detail}`
}

function normalizeKeeperConfig(raw: unknown, requestedName: string): KeeperConfig {
  const data = isRecord(raw) ? raw : {}
  if (data.config_error !== undefined && data.config_error !== null) {
    throw new Error(keeperConfigUnavailableMessage(data.config_error))
  }
  const maxContextOverride = decodeMaxContextOverride(data.max_context_override)
  const prompt = isRecord(data.prompt) ? data.prompt : {}
  const promptBlocks = isRecord(prompt.system_prompt_blocks) ? prompt.system_prompt_blocks : {}
  const execution = isRecord(data.execution) ? data.execution : {}
  const proactive = isRecord(data.proactive) ? data.proactive : {}
  const skills = isRecord(data.skills) ? data.skills : null
  if (!skills || !Object.hasOwn(skills, 'names')) {
    throw new Error('Invalid keeper config response: skills.names is required')
  }
  const hooks = isRecord(data.hooks) ? data.hooks : null
  const runtime = isRecord(data.runtime) ? data.runtime : {}
  const runtimeTrust = isRecord(data.runtime_trust) ? data.runtime_trust : null
  const workspace = isRecord(data.workspace) ? data.workspace : {}
  const sources = isRecord(data.sources) ? data.sources : {}
  const metrics = isRecord(data.metrics) ? data.metrics : {}
  const lastLatencyMs = asInt(metrics.last_latency_ms)

  return {
    name: asNullableString(data.name) ?? requestedName,
    config_revision: decodeConfigRevision(data.config_revision),
    config_write: decodeConfigWrite(data.config_write),
    config_transaction_warnings:
      decodeConfigWarnings(data.config_transaction_warnings),
    autoboot_enabled: asLooseBoolean(data.autoboot_enabled, true),
    max_context_override: maxContextOverride,
    sandbox_profile: asNullableString(data.sandbox_profile) ?? UNKNOWN_SANDBOX_PROFILE,
    network_mode: asNullableString(data.network_mode) ?? UNKNOWN_NETWORK_MODE,
    remote_endpoint: asNullableString(data.remote_endpoint),
    keeper_last_error: asNullableString(data.keeper_last_error),
    sandbox_roots: normalizeStringList(data.sandbox_roots),
    prompt: {
      instructions: asNullableString(prompt.instructions) ?? '',
      system_prompt_blocks: {
        system: normalizePromptBlock(promptBlocks.system, 'keeper'),
      },
      effective_system_prompt: asNullableString(prompt.effective_system_prompt) ?? '',
      assembled_system_prompt: asNullableString(prompt.assembled_system_prompt) ?? '',
      unified_user_message_preview:
        asNullableString(prompt.unified_user_message_preview) ?? '',
    },
    execution: {
      models: normalizeStringList(execution.models),
      active_model: '',
      active_model_label: null,
      last_model_used_label: null,
      verify: asLooseBoolean(execution.verify),
      selected_runtime_id: asNullableString(execution.selected_runtime_id) ?? '',
      selected_runtime_canonical:
        asNullableString(execution.selected_runtime_canonical)
        ?? asNullableString(execution.selected_runtime_id)
        ?? '',
      runtime_options: normalizeStringList(execution.runtime_options),
    },
    proactive: {
      enabled: asLooseBoolean(proactive.enabled),
    },
    skills: {
      names: decodeSkillNames(skills.names),
    },
    hooks: hooks
      ? {
          scope: asNullableString(hooks.scope),
          slots: normalizeKeeperHookSlots(hooks.slots),
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
    },
    sources: {
      live_meta_path: asNullableString(sources.live_meta_path) ?? '',
      default_manifest_path: asNullableString(sources.default_manifest_path),
      default_source_kind: normalizeDefaultSourceKind(sources.default_source_kind),
      precedence: normalizeStringList(sources.precedence),
      has_live_override: asLooseBoolean(sources.has_live_override),
      override_fields: normalizeStringList(sources.override_fields),
      override_field_sources: normalizeOverrideFieldSources(sources.override_field_sources),
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
    },
    field_presence: normalizeKeeperConfigFieldPresence(data),
  }
}

// --- Keeper config (structured read-only view) ---

export function fetchKeeperConfig(name: string): Promise<KeeperConfig> {
  return get<unknown>(`/api/v1/keepers/${encodeURIComponent(name)}/config`)
    .then(raw => normalizeKeeperConfig(raw, name))
}

// The closed profile set is declared once, in types/core.ts, next to the
// coverage record that drives the panel's parser and its select. This module
// re-exports it so `from './api/dashboard'` consumers are unchanged.
export type { SandboxProfile } from '../types'
export type SandboxNetworkMode = 'none' | 'inherit'

export type KeeperConfigUpdatePayload = {
  runtime_id?: string
  mention_targets?: string[]
  autoboot_enabled?: boolean
  max_context_override?: number | null
  // Sandbox
  sandbox_profile?: SandboxProfile
  network_mode?: SandboxNetworkMode
  // null detaches the endpoint. Omitting it carries the keeper TOML's value
  // into the new profile, which the runtime then refuses.
  remote_endpoint?: string | null
  // Prompt fields
  instructions?: string
  // Proactive
  proactive_enabled?: boolean
  skills?: { names?: string[] }
}

export async function patchKeeperConfig(
  name: string,
  payload: KeeperConfigUpdatePayload,
  expectedConfigRevision: KeeperConfigRevision,
): Promise<KeeperConfig> {
  await ensureDevToken()
  return post<unknown>(
    `/api/v1/keepers/${encodeURIComponent(name)}/config`,
    {
      ...payload,
      expected_config_revision: expectedConfigRevision,
    },
  ).then(raw => normalizeKeeperConfig(raw, name))
}
