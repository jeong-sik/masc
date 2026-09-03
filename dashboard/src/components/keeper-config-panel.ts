// Keeper config panel -- structured config viewer with inline editing.
// Fetches /api/v1/keepers/:name/config and renders grouped sections.
// Redesigned: clean section headers, consistent row styling, proper form controls.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { signal } from '@preact/signals'
import {
  patchKeeperConfig,
} from '../api/dashboard'
import { ApiRequestError } from '../api/core'
import { pauseKeeper, resumeKeeper, wakeKeeper } from '../api/keeper'
import type { DashboardRuntimeProviderSnapshot, KeeperConfigUpdatePayload, SandboxProfile, SandboxNetworkMode } from '../api/dashboard'
import type { KeeperConfig, KeeperHookSlot } from '../types'
import { SANDBOX_PROFILE_OPTIONS, toSandboxProfile } from '../types'
import { formatTokens } from '../lib/format-number'
import {
  PHASE_LABEL_KO,
  PHASE_TONE,
  type FleetTone,
  type KeeperPhaseToken,
} from '../lib/fleet-tone'

/** The config overlay's phase pill reads three runtime booleans rather than
 *  a `Keeper`, so it cannot call `keeperDisplayStatus`. It maps them onto
 *  the same token union instead, so the word and the dot colour below come
 *  from the shared tables like every other surface.
 *
 *  The pill used to compute its word and its dot from two separate ternary
 *  chains with opposite precedence — the word tested `paused` first, the dot
 *  tested `keepalive_running` first. In the window where both are true, which
 *  is the normal state right after a pause (the pause button's own title says
 *  "running → paused, 현재 turn 은 정상 종료"), it rendered `일시정지` beside a
 *  green glowing dot. One token now feeds both.
 *
 *  `registered` without a running keepalive loop is `unbooted`, matching
 *  `PHASE_DESCRIPTION_KO.unbooted` — "등록만 되어 있고 아직 부팅되지 않았습니다". */
function configPhaseToken(runtime: {
  paused?: boolean
  keepalive_running?: boolean
  registered?: boolean
}): KeeperPhaseToken {
  if (runtime.paused) return 'paused'
  if (runtime.keepalive_running) return 'running'
  if (runtime.registered) return 'unbooted'
  return 'offline'
}

/** v2 skin colour names (`--status-*`, `styles/variables.css`) rather than
 *  the `--color-status-*` role names, matching the rest of this overlay. */
const PHASE_DOT_COLOR: Record<FleetTone, string> = {
  ok: 'var(--status-ok)',
  warn: 'var(--status-warn)',
  bad: 'var(--status-bad)',
  busy: 'var(--color-accent-fg)',
  idle: 'var(--text-dim)',
}
import { MISSING_DATA_DASH } from '../lib/format-string'
import { relativeTime } from '../lib/format-time'
import type { AsyncState } from '../lib/async-state'
import { showToast } from './common/toast'
import { ErrorState, LoadingState } from './common/feedback-state'
import { BTN_FILLED_BASE } from './common/button-filled-base'
import { ExpandableTextarea } from './common/expandable-textarea'
import { KeeperGithubIdentityPanel } from './keeper-github-identity-panel'
import { KeeperIdentityPanel } from './keeper-identity-panel'
import {
  findRuntimeCatalogEntry,
  loadRuntimeCatalog,
  runtimeCatalogState,
} from '../lib/runtime-catalog-resource'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
  runtimeCatalogSnapshotFacts,
} from '../lib/runtime-provider-summary'
import { keepers, refreshKeeperRuntimeStatus } from '../store'
import { bumpKeeperRuntimeTraceRefresh } from './keeper-runtime-trace-refresh'
import { KcfAvatarBlock, KcfPlan } from './keeper-config-v2-blocks'
import { navigate } from '../router'
import { SetupGuideCard } from './setup-guide-card'
import { SectionHeader } from './common/section-header'
import { StatusDot } from './common/status-dot'
import { KeeperBadge } from './keeper-badge'
import {
  applyKeeperConfigUpdate,
  configKeeperName,
  configState,
  loadKeeperConfig,
  registerKeeperConfigResetHandler,
  registerKeeperConfigUpdateHandler,
} from './keeper-config-state'

// The CAS conflict code Keeper_turn_up_update.config_revision_conflict_code
// writes on the OCaml side — the one language-boundary copy in this bundle.
const REVISION_CONFLICT_CODE = 'keeper_config_revision_conflict'

async function refreshKeeperSurfacesAfterConfigSave(): Promise<void> {
  // Re-fetch the right-rail runtime-trace evidence (drift badge) immediately;
  // refreshKeeperRuntimeStatus below only updates the live-runtime slice, which
  // does not change on save. Bump unconditionally so a failed status refresh
  // still updates the assignment badge.
  bumpKeeperRuntimeTraceRefresh()
  try {
    await refreshKeeperRuntimeStatus({ force: true })
  } catch (err) {
    const message = err instanceof Error ? err.message : '런타임 상태 새로고침 실패'
    showToast(message, 'warning')
  }
}

export {
  applyKeeperConfigUpdate,
  configState,
  keeperConfigSubscriptionCountsForTests,
  loadKeeperConfig,
  peekKeeperConfigLoadStatus,
  peekLoadedKeeperConfig,
  resetKeeperConfig,
} from './keeper-config-state'

// ── v2 prototype config modal: left rail tabs (keeper-config.css .kcf-*) ──
// The full keeper config redesign (keeper-v2/keeper-config.jsx) presents the
// field set as a fullscreen .kcf-overlay modal with an 8-tab left rail instead
// of a single vertical accordion. Each tab groups the existing live fields by
// concern; no field, save flow, or shared signal is dropped — only regrouped.
export type KcfTabId =
  | 'identity'
  | 'prompt'
  | 'runtime'
  | 'policy'
  | 'access'
  | 'hooks'
  | 'health'

const KCF_TABS: readonly (readonly [KcfTabId, string, string])[] = [
  ['identity', '정체성', '◈'],
  ['prompt', '프롬프트', '¶'],
  ['runtime', '런타임', '◷'],
  ['policy', '실행 정책', '⚖'],
  ['access', '권한·샌드박스', '⚿'],
  ['hooks', '훅', '⬡'],
  ['health', '상태·진단', '◉'],
]

export const KCF_TAB_IDS: readonly KcfTabId[] = KCF_TABS.map(([id]) => id)

type KeeperConfigControlKind = 'live-read' | 'live-write' | 'browser-local' | 'unsupported'

type PrimitiveConfigField = string | number | boolean | null | undefined
type ConfigFieldIsLeaf<T> =
  NonNullable<T> extends PrimitiveConfigField ? true
    : NonNullable<T> extends readonly unknown[] ? true
      : NonNullable<T> extends (...args: readonly never[]) => unknown ? true
        : string extends keyof NonNullable<T> ? true
          : false
type ConfigFieldPath<T> = {
  [K in keyof T & string]: ConfigFieldIsLeaf<T[K]> extends true
    ? K
    : K | `${K}.${ConfigFieldPath<NonNullable<T[K]>>}`
}[keyof T & string]

export type KeeperConfigFieldPath = ConfigFieldPath<KeeperConfig>

export type KeeperConfigControlEndpoint =
  | '/api/v1/keepers/:name/config'
  | '/api/v1/keepers/:name/directive'
  | '/api/v1/dashboard/goals'
  | '/api/v1/providers'
  | '/api/v1/keepers/:name/github-identity'
  | '/api/v1/keepers/:name/github-login'

export type KeeperConfigBrowserStateKey =
  | 'promptPreviewTab'
  | 'hookFilterQuery'

export type KeeperConfigControlEvidence =
  | { readonly kind: 'keeper-config-field'; readonly path: KeeperConfigFieldPath }
  | { readonly kind: 'api'; readonly method: 'GET' | 'PATCH' | 'POST'; readonly endpoint: KeeperConfigControlEndpoint; readonly operation?: string }
  | { readonly kind: 'browser-state'; readonly key: KeeperConfigBrowserStateKey }
  | { readonly kind: 'unsupported'; readonly reason: string }

export type KeeperConfigControlContractStatus =
  | { readonly kind: 'ok'; readonly missingConfigFields: readonly [] }
  | { readonly kind: 'missing-config-field'; readonly missingConfigFields: readonly KeeperConfigFieldPath[] }

export type KeeperConfigControlInventoryItem = {
  readonly id: string
  readonly tab: KcfTabId
  readonly label: string
  readonly kind: KeeperConfigControlKind
  readonly source: string
  readonly action: string
  readonly contracts: readonly KeeperConfigControlEvidence[]
}

const kcfTab = signal<KcfTabId>('identity')

// Deep-link entry point: focus a specific config tab before the modal opens.
// `kcfTab` is reset to 'identity' only on panel teardown (see
// resetKeeperConfigPanelDrafts), never on mount, so a value set here survives the
// next open. Used by the read-only runtime card (keeper-runtime-model-editor) to
// land the operator on the 런타임 tab where runtime_id is actually edited.
export function focusKeeperConfigTab(tab: KcfTabId): void {
  kcfTab.value = tab
}

// ── State ────────────────────────────────────────────────

// Client-only search over the goal catalogue (title/id substring). The catalogue
// can be large, so the goals tab filters the rendered list without a fetch.
const editMode = signal(false)
const saving = signal(false)
const saveError = signal<string | null>(null)

// Draft values for editable fields (only used in edit mode)
type EditDraft = {
  instructions: string
}

const editDraft = signal<EditDraft | null>(null)
const hookFilterQuery = signal<string>('')
// The hook-slot / deny-list / cost-budget block is keeper-AGNOSTIC — the
// backend builds it from a global static introspection with no keeper name,
// so it is identical for every keeper. It is grouped under a collapsible
// "전역 런타임 아키텍처" section (collapsed by default) to keep the per-keeper
// editable controls above as the focus, instead of reading as per-keeper state.
const globalArchExpanded = signal<boolean>(false)
const lastSavedAt = signal<string | null>(null)
const promptPreviewTab = signal<'blocks' | 'system' | 'world'>('blocks')

// ── Hook slot filter ─────────────────────────────────────

export type HookSlotEntry = readonly [name: string, slot: KeeperHookSlot]

/**
 * All detail tags of a hook slot, across every category.
 *
 * A slot's gates / effects / features are distinct categories that can
 * COEXIST (e.g. `pre_tool_use` carries both gates and a cost-telemetry
 * feature), so they are concatenated, not coalesced. The earlier
 * `slot.gates ?? slot.effects ?? slot.features` returned only the first
 * category, and — because the normalizer fills absent categories with `[]`
 * rather than `undefined` — that nullish chain always stopped at the empty
 * `gates` array for every effects-/features-only slot, hiding their tags
 * from both the filter and the rendered chips.
 */
export function hookSlotDetails(slot: KeeperHookSlot): readonly string[] {
  return [...(slot.gates ?? []), ...(slot.effects ?? []), ...(slot.features ?? [])]
}

/**
 * Pure filter for hook slot entries.
 *
 * Case-insensitive substring match against:
 * - slot name (the `Record<string, KeeperHookSlot>` key)
 * - `slot.source`
 * - any detail tag from `hookSlotDetails` (gates ∪ effects ∪ features)
 *
 * Empty/whitespace query returns the input reference unchanged so
 * `useMemo` preserves referential equality when no filter is active.
 * Input is never mutated.
 */
export function filterHookSlots(
  entries: readonly HookSlotEntry[],
  query: string,
): readonly HookSlotEntry[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return entries
  return entries.filter(([name, slot]) => {
    if (name.toLowerCase().includes(needle)) return true
    if (slot.source && slot.source.toLowerCase().includes(needle)) return true
    const tags = hookSlotDetails(slot)
    for (const tag of tags) {
      if (tag && tag.toLowerCase().includes(needle)) return true
    }
    return false
  })
}

function initDraftFromConfig(c: KeeperConfig): EditDraft {
  return {
    instructions: c.prompt.instructions,
  }
}

function buildPayload(draft: EditDraft, orig: KeeperConfig): KeeperConfigUpdatePayload {
  const payload: KeeperConfigUpdatePayload = {}
  const setIfChanged = (key: keyof EditDraft) => {
    const next = draft[key].trim()
    const prev = orig.prompt[key].trim()
    if (next !== prev) {
      // Preserve the user's exact whitespace when persisting; trim only for comparison.
      payload[key] = draft[key]
    }
  }
  setIfChanged('instructions')
  return payload
}

// Runtime config draft for sandbox/proactive inline editing
export type MaxContextOverrideDraftResult =
  | { ok: true; value: number | null }
  | { ok: false; error: string }

export function parseMaxContextOverrideDraft(raw: string): MaxContextOverrideDraftResult {
  if (raw === '0') return { ok: true, value: null }
  if (!/^[1-9]\d*$/.test(raw)) {
    return { ok: false, error: '양의 정수만 허용 (0 = 해제)' }
  }
  const value = Number(raw)
  if (!Number.isSafeInteger(value)) {
    return { ok: false, error: '컨텍스트 오버라이드는 안전한 정수 범위 안이어야 합니다.' }
  }
  return { ok: true, value }
}

export type RuntimeDraft = {
  runtime_id: string
  autoboot_enabled: boolean
  max_context_override: string
  sandbox_profile: SandboxProfile | null
  mention_targets_text: string
  network_mode: SandboxNetworkMode
  // '' = no endpoint. Only meaningful under remote_ssh; serialised as null.
  remote_endpoint: string
  proactive_enabled: boolean
  // Keeper-level autonomous wake prompt; '' = inherit fleet (sent as null)
  skill_selection:
    | { mode: 'all'; prior_names_text: string }
    | { mode: 'names'; names_text: string }
}

export type KeeperConfigBooleanProjection =
  | { kind: 'configured'; configured: boolean; live: boolean }
  | {
      kind: 'drift'
      configured: boolean
      live: boolean
      defaultSource: 'toml'
      defaultManifestPath: string | null
    }
  | { kind: 'live-only'; live: boolean }
  | { kind: 'invalid-evidence'; live: boolean }

type KeeperConfigBooleanField = 'autoboot_enabled' | 'proactive.enabled'

/** Resolve an editable boolean against the same declarative config evidence
 * the PATCH endpoint writes. The top-level value is live-meta state; when a
 * typed source row proves that TOML differs, the editor must start from TOML
 * rather than presenting the stale runtime overlay as the persisted policy. */
export function keeperConfigBooleanProjection(
  c: KeeperConfig,
  field: KeeperConfigBooleanField,
  live: boolean,
): KeeperConfigBooleanProjection {
  const evidence = c.sources.override_field_sources?.find(row => row.field === field)
  if (!evidence || evidence.default_missing === true) return { kind: 'live-only', live }
  if (
    evidence.default_source_kind !== 'toml'
    || typeof evidence.default_value !== 'boolean'
    || typeof evidence.live_value !== 'boolean'
  ) {
    return { kind: 'invalid-evidence', live }
  }
  if (evidence.default_value === evidence.live_value) {
    return { kind: 'configured', configured: evidence.default_value, live: evidence.live_value }
  }
  return {
    kind: 'drift',
    configured: evidence.default_value,
    live: evidence.live_value,
    defaultSource: 'toml',
    defaultManifestPath: evidence.default_manifest_path,
  }
}

function configuredBooleanValue(projection: KeeperConfigBooleanProjection): boolean {
  return projection.kind === 'configured' || projection.kind === 'drift'
    ? projection.configured
    : projection.live
}

function proactiveConfigProjection(c: KeeperConfig): KeeperConfigBooleanProjection {
  return keeperConfigBooleanProjection(c, 'proactive.enabled', c.proactive.enabled)
}

function proactiveConfigValue(c: KeeperConfig): boolean {
  return configuredBooleanValue(proactiveConfigProjection(c))
}

function proactiveConfigHint(c: KeeperConfig): string {
  const projection = proactiveConfigProjection(c)
  if (projection.kind === 'drift') {
    const configured = projection.configured ? 'ON' : 'OFF'
    const live = projection.live ? 'ON' : 'OFF'
    return `유휴 시 keeper 자가 기동 · TOML ${configured} / live meta ${live}`
  }
  if (projection.kind === 'invalid-evidence') {
    return '유휴 시 keeper 자가 기동 · config source evidence invalid'
  }
  return '유휴 시 keeper 자가 기동'
}

type KeeperRuntimeDraftState = {
  keeperName: string
  draft: RuntimeDraft
}

type KeeperConfigPanelOwner = {
  keeperName: string
  epoch: symbol
}

type KeeperConfigSaveRequest = {
  owner: KeeperConfigPanelOwner
  request: symbol
}

const runtimeDraft = signal<KeeperRuntimeDraftState | null>(null)
const activeKeeperConfigOwner = signal<KeeperConfigPanelOwner | null>(null)
const runtimeSaving = signal(false)
const runtimeSaveRequest = signal<KeeperConfigSaveRequest | null>(null)
const promptSaveRequest = signal<KeeperConfigSaveRequest | null>(null)
const runtimeDirectiveSaving = signal<'pause' | 'resume' | 'wakeup' | null>(null)
function resetKeeperConfigPanelDrafts(): void {
  editMode.value = false
  editDraft.value = null
  saveError.value = null
  lastSavedAt.value = null
  promptPreviewTab.value = 'blocks'
  runtimeDraft.value = null
  activeKeeperConfigOwner.value = null
  runtimeSaving.value = false
  runtimeSaveRequest.value = null
  promptSaveRequest.value = null
  runtimeDirectiveSaving.value = null
  hookFilterQuery.value = ''
  globalArchExpanded.value = false
  kcfTab.value = 'identity'
}

function syncRuntimeDraftFromConfig(name: string, updated: KeeperConfig): void {
  if (activeKeeperConfigOwner.value?.keeperName !== name) return
  runtimeDraft.value = {
    keeperName: name,
    draft: initRuntimeDraftFromConfig(updated),
  }
}

let panelSubscriptionRefs = 0
let unregisterPanelReset: (() => void) | null = null
let unregisterPanelUpdate: (() => void) | null = null

function retainKeeperConfigPanelSubscriptions(): () => void {
  if (panelSubscriptionRefs === 0) {
    unregisterPanelReset = registerKeeperConfigResetHandler(resetKeeperConfigPanelDrafts)
    unregisterPanelUpdate = registerKeeperConfigUpdateHandler(syncRuntimeDraftFromConfig)
  }
  panelSubscriptionRefs += 1

  return () => {
    panelSubscriptionRefs = Math.max(0, panelSubscriptionRefs - 1)
    if (panelSubscriptionRefs > 0) return
    resetKeeperConfigPanelDrafts()
    unregisterPanelReset?.()
    unregisterPanelUpdate?.()
    unregisterPanelReset = null
    unregisterPanelUpdate = null
  }
}

// The profile parser and the select's option list both read
// SANDBOX_PROFILE_COVERAGE (types/core.ts), so this panel holds no second copy
// of the runtime's set. `toSandboxProfile` returns null for a value it cannot
// name: the old default was 'local', the loosest profile, so a keeper
// declaring microvm was shown — and saved back — as running on the host.

export function coerceNetworkMode(raw: string | undefined): SandboxNetworkMode {
  return raw === 'none' ? 'none' : 'inherit'
}

export function initRuntimeDraftFromConfig(c: KeeperConfig): RuntimeDraft {
  return {
    runtime_id: c.execution.selected_runtime_id ?? '',
    autoboot_enabled: c.autoboot_enabled,
    max_context_override: String(c.max_context_override ?? 0),
    sandbox_profile: toSandboxProfile(c.sandbox_profile),
    mention_targets_text: c.workspace.mention_targets.join('\n'),
    network_mode: coerceNetworkMode(c.network_mode),
    remote_endpoint: c.remote_endpoint ?? '',
    proactive_enabled: proactiveConfigValue(c),
    skill_selection: c.skills.names === null
      ? { mode: 'all', prior_names_text: '' }
      : { mode: 'names', names_text: c.skills.names.join('\n') },
  }
}

// Re-base a runtime draft onto a freshly loaded config after a revision
// conflict, keeping exactly the fields the user changed relative to the base
// they saw. Re-saving a stale-base draft against the fresh config would
// diff the *old base values* as if the user had edited them, silently
// reverting the other writer's changes on untouched fields.
export function rebaseRuntimeDraftOnFreshConfig(
  draft: RuntimeDraft,
  seen: KeeperConfig,
  fresh: KeeperConfig,
): RuntimeDraft {
  const base = initRuntimeDraftFromConfig(seen)
  const rebased = initRuntimeDraftFromConfig(fresh)
  if (draft.runtime_id !== base.runtime_id) rebased.runtime_id = draft.runtime_id
  if (draft.autoboot_enabled !== base.autoboot_enabled) {
    rebased.autoboot_enabled = draft.autoboot_enabled
  }
  if (draft.max_context_override !== base.max_context_override) {
    rebased.max_context_override = draft.max_context_override
  }
  if (draft.sandbox_profile !== base.sandbox_profile) {
    rebased.sandbox_profile = draft.sandbox_profile
  }
  if (draft.mention_targets_text !== base.mention_targets_text) {
    rebased.mention_targets_text = draft.mention_targets_text
  }
  if (draft.network_mode !== base.network_mode) rebased.network_mode = draft.network_mode
  if (draft.remote_endpoint !== base.remote_endpoint) {
    rebased.remote_endpoint = draft.remote_endpoint
  }
  if (draft.proactive_enabled !== base.proactive_enabled) {
    rebased.proactive_enabled = draft.proactive_enabled
  }
  const draftSelection = draft.skill_selection
  const baseSelection = base.skill_selection
  const selectionChanged =
    draftSelection.mode !== baseSelection.mode
    || (draftSelection.mode === 'names'
        && baseSelection.mode === 'names'
        && draftSelection.names_text !== baseSelection.names_text)
    || (draftSelection.mode === 'all'
        && baseSelection.mode === 'all'
        && draftSelection.prior_names_text !== baseSelection.prior_names_text)
  if (selectionChanged) rebased.skill_selection = { ...draftSelection }
  return rebased
}

export function keeperRuntimeConfigWriteUnsupportedReason(c: KeeperConfig): string | null {
  const name = c.name?.trim()
  if (!name) {
    return 'runtime 설정 저장은 유효한 키퍼 이름이 확인될 때만 지원됩니다.'
  }
  return null
}

export function keeperRuntimeConfigCanWrite(c: KeeperConfig): boolean {
  return keeperRuntimeConfigWriteUnsupportedReason(c) === null
}

function keeperConfigManifestSource(c: KeeperConfig): string {
  const kind = c.sources.default_source_kind ?? 'unknown'
  const manifest = c.sources.default_manifest_path?.trim()
  return manifest ? `${kind}:${manifest}` : `${kind}:manifest path unavailable`
}

const KEEPER_CONFIG_API = '/api/v1/keepers/:name/config'

export function keeperConfigFailureRequiresAuthoritativeReload(error: unknown): boolean {
  return error instanceof ApiRequestError
    && (
      error.errorCode === 'keeper_manifest_reconciliation_required'
      || error.errorCode === 'keeper_config_composite_reconciliation_required'
      || error.authoritativeReloadRequired
      || (error.configApplied === true && error.runtimeSync === false)
    )
}

export function configDurabilityWarningMessage(
  subject: string,
  warnings: NonNullable<KeeperConfig['config_write']>['warnings'],
): string | null {
  if (warnings.length === 0) return null
  const warningCodes = warnings.map(warning => warning.code).join(', ')
  return `${subject} 적용됐지만 config durability 경고가 있습니다: ${warningCodes}`
}
const KEEPER_DIRECTIVE_API = '/api/v1/keepers/:name/directive'
const DASHBOARD_GOALS_API = '/api/v1/dashboard/goals'
const RUNTIME_PROVIDERS_API = '/api/v1/providers'

function configField(path: KeeperConfigFieldPath): KeeperConfigControlEvidence {
  return { kind: 'keeper-config-field', path }
}

function configFields(paths: readonly KeeperConfigFieldPath[]): KeeperConfigControlEvidence[] {
  return paths.map(configField)
}

function apiContract(
  method: 'GET' | 'PATCH' | 'POST',
  endpoint: KeeperConfigControlEndpoint,
  operation?: string,
): KeeperConfigControlEvidence {
  return operation
    ? { kind: 'api', method, endpoint, operation }
    : { kind: 'api', method, endpoint }
}

function browserState(key: KeeperConfigBrowserStateKey): KeeperConfigControlEvidence {
  return { kind: 'browser-state', key }
}

function unsupportedContract(reason: string): KeeperConfigControlEvidence {
  return { kind: 'unsupported', reason }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function keeperConfigHasField(config: KeeperConfig, path: KeeperConfigFieldPath): boolean {
  const presentPaths = config.field_presence?.present_paths
  if (presentPaths) return presentPaths.includes(path)

  let current: unknown = config
  for (const segment of path.split('.')) {
    if (!isRecord(current) || !Object.prototype.hasOwnProperty.call(current, segment)) {
      return false
    }
    current = current[segment]
  }
  return true
}

export function keeperConfigControlContractStatus(
  contracts: readonly KeeperConfigControlEvidence[],
  config: KeeperConfig,
): KeeperConfigControlContractStatus {
  const missingConfigFields = contracts
    .filter((contract): contract is Extract<KeeperConfigControlEvidence, { kind: 'keeper-config-field' }> => contract.kind === 'keeper-config-field')
    .map(contract => contract.path)
    .filter(path => !keeperConfigHasField(config, path))

  if (missingConfigFields.length === 0) return { kind: 'ok', missingConfigFields: [] }
  return { kind: 'missing-config-field', missingConfigFields }
}

function configReadContracts(paths: readonly KeeperConfigFieldPath[]): KeeperConfigControlEvidence[] {
  return [apiContract('GET', KEEPER_CONFIG_API), ...configFields(paths)]
}

function keeperRuntimeWriteContracts(
  c: KeeperConfig,
  writeOperation: string,
  paths: readonly KeeperConfigFieldPath[],
): KeeperConfigControlEvidence[] {
  const readContracts = configReadContracts(paths)
  const reason = keeperRuntimeConfigWriteUnsupportedReason(c)
  if (reason) {
    return [...readContracts, unsupportedContract(reason)]
  }
  return [...readContracts, apiContract('PATCH', KEEPER_CONFIG_API, writeOperation)]
}

function keeperRuntimeControlKind(c: KeeperConfig): KeeperConfigControlKind {
  return keeperRuntimeConfigCanWrite(c) ? 'live-write' : 'unsupported'
}

function keeperRuntimeControlAction(c: KeeperConfig, writeAction: string): string {
  const reason = keeperRuntimeConfigWriteUnsupportedReason(c)
  return reason ?? writeAction
}

function keeperRuntimeControlItem(
  c: KeeperConfig,
  tab: KcfTabId,
  id: string,
  label: string,
  source: string,
  writeAction: string,
  writeOperation: string,
  paths: readonly KeeperConfigFieldPath[],
): KeeperConfigControlInventoryItem {
  return {
    id,
    tab,
    label,
    kind: keeperRuntimeControlKind(c),
    source,
    action: keeperRuntimeControlAction(c, writeAction),
    contracts: keeperRuntimeWriteContracts(c, writeOperation, paths),
  }
}

export function keeperConfigControlInventory(
  tab: KcfTabId,
  c: KeeperConfig,
): readonly KeeperConfigControlInventoryItem[] {
  const manifestSource = keeperConfigManifestSource(c)
  const configApiSource = 'GET /api/v1/keepers/:name/config'
  switch (tab) {
    case 'identity':
      return [
        {
          id: 'kcf-identity-provenance',
          tab,
          label: 'Keeper provenance',
          kind: 'live-read',
          source: `${configApiSource} sources.*`,
          action: 'read-only source and precedence projection',
          contracts: configReadContracts([
            'sources.live_meta_path',
            'sources.default_manifest_path',
            'sources.default_source_kind',
            'sources.precedence',
            'sources.has_live_override',
            'sources.override_fields',
            'sources.override_field_sources',
          ]),
        },
      ]
    case 'prompt':
      return [
        {
          id: 'kcf-prompt-instructions',
          tab,
          label: 'Keeper instructions',
          kind: 'live-write',
          source: `${configApiSource} prompt.instructions + sources.override_fields`,
          action: 'PATCH /api/v1/keepers/:name/config instructions',
          contracts: [
            ...configReadContracts(['prompt.instructions', 'sources.override_fields']),
            apiContract('PATCH', KEEPER_CONFIG_API, 'instructions'),
          ],
        },
        {
          id: 'kcf-prompt-preview-tabs',
          tab,
          label: 'Prompt preview mode',
          kind: 'browser-local',
          source: 'promptPreviewTab signal',
          action: 'switch visible prompt preview only',
          contracts: [browserState('promptPreviewTab')],
        },
      ]
    case 'runtime':
      return [
        keeperRuntimeControlItem(
          c,
          tab,
          'kcf-runtime-assignment',
          'Runtime assignment',
          `${configApiSource} execution.selected_runtime_id + ${manifestSource}`,
          'PATCH /api/v1/keepers/:name/config runtime_id',
          'runtime_id',
          [
            'execution.selected_runtime_id',
            'sources.default_manifest_path',
            'sources.default_source_kind',
          ],
        ),
        {
          id: 'kcf-runtime-catalog',
          tab,
          label: 'Runtime catalog diagnostics',
          kind: 'live-read',
          source: 'GET /api/v1/providers',
          action: 'read-only selected runtime diagnostics',
          contracts: [apiContract('GET', RUNTIME_PROVIDERS_API)],
        },
        keeperRuntimeControlItem(
          c,
          tab,
          'kcf-runtime-context-override',
          'Context override',
          `${configApiSource} max_context_override`,
          'PATCH /api/v1/keepers/:name/config max_context_override',
          'max_context_override',
          ['max_context_override'],
        ),
      ]
    case 'policy':
      return [
        {
          id: 'kcf-policy-verify',
          tab,
          label: 'Verify gate',
          kind: 'live-read',
          source: `${configApiSource} execution.verify`,
          action: 'read-only execution policy projection',
          contracts: configReadContracts(['execution.verify']),
        },
        keeperRuntimeControlItem(
          c,
          tab,
          'kcf-policy-proactive',
          'Proactive and autoboot',
          `${configApiSource} proactive.* + autoboot_enabled`,
          'PATCH /api/v1/keepers/:name/config proactive/autoboot fields',
          'proactive/autoboot fields',
          [
            'autoboot_enabled',
            'proactive.enabled',
            'sources.override_field_sources',
          ],
        ),
        keeperRuntimeControlItem(
          c,
          tab,
          'kcf-policy-skills',
          'Keeper Skills',
          `${configApiSource} skills.names`,
          'PATCH /api/v1/keepers/:name/config skills',
          'skills.names',
          ['skills.names'],
        ),
      ]
    case 'access':
      return [
        keeperRuntimeControlItem(
          c,
          tab,
          'kcf-access-sandbox',
          'Sandbox and network',
          `${configApiSource} sandbox_profile/network_mode + ${manifestSource}`,
          'PATCH /api/v1/keepers/:name/config sandbox/network/path fields',
          'sandbox/network/path fields',
          [
            'sandbox_profile',
            'network_mode',
            'sources.default_manifest_path',
            'sources.default_source_kind',
          ],
        ),
        keeperRuntimeControlItem(
          c,
          tab,
          'kcf-access-mentions',
          'Mention targets',
          `${configApiSource} workspace.mention_targets + ${manifestSource}`,
          'PATCH /api/v1/keepers/:name/config mention_targets',
          'mention_targets',
          [
            'workspace.mention_targets',
            'sources.default_manifest_path',
            'sources.default_source_kind',
          ],
        ),
        {
          id: 'kcf-access-effective-scope',
          tab,
          label: 'Effective scope',
          kind: 'live-read',
          source: `${configApiSource} sandbox_roots + workspace.bound_workspace_ids`,
          action: 'read-only computed access projection',
          contracts: configReadContracts(['sandbox_roots', 'workspace.bound_workspace_ids']),
        },
        {
          id: 'kcf-access-github-identity',
          tab,
          label: 'GitHub CLI identity',
          kind: 'live-write',
          source: 'GET /api/v1/keepers/:name/github-identity stored/effective probes',
          action: 'POST /api/v1/keepers/:name/github-login operator web login stream',
          contracts: [
            apiContract('GET', '/api/v1/keepers/:name/github-identity'),
            apiContract('POST', '/api/v1/keepers/:name/github-login'),
          ],
        },
      ]
    case 'hooks':
      return [
        {
          id: 'kcf-hooks-slots',
          tab,
          label: 'Hook slots',
          kind: 'live-read',
          source: `${configApiSource} hooks.scope/hooks.slots`,
          action: 'read-only global runtime architecture projection',
          contracts: configReadContracts(['hooks.scope', 'hooks.slots']),
        },
        {
          id: 'kcf-hooks-filter',
          tab,
          label: 'Hook slot filter',
          kind: 'browser-local',
          source: 'hookFilterQuery signal',
          action: 'client-side slot/source/tag filter only',
          contracts: [browserState('hookFilterQuery')],
        },
        {
          id: 'kcf-hooks-editing',
          tab,
          label: 'Keeper-scoped hook editing',
          kind: 'unsupported',
          source: 'no keeper-scoped hook writer exposed',
          action: 'render read-only global architecture',
          contracts: [unsupportedContract('no keeper-scoped hook writer exposed')],
        },
      ]
    case 'health':
      return [
        {
          id: 'kcf-health-runtime-state',
          tab,
          label: 'Runtime state and trust',
          kind: 'live-read',
          source: `${configApiSource} runtime.* + runtime_trust`,
          action: 'read-only liveness and trust diagnostics',
          contracts: configReadContracts([
            'runtime.paused',
            'runtime.registered',
            'runtime.keepalive_running',
            'runtime.registry_state',
            'runtime.fiber_health',
            'runtime.runtime_blocker_class',
            'runtime.runtime_blocker_summary',
            'runtime_trust',
          ]),
        },
        {
          id: 'kcf-health-directives',
          tab,
          label: 'Lifecycle directives',
          kind: 'live-write',
          source: 'keeper lifecycle API + runtime.paused/registered/keepalive_running',
          action: 'pause/resume/wakeup keeper lifecycle API',
          contracts: [
            ...configReadContracts(['runtime.paused', 'runtime.registered', 'runtime.keepalive_running']),
            apiContract('POST', KEEPER_DIRECTIVE_API, 'pause/resume/wakeup'),
          ],
        },
        {
          id: 'kcf-health-metrics',
          tab,
          label: 'Runtime metrics',
          kind: 'live-read',
          source: `${configApiSource} metrics.*`,
          action: 'read-only counters and last turn telemetry',
          contracts: configReadContracts([
            'metrics.generation',
            'metrics.total_turns',
            'metrics.total_input_tokens',
            'metrics.total_output_tokens',
            'metrics.total_tokens',
            'metrics.total_cost_usd',
            'metrics.last_model_used',
            'metrics.last_input_tokens',
            'metrics.last_output_tokens',
            'metrics.last_total_tokens',
            'metrics.last_latency_ms',
            'metrics.last_total_tokens_per_sec',
            'metrics.last_output_tokens_per_sec',
          ]),
        },
      ]
  }
}

/** The control an operator has to change to clear a build failure. The panel
 *  renders the message under exactly this control; without it every message
 *  landed on the 컨텍스트 오버라이드 input, which was the only failure producer
 *  when the single error channel was written. */
export type RuntimePayloadControl =
  | 'max_context_override'
  | 'sandbox_profile'
  | 'remote_endpoint'

/** A failed build still reports `payload` — the edits the draft could express.
 *  It is never sent (both `saveRuntimeConfig` and {@link buildRuntimePayload}
 *  branch on `ok` first); it exists so the dirty markers and the save footer
 *  read one field in both outcomes instead of special-casing whichever control
 *  happens to be the failing one. */
export type RuntimePayloadBuildResult =
  | { ok: true; payload: KeeperConfigUpdatePayload }
  | { ok: false; control: RuntimePayloadControl; error: string; payload: KeeperConfigUpdatePayload }

export function buildRuntimePayloadResult(
  draft: RuntimeDraft,
  orig: KeeperConfig,
): RuntimePayloadBuildResult {
  const maxContextOverride = parseMaxContextOverrideDraft(draft.max_context_override)
  const profile = draft.sandbox_profile
  const endpointDraft = draft.remote_endpoint.trim()
  const endpointOrig = (orig.remote_endpoint ?? '').trim()

  const payload: KeeperConfigUpdatePayload = {}
  const newMentionTargets = listTextToStrings(draft.mention_targets_text)
  if (draft.runtime_id.trim() !== (orig.execution.selected_runtime_id ?? '').trim()) payload.runtime_id = draft.runtime_id.trim()
  if (draft.autoboot_enabled !== orig.autoboot_enabled) payload.autoboot_enabled = draft.autoboot_enabled
  if (maxContextOverride.ok && maxContextOverride.value !== orig.max_context_override) {
    payload.max_context_override = maxContextOverride.value
  }
  if (!sameStringArray(newMentionTargets, orig.workspace.mention_targets)) payload.mention_targets = newMentionTargets
  if (profile !== null && profile !== toSandboxProfile(orig.sandbox_profile)) payload.sandbox_profile = profile
  if (draft.network_mode !== coerceNetworkMode(orig.network_mode)) payload.network_mode = draft.network_mode
  // null is an explicit detach. Leaving the field out instead carries the
  // keeper TOML's endpoint into the new profile, which the runtime refuses
  // with remote_endpoint_requires_remote_ssh.
  if (endpointDraft !== endpointOrig) {
    payload.remote_endpoint = endpointDraft === '' ? null : endpointDraft
  }
  if (draft.proactive_enabled !== proactiveConfigValue(orig)) payload.proactive_enabled = draft.proactive_enabled
  if (draft.skill_selection.mode === 'all') {
    if (orig.skills.names !== null) payload.skills = {}
  } else {
    const names = listTextToStrings(draft.skill_selection.names_text)
    if (orig.skills.names === null || !sameStringArray(names, orig.skills.names)) {
      payload.skills = { names }
    }
  }

  if (!maxContextOverride.ok) {
    return { ok: false, control: 'max_context_override', error: maxContextOverride.error, payload }
  }
  if (profile === null) {
    return {
      ok: false,
      control: 'sandbox_profile',
      error: '샌드박스 프로필을 읽지 못했습니다. 새로 고친 뒤 다시 선택해 주세요.',
      payload,
    }
  }
  if (profile === 'remote_ssh' && endpointDraft === '') {
    return {
      ok: false,
      control: 'remote_endpoint',
      error:
        'remote_ssh 는 remote_endpoint 가 있어야 합니다. runtime.toml 의 [exec.ssh.endpoints.<이름>] 에 등록된 이름을 넣어 주세요.',
      payload,
    }
  }
  // Keeper_turn_up_args.parse refuses the whole update with
  // remote_endpoint_requires_remote_ssh when a non-remote_ssh profile still
  // carries an endpoint — including an update that only flips autoboot. The
  // endpoint has to be cleared first, so the panel says so instead of sending
  // a request the runtime is certain to reject.
  if (profile !== 'remote_ssh' && endpointDraft !== '') {
    return {
      ok: false,
      control: 'remote_endpoint',
      error: `remote_endpoint 는 remote_ssh 에서만 쓸 수 있습니다. ${profile} 로 저장하려면 먼저 비워 주세요.`,
      payload,
    }
  }
  return { ok: true, payload }
}

export function buildRuntimePayload(draft: RuntimeDraft, orig: KeeperConfig): KeeperConfigUpdatePayload {
  const result = buildRuntimePayloadResult(draft, orig)
  if (!result.ok) throw new RangeError(result.error)
  return result.payload
}

function updateRuntimeDraft(field: keyof RuntimeDraft, value: boolean | number | string) {
  const state = runtimeDraft.value
  if (!state) return
  const next = { ...state.draft, [field]: value } as RuntimeDraft
  // 'none' belongs to the guest profiles. Testing against 'docker' alone put
  // a microvm keeper back on 'inherit', which container cannot honour at all:
  // it has no host network, so the keeper would have been saved with a mode
  // its own backend refuses.
  const isGuest = next.sandbox_profile === 'docker' || next.sandbox_profile === 'microvm'
  if ((field === 'sandbox_profile' || field === 'network_mode') && !isGuest && next.network_mode === 'none') {
    next.network_mode = 'inherit'
  }
  // The endpoint names an [exec.ssh.endpoints.<name>] entry only the SSH
  // dispatch reads. Carrying it into another profile is refused at config load
  // (remote_endpoint_requires_remote_ssh), so switching away clears it here and
  // the payload sends null rather than leaving the field out.
  if (field === 'sandbox_profile' && next.sandbox_profile !== 'remote_ssh') {
    next.remote_endpoint = ''
  }
  runtimeDraft.value = { ...state, draft: next }
}

function updateSkillSelectionMode(mode: 'all' | 'names') {
  const state = runtimeDraft.value
  if (!state) return
  const selection = state.draft.skill_selection
  runtimeDraft.value = {
    ...state,
    draft: {
      ...state.draft,
      skill_selection: mode === 'all'
        ? {
            mode: 'all',
            prior_names_text: selection.mode === 'names'
              ? selection.names_text
              : selection.prior_names_text,
          }
        : {
            mode: 'names',
            names_text: selection.mode === 'names'
              ? selection.names_text
              : selection.prior_names_text,
          },
    },
  }
}

function updateSkillNames(namesText: string) {
  const state = runtimeDraft.value
  if (!state || state.draft.skill_selection.mode !== 'names') return
  runtimeDraft.value = {
    ...state,
    draft: {
      ...state.draft,
      skill_selection: { mode: 'names', names_text: namesText },
    },
  }
}

function sameStringArray(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) return false
  return a.every((value, index) => value === b[index])
}

function listTextToStrings(text: string): string[] {
  return dedupeStrings(text.split('\n'))
}

function computeRuntimeDirtyFlags(rd: RuntimeDraft, c: KeeperConfig): Record<string, boolean> {
  const result = buildRuntimePayloadResult(rd, c)
  // The payload carries every expressible edit whether or not the build
  // succeeded, so a control blocked by another control's error still shows its
  // dirty marker.
  const payload = result.payload
  return {
    runtime_id: 'runtime_id' in payload,
    autoboot_enabled: 'autoboot_enabled' in payload,
    // An unparseable draft ('abc') cannot reach the payload at all, so its
    // marker falls back to comparing the raw text.
    max_context_override:
      'max_context_override' in payload
      || rd.max_context_override !== String(c.max_context_override ?? 0),
    mention_targets: 'mention_targets' in payload,
    sandbox_profile: 'sandbox_profile' in payload,
    network_mode: 'network_mode' in payload,
    remote_endpoint: 'remote_endpoint' in payload,
    proactive_enabled: 'proactive_enabled' in payload,
    skills: 'skills' in payload,
  }
}

function dedupeStrings(values: readonly string[]): string[] {
  const seen = new Set<string>()
  const next: string[] = []
  for (const raw of values) {
    const value = raw.trim()
    if (!value || seen.has(value)) continue
    seen.add(value)
    next.push(value)
  }
  return next
}

function runtimeCatalogRuntimeKey(entry: DashboardRuntimeProviderSnapshot): string {
  return entry.runtime_id?.trim() || entry.provider.trim()
}

function runtimeCatalogProviderLabel(entry: DashboardRuntimeProviderSnapshot): string {
  return entry.provider_display_name ?? entry.provider_id ?? entry.provider
}

function runtimeCatalogModelLabel(entry: DashboardRuntimeProviderSnapshot): string {
  return entry.model_api_name ?? entry.model_id ?? entry.models[0] ?? MISSING_DATA_DASH
}

function selectedRuntimeCatalogEntry(
  state: AsyncState<DashboardRuntimeProviderSnapshot[]>,
  runtimeId: string,
): DashboardRuntimeProviderSnapshot | null {
  if (state.status !== 'loaded') return null
  return findRuntimeCatalogEntry(state.data, runtimeId)
}

function runtimeCatalogStateRows(
  state: AsyncState<DashboardRuntimeProviderSnapshot[]>,
  runtimeId: string,
  entry: DashboardRuntimeProviderSnapshot | null,
): readonly KcfFactRow[] {
  if (state.status === 'idle' || state.status === 'loading') {
    return [['catalog 상태', state.status]]
  }
  if (state.status === 'error') {
    return [
      ['catalog 상태', 'error'],
      ['catalog error', state.message, true],
    ]
  }
  if (runtimeId.trim() !== '' && !entry) {
    return [
      ['catalog 상태', 'runtime 미수집'],
      ['선택 runtime', runtimeId, true],
      ['catalog entries', String(state.data.length)],
    ]
  }
  return []
}

function runtimeCatalogSpecRows(entry: DashboardRuntimeProviderSnapshot): readonly KcfFactRow[] {
  return [
    ['runtime catalog', runtimeCatalogRuntimeKey(entry), true],
    ['provider', runtimeCatalogProviderLabel(entry)],
    ['model', runtimeCatalogModelLabel(entry), true],
    ['snapshot', runtimeCatalogSnapshotFacts(entry), true],
    ['effective', runtimeCatalogEffectiveCapabilities(entry), true],
    ['request', runtimeCatalogRequestConfig(entry), true],
    ['declared', runtimeCatalogDeclaredSpec(entry), true],
    ['policy', runtimeCatalogParameterPolicy(entry), true],
  ]
}

type KcfFactRow = readonly [key: string, value: string | number | null | undefined, mono?: boolean]

function KcfSec({
  title,
  desc,
  right,
  children,
}: {
  title: string
  desc?: string
  right?: unknown
  children: unknown
}) {
  return html`
    <section class="kcf-sec">
      <div class="kcf-sec-h">
        <h3>${title}</h3>
        ${right ?? null}
      </div>
      ${desc ? html`<p class="kcf-sec-desc">${desc}</p>` : null}
      <div class="kcf-sec-body">${children}</div>
    </section>
  `
}

// Read-only 2-column fact grid. Rows whose value is null/undefined/'' are
// dropped (matches the prototype, which hides empty facts rather than printing
// a dash). booleans render as ON/OFF text so the grid stays uniform.
function KcfFacts({ rows }: { rows: readonly KcfFactRow[] }) {
  const visible = rows.filter((r) => r[1] !== null && r[1] !== undefined && r[1] !== '')
  if (visible.length === 0) return null
  return html`
    <div class="kcf-facts">
      ${visible.map(([k, v, mono], i) => html`
        <div key=${i} class="kcf-fact">
          <span class="kcf-fact-k">${k}</span>
          <span class=${`kcf-fact-v ${mono ? 'mono' : ''}`}>${v}</span>
        </div>
      `)}
    </div>
  `
}

function keeperConfigControlKindLabel(kind: KeeperConfigControlKind): string {
  if (kind === 'live-write') return 'live write'
  if (kind === 'live-read') return 'live read'
  if (kind === 'browser-local') return 'browser local'
  return 'unsupported'
}

function keeperConfigControlEvidenceLabel(evidence: KeeperConfigControlEvidence): string {
  if (evidence.kind === 'keeper-config-field') return `config:${evidence.path}`
  if (evidence.kind === 'browser-state') return `local:${evidence.key}`
  if (evidence.kind === 'unsupported') return `unsupported:${evidence.reason}`
  return evidence.operation
    ? `${evidence.method} ${evidence.endpoint}#${evidence.operation}`
    : `${evidence.method} ${evidence.endpoint}`
}

function keeperConfigControlEvidenceLabels(
  contracts: readonly KeeperConfigControlEvidence[],
): string {
  return contracts.map(keeperConfigControlEvidenceLabel).join(' | ')
}

function keeperConfigControlEndpointShortLabel(endpoint: KeeperConfigControlEndpoint): string {
  if (endpoint === KEEPER_CONFIG_API) return 'config'
  if (endpoint === KEEPER_DIRECTIVE_API) return 'directive'
  if (endpoint === DASHBOARD_GOALS_API) return 'goals'
  return 'providers'
}

function keeperConfigControlEvidenceSummary(
  contracts: readonly KeeperConfigControlEvidence[],
  contractStatus: KeeperConfigControlContractStatus = { kind: 'ok', missingConfigFields: [] },
): string {
  const apiLabels = contracts
    .filter((contract): contract is Extract<KeeperConfigControlEvidence, { kind: 'api' }> => contract.kind === 'api')
    .map(contract => {
      const endpoint = keeperConfigControlEndpointShortLabel(contract.endpoint)
      return contract.operation
        ? `${contract.method} ${endpoint}#${contract.operation}`
        : `${contract.method} ${endpoint}`
    })
  const fieldCount = contracts.filter(contract => contract.kind === 'keeper-config-field').length
  const localLabels = contracts
    .filter((contract): contract is Extract<KeeperConfigControlEvidence, { kind: 'browser-state' }> => contract.kind === 'browser-state')
    .map(contract => `local:${contract.key}`)
  const unsupported = contracts.some(contract => contract.kind === 'unsupported')
  return [
    ...apiLabels,
    fieldCount > 0 ? `${fieldCount} config field${fieldCount === 1 ? '' : 's'}` : null,
    ...localLabels,
    unsupported ? 'unsupported reason' : null,
    contractStatus.kind === 'missing-config-field'
      ? `missing ${contractStatus.missingConfigFields.length} config field${contractStatus.missingConfigFields.length === 1 ? '' : 's'}`
      : null,
  ].filter((part): part is string => part !== null).join(' · ')
}

function KeeperConfigControlLedger({ tab, config }: { tab: KcfTabId; config: KeeperConfig }) {
  const items = keeperConfigControlInventory(tab, config)
  if (items.length === 0) return null
  return html`
    <section class="kcf-control-ledger" data-testid="keeper-config-control-ledger">
      <div class="kcf-control-ledger-h">
        <span>Control backing</span>
        <span class="mono" data-testid="keeper-config-control-ledger-count">${items.length}</span>
      </div>
      <div class="kcf-control-ledger-grid">
        ${items.map(item => {
          const contractStatus = keeperConfigControlContractStatus(item.contracts, config)
          const missingConfigFields = contractStatus.missingConfigFields.join(' | ')
          return html`
          <div
            key=${item.id}
            class=${`kcf-control-ledger-row ${item.kind} ${contractStatus.kind}`}
            data-testid="keeper-config-control-ledger-row"
            data-control-id=${item.id}
            data-control-kind=${item.kind}
            data-control-contract-status=${contractStatus.kind}
            data-control-contracts=${keeperConfigControlEvidenceLabels(item.contracts)}
            data-control-missing-config-fields=${missingConfigFields}
          >
            <span class="kcf-control-kind">${keeperConfigControlKindLabel(item.kind)}</span>
            <span class="kcf-control-label">${item.label}</span>
            <span class="kcf-control-source mono" title=${item.source}>${item.source}</span>
            <span class="kcf-control-action" title=${item.action}>${item.action}</span>
            <span
              class="kcf-control-contracts mono"
              title=${keeperConfigControlEvidenceLabels(item.contracts)}
            >
              ${keeperConfigControlEvidenceSummary(item.contracts, contractStatus)}
            </span>
          </div>
        `})}
      </div>
    </section>
  `
}

function KcfReadonlyText({ label, hint, text }: { label: string; hint?: string; text: string }) {
  const value = text && text.trim() !== '' ? text : MISSING_DATA_DASH
  return html`
    <div class="kcf-textfield">
      <div class="kcf-tf-h"><label>${label}</label>${hint ? html`<span class="kcf-tf-hint">${hint}</span>` : null}</div>
      <div class="kcf-text mono" style="white-space:pre-wrap; max-height:9rem; overflow-y:auto;">${value}</div>
    </div>
  `
}



// .set-* inline controls — keeper-v2 primitives (SetRow / Toggle / Segmented),
// styled by the vendored surfaces.css. Used for the editable boolean toggles and
// the bounded percentage gates so they read like the prototype. The numeric
// gates (token/message/cooldown/idle) stay as free number inputs — the
// prototype renders those as fixed presets or read-only, which would drop the
// live editor's arbitrary-value capability.
function SetRow({
  label,
  hint,
  dirty = false,
  children,
}: {
  label: string
  hint?: unknown
  dirty?: boolean
  children: unknown
}) {
  return html`
    <div class="set-row">
      <div class="set-row-l">
        <div class="set-label">${label}${dirty ? html`<span class="ml-2 text-2xs text-[var(--color-accent-fg)] font-semibold">●</span>` : null}</div>
        ${hint ? html`<div class="set-hint">${hint}</div>` : null}
      </div>
      <div class="set-row-c">${children}</div>
    </div>
  `
}

function SetToggle({ on, onChange, ariaLabel }: { on: boolean; onChange: (v: boolean) => void; ariaLabel: string }) {
  return html`
    <button
      type="button"
      class=${`set-toggle ${on ? 'on' : ''}`}
      role="switch"
      aria-checked=${on ? 'true' : 'false'}
      aria-label=${ariaLabel}
      onClick=${() => onChange(!on)}
    >
      <span class="knob"></span>
    </button>
  `
}

function ConfigRow({
  label,
  value,
  tone = 'neutral',
}: {
  label: string
  value: string
  tone?: 'neutral' | 'warn'
}) {
  const valueClass =
    tone === 'warn'
      ? 'text-sm font-semibold text-[var(--color-status-warn)]'
      : 'text-sm font-semibold text-text-strong'
  return html`
    <div class="flex items-center justify-between py-2.5 px-4 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-2 v2-monitoring-row">
      <span class="text-sm font-medium text-text-muted">${label}</span>
      <span class=${valueClass}>${value}</span>
    </div>
  `
}

/* What a Keeper without a network actually looks like from the inside, because
   the tools do not say it. `gh` cannot reach github.com to check a token, so it
   reports the token as invalid; a Keeper reads that literally and tells its
   owner to re-authenticate, which changes nothing. Seen on
   kidsnote-pr-jira-checker, 2026-09-03: a valid token, the right hosts.yml
   mounted into the guest, and three rounds of re-authentication. */
function NoNetworkCallout() {
  return html`
    <${Callout}
      title="이 Keeper 는 네트워크가 없습니다"
      body="게스트에서 나가는 연결이 전부 막힙니다. gh, curl, git 은 실패하고, gh 는 그 실패를 '토큰이 invalid' 로 보고합니다 — 자격증명이 멀쩡해도 그렇게 보입니다. 인증을 다시 하기 전에 이 값을 먼저 보세요. inherit 으로 바꾸면 sandbox 를 다시 만들어야 반영됩니다."
      tone="warn"
    />
  `
}

function BoolRow({ label, value }: { label: string; value: boolean }) {
  return html`
    <div class="flex items-center justify-between py-2.5 px-4 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] mb-2 v2-monitoring-row">
      <span class="text-sm text-[var(--color-fg-muted)]">${label}</span>
      <${BoolBadge} value=${value} />
    </div>
  `
}

function MajorSectionHeader({ title }: { title: string }) {
  return html`
    <div class="rounded-[var(--r-3)] border border-[var(--accent-20)] bg-[var(--accent-5)] px-4 py-3 mt-8 mb-4 flex items-center gap-2 shadow-[var(--shadow-1)] v2-monitoring-panel">
      <${StatusDot} size="sm" class="bg-[var(--accent-50)] shadow-[0_0_8px_rgb(var(--info-glow)/0.6)]" />
      <span class="text-xs font-bold uppercase tracking-[var(--track-caps)] text-accent-fg">${title}</span>
    </div>
  `
}

function Callout({
  title,
  body,
  tone = 'neutral',
}: {
  title: string
  body: string
  tone?: 'neutral' | 'warn'
}) {
  const toneClass =
    tone === 'warn'
      ? 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]'
      : 'border-card-border/60 bg-card/35 text-text-body'
  return html`
    <div class="rounded-[var(--r-1)] border px-3 py-3 shadow-[var(--shadow-1)] ${toneClass} v2-monitoring-panel">
      <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-text-muted mb-1">${title}</div>
      <div class="text-xs leading-relaxed">${body}</div>
    </div>
  `
}

function BoolBadge({ value }: { value: boolean }) {
  return value
    ? html`<span class="text-2xs font-bold px-2 py-0.5 rounded-[var(--r-1)] bg-ok/10 text-ok border border-ok/20 shadow-1 shadow-ok/5">ON</span>`
    : html`<span class="text-2xs font-bold px-2 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] text-text-dim border border-[var(--color-border-default)] shadow-1">OFF</span>`
}

function ModelList({ models }: { models: string[] }) {
  if (models.length === 0) return html`<span class="text-2xs text-text-muted italic">none</span>`
  return html`
    <div class="flex flex-wrap gap-1.5 v2-monitoring-row">
      ${models.map(m => html`<span class="inline-flex items-center py-1 px-2.5 rounded-[var(--r-1)] text-2xs font-semibold bg-[var(--accent-10)] text-accent-fg border border-[var(--accent-20)] shadow-1 hover:bg-[var(--accent-20)] transition-colors cursor-default">${m}</span>`)}
    </div>
  `
}

function RuntimeList({ runtimes }: { runtimes: string[] }) {
  if (runtimes.length === 0) return html`<span class="text-2xs text-text-muted italic">none</span>`
  return html`
    <div class="flex flex-wrap gap-1.5 v2-monitoring-row">
      ${runtimes.map((_runtime, index) => html`<span class="inline-flex items-center py-1 px-2.5 rounded-[var(--r-1)] text-2xs font-semibold bg-[var(--accent-10)] text-accent-fg border border-[var(--accent-20)] shadow-1 hover:bg-[var(--accent-20)] transition-colors cursor-default">runtime ${index + 1}</span>`)}
    </div>
  `
}

function LongText({ text, truncateAt = 200 }: { text: string; truncateAt?: number | null }) {
  if (!text || text.trim() === '') return html`<span class="text-2xs text-text-muted italic">--</span>`
  const truncated =
    truncateAt !== null && truncateAt >= 0 && text.length > truncateAt
      ? text.slice(0, truncateAt) + '...'
      : text
  return html`<div class="text-xs text-text-body whitespace-pre-wrap max-h-35 overflow-y-auto custom-scrollbar border border-card-border bg-card/40 backdrop-blur-sm p-3 rounded-[var(--r-1)] mt-1.5 leading-relaxed shadow-inset hover:bg-card/60 transition-colors v2-monitoring-panel">${truncated}</div>`
}


function PromptSourceBadge({ source }: { source: string }) {
  const tone =
    source === 'override'
      ? 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]'
      : source === 'file'
        ? 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]'
        : 'bg-[var(--color-bg-elevated)] text-text-dim border-[var(--color-border-default)]'
  return html`<span class="text-3xs font-bold px-2 py-0.5 rounded-[var(--r-1)] border ${tone} shadow-1">${source.toUpperCase()}</span>`
}

function PromptBlock({
  title,
  block,
}: {
  title: string
  block: { key: string; source: string; text: string }
}) {
  return html`
    <div class="mt-2 v2-monitoring-panel">
      <${SectionHeader} size="xs" class="mb-1" right=${html`
        <div class="flex items-center gap-2">
          <span class="text-3xs text-text-dim">${block.key}</span>
          <${PromptSourceBadge} source=${block.source} />
        </div>
      `}>${title}</${SectionHeader}>
      <${LongText} text=${block.text} truncateAt=${null} />
    </div>
  `
}

function InlineContextOverrideRow({ value, onChange, error, dirty = false }: {
  value: string
  onChange: (value: string) => void
  error: string | null
  dirty?: boolean
}) {
  return html`
    <div class="kcf-inline-row py-2.5 px-4 rounded-[var(--r-1)] border ${dirty ? 'border-l-4 border-l-[var(--color-accent-fg)]' : ''} ${error ? 'border-[var(--color-status-err)]' : 'border-card-border/50'} bg-card/20 mb-2 v2-monitoring-row">
      <div class="flex items-center justify-between">
        <span class="text-sm font-medium text-text-muted">컨텍스트 오버라이드${dirty ? html`<span class="ml-2 text-2xs text-[var(--color-accent-fg)] font-semibold">●</span>` : null}</span>
        <div class="kcf-inline-control flex items-center gap-2">
          <input
            type="text"
            inputMode="numeric"
            aria-label="컨텍스트 오버라이드"
            aria-invalid=${error ? 'true' : 'false'}
            class="w-24 text-right bg-card/60 text-text-strong text-sm font-semibold border ${error ? 'border-[var(--color-status-err)]' : 'border-card-border'} rounded-[var(--r-1)] py-1.5 px-2"
            value=${value}
            onInput=${(event: Event) => onChange((event.target as HTMLInputElement).value)}
          />
          <span class="text-xs text-text-dim w-5">tok</span>
        </div>
      </div>
      ${error ? html`<div class="mt-1 text-2xs text-[var(--color-status-err)]" role="alert">${error}</div>` : html`<div class="mt-1 text-2xs text-text-dim">양의 정수만 허용 (0 = 해제)</div>`}
    </div>
  `
}

/** The error line for a control that has no error slot of its own. Renders
 *  nothing for `null`, so a control without a failure carries no empty row. */
function InlineControlError(message: string | null) {
  if (message === null) return null
  return html`
    <div class="kcf-inline-error -mt-1 mb-2 px-4 text-2xs text-[var(--color-status-err)]" role="alert">${message}</div>
  `
}

/** A labelled `<select>` over a closed option list.
 *
 *  When `value` is not one of `options`, a disabled placeholder option carrying
 *  that value is rendered first and stays selected. Without it the browser
 *  selects index 0, so a keeper whose sandbox_profile could not be read was
 *  displayed as 'docker' — and 'docker' was then unpickable, because selecting
 *  the option already showing fires no change event and the draft stayed null.
 *  The placeholder is disabled because "not read" is not a state the operator
 *  can choose; it is a state they have to leave. */
export function InlineSelectRow({
  label,
  value,
  options,
  placeholder,
  onChange,
  dirty = false,
  tone = 'neutral',
}: {
  label: string
  value: string
  options: readonly string[]
  placeholder?: string
  onChange: (v: string) => void
  dirty?: boolean
  tone?: 'neutral' | 'warn'
}) {
  const valueIsListed = options.includes(value)
  const controlClass =
    tone === 'warn'
      ? 'kcf-inline-control text-sm bg-[var(--warn-10)] border border-[var(--warn-20)] rounded-[var(--r-1)] px-3 py-1.5 text-[var(--color-status-warn)] font-semibold'
      : 'kcf-inline-control text-sm bg-card/60 border border-card-border rounded-[var(--r-1)] px-3 py-1.5 text-text-strong'
  return html`
    <div class="kcf-inline-row flex items-center justify-between py-2.5 px-4 rounded-[var(--r-4)] border ${dirty ? 'border-l-4 border-l-[var(--color-accent-fg)] border-card-border/50' : 'border-card-border/50'} bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-2 gap-3 v2-monitoring-row">
      <span class="text-sm font-medium text-text-muted">${label}${dirty ? html`<span class="ml-2 text-2xs text-[var(--color-accent-fg)] font-semibold">●</span>` : null}</span>
      <select
        aria-label=${label}
        class=${controlClass}
        value=${value}
        onChange=${(e: Event) => onChange((e.target as HTMLSelectElement).value)}
      >
        ${valueIsListed
          ? null
          : html`<option value=${value} disabled>${placeholder ?? '(고르지 않음)'}</option>`}
        ${options.map(option => html`<option value=${option}>${option}</option>`)}
      </select>
    </div>
  `
}

export function InlineTextRow({
  label,
  value,
  placeholder,
  hint,
  onChange,
  dirty = false,
}: {
  label: string
  value: string
  placeholder?: string
  hint?: string
  onChange: (v: string) => void
  dirty?: boolean
}) {
  return html`
    <div class="kcf-inline-row py-2.5 px-4 rounded-[var(--r-4)] border ${dirty ? 'border-l-4 border-l-[var(--color-accent-fg)] border-card-border/50' : 'border-card-border/50'} bg-card/20 mb-2 v2-monitoring-row">
      <div class="flex items-center justify-between gap-3">
        <span class="text-sm font-medium text-text-muted">${label}${dirty ? html`<span class="ml-2 text-2xs text-[var(--color-accent-fg)] font-semibold">●</span>` : null}</span>
        <input
          type="text"
          aria-label=${label}
          placeholder=${placeholder ?? ''}
          class="kcf-inline-control w-48 text-sm bg-card/60 border border-card-border rounded-[var(--r-1)] px-3 py-1.5 text-text-strong"
          value=${value}
          onInput=${(event: Event) => onChange((event.target as HTMLInputElement).value)}
        />
      </div>
      ${hint ? html`<div class="mt-1 text-2xs text-text-dim">${hint}</div>` : null}
    </div>
  `
}

// ── Edit field components ────────────────────────────────

function updateDraft(field: keyof EditDraft, value: string) {
  const d = editDraft.value
  if (!d) return
  editDraft.value = { ...d, [field]: value }
}

function EditTextarea({ field, label, rows = 6 }: { field: keyof EditDraft; label: string; rows?: number }) {
  const d = editDraft.value
  if (!d) return null
  const val = d[field] as string
  const orig = configState.value.status === 'loaded' ? configState.value.data.prompt[field] : val
  const dirty = val.trim() !== (orig as string).trim()
  return html`
    <div class="mt-3 v2-monitoring-panel">
      <div class="flex items-center gap-2 mb-1.5">
        <span class="text-2xs font-semibold uppercase tracking-wider text-text-muted">${label}</span>
        ${dirty ? html`<span class="text-2xs text-[var(--color-accent-fg)] font-semibold">● 수정됨</span>` : null}
      </div>
      <${ExpandableTextarea}
        label=${label}
        value=${val}
        rows=${rows}
        dirty=${dirty}
        onChange=${(value: string) => updateDraft(field, value)}
      />
    </div>
  `
}

function runtimeSelectionSummary(c: KeeperConfig): string {
  const selected = c.execution.selected_runtime_id || MISSING_DATA_DASH
  const canonical = c.execution.selected_runtime_canonical || selected
  const selectionPart = '선택은 runtime.toml [runtime.assignments] 에서 관리됩니다.'
  const canonicalPart =
    canonical !== '' && canonical !== selected
      ? ` 현재 값 ${selected} 는 runtime에서 ${canonical} 으로 정규화됩니다.`
      : ''
  return `이 keeper는 runtime profile ${selected} 를 사용합니다. ${selectionPart}${canonicalPart}`
}

function recordValue(value: unknown): Record<string, unknown> | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function stringValue(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value : null
}

function stringField(record: Record<string, unknown> | null | undefined, key: string): string | null {
  return record ? stringValue(record[key]) : null
}

function runtimeTrustHealthRows(c: KeeperConfig): Array<[string, string, boolean?]> {
  const trust = c.runtime_trust
  if (!trust) {
    return [
      ['실행 주의', '데이터 없음', true],
      ['실행 판정', MISSING_DATA_DASH, true],
      ['완료 계약', MISSING_DATA_DASH, true],
    ]
  }

  const trustRecord = recordValue(trust)
  const execution = recordValue(trust.execution)
  const latestReceipt = recordValue(trustRecord?.latest_receipt)
  const disposition = trust.disposition ?? MISSING_DATA_DASH
  const reason = trust.attention_reason ?? trust.disposition_reason ?? MISSING_DATA_DASH
  const completionContract =
    stringField(execution, 'completion_contract_result')
    ?? stringField(latestReceipt, 'completion_contract_result')
    ?? MISSING_DATA_DASH
  const receiptTask =
    stringField(latestReceipt, 'current_task_id')
    ?? stringField(trustRecord, 'current_task_id')
    ?? '없음'
  const latestReceiptAt =
    stringField(execution, 'latest_receipt_at')
    ?? stringField(latestReceipt, 'recorded_at')
    ?? MISSING_DATA_DASH

  return [
    ['실행 주의', trust.needs_attention ? `ON · ${reason}` : 'OFF'],
    ['실행 판정', disposition, true],
    ['완료 계약', completionContract, true],
    ['작업 scope', receiptTask, true],
    ['최근 receipt', latestReceiptAt, true],
  ]
}

// ── Main component ───────────────────────────────────────

export function KeeperConfigPanel({ keeperName, onClose }: { keeperName: string; onClose?: () => void }) {
  const state = configState.value
  const panelEpoch = useRef(Symbol('keeper-config-panel'))
  const panelOwner: KeeperConfigPanelOwner = {
    keeperName,
    epoch: panelEpoch.current,
  }
  activeKeeperConfigOwner.value = panelOwner

  useEffect(() => retainKeeperConfigPanelSubscriptions(), [])

  // Trigger load on first render or name change
  if (configKeeperName.value !== keeperName || state.status === 'idle') {
    void loadKeeperConfig(keeperName)
  }
  if (runtimeCatalogState.value.status === 'idle') {
    loadRuntimeCatalog()
  }

  // Loading / error states render inside the same .kcf-overlay frame so the
  // modal does not pop in only after the config resolves (the panel is mounted
  // modal-only; onClose is supplied in production).
  const inModalShell = (inner: unknown) => html`
    <div
      class="kcf-overlay"
      role="dialog"
      aria-modal="true"
      aria-label=${`${keeperName} keeper 설정`}
      data-testid="kw-config-overlay"
      onClick=${onClose ?? (() => {})}
    >
      <div class="kcf v2-monitoring-surface" onClick=${(event: Event) => event.stopPropagation()}>
        <div class="kcf-top">
          <${KeeperBadge} id=${keeperName} name=${keeperName} variant="sigil" size="lg" />
          <div class="kcf-top-id"><div class="kcf-top-name">${keeperName}</div></div>
          <div class="kcf-top-spacer"></div>
          ${onClose ? html`<button type="button" class="kcf-top-x" onClick=${onClose} data-testid="kw-config-close" title="닫기 (Esc)">✕</button>` : null}
        </div>
        <div class="kcf-main v2-monitoring-panel">${inner}</div>
      </div>
    </div>
  `

  if (state.status === 'loading') {
    return inModalShell(html`<${LoadingState}>설정 불러오는 중...<//>`)
  }

  if (state.status === 'error') {
    return inModalShell(html`<${ErrorState} message=${state.message} />`)
  }

  if (state.status !== 'loaded') return null

  const c = state.data
  const isEditing = editMode.value
  const isSaving = saving.value
  // Fleet-roster row for this keeper: carries the live fields the config API
  // does not project (koreanName, sandbox_target, created_at) — the top bar
  // and the identity tab's 파생 사실 section read from it.
  const keeperRow = keepers.value.find(k => k.name === keeperName) ?? null
  const keeperKoreanName = keeperRow?.koreanName?.trim() || null
  const keeperSandboxTarget = keeperRow?.sandbox_target?.trim() || null
  const keeperCreatedAt = keeperRow?.created_at?.trim() || null
  const runtimeWriteUnsupportedReason = keeperRuntimeConfigWriteUnsupportedReason(c)
  const runtimeCanEdit = runtimeWriteUnsupportedReason === null

  // Initialize runtime draft if not yet set
  if (runtimeDraft.value?.keeperName !== keeperName && c.name === keeperName) {
    runtimeDraft.value = {
      keeperName,
      draft: initRuntimeDraftFromConfig(c),
    }
  }
  const rd = runtimeDraft.value?.keeperName === keeperName
    ? runtimeDraft.value.draft
    : null
  const dirtyFlags = rd ? computeRuntimeDirtyFlags(rd, c) : {}
  const runtimePayloadResult = rd ? buildRuntimePayloadResult(rd, c) : null
  const runtimeValidationError = runtimePayloadResult && !runtimePayloadResult.ok
    ? runtimePayloadResult.error
    : null
  // The message belongs under the control that has to change. Every other
  // control renders no error, so a valid field never carries someone else's.
  const runtimeErrorFor = (control: RuntimePayloadControl): string | null =>
    runtimePayloadResult && !runtimePayloadResult.ok && runtimePayloadResult.control === control
      ? runtimePayloadResult.error
      : null
  // A failed build has no payload to size, so the footer keys on whether the
  // operator has edited anything at all. Keying it on max_context_override
  // alone hid the footer for the sandbox and endpoint failures.
  const runtimeHasChanges = runtimeCanEdit && rd && runtimePayloadResult
    ? runtimePayloadResult.ok
      ? Object.keys(runtimePayloadResult.payload).length > 0
      : Object.values(dirtyFlags).some(flag => flag === true)
    : false
  const runtimeOptions = rd
    ? dedupeStrings([
        rd.runtime_id,
        c.execution.selected_runtime_id ?? '',
        c.execution.selected_runtime_canonical ?? '',
        ...(c.execution.runtime_options ?? []),
      ])
    : []
  const runtimeCatalog = runtimeCatalogState.value
  const selectedRuntimeId = rd?.runtime_id || (c.execution.selected_runtime_id ?? '')
  const selectedRuntimeCatalog = selectedRuntimeCatalogEntry(runtimeCatalog, selectedRuntimeId)
  const selectedRuntimeCatalogRows = selectedRuntimeCatalog
    ? runtimeCatalogSpecRows(selectedRuntimeCatalog)
    : runtimeCatalogStateRows(runtimeCatalog, selectedRuntimeId, selectedRuntimeCatalog)
  const runtimeWriteUnsupportedNotice = runtimeWriteUnsupportedReason ? html`
    <div data-testid="keeper-runtime-write-unsupported" class="mb-3">
      <${Callout}
        title="런타임 설정 읽기 전용"
        body=${`${runtimeWriteUnsupportedReason} runtime.toml [runtime.assignments]와 keeper manifest 출처가 확인되면 이 패널의 runtime 설정 쓰기가 활성화됩니다.`}
      />
    </div>
  ` : null

  async function saveRuntimeConfig() {
    if (!rd || !runtimeCanEdit) return
    const result = buildRuntimePayloadResult(rd, c)
    if (!result.ok) {
      showToast(result.error, 'error')
      return
    }
    const payload = result.payload
    if (Object.keys(payload).length === 0) return
    if ('state' in c.config_revision) {
      // The server could not read the revision; posting the unavailable
      // marker as a CAS expected value can only fail later with a worse
      // message, so surface the server's own detail here instead.
      showToast(`설정 버전을 읽지 못해 저장할 수 없어요: ${c.config_revision.detail}`, 'error')
      return
    }
    const saveRequest: KeeperConfigSaveRequest = {
      owner: panelOwner,
      request: Symbol('keeper-config-save'),
    }
    runtimeSaveRequest.value = saveRequest
    runtimeSaving.value = true
    try {
      const updated = await patchKeeperConfig(keeperName, payload, c.config_revision)
      const activeOwner = activeKeeperConfigOwner.value
      if (
        activeOwner?.keeperName !== saveRequest.owner.keeperName
        || activeOwner.epoch !== saveRequest.owner.epoch
      ) return
      applyKeeperConfigUpdate(keeperName, updated)
      void refreshKeeperSurfacesAfterConfigSave()
      const durabilityWarning = configDurabilityWarningMessage(
        'Keeper 설정은',
        updated.config_write?.warnings ?? [],
      )
      if (durabilityWarning) {
        showToast(durabilityWarning, 'warning')
      } else {
        showToast('Keeper 설정 저장 완료', 'success')
      }
    } catch (err) {
      const activeOwner = activeKeeperConfigOwner.value
      if (
        activeOwner?.keeperName !== saveRequest.owner.keeperName
        || activeOwner.epoch !== saveRequest.owner.epoch
      ) return
      if (
        err instanceof ApiRequestError
        && err.errorCode === REVISION_CONFLICT_CODE
      ) {
        // The config the user saw is the closure [c]; capture the in-flight
        // draft before the reload subscription resets it from the fresh
        // config, then re-apply only the user's own edits on the fresh base.
        const staleDraft =
          runtimeDraft.value?.keeperName === keeperName
            ? runtimeDraft.value.draft
            : null
        const seenConfig = c
        await loadKeeperConfig(keeperName, { force: true })
        const freshState = configState.value
        if (staleDraft && freshState.status === 'loaded') {
          runtimeDraft.value = {
            keeperName,
            draft: rebaseRuntimeDraftOnFreshConfig(
              staleDraft,
              seenConfig,
              freshState.data,
            ),
          }
        }
        showToast(
          'Keeper 설정이 다른 화면에서 변경되어 최신 값을 불러왔습니다. 편집한 내용은 남겨뒀으니 확인 후 다시 저장해주세요',
          'warning',
        )
        return
      }
      if (keeperConfigFailureRequiresAuthoritativeReload(err)) {
        runtimeDraft.value = null
        await loadKeeperConfig(keeperName, { force: true })
        showToast('Keeper 설정 저장 결과를 확정할 수 없어 권위 설정을 다시 불러왔습니다', 'warning')
        return
      }
      const msg = err instanceof Error ? err.message : '저장 실패'
      showToast(msg, 'error')
    } finally {
      if (runtimeSaveRequest.value?.request === saveRequest.request) {
        runtimeSaveRequest.value = null
        runtimeSaving.value = false
      }
    }
  }

  async function runRuntimeDirective(action: 'pause' | 'resume' | 'wakeup') {
    runtimeDirectiveSaving.value = action
    try {
      const result =
        action === 'pause'
          ? await pauseKeeper(keeperName)
          : action === 'resume'
            ? await resumeKeeper(keeperName)
            : await wakeKeeper(keeperName)
      if (!result.ok) {
        throw new Error(result.error || `${action} directive failed`)
      }
      runtimeDraft.value = null
      await loadKeeperConfig(keeperName, { force: true })
      const label =
        action === 'pause' ? '일시정지' : action === 'resume' ? '재개' : '깨우기'
      showToast(`keeper ${label} 요청 완료`, 'success')
    } catch (err) {
      showToast(err instanceof Error ? err.message : 'directive 실패', 'error')
    } finally {
      runtimeDirectiveSaving.value = null
    }
  }

  function resetRuntimeDraft() {
    runtimeDraft.value = {
      keeperName,
      draft: initRuntimeDraftFromConfig(c),
    }
  }

  function enterEditMode() {
    editDraft.value = initDraftFromConfig(c)
    saveError.value = null
    editMode.value = true
  }

  function cancelEdit() {
    editMode.value = false
    editDraft.value = null
    saveError.value = null
  }

  async function saveConfig() {
    const draft = editDraft.value
    if (!draft) return
    const payload = buildPayload(draft, c)
    if (Object.keys(payload).length === 0) {
      showToast('변경사항이 없습니다', 'warning')
      cancelEdit()
      return
    }
    if ('state' in c.config_revision) {
      showToast(`설정 버전을 읽지 못해 저장할 수 없어요: ${c.config_revision.detail}`, 'error')
      return
    }
    const saveRequest: KeeperConfigSaveRequest = {
      owner: panelOwner,
      request: Symbol('keeper-prompt-config-save'),
    }
    promptSaveRequest.value = saveRequest
    saving.value = true
    saveError.value = null
    try {
      const updated = await patchKeeperConfig(keeperName, payload, c.config_revision)
      const activeOwner = activeKeeperConfigOwner.value
      if (
        activeOwner?.keeperName !== panelOwner.keeperName
        || activeOwner.epoch !== panelOwner.epoch
      ) return
      applyKeeperConfigUpdate(keeperName, updated)
      void refreshKeeperSurfacesAfterConfigSave()
      editMode.value = false
      editDraft.value = null
      lastSavedAt.value = new Date().toISOString()
      const durabilityWarning = configDurabilityWarningMessage(
        '프롬프트는',
        updated.config_write?.warnings ?? [],
      )
      if (durabilityWarning) {
        showToast(durabilityWarning, 'warning')
      } else {
        showToast('프롬프트 저장 완료', 'success')
      }
    } catch (err) {
      const activeOwner = activeKeeperConfigOwner.value
      if (
        activeOwner?.keeperName !== saveRequest.owner.keeperName
        || activeOwner.epoch !== saveRequest.owner.epoch
      ) return
      if (
        err instanceof ApiRequestError
        && err.errorCode === REVISION_CONFLICT_CODE
      ) {
        // Single-field draft: keep the user's text and stay in edit mode.
        // The next save diffs against the freshly loaded config, so only the
        // still-changed instructions field is sent with the fresh revision.
        await loadKeeperConfig(keeperName, { force: true })
        showToast(
          'Keeper 설정이 다른 화면에서 변경되어 최신 값을 불러왔습니다. 편집한 내용은 남겨뒀으니 확인 후 다시 저장해주세요',
          'warning',
        )
        return
      }
      if (keeperConfigFailureRequiresAuthoritativeReload(err)) {
        editMode.value = false
        editDraft.value = null
        await loadKeeperConfig(keeperName, { force: true })
        showToast('Keeper 설정 저장 결과를 확정할 수 없어 권위 설정을 다시 불러왔습니다', 'warning')
        return
      }
      saveError.value = err instanceof Error ? err.message : '저장 실패'
    } finally {
      if (promptSaveRequest.value?.request === saveRequest.request) {
        promptSaveRequest.value = null
        saving.value = false
      }
    }
  }

  // --- Toolbar ---
  const lastSavedText = lastSavedAt.value
    ? `마지막 저장: ${relativeTime(lastSavedAt.value)}`
    : null
  const toolbar = html`
    <div class="flex flex-wrap gap-2 items-center mb-3 v2-monitoring-toolbar">
      ${isEditing ? html`
        <button type="button"
          class="${BTN_FILLED_BASE} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)] v2-monitoring-action"
          onClick=${saveConfig}
          disabled=${isSaving}
        >${isSaving ? '저장 중...' : '저장'}</button>
        <button type="button"
          class="${BTN_FILLED_BASE} bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)] v2-monitoring-action"
          onClick=${cancelEdit}
          disabled=${isSaving}
        >취소</button>
      ` : html`
        <button type="button"
          class="${BTN_FILLED_BASE} bg-[var(--purple)] text-[var(--color-bg-0)] v2-monitoring-action"
          title="편집: 프롬프트 편집 모드로 진입합니다"
          onClick=${enterEditMode}
        >편집하기</button>
      `}
      ${lastSavedText && !isEditing
        ? html`<span class="text-2xs text-[var(--color-fg-muted)]">${lastSavedText}</span>`
        : null}
      ${saveError.value ? html`<span class="text-xs text-[var(--color-status-err)]" role="alert">${saveError.value}</span>` : null}
    </div>
  `

  // --- Prompt section (editable) ---
  const promptSection = isEditing ? html`
    <${MajorSectionHeader} title="프롬프트 (편집)" />
    <${EditTextarea} field="instructions" label="지시사항" rows=${10} />
  ` : html`
    <${MajorSectionHeader} title="프롬프트" />
    ${c.prompt.instructions ? html`
      <${SectionHeader} size="xs" class="mb-0.5">지시사항</${SectionHeader}>
      <${LongText} text=${c.prompt.instructions} />
    ` : null}
    <${SectionHeader} size="xs" class="mt-3 mb-0.5" right=${html`
      <button
        type="button"
        class="set-link text-2xs v2-monitoring-action"
        data-testid="kcf-prompt-global-edit-link"
        title="세계관·능력 등 전역 프롬프트 블록은 설정 › 프롬프트에서 관리합니다"
        onClick=${() => { navigate('settings', { section: 'prompts' }) }}
      >설정 › 프롬프트 열기 →</button>
    `}>시스템 프롬프트</${SectionHeader}>
    <div class="text-3xs text-text-dim mb-2">
      헌법·세계관·능력 블록은 <span class="font-mono">전역 프롬프트</span>입니다 (read-only) — 편집은 설정 › 프롬프트. 아래 지시사항은 이 keeper 고유값이며 목표 연결은 배정 목표 탭에서 관리합니다.
    </div>
    <div class="flex gap-2 mb-2 v2-monitoring-toolbar">
      <button
        type="button"
        class="text-2xs px-2 py-1 rounded-[var(--r-1)] border transition-colors ${promptPreviewTab.value === 'blocks' ? 'bg-[var(--accent-10)] border-[var(--accent-20)] text-accent-fg' : 'border-card-border text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-surface)]'} v2-monitoring-action"
        onClick=${() => { promptPreviewTab.value = 'blocks' }}
      >블록</button>
      <button
        type="button"
        class="text-2xs px-2 py-1 rounded-[var(--r-1)] border transition-colors ${promptPreviewTab.value === 'system' ? 'bg-[var(--accent-10)] border-[var(--accent-20)] text-accent-fg' : 'border-card-border text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-surface)]'} v2-monitoring-action"
        onClick=${() => { promptPreviewTab.value = 'system' }}
      >통합 시스템</button>
      <button
        type="button"
        class="text-2xs px-2 py-1 rounded-[var(--r-1)] border transition-colors ${promptPreviewTab.value === 'world' ? 'bg-[var(--accent-10)] border-[var(--accent-20)] text-accent-fg' : 'border-card-border text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-surface)]'} v2-monitoring-action"
        onClick=${() => { promptPreviewTab.value = 'world' }}
      >월드 상태</button>
    </div>
    ${promptPreviewTab.value === 'blocks'
      ? html`
          <${PromptBlock} title="공유 시스템" block=${c.prompt.system_prompt_blocks.system} />
        `
      : promptPreviewTab.value === 'system'
        ? html`<${LongText} text=${c.prompt.assembled_system_prompt || c.prompt.effective_system_prompt} truncateAt=${null} />`
        : html`<${LongText} text=${c.prompt.unified_user_message_preview} truncateAt=${null} />`}
  `

  const currentMentionTargets = rd
    ? listTextToStrings(rd.mention_targets_text)
    : c.workspace.mention_targets

  // ── Tab content (the live fields, regrouped under the 8 prototype tabs) ──
  // identity ◈ — avatar + owned attrs + derived facts + source provenance
  const identityTab = html`
    <${KcfSec} title="아바타" desc="이 keeper 의 얼굴 — 시길(슬롯 색 + 2글자 모노그램)은 keeper id 에서 결정론적으로 파생되어 목록·채팅·보드와 항상 일치합니다. 초상화·슬롯 색·시길 편집은 keeper avatar API 가 없어 기획 단계입니다.">
      <${KcfAvatarBlock} keeperName=${keeperName} displayName=${keeperKoreanName ?? keeperName} />
    </${KcfSec}>

    <${KcfSec} title="정체성" desc="이 keeper가 소유한 속성. 아래 파생 사실은 배정·파생된 값이라 여기서 바꾸지 않습니다.">
      <div class="kcf-idrow">
        <div class="kcf-field">
          <div class="kcf-tf-h">
            <label>표시 이름</label>
            <span class="kcf-tf-hint">목록·채팅·보드에 표시 · <${KcfPlan}>이름 변경</KcfPlan></span>
          </div>
          <input
            class="kcf-input"
            value=${keeperKoreanName ?? keeperName}
            readOnly
            aria-label="표시 이름"
            title="표시 이름 변경 API 미노출 — 기획 단계"
          />
        </div>
      </div>
    </${KcfSec}>

    <${KcfSec} title="파생 사실" desc="배정·파생된 사실 — 읽기 전용. 격리는 sandbox_profile 기준입니다.">
      <${KcfFacts} rows=${[
        ['sandbox', keeperSandboxTarget ? keeperSandboxTarget : '— 비활성', true],
        ['생성', keeperCreatedAt],
        ['runtime profile', c.execution.selected_runtime_id, true],
      ]} />
    </${KcfSec}>

    <${KcfSec} title="편집 가능 범위" desc="keeper 프롬프트 · live override · [runtime.assignments]">
      <${KcfFacts} rows=${[
        ['기본 소스', c.sources.default_source_kind],
        ['라이브 오버라이드', c.sources.has_live_override ? 'ON' : 'OFF'],
        ...(proactiveConfigProjection(c).kind === 'drift'
          ? [[
              '프로액티브 설정 드리프트',
              `TOML ${proactiveConfigValue(c) ? 'ON' : 'OFF'} / live meta ${c.proactive.enabled ? 'ON' : 'OFF'}`,
            ] as const]
          : []),
      ]} />
    </${KcfSec}>

    <${KcfSec} title="소스 · 경로" desc="읽기 전용">
      <${KcfReadonlyText} label="라이브 메타 경로" text=${c.sources.live_meta_path} />
      ${c.sources.default_manifest_path ? html`<${KcfReadonlyText} label="기본 매니페스트 경로" text=${c.sources.default_manifest_path} />` : null}
      <div style="margin-top:14px;">
        <div class="kcf-tf-h"><label>우선순위</label></div>
        <${ModelList} models=${c.sources.precedence} />
      </div>
      <div style="margin-top:10px;">
        <div class="kcf-tf-h"><label>오버라이드 필드</label></div>
        <${ModelList} models=${c.sources.override_fields} />
      </div>
    </${KcfSec}>

  `

  // prompt ¶ — edit toolbar + active goals + instructions + system prompt preview
  const promptTab = html`
    ${toolbar}
    ${promptSection}
  `

  // runtime ◷ — runtime selection + execution profile (read-only introspection + runtime_id picker)
  const runtimeTab = html`
    ${runtimeWriteUnsupportedNotice}
    <${KcfSec} title="Runtime 선택" desc=${runtimeSelectionSummary(c)}>
      ${rd && runtimeCanEdit ? html`
        <${InlineSelectRow}
          label="runtime_id"
          value=${rd.runtime_id}
          options=${runtimeOptions}
          onChange=${(value: string) => updateRuntimeDraft('runtime_id', value)}
          dirty=${dirtyFlags.runtime_id}
        />
      ` : html`
        <${KcfFacts} rows=${[['선택 runtime', c.execution.selected_runtime_id, true]]} />
      `}
      ${c.execution.selected_runtime_canonical
        && c.execution.selected_runtime_canonical !== c.execution.selected_runtime_id
        ? html`<${KcfFacts} rows=${[['정규화 runtime', c.execution.selected_runtime_canonical, true]]} />`
        : null}
    </${KcfSec}>

    ${selectedRuntimeCatalogRows.length > 0
      ? html`
        <${KcfSec} title="Runtime catalog spec" desc="Provider × Model 스펙 (읽기 전용)">
          <${KcfFacts} rows=${selectedRuntimeCatalogRows} />
        </${KcfSec}>
      `
      : null}

    <${KcfSec} title="실행" desc="읽기 전용 · fallback은 위에서부터 순서대로">
      <${KcfFacts} rows=${[
        ['활성 런타임', c.execution.active_model ? 'runtime' : null],
      ]} />
      ${rd && runtimeCanEdit ? html`
        <${InlineContextOverrideRow}
          value=${rd.max_context_override}
          onChange=${(value: string) => updateRuntimeDraft('max_context_override', value)}
          error=${runtimeErrorFor('max_context_override')}
          dirty=${dirtyFlags.max_context_override} />
      ` : html`
        <${ConfigRow} label="컨텍스트 오버라이드" value=${c.max_context_override != null ? formatTokens(c.max_context_override) : MISSING_DATA_DASH} />
      `}
      <div style="margin-top:14px;">
        <div class="kcf-tf-h"><label>런타임 후보</label></div>
        <${RuntimeList} runtimes=${c.execution.models} />
      </div>
    </${KcfSec}>

    ${c.execution.runtime_options.length > 1 ? html`
      <${KcfSec} title="fallback 후보" desc="runtime.toml [runtime.assignments] 에 등록된 이 keeper 의 런타임 후보 — 등록 순서대로 표시됩니다.">
        <div class="kcf-chain">
          ${c.execution.runtime_options.map(r => html`<span key=${r} class="kcf-chain-item mono">${r}</span>`)}
        </div>
      </${KcfSec}>
    ` : null}
  `

  // policy ⚖ — verify gate + proactive + tool policy
  const policyTab = html`
    ${runtimeWriteUnsupportedNotice}
    <${MajorSectionHeader} title="검증" />
    <${BoolRow} label="검증" value=${c.execution.verify} />
    <div class="kcf-dead">☠ 제거됨 · <span class="mono">Handoff_triggered</span> 이벤트와 자동 핸드오프 임계치는 소스에서 삭제됐습니다 — config 스키마에 handoff 설정 필드가 없습니다.</div>

    <${SectionHeader} title="프로액티브" />
    ${rd && runtimeCanEdit ? html`
      <${SetRow} label="자동 부팅" hint="서버 시작 시 keeper 등록" dirty=${dirtyFlags.autoboot_enabled}>
        <${SetToggle} ariaLabel="자동 부팅" on=${rd.autoboot_enabled}
          onChange=${(v: boolean) => updateRuntimeDraft('autoboot_enabled', v)} />
      </${SetRow}>
      <${SetRow} label="활성" hint=${proactiveConfigHint(c)} dirty=${dirtyFlags.proactive_enabled}>
        <${SetToggle} ariaLabel="프로액티브 활성" on=${rd.proactive_enabled}
          onChange=${(v: boolean) => updateRuntimeDraft('proactive_enabled', v)} />
      </${SetRow}>
    ` : html`
      <${BoolRow} label="자동 부팅" value=${c.autoboot_enabled} />
      <${BoolRow} label="활성" value=${proactiveConfigValue(c)} />
    `}

    <${KcfSec} title="Keeper Skills" desc="Keeper TOML의 [keeper.skills] 선택을 그대로 편집합니다. 이름 비교는 정확히 일치하며, 현재 카탈로그에 없는 이름도 저장 후 관측 화면에 남습니다.">
      ${rd && runtimeCanEdit ? html`
        <div class="kcf-field ${dirtyFlags.skills ? 'border-l-4 border-l-[var(--color-accent-fg)] pl-3' : ''}">
          <div class="kcf-tf-h">
            <label>Skill 선택</label>
            <span class="kcf-tf-hint">전체 또는 정확한 이름 목록</span>
          </div>
          <select
            class="kcf-input"
            aria-label="Skill 선택 방식"
            value=${rd.skill_selection.mode}
            onChange=${(event: Event) => updateSkillSelectionMode(
              (event.target as HTMLSelectElement).value === 'all' ? 'all' : 'names',
            )}
          >
            <option value="all">모든 공개 Skill</option>
            <option value="names">이름으로 선택</option>
          </select>
          ${rd.skill_selection.mode === 'names' ? html`
            <textarea
              class="kcf-text mono mt-2"
              aria-label="Skill 이름"
              rows=${4}
              value=${rd.skill_selection.names_text}
              placeholder="ocaml-coding"
              onInput=${(event: Event) => updateSkillNames(
                (event.target as HTMLTextAreaElement).value,
              )}
            ></textarea>
            <span class="kcf-tf-hint">한 줄에 하나 · 빈 목록은 어떤 Skill도 선택하지 않음</span>
          ` : null}
        </div>
      ` : html`
        <${ConfigRow}
          label="Skill 선택"
          value=${c.skills.names === null
            ? '모든 공개 Skill'
            : c.skills.names.length === 0
              ? '선택하지 않음'
              : c.skills.names.join(', ')}
        />
      `}
    </${KcfSec}>

  `

  // access ⚿ — sandbox / network + mention targets + bound namespaces
  const accessTab = html`
    ${runtimeWriteUnsupportedNotice}
    <${MajorSectionHeader} title="실행 범위 · 샌드박스" />
    ${rd && runtimeCanEdit ? html`
      <${InlineSelectRow}
        label="sandbox_profile"
        value=${rd.sandbox_profile ?? ''}
        options=${SANDBOX_PROFILE_OPTIONS}
        placeholder="(읽지 못함)"
        onChange=${(value: string) => updateRuntimeDraft('sandbox_profile', value as SandboxProfile)}
        dirty=${dirtyFlags.sandbox_profile}
      />
      ${InlineControlError(runtimeErrorFor('sandbox_profile'))}
      ${rd.sandbox_profile === null ? html`
        <${Callout}
          title="sandbox_profile 을 읽지 못했습니다"
          body=${`서버가 보낸 값은 ${c.sandbox_profile ?? '(없음)'} 입니다. ${SANDBOX_PROFILE_OPTIONS.join(', ')} 중 하나를 고르기 전에는 저장되지 않습니다.`}
          tone="warn"
        />
      ` : null}
      <!-- The row also has to appear for a keeper whose profile is not
           remote_ssh but whose TOML still carries an endpoint: the runtime
           refuses every save for that pairing, so hiding the field named in
           the refusal left the operator with nothing to change. The read-only
           branch below has always shown it on the same condition. -->
      ${rd.sandbox_profile === 'remote_ssh' || c.remote_endpoint ? html`
        <${InlineTextRow}
          label="remote_endpoint"
          value=${rd.remote_endpoint}
          placeholder="builder"
          hint="runtime.toml 의 [exec.ssh.endpoints.<이름>] 에 등록된 이름. 등록되지 않은 이름은 저장할 때 거절됩니다."
          onChange=${(value: string) => updateRuntimeDraft('remote_endpoint', value)}
          dirty=${dirtyFlags.remote_endpoint}
        />
        ${InlineControlError(runtimeErrorFor('remote_endpoint'))}
      ` : null}
      ${rd.sandbox_profile === 'remote_ssh' ? html`
        <${Callout}
          title="remote_ssh 는 원격 호스트에서 실행합니다"
          body="이 keeper 의 명령은 remote_endpoint 가 가리키는 호스트에서 돌아갑니다. 매번 버리는 게스트가 아니라 그 호스트의 계정을 그대로 씁니다. network_mode 는 inherit 하나만 받습니다 — none 으로 적은 TOML 은 설정을 읽는 단계에서 remote_ssh_no_network_mode 로 거절됩니다. docker 쪽 격리 설정은 이 프로필에 적용되지 않습니다."
          tone="warn"
        />
      ` : null}
      <${InlineSelectRow}
        label="network_mode"
        value=${rd.network_mode}
        options=${rd.sandbox_profile === 'docker' || rd.sandbox_profile === 'microvm'
          ? ['inherit', 'none'] as const
          : ['inherit'] as const}
        onChange=${(value: string) => updateRuntimeDraft('network_mode', value as SandboxNetworkMode)}
        dirty=${dirtyFlags.network_mode}
        tone=${rd.network_mode === 'none' ? 'warn' : 'neutral'}
      />
      ${rd.network_mode === 'none' ? html`<${NoNetworkCallout} />` : null}
      <div class="kcf-paths">
        <span class="kcf-path-eff mono">sandbox: ${(c.sandbox_roots ?? []).join(', ')}</span>
      </div>
      ${rd.sandbox_profile === 'docker' || rd.sandbox_profile === 'microvm' ? html`
        <${SetupGuideCard} connectorId="sandbox_hardened" />
      ` : null}
      ${rd.sandbox_profile === 'microvm' ? html`
        <${Callout}
          title="microvm 이미지는 따로 넣어야 합니다"
          body="microvm 은 container 저장소의 이미지를 씁니다. docker 에 빌드한 것으로는 실행되지 않고 실행 직전에 거절됩니다. network_mode = inherit 은 container 의 NAT 를 쓰며 외부로 나갑니다 — 다만 게스트 기본 DNS 가 응답하지 않아 nameserver 를 함께 넘깁니다(MASC_KEEPER_MICROVM_DNS, 기본 1.1.1.1). host 네트워크 자체는 container 에 없습니다."
          tone="warn"
        />
      ` : null}
    ` : html`
      <${ConfigRow} label="sandbox_profile" value=${c.sandbox_profile ?? '(미선언)'} />
      ${c.remote_endpoint ? html`<${ConfigRow} label="remote_endpoint" value=${c.remote_endpoint} />` : null}
      <${ConfigRow}
        label="network_mode"
        value=${c.network_mode ?? 'inherit'}
        tone=${(c.network_mode ?? 'inherit') === 'none' ? 'warn' : 'neutral'}
      />
      ${(c.network_mode ?? 'inherit') === 'none' ? html`<${NoNetworkCallout} />` : null}

      <${ConfigRow} label="sandbox_roots" value=${(c.sandbox_roots ?? []).join(', ')} />
    `}

    ${c.keeper_last_error ? html`
      <${Callout}
        title="샌드박스 오류"
        body=${c.keeper_last_error}
        tone="warn"
      />
    ` : null}

    <${SectionHeader} title="멘션 · 네임스페이스" />
    ${rd && runtimeCanEdit ? html`
      <div class="py-2.5 px-4 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] mb-2 ${dirtyFlags.mention_targets ? 'border-l-4 border-l-[var(--color-accent-fg)]' : ''} v2-monitoring-panel">
        <div class="flex items-center justify-between mb-2">
          <span class="text-sm text-[var(--color-fg-secondary)]">mention_targets</span>
          <span class="text-xs text-[var(--color-fg-muted)]">${currentMentionTargets.length}개</span>
        </div>
        <textarea aria-label="mention_targets" class="w-full text-sm font-mono bg-[var(--color-bg-hover)] border border-[var(--color-border-default)] rounded-[var(--r-1)] px-3 py-2 text-[var(--color-fg-secondary)] resize-y"
          rows=${3}
          value=${rd.mention_targets_text}
          placeholder="sangsu"
          onInput=${(e: Event) => updateRuntimeDraft('mention_targets_text', (e.target as HTMLTextAreaElement).value)}
        ></textarea>
      </div>
    ` : currentMentionTargets.length > 0 ? html`
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">멘션 대상</${SectionHeader}>
        <${ModelList} models=${currentMentionTargets} />
      </div>
    ` : null}
    <div class="mt-1.5">
      <${SectionHeader} size="xs" class="mb-1">참여 네임스페이스</${SectionHeader}>
      <${ModelList} models=${c.workspace.bound_workspace_ids} />
    </div>

    <${KeeperGithubIdentityPanel} keeperName=${keeperName} />

    <${KeeperIdentityPanel} keeperName=${keeperName} />

  `

  const hooksTab = c.hooks ? (() => {
    const allEntries: readonly HookSlotEntry[] = Object.entries(c.hooks.slots) as HookSlotEntry[]
    const activeCount = allEntries.filter(([, slot]) => slot.active).length
    const visibleEntries = filterHookSlots(allEntries, hookFilterQuery.value)
    const isFiltering = hookFilterQuery.value.trim() !== ''
    const expanded = globalArchExpanded.value
    return html`
      <button
        type="button"
        onClick=${() => { globalArchExpanded.value = !globalArchExpanded.value }}
        aria-expanded=${expanded}
        class="w-full text-left rounded-[var(--r-3)] border border-[var(--accent-20)] bg-[var(--accent-5)] px-4 py-3 mb-4 flex items-center gap-2 shadow-[var(--shadow-1)] v2-monitoring-panel"
      >
        <span class="text-2xs text-accent-fg w-3 shrink-0" aria-hidden="true">${expanded ? '▾' : '▸'}</span>
        <span class="text-xs font-bold uppercase tracking-[var(--track-caps)] text-accent-fg">전역 런타임 아키텍처</span>
        <span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)]">전역 · 읽기 전용</span>
        <div class="flex-1"></div>
        <span class="text-3xs text-text-muted">${activeCount}/${allEntries.length} 슬롯 활성</span>
      </button>
      ${expanded ? html`
        <p class="text-3xs text-text-muted mb-3 px-1 leading-relaxed">
          모든 keeper에 공통인 런타임 hook 합성입니다. keeper별로 다르지 않으며 이 화면에서 편집할 수 없습니다.
        </p>
        <div class="flex items-center justify-between gap-2 mb-2">
          <span class="text-3xs text-text-muted">${allEntries.length} slots</span>
          <input
            type="search"
            value=${hookFilterQuery.value}
            placeholder="슬롯 이름 / source / gate 필터"
            aria-label="훅 슬롯 필터"
            onInput=${(e: Event) => { hookFilterQuery.value = (e.target as HTMLInputElement).value }}
            class="min-w-40 max-w-65 flex-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs text-[var(--color-fg-secondary)] placeholder:text-[var(--color-fg-disabled)] focus:outline-none focus:border-[var(--color-accent-fg)]"
          />
        </div>
        ${isFiltering && visibleEntries.length === 0 && allEntries.length > 0
          ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${allEntries.length} slots)</div>`
          : html`
            <div class="kcf-hooks">
              <div class="kcf-hook-hd"><span>슬롯</span><span>source</span><span>gate · effect</span></div>
              ${visibleEntries.map(([name, slot]) => html`
                <div key=${name} class=${`kcf-hook ${slot.active ? '' : 'off'}`}>
                  <span class="kcf-hook-slot mono">${name}</span>
                  <span class=${`kcf-hook-src mono ${slot.active ? '' : 'na'}`}>${slot.source}</span>
                  <span class="kcf-hook-gate">
                    ${hookSlotDetails(slot).length > 0
                      ? html`<div class="flex flex-wrap gap-1">${hookSlotDetails(slot).map((d: string) => html`<span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] ${d.endsWith('_off') ? 'bg-[var(--color-bg-hover)] text-[var(--color-fg-disabled)]' : 'bg-[var(--accent-10)] text-[var(--color-accent-fg)] opacity-80'}">${d}</span>`)}</div>`
                      : (slot.active ? '—' : '비등록')}
                  </span>
                </div>
              `)}
            </div>
          `}
        <div style="margin-top:14px;">
          <${KcfFacts} rows=${[
            ['적용 범위', c.hooks.scope ?? MISSING_DATA_DASH, true],
            ['활성 슬롯 수', String(allEntries.filter(([, slot]) => slot.active).length), true],
          ]} />
        </div>
      ` : null}
      <div class="kc-inh-note">외부 효과 호출은 <button type="button" class="set-link" onClick=${() => navigate('approvals')}>Gate 큐</button>로 갑니다.</div>
    `
  })() : html`<div class="text-2xs text-[var(--color-fg-muted)] py-4">hook 정보가 없습니다.</div>`

  // health ◉ — runtime liveness / registry / fiber diagnostics
  const directiveBusy = runtimeDirectiveSaving.value !== null
  const healthTab = html`
    <${KcfSec} title="런타임 상태" desc="이 keeper의 라이브니스 · 등록 · 파이버 진단입니다.">
      <${KcfFacts} rows=${[
        ['일시정지', c.runtime.paused ? 'ON' : 'OFF'],
        ['자동 부팅 설정', c.autoboot_enabled ? 'ON' : 'OFF'],
        ['레지스트리 등록', c.runtime.registered ? 'ON' : 'OFF'],
        ['킵얼라이브 실행', c.runtime.keepalive_running ? 'ON' : 'OFF'],
        ['레지스트리 상태', c.runtime.registry_state, true],
        ['파이버 상태', c.runtime.fiber_health, true],
      ]} />
      <div class="mt-3">
        <${KcfFacts} rows=${runtimeTrustHealthRows(c)} />
      </div>
      <div class="flex flex-wrap gap-2 mt-3 v2-monitoring-toolbar">
        <button
          type="button"
          class="kcf-btn save v2-monitoring-action"
          onClick=${() => { void runRuntimeDirective('resume') }}
          disabled=${directiveBusy}
          aria-label="keeper 재개 또는 등록"
          title="재개: paused 상태를 해제하고 registry 누락 시 keeper를 다시 등록합니다"
        >${runtimeDirectiveSaving.value === 'resume' ? '재개 중...' : '재개·등록'}</button>
        <button
          type="button"
          class="kcf-btn ghost v2-monitoring-action"
          onClick=${() => { void runRuntimeDirective('wakeup') }}
          disabled=${directiveBusy || !c.runtime.keepalive_running}
          aria-label="keeper 깨우기"
          title="깨우기: 실행 중인 keepalive fiber에 즉시 wakeup directive를 보냅니다"
        >${runtimeDirectiveSaving.value === 'wakeup' ? '깨우는 중...' : '깨우기'}</button>
        <button
          type="button"
          class="kcf-btn ghost v2-monitoring-action"
          onClick=${() => { void runRuntimeDirective('pause') }}
          disabled=${directiveBusy || c.runtime.paused}
          aria-label="keeper 일시정지"
          title="일시정지: operator paused 상태를 저장하고 keepalive loop에 pause directive를 보냅니다"
        >${runtimeDirectiveSaving.value === 'pause' ? '일시정지 중...' : '일시정지'}</button>
      </div>
    </${KcfSec}>
  `

  const tabContent: Record<KcfTabId, unknown> = {
    identity: identityTab,
    prompt: promptTab,
    runtime: runtimeTab,
    policy: policyTab,
    access: accessTab,
    hooks: hooksTab,
    health: healthTab,
  }
  const activeTab = kcfTab.value
  const activeTabLabel = KCF_TABS.find((t) => t[0] === activeTab)?.[1] ?? ''
  // One token drives both the word and the dot.
  //
  // These were two independent ternaries with *opposite* precedence: the
  // label tested `paused` first, the dot tested `keepalive_running` first.
  // A keeper in the window where both are true — which is the normal state
  // right after a pause, since the directive is delivered to a still-running
  // keepalive loop (see the pause button's own title: "running → paused,
  // 현재 turn 은 정상 종료") — rendered the word `일시정지` next to a green
  // glowing dot.
  //
  // The words also came from a 4-value vocabulary local to this pill
  // (`실행` / `대기` / `오프라인`) that no other surface uses; they now come
  // from `PHASE_LABEL_KO`, so this pill agrees with the roster, the phase
  // badge and the agent detail header.
  const phaseToken = configPhaseToken(c.runtime)
  const phaseLabel = PHASE_LABEL_KO[phaseToken]
  const phaseDotColor = PHASE_DOT_COLOR[PHASE_TONE[phaseToken]]

  return html`
    <div
      class="kcf-overlay"
      role="dialog"
      aria-modal="true"
      aria-label=${`${keeperName} keeper 설정`}
      data-testid="kw-config-overlay"
      onClick=${onClose ?? (() => {})}
    >
      <div class="kcf v2-monitoring-surface" onClick=${(event: Event) => event.stopPropagation()}>
        <div class="kcf-top">
          <${KeeperBadge} id=${keeperName} name=${keeperName} variant="sigil" size="lg" />
          <div class="kcf-top-id">
            <div class="kcf-top-name">${keeperName}${keeperKoreanName ? html`<span class="kcf-top-kr">${keeperKoreanName}</span>` : null}</div>
            <div class="kcf-top-sub mono">${c.execution.selected_runtime_id || c.sources.default_source_kind || MISSING_DATA_DASH}</div>
          </div>
          <span class="kcf-top-phase">
            <span style=${`width:7px;height:7px;border-radius:50%;background:${phaseDotColor};display:inline-block;${phaseToken === 'running' ? 'box-shadow:0 0 6px ' + phaseDotColor + ';' : ''}`} aria-hidden="true"></span>
            ${phaseLabel}
          </span>
          ${keeperSandboxTarget ? html`
            <span class="kcf-top-sandbox" title="이 keeper 전용 작업 경로 (live field: sandbox_target) — local 은 worktree root, docker 는 container target 입니다">⬡ ${keeperSandboxTarget}</span>
          ` : null}
          <div class="kcf-top-spacer"></div>
          ${onClose ? html`
            <button type="button" class="kcf-top-x" onClick=${onClose} data-testid="kw-config-close" title="닫기 (Esc)">✕</button>
          ` : null}
        </div>

        <div class="kcf-body">
          <nav class="kcf-tabs" role="tablist" aria-label="keeper 설정 탭">
            ${KCF_TABS.map(([id, lbl, ic]) => html`
              <button
                type="button"
                role="tab"
                key=${id}
                aria-selected=${activeTab === id ? 'true' : 'false'}
                class=${`kcf-tab ${activeTab === id ? 'on' : ''}`}
                onClick=${() => { kcfTab.value = id }}
              >
                <span class="kcf-tab-ic" aria-hidden="true">${ic}</span>
                <span class="kcf-tab-lbl">${lbl}</span>
              </button>
            `)}
          </nav>

          <div class="kcf-main v2-monitoring-panel">
            <${KeeperConfigControlLedger} tab=${activeTab} config=${c} />
            ${tabContent[activeTab]}
          </div>
        </div>

        <div class="kcf-foot v2-monitoring-toolbar">
          <span class="kcf-foot-note mono">${activeTabLabel} · ${keeperName}</span>
          <div class="kcf-foot-spacer"></div>
          ${runtimeHasChanges ? html`
            <span class="text-xs font-semibold ${runtimeValidationError ? 'text-[var(--color-status-err)]' : 'text-accent-fg'} mr-1">
              ${runtimeValidationError ?? '변경된 Keeper 설정'}
            </span>
            <button type="button"
              class="kcf-btn ghost v2-monitoring-action"
              title="초기화: 변경한 Keeper 설정을 서버 값으로 되돌립니다"
              onClick=${resetRuntimeDraft}
            >초기화하기</button>
            <button type="button"
              class="kcf-btn save v2-monitoring-action"
              onClick=${saveRuntimeConfig}
              disabled=${runtimeSaving.value || runtimeValidationError !== null}
            >${runtimeSaving.value ? '저장 중...' : 'Keeper 설정 저장'}</button>
          ` : null}
          ${onClose ? html`
            <button type="button" class="kcf-btn ghost v2-monitoring-action" onClick=${onClose}>닫기</button>
          ` : null}
        </div>
      </div>
    </div>
  `
}
