// Keeper config panel -- structured config viewer with inline editing.
// Fetches /api/v1/keepers/:name/config and renders grouped sections.
// Redesigned: clean section headers, consistent row styling, proper form controls.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { signal } from '@preact/signals'
import {
  fetchDashboardGoalsTree,
  fetchDashboardTools,
  patchKeeperConfig,
  setKeeperToolPolicy,
} from '../api/dashboard'
import { pauseKeeper, resumeKeeper, wakeKeeper } from '../api/keeper'
import type { DashboardRuntimeProviderSnapshot, DashboardToolInventoryItem, KeeperConfigUpdatePayload, SandboxProfile, SandboxNetworkMode } from '../api/dashboard'
import type { GoalTreeNode, KeeperConfig, KeeperHookSlot } from '../types'
import { formatTokens, formatPct, formatCost } from '../lib/format-number'
import { isVerifierRoleKeeper } from '../lib/keeper-utils'
import { MISSING_DATA_DASH } from '../lib/format-string'
import type { AsyncState } from '../lib/async-state'
import { showToast } from './common/toast'
import { ErrorState, LoadingState } from './common/feedback-state'
import { BTN_FILLED_BASE } from './common/button-filled-base'
import { ExpandableTextarea } from './common/expandable-textarea'
import { KeeperToolAccessSummary } from './keeper-tool-access'
import { createAsyncResource } from '../lib/async-state'
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
import { refreshKeeperRuntimeStatus } from '../store'
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
  | 'goals'
  | 'hooks'
  | 'health'

const KCF_TABS: readonly (readonly [KcfTabId, string, string])[] = [
  ['identity', '정체성', '◈'],
  ['prompt', '프롬프트', '¶'],
  ['runtime', '런타임', '◷'],
  ['policy', '실행 정책', '⚖'],
  ['access', '권한·샌드박스', '⚿'],
  ['goals', '목표', '◎'],
  ['hooks', '훅', '⬡'],
  ['health', '상태·진단', '◉'],
]

const kcfTab = signal<KcfTabId>('identity')

// ── State ────────────────────────────────────────────────

const goalOptionsResource = createAsyncResource<GoalTreeNode[]>()
const goalOptionsState = goalOptionsResource.state
// Client-only search over the goal catalogue (title/id substring). The catalogue
// can be large, so the goals tab filters the rendered list without a fetch.
const goalSearchQuery = signal('')
// Live tool registry (GET /api/v1/dashboard/tools) — the per-tool policy grid is
// derived from this, never a hardcoded catalogue, so a tool added to the runtime
// surfaces here on the next load.
const toolInventoryResource = createAsyncResource<DashboardToolInventoryItem[]>()
const toolInventoryState = toolInventoryResource.state
const editMode = signal(false)
const saving = signal(false)
const saveError = signal<string | null>(null)

// Draft values for editable fields (only used in edit mode)
type EditDraft = {
  goal: string
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
    goal: c.prompt.goal,
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
  setIfChanged('goal')
  setIfChanged('instructions')
  return payload
}

function formatRelativeTime(date: Date): string {
  const sec = Math.round((Date.now() - date.getTime()) / 1000)
  if (sec < 60) return `${sec}초 전`
  const min = Math.round(sec / 60)
  if (min < 60) return `${min}분 전`
  const hour = Math.round(min / 60)
  if (hour < 24) return `${hour}시간 전`
  return date.toLocaleString('ko-KR')
}

// Runtime config draft for sandbox/proactive/compaction/handoff inline editing
export function normalizeMaxContextOverrideDraft(value: number, maxTokens?: number | null): number {
  if (!Number.isFinite(value)) return 0
  const normalized = Math.max(0, Math.trunc(value))
  const max = Number.isFinite(maxTokens) && (maxTokens ?? 0) > 0
    ? Math.trunc(maxTokens as number)
    : null
  return max == null ? normalized : Math.min(max, normalized)
}

export type RuntimeDraft = {
  runtime_id: string
  autoboot_enabled: boolean
  max_context_override: number
  sandbox_profile: SandboxProfile
  active_goal_ids: string[]
  mention_targets_text: string
  network_mode: SandboxNetworkMode
  allowed_paths_text: string
  proactive_enabled: boolean
  proactive_idle_sec: number
  proactive_cooldown_sec: number
  compaction_profile: string
  compaction_ratio_gate: number
  compaction_message_gate: number
  compaction_token_gate: number
  compaction_cooldown_sec: number
  auto_handoff: boolean
  handoff_threshold: number
  handoff_cooldown_sec: number
}

const runtimeDraft = signal<RuntimeDraft | null>(null)
const runtimeSaving = signal(false)
const runtimeDirectiveSaving = signal<'pause' | 'resume' | 'wakeup' | null>(null)
// Tool policy is saved via the separate /tools set_policy endpoint (not the
// /config PATCH), so it has its own draft/saving state. null draft = "show the
// live policy"; a string = the operator's in-progress edit.
const toolAccessDraftText = signal<string | null>(null)
const denylistDraftText = signal<string | null>(null)
const denylistSaving = signal(false)

function resetKeeperConfigPanelDrafts(): void {
  goalOptionsResource.reset()
  goalSearchQuery.value = ''
  toolInventoryResource.reset()
  editMode.value = false
  editDraft.value = null
  saveError.value = null
  lastSavedAt.value = null
  promptPreviewTab.value = 'blocks'
  runtimeDraft.value = null
  runtimeSaving.value = false
  runtimeDirectiveSaving.value = null
  toolAccessDraftText.value = null
  denylistDraftText.value = null
  denylistSaving.value = false
  hookFilterQuery.value = ''
  globalArchExpanded.value = false
  kcfTab.value = 'identity'
}

function syncRuntimeDraftFromConfig(_name: string, updated: KeeperConfig): void {
  runtimeDraft.value = initRuntimeDraftFromConfig(updated)
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

export function coerceSandboxProfile(raw: string | undefined): SandboxProfile {
  return raw === 'docker' ? 'docker' : 'local'
}

export function coerceNetworkMode(raw: string | undefined): SandboxNetworkMode {
  return raw === 'none' ? 'none' : 'inherit'
}

export function initRuntimeDraftFromConfig(c: KeeperConfig): RuntimeDraft {
  return {
    runtime_id: c.execution.selected_runtime_id ?? '',
    autoboot_enabled: c.autoboot_enabled,
    max_context_override: normalizeMaxContextOverrideDraft(
      c.max_context_override ?? 0,
      c.limits.max_context_override_tokens,
    ),
    sandbox_profile: coerceSandboxProfile(c.sandbox_profile),
    active_goal_ids: c.workspace.active_goal_ids.length > 0
      ? c.workspace.active_goal_ids
      : c.active_goal_ids,
    mention_targets_text: c.workspace.mention_targets.join('\n'),
    network_mode: coerceNetworkMode(c.network_mode),
    allowed_paths_text: (c.allowed_paths ?? []).join('\n'),
    proactive_enabled: c.proactive.enabled,
    proactive_idle_sec: c.proactive.idle_sec,
    proactive_cooldown_sec: c.proactive.cooldown_sec,
    compaction_profile: c.compaction.profile,
    compaction_ratio_gate: c.compaction.ratio_gate,
    compaction_message_gate: c.compaction.message_gate,
    compaction_token_gate: c.compaction.token_gate,
    compaction_cooldown_sec: c.compaction.cooldown_sec,
    auto_handoff: c.handoff.auto,
    handoff_threshold: c.handoff.threshold,
    handoff_cooldown_sec: c.handoff.cooldown_sec,
  }
}

export function keeperRuntimeConfigWriteUnsupportedReason(c: KeeperConfig): string | null {
  const kind = c.sources.default_source_kind ?? 'unknown'
  if (kind !== 'toml') {
    return `runtime 설정 저장은 TOML-backed keeper manifest에서만 지원됩니다. 현재 기본 소스: ${kind}.`
  }
  const manifestPath = c.sources.default_manifest_path?.trim()
  if (!manifestPath) {
    return 'runtime 설정 저장은 기본 매니페스트 경로가 확인될 때만 지원됩니다.'
  }
  return null
}

export function keeperRuntimeConfigCanWrite(c: KeeperConfig): boolean {
  return keeperRuntimeConfigWriteUnsupportedReason(c) === null
}

export function buildRuntimePayload(draft: RuntimeDraft, orig: KeeperConfig): KeeperConfigUpdatePayload {
  const payload: KeeperConfigUpdatePayload = {}
  const newPaths = listTextToStrings(draft.allowed_paths_text)
  const newMentionTargets = listTextToStrings(draft.mention_targets_text)
  const origPaths = orig.allowed_paths ?? []
  const origActiveGoalIds = orig.workspace.active_goal_ids.length > 0
    ? orig.workspace.active_goal_ids
    : orig.active_goal_ids
  if (draft.runtime_id.trim() !== (orig.execution.selected_runtime_id ?? '').trim()) payload.runtime_id = draft.runtime_id.trim()
  if (draft.autoboot_enabled !== orig.autoboot_enabled) payload.autoboot_enabled = draft.autoboot_enabled
  const draftMaxContextOverride = normalizeMaxContextOverrideDraft(
    draft.max_context_override,
    orig.limits.max_context_override_tokens,
  )
  if (draftMaxContextOverride !== (orig.max_context_override ?? 0)) {
    payload.max_context_override = draftMaxContextOverride > 0 ? draftMaxContextOverride : null
  }
  if (!sameStringArray(draft.active_goal_ids, origActiveGoalIds)) payload.active_goal_ids = draft.active_goal_ids
  if (!sameStringArray(newMentionTargets, orig.workspace.mention_targets)) payload.mention_targets = newMentionTargets
  if (!sameStringArray(newPaths, origPaths)) payload.allowed_paths = newPaths
  if (draft.sandbox_profile !== coerceSandboxProfile(orig.sandbox_profile)) payload.sandbox_profile = draft.sandbox_profile
  if (draft.network_mode !== coerceNetworkMode(orig.network_mode)) payload.network_mode = draft.network_mode
  if (draft.proactive_enabled !== orig.proactive.enabled) payload.proactive_enabled = draft.proactive_enabled
  if (draft.proactive_idle_sec !== orig.proactive.idle_sec) payload.proactive_idle_sec = draft.proactive_idle_sec
  if (draft.proactive_cooldown_sec !== orig.proactive.cooldown_sec) payload.proactive_cooldown_sec = draft.proactive_cooldown_sec
  if (draft.compaction_profile !== orig.compaction.profile) payload.compaction_profile = draft.compaction_profile
  if (draft.compaction_ratio_gate !== orig.compaction.ratio_gate) payload.compaction_ratio_gate = draft.compaction_ratio_gate
  if (draft.compaction_message_gate !== orig.compaction.message_gate) payload.compaction_message_gate = draft.compaction_message_gate
  if (draft.compaction_token_gate !== orig.compaction.token_gate) payload.compaction_token_gate = draft.compaction_token_gate
  if (draft.compaction_cooldown_sec !== orig.compaction.cooldown_sec) payload.continuity_compaction_cooldown_sec = draft.compaction_cooldown_sec
  if (draft.auto_handoff !== orig.handoff.auto) payload.auto_handoff = draft.auto_handoff
  if (draft.handoff_threshold !== orig.handoff.threshold) payload.handoff_threshold = draft.handoff_threshold
  if (draft.handoff_cooldown_sec !== orig.handoff.cooldown_sec) payload.handoff_cooldown_sec = draft.handoff_cooldown_sec
  return payload
}

function updateRuntimeDraft(field: keyof RuntimeDraft, value: boolean | number | string) {
  const d = runtimeDraft.value
  if (!d) return
  const next = { ...d, [field]: value } as RuntimeDraft
  if (field === 'sandbox_profile' && next.sandbox_profile !== 'docker' && next.network_mode === 'none') {
    next.network_mode = 'inherit'
  }
  if (field === 'network_mode' && next.sandbox_profile !== 'docker' && next.network_mode === 'none') {
    next.network_mode = 'inherit'
  }
  runtimeDraft.value = next
}

function sameStringArray(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) return false
  return a.every((value, index) => value === b[index])
}

function listTextToStrings(text: string): string[] {
  return dedupeStrings(text.split('\n'))
}

function computeRuntimeDirtyFlags(rd: RuntimeDraft, c: KeeperConfig): Record<string, boolean> {
  const payload = buildRuntimePayload(rd, c)
  return {
    runtime_id: 'runtime_id' in payload,
    autoboot_enabled: 'autoboot_enabled' in payload,
    max_context_override: 'max_context_override' in payload,
    active_goal_ids: 'active_goal_ids' in payload,
    mention_targets: 'mention_targets' in payload,
    allowed_paths: 'allowed_paths' in payload,
    sandbox_profile: 'sandbox_profile' in payload,
    network_mode: 'network_mode' in payload,
    proactive_enabled: 'proactive_enabled' in payload,
    proactive_idle_sec: 'proactive_idle_sec' in payload,
    proactive_cooldown_sec: 'proactive_cooldown_sec' in payload,
    compaction_profile: 'compaction_profile' in payload,
    compaction_ratio_gate: 'compaction_ratio_gate' in payload,
    compaction_message_gate: 'compaction_message_gate' in payload,
    compaction_token_gate: 'compaction_token_gate' in payload,
    compaction_cooldown_sec: 'continuity_compaction_cooldown_sec' in payload,
    auto_handoff: 'auto_handoff' in payload,
    handoff_threshold: 'handoff_threshold' in payload,
    handoff_cooldown_sec: 'handoff_cooldown_sec' in payload,
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

function updateRuntimeActiveGoalIds(values: readonly string[]) {
  const d = runtimeDraft.value
  if (!d) return
  runtimeDraft.value = { ...d, active_goal_ids: dedupeStrings(values) }
}

function toggleRuntimeActiveGoal(goalId: string, checked: boolean) {
  const d = runtimeDraft.value
  if (!d) return
  const next = checked
    ? [...d.active_goal_ids, goalId]
    : d.active_goal_ids.filter((id) => id !== goalId)
  updateRuntimeActiveGoalIds(next)
}

function flattenGoalTree(nodes: readonly GoalTreeNode[]): GoalTreeNode[] {
  const out: GoalTreeNode[] = []
  for (const node of nodes) {
    out.push(node)
    out.push(...flattenGoalTree(node.children ?? []))
  }
  return out
}

async function loadGoalOptions(options?: { force?: boolean }): Promise<void> {
  const force = options?.force === true
  if (!force && goalOptionsState.value.status === 'loaded') return
  if (force) goalOptionsResource.reset()
  await goalOptionsResource.load(async () => {
    const response = await fetchDashboardGoalsTree()
    return flattenGoalTree(response.tree)
  })
}

async function loadToolInventory(options?: { force?: boolean }): Promise<void> {
  const force = options?.force === true
  if (!force && toolInventoryState.value.status === 'loaded') return
  if (force) toolInventoryResource.reset()
  await toolInventoryResource.load(async () => {
    const response = await fetchDashboardTools()
    return response.tool_inventory?.tools ?? []
  })
}

// Case-insensitive title/id substring filter for the goals catalogue.
export function filterGoalOptions(
  goals: readonly GoalTreeNode[],
  query: string,
): readonly GoalTreeNode[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return goals
  return goals.filter(
    (goal) =>
      goal.title.toLowerCase().includes(needle) || goal.id.toLowerCase().includes(needle),
  )
}

// ── Helpers ──────────────────────────────────────────────

// .kcf-* widgets — keeper-v2/keeper-config.jsx contract, styled by the vendored
// keeper-config.css. Used inside the 8-tab modal so the field set matches the
// prototype's section/fact/text-field anatomy. The editable widgets keep the
// live input model + aria-labels; only the read-only display adopts .kcf-facts.

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

function KcfReadonlyText({ label, hint, text }: { label: string; hint?: string; text: string }) {
  const value = text && text.trim() !== '' ? text : MISSING_DATA_DASH
  return html`
    <div class="kcf-textfield">
      <div class="kcf-tf-h"><label>${label}</label>${hint ? html`<span class="kcf-tf-hint">${hint}</span>` : null}</div>
      <div class="kcf-text mono" style="white-space:pre-wrap; max-height:9rem; overflow-y:auto;">${value}</div>
    </div>
  `
}

// ── prompt assembly trace (조립 추적) ──
// Keeper-scoped layered lineage built from the keeper's OWN config provenance:
// system_prompt_blocks (shared base), prompt.goal/instructions (manifest, or a
// live override when sources.override_fields lists the field), and active_goals.
// This is deliberately NOT the workspace-global KeeperPromptAssemblyPanel — that
// component fetches dashboard-wide prompt-registry overrides (fetchDashboardPrompts)
// and cannot render one keeper's assembled layers. Read-only; every segment is
// real config text with real provenance, no fabricated base prose.
type KcfAssemblySource = 'base' | 'manifest' | 'override' | 'goals'

interface KcfAssemblySegment {
  readonly src: KcfAssemblySource
  readonly field: string
  readonly path: string
  readonly text: string
  readonly win: boolean
}

const KCF_ASSEMBLY_SRC_META: Readonly<Record<KcfAssemblySource, { lbl: string; cls: string }>> = {
  base: { lbl: '공유 베이스', cls: 'src-base' },
  manifest: { lbl: '매니페스트', cls: 'src-manifest' },
  override: { lbl: 'live override', cls: 'src-override' },
  goals: { lbl: '배정 목표', cls: 'src-goals' },
}

// Server override_fields are dot-namespaced (keeper_status_bridge.ml
// live_override_details): 'prompt.goal', 'prompt.instructions', etc. A field is
// marked as winning over the manifest only when its exact key is present.
export function buildKcfAssemblySegments(c: KeeperConfig): KcfAssemblySegment[] {
  const overrideFields = new Set(c.sources.override_fields)
  const manifestPath =
    c.sources.default_manifest_path && c.sources.default_manifest_path.trim() !== ''
      ? c.sources.default_manifest_path
      : '매니페스트'
  const livePath =
    c.sources.live_meta_path && c.sources.live_meta_path.trim() !== ''
      ? c.sources.live_meta_path
      : 'live override'
  const segments: KcfAssemblySegment[] = []
  const blocks = c.prompt.system_prompt_blocks
  const baseBlocks: readonly (readonly [string, { key: string; source: string; text: string }])[] = [
    ['헌법', blocks.constitution],
    ['세계관', blocks.world],
    ['능력', blocks.capabilities],
  ]
  for (const [label, block] of baseBlocks) {
    if (block.text.trim() !== '') {
      segments.push({ src: 'base', field: label, path: block.source, text: block.text, win: false })
    }
  }
  const pushPromptField = (overrideKey: string, label: string, text: string) => {
    if (text.trim() === '') return
    const overridden = overrideFields.has(overrideKey)
    segments.push({
      src: overridden ? 'override' : 'manifest',
      field: label,
      path: overridden ? livePath : manifestPath,
      text,
      win: overridden,
    })
  }
  pushPromptField('prompt.goal', '목표 (objective)', c.prompt.goal)
  pushPromptField('prompt.instructions', '지시사항 (instructions)', c.prompt.instructions)
  const goals = c.workspace.active_goals
  if (goals.length > 0) {
    segments.push({
      src: 'goals',
      field: `배정 goal ${goals.length}개`,
      path: 'goal store',
      text: goals.map((g) => `· ${g.title}`).join('\n'),
      win: false,
    })
  }
  return segments
}

function KcfAssemblyTrace({ config }: { config: KeeperConfig }) {
  const segments = buildKcfAssemblySegments(config)
  if (segments.length === 0) {
    return html`<div class="kcf-goals-empty">조립할 프롬프트 레이어가 없습니다.</div>`
  }
  const presentSources = [...new Set(segments.map((s) => s.src))]
  return html`
    <div class="kasm">
      <div class="kasm-legend">
        ${presentSources.map((src) => {
          const meta = KCF_ASSEMBLY_SRC_META[src]
          return html`<span key=${src} class=${`kasm-leg ${meta.cls}`}><i></i>${meta.lbl}</span>`
        })}
      </div>
      <div class="kasm-stack">
        ${segments.map((seg, i) => {
          const meta = KCF_ASSEMBLY_SRC_META[seg.src]
          return html`
            <div key=${i} class=${`kasm-seg ${meta.cls} ${seg.win ? 'win' : ''}`}>
              <div class="kasm-seg-h">
                <span class="kasm-seg-src">${meta.lbl}</span>
                <span class="kasm-seg-field mono">${seg.field}</span>
                ${seg.win ? html`<span class="kasm-seg-win">매니페스트 덮어씀</span>` : null}
                <span class="kasm-seg-path mono">${seg.path}</span>
              </div>
              <div class="kasm-seg-text">${seg.text}</div>
            </div>
          `
        })}
      </div>
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

// Segmented selector for a bounded numeric value. To avoid silently dropping a
// value that is not one of the presets, the current value is folded into the
// option list (sorted) so it stays visible and selectable.
function SetSeg({
  value,
  options,
  onChange,
  ariaLabel,
}: {
  value: number
  options: readonly number[]
  onChange: (v: number) => void
  ariaLabel: string
}) {
  const opts = options.includes(value)
    ? options
    : [...options, value].sort((a, b) => a - b)
  return html`
    <div class="set-seg" role="radiogroup" aria-label=${ariaLabel}>
      ${opts.map((o) => html`
        <button
          type="button"
          key=${o}
          class=${`set-seg-b ${o === value ? 'on' : ''}`}
          aria-pressed=${o === value ? 'true' : 'false'}
          onClick=${() => onChange(o)}
        >${o}</button>
      `)}
    </div>
  `
}

function ConfigRow({ label, value }: { label: string; value: string }) {
  return html`
    <div class="flex items-center justify-between py-2.5 px-4 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-2 v2-monitoring-row">
      <span class="text-sm font-medium text-text-muted">${label}</span>
      <span class="text-sm font-semibold text-text-strong">${value}</span>
    </div>
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

function formatSeconds(value: number): string {
  if (!Number.isFinite(value)) return MISSING_DATA_DASH
  return value >= 60 ? `${(value / 60).toFixed(1)}m` : `${value.toFixed(value % 1 === 0 ? 0 : 1)}s`
}

function perProviderTimeoutLabel(execution: KeeperConfig['execution']): string {
  if (
    execution.per_provider_timeout_mode === 'override'
    && typeof execution.per_provider_timeout_sec === 'number'
  ) {
    return formatSeconds(execution.per_provider_timeout_sec)
  }
  return 'turn budget default'
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

function formatHookDestructiveTools(value: string[] | string): string {
  if (Array.isArray(value)) {
    return value.length > 0 ? value.join(', ') : MISSING_DATA_DASH
  }
  const text = value.trim()
  return text !== '' ? text : MISSING_DATA_DASH
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

// ── Inline editing components for runtime config ────────

function InlineNumberRow({ label, value, onChange, min, max, step, suffix, dirty = false }: {
  label: string; value: number; onChange: (v: number) => void;
  min?: number; max?: number; step?: number; suffix?: string; dirty?: boolean
}) {
  const [invalid, setInvalid] = useState(false)
  return html`
    <div class="flex items-center justify-between py-2.5 px-4 rounded-[var(--r-1)] border ${dirty ? 'border-l-4 border-l-[var(--color-accent-fg)] border-card-border/50' : 'border-card-border/50'} bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-2 v2-monitoring-row">
      <span class="text-sm font-medium text-text-muted">${label}${dirty ? html`<span class="ml-2 text-2xs text-[var(--color-accent-fg)] font-semibold">●</span>` : null}</span>
      <div class="flex items-center gap-2">
        <input type="number"
          aria-label=${label}
          class="w-24 text-right bg-card/60 text-text-strong text-sm font-semibold border ${invalid ? 'border-[var(--color-status-err)]' : 'border-card-border'} rounded-[var(--r-1)] py-1.5 px-2 focus:outline-none focus:border-accent-fg/50 transition-colors"
          value=${value}
          min=${min}
          max=${max}
          step=${step}
          onInput=${(e: Event) => {
            const input = e.target as HTMLInputElement
            const v = parseFloat(input.value)
            setInvalid(!input.checkValidity())
            if (!isNaN(v)) onChange(v)
          }}
        />
        ${suffix ? html`<span class="text-xs text-text-dim w-5">${suffix}</span>` : null}
      </div>
    </div>
  `
}

export function InlineSelectRow({
  label,
  value,
  options,
  onChange,
  dirty = false,
}: {
  label: string
  value: string
  options: readonly string[]
  onChange: (v: string) => void
  dirty?: boolean
}) {
  return html`
    <div class="flex items-center justify-between py-2.5 px-4 rounded-[var(--r-4)] border ${dirty ? 'border-l-4 border-l-[var(--color-accent-fg)] border-card-border/50' : 'border-card-border/50'} bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-2 gap-3 v2-monitoring-row">
      <span class="text-sm font-medium text-text-muted">${label}${dirty ? html`<span class="ml-2 text-2xs text-[var(--color-accent-fg)] font-semibold">●</span>` : null}</span>
      <select
        aria-label=${label}
        class="text-sm bg-card/60 border border-card-border rounded-[var(--r-1)] px-3 py-1.5 text-text-strong"
        value=${value}
        onChange=${(e: Event) => onChange((e.target as HTMLSelectElement).value)}
      >
        ${options.map(option => html`<option value=${option}>${option}</option>`)}
      </select>
    </div>
  `
}

// ── Edit field components ────────────────────────────────

function updateDraft(field: keyof EditDraft, value: string | boolean | number) {
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

  useEffect(() => retainKeeperConfigPanelSubscriptions(), [])

  // Trigger load on first render or name change
  if (configKeeperName.value !== keeperName || state.status === 'idle') {
    void loadKeeperConfig(keeperName)
  }
  if (goalOptionsState.value.status === 'idle') {
    void loadGoalOptions()
  }
  if (toolInventoryState.value.status === 'idle') {
    void loadToolInventory()
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
  const runtimeWriteUnsupportedReason = keeperRuntimeConfigWriteUnsupportedReason(c)
  const runtimeCanEdit = runtimeWriteUnsupportedReason === null

  // Initialize runtime draft if not yet set
  if (!runtimeDraft.value) {
    runtimeDraft.value = initRuntimeDraftFromConfig(c)
  }
  const rd = runtimeDraft.value
  const dirtyFlags = rd ? computeRuntimeDirtyFlags(rd, c) : {}

  const runtimeHasChanges = runtimeCanEdit && rd ? Object.keys(buildRuntimePayload(rd, c)).length > 0 : false
  const maxContextOverrideTokens = c.limits.max_context_override_tokens ?? undefined
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
    const payload = buildRuntimePayload(rd, c)
    if (Object.keys(payload).length === 0) return
    runtimeSaving.value = true
    try {
      const updated = await patchKeeperConfig(keeperName, payload)
      applyKeeperConfigUpdate(keeperName, updated)
      void refreshKeeperRuntimeStatus().catch(err => {
        const message = err instanceof Error ? err.message : '런타임 상태 새로고침 실패'
        showToast(message, 'warning')
      })
      showToast('런타임 설정 저장 완료', 'success')
    } catch (err) {
      const msg = err instanceof Error ? err.message : '저장 실패'
      showToast(msg, 'error')
    } finally {
      runtimeSaving.value = false
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
    runtimeDraft.value = initRuntimeDraftFromConfig(c)
  }

  // Parse tool policy textareas into deduped, trimmed tool-name lists.
  function parseToolPolicyListDraft(text: string): string[] {
    return [...new Set(text.split('\n').map((s) => s.trim()).filter(Boolean))]
  }

  async function saveToolPolicy() {
    const accessText = toolAccessDraftText.value ?? c.tools.tool_access.join('\n')
    const denyText = denylistDraftText.value ?? c.tools.tool_denylist.join('\n')
    const toolAccess = parseToolPolicyListDraft(accessText)
    const deny = parseToolPolicyListDraft(denyText)
    denylistSaving.value = true
    try {
      const updated = await setKeeperToolPolicy(keeperName, {
        tool_access: toolAccess,
        deny,
      })
      applyKeeperConfigUpdate(keeperName, updated)
      toolAccessDraftText.value = null
      denylistDraftText.value = null
      showToast('도구 정책 저장 완료', 'success')
    } catch (err) {
      showToast(err instanceof Error ? err.message : '저장 실패', 'error')
    } finally {
      denylistSaving.value = false
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
    saving.value = true
    saveError.value = null
    try {
      const updated = await patchKeeperConfig(keeperName, payload)
      applyKeeperConfigUpdate(keeperName, updated)
      editMode.value = false
      editDraft.value = null
      lastSavedAt.value = new Date().toISOString()
      showToast('프롬프트 저장 완료', 'success')
    } catch (err) {
      saveError.value = err instanceof Error ? err.message : '저장 실패'
    } finally {
      saving.value = false
    }
  }

  // --- Toolbar ---
  const lastSavedText = lastSavedAt.value
    ? `마지막 저장: ${formatRelativeTime(new Date(lastSavedAt.value))}`
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
    <${EditTextarea} field="goal" label="목표" rows=${8} />
    <${EditTextarea} field="instructions" label="지시사항" rows=${10} />
  ` : html`
    <${MajorSectionHeader} title="프롬프트" />
    <${SectionHeader} size="xs" class="mb-0.5">목표</${SectionHeader}>
    <${LongText} text=${c.prompt.goal} />
    ${c.prompt.instructions ? html`
      <${SectionHeader} size="xs" class="mt-2 mb-0.5">지시사항</${SectionHeader}>
      <${LongText} text=${c.prompt.instructions} />
    ` : null}
    <${SectionHeader} size="xs" class="mt-3 mb-0.5">시스템 프롬프트</${SectionHeader}>
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
          <${PromptBlock} title="헌법" block=${c.prompt.system_prompt_blocks.constitution} />
          <${PromptBlock} title="세계관" block=${c.prompt.system_prompt_blocks.world} />
          <${PromptBlock} title="능력" block=${c.prompt.system_prompt_blocks.capabilities} />
        `
      : promptPreviewTab.value === 'system'
        ? html`<${LongText} text=${c.prompt.unified_system_prompt || c.prompt.effective_system_prompt} truncateAt=${null} />`
        : html`<${LongText} text=${c.prompt.unified_user_message_preview} truncateAt=${null} />`}
  `

  const goalState = goalOptionsState.value
  const goalOptionsLoaded = goalState.status === 'loaded'
  const goalOptions: GoalTreeNode[] = goalOptionsLoaded ? goalState.data : []
  const selectedActiveGoalIds = rd
    ? rd.active_goal_ids
    : (c.workspace.active_goal_ids.length > 0 ? c.workspace.active_goal_ids : c.active_goal_ids)
  const currentMentionTargets = rd
    ? listTextToStrings(rd.mention_targets_text)
    : c.workspace.mention_targets
  const knownGoalIds = new Set(goalOptions.map((goal) => goal.id))
  const unknownSelectedGoalIds = goalOptionsLoaded
    ? selectedActiveGoalIds.filter((goalId) => !knownGoalIds.has(goalId))
    : []

  // ── Tab content (the live fields, regrouped under the 8 prototype tabs) ──
  // identity ◈ — access-summary facts + source provenance + verifier role
  const identityTab = html`
    <${KeeperToolAccessSummary} config=${c} />

    <${KcfSec} title="편집 가능 범위" desc="여기서 저장되는 값은 keeper 프롬프트, live override 계층, runtime.toml의 [runtime.assignments]입니다.">
      <${KcfFacts} rows=${[
        ['기본 소스', c.sources.default_source_kind],
        ['라이브 오버라이드', c.sources.has_live_override ? 'ON' : 'OFF'],
      ]} />
    </${KcfSec}>

    <${KcfSec} title="소스 · 경로" desc="등록 상태와 매니페스트 경로는 읽기 전용입니다.">
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

    ${isVerifierRoleKeeper(currentMentionTargets) ? html`
    <div class="kcf-sec" style="margin-bottom:18px;">
      <div class="flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-3 py-2">
        <span class="rounded-[var(--r-1)] border border-[var(--accent-40)] bg-[var(--accent-5)] px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-accent-fg">검증자</span>
        <span class="text-2xs text-text-body">이 keeper는 task completion_contract를 독립 실측하는 검증자 역할입니다.</span>
      </div>
    </div>
    ` : null}
  `

  // prompt ¶ — edit toolbar + active goals + instructions + system prompt preview
  const promptTab = html`
    ${toolbar}
    ${promptSection}
    <${KcfSec}
      title="조립 추적"
      desc="이 keeper의 시스템 프롬프트가 어느 레이어에서 조립됐는지 — 공유 베이스 위에 매니페스트/live override가 쌓이고, override_fields에 오른 필드가 매니페스트를 덮어씁니다.">
      <${KcfAssemblyTrace} config=${c} />
    </${KcfSec}>
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
        <${KcfSec} title="Runtime catalog spec" desc="선택 runtime 의 /api/v1/providers Provider × Model projection입니다. 요청 파라미터와 effective capability는 여기서 읽기 전용으로 확인합니다.">
          <${KcfFacts} rows=${selectedRuntimeCatalogRows} />
        </${KcfSec}>
      `
      : null}

    <${KcfSec} title="실행" desc="런타임 후보·타임아웃은 읽기 전용입니다. fallback 은 마지막 runtime 을 제외한 항목에 순서대로 적용됩니다.">
      <${KcfFacts} rows=${[
        ['활성 런타임', c.execution.active_model ? 'runtime' : null],
        ['runtime timeout', perProviderTimeoutLabel(c.execution), true],
      ]} />
      ${rd && runtimeCanEdit ? html`
        <${InlineNumberRow} label="컨텍스트 오버라이드" value=${rd.max_context_override}
          onChange=${(v: number) => updateRuntimeDraft('max_context_override', normalizeMaxContextOverrideDraft(v, c.limits.max_context_override_tokens))}
          min=${0} max=${maxContextOverrideTokens} step=${1000} suffix="tok"
          dirty=${dirtyFlags.max_context_override} />
      ` : html`
        <${ConfigRow} label="컨텍스트 오버라이드" value=${c.max_context_override != null ? formatTokens(c.max_context_override) : MISSING_DATA_DASH} />
      `}
      <div style="margin-top:14px;">
        <div class="kcf-tf-h"><label>런타임 후보</label></div>
        <${RuntimeList} runtimes=${c.execution.models} />
      </div>
    </${KcfSec}>
  `

  // policy ⚖ — verify gate + compaction + proactive + handoff + tool policy
  const policyTab = html`
    ${runtimeWriteUnsupportedNotice}
    <${MajorSectionHeader} title="검증" />
    <${BoolRow} label="검증" value=${c.execution.verify} />

    <${SectionHeader} title="컴팩션" />
    ${rd && runtimeCanEdit ? html`
      <${InlineSelectRow}
        label="compaction_profile"
        value=${rd.compaction_profile}
        options=${['aggressive', 'balanced', 'conservative', 'custom'] as const}
        onChange=${(value: string) => updateRuntimeDraft('compaction_profile', value)}
        dirty=${dirtyFlags.compaction_profile}
      />
      <${SetRow} label="비율 게이트" hint="컨텍스트 사용률 %" dirty=${dirtyFlags.compaction_ratio_gate}>
        <${SetSeg} ariaLabel="비율 게이트" value=${Math.round(rd.compaction_ratio_gate * 100)}
          options=${[75, 80, 85, 90]}
          onChange=${(v: number) => updateRuntimeDraft('compaction_ratio_gate', v / 100)} />
      </${SetRow}>
      <${InlineNumberRow} label="메시지 게이트" value=${rd.compaction_message_gate}
        onChange=${(v: number) => updateRuntimeDraft('compaction_message_gate', v)}
        min=${0} max=${500} step=${5}
        dirty=${dirtyFlags.compaction_message_gate} />
      <${InlineNumberRow} label="토큰 게이트" value=${rd.compaction_token_gate}
        onChange=${(v: number) => updateRuntimeDraft('compaction_token_gate', v)}
        min=${0} max=${maxContextOverrideTokens} step=${1000} suffix="tok"
        dirty=${dirtyFlags.compaction_token_gate} />
      <${InlineNumberRow} label="쿨다운 (초)" value=${rd.compaction_cooldown_sec}
        onChange=${(v: number) => updateRuntimeDraft('compaction_cooldown_sec', v)}
        min=${0} max=${3600} step=${30} suffix="s"
        dirty=${dirtyFlags.compaction_cooldown_sec} />
    ` : html`
      <${ConfigRow} label="프로필" value=${c.compaction.profile || MISSING_DATA_DASH} />
      <${ConfigRow} label="비율 게이트" value=${formatPct(c.compaction.ratio_gate)} />
      <${ConfigRow} label="메시지 게이트" value=${String(c.compaction.message_gate)} />
      <${ConfigRow} label="토큰 게이트" value=${formatTokens(c.compaction.token_gate)} />
      <${ConfigRow} label="쿨다운" value=${c.compaction.cooldown_sec + 's'} />
    `}

    <${SectionHeader} title="프로액티브" />
    ${rd && runtimeCanEdit ? html`
      <${SetRow} label="자동 부팅" hint="서버 시작 시 keeper 등록" dirty=${dirtyFlags.autoboot_enabled}>
        <${SetToggle} ariaLabel="자동 부팅" on=${rd.autoboot_enabled}
          onChange=${(v: boolean) => updateRuntimeDraft('autoboot_enabled', v)} />
      </${SetRow}>
      <${SetRow} label="활성" hint="유휴 시 keeper 자가 기동" dirty=${dirtyFlags.proactive_enabled}>
        <${SetToggle} ariaLabel="프로액티브 활성" on=${rd.proactive_enabled}
          onChange=${(v: boolean) => updateRuntimeDraft('proactive_enabled', v)} />
      </${SetRow}>
      <${InlineNumberRow} label="유휴 트리거 (초)" value=${rd.proactive_idle_sec}
        onChange=${(v: number) => updateRuntimeDraft('proactive_idle_sec', v)}
        min=${10} max=${3600} step=${10} suffix="s"
        dirty=${dirtyFlags.proactive_idle_sec} />
      <${InlineNumberRow} label="쿨다운 (초)" value=${rd.proactive_cooldown_sec}
        onChange=${(v: number) => updateRuntimeDraft('proactive_cooldown_sec', v)}
        min=${10} max=${3600} step=${10} suffix="s"
        dirty=${dirtyFlags.proactive_cooldown_sec} />
    ` : html`
      <${BoolRow} label="자동 부팅" value=${c.autoboot_enabled} />
      <${BoolRow} label="활성" value=${c.proactive.enabled} />
      <${ConfigRow} label="유휴 트리거" value=${c.proactive.idle_sec + 's'} />
      <${ConfigRow} label="쿨다운" value=${c.proactive.cooldown_sec + 's'} />
    `}

    <${SectionHeader} title="핸드오프" />
    ${rd && runtimeCanEdit ? html`
      <${SetRow} label="자동" hint="컨텍스트 임계 도달 시 자동 인계" dirty=${dirtyFlags.auto_handoff}>
        <${SetToggle} ariaLabel="자동 핸드오프" on=${rd.auto_handoff}
          onChange=${(v: boolean) => updateRuntimeDraft('auto_handoff', v)} />
      </${SetRow}>
      <${SetRow} label="임계값" hint="컨텍스트 %" dirty=${dirtyFlags.handoff_threshold}>
        <${SetSeg} ariaLabel="핸드오프 임계값" value=${Math.round(rd.handoff_threshold * 100)}
          options=${[80, 85, 90, 95]}
          onChange=${(v: number) => updateRuntimeDraft('handoff_threshold', v / 100)} />
      </${SetRow}>
      <${InlineNumberRow} label="쿨다운 (초)" value=${rd.handoff_cooldown_sec}
        onChange=${(v: number) => updateRuntimeDraft('handoff_cooldown_sec', v)}
        min=${0} max=${3600} step=${30} suffix="s"
        dirty=${dirtyFlags.handoff_cooldown_sec} />
    ` : html`
      <${BoolRow} label="자동" value=${c.handoff.auto} />
      <${ConfigRow} label="임계값" value=${formatPct(c.handoff.threshold)} />
      <${ConfigRow} label="쿨다운" value=${c.handoff.cooldown_sec + 's'} />
    `}

    ${(() => {
      const accessText = toolAccessDraftText.value ?? c.tools.tool_access.join('\n')
      const denyText = denylistDraftText.value ?? c.tools.tool_denylist.join('\n')
      const accessDeduped = parseToolPolicyListDraft(accessText)
      const denyDeduped = parseToolPolicyListDraft(denyText)
      const changed =
        JSON.stringify(accessDeduped) !== JSON.stringify(c.tools.tool_access)
        || JSON.stringify(denyDeduped) !== JSON.stringify(c.tools.tool_denylist)
      // Per-tool grid edits the SAME tool_access draft the textarea below shows —
      // one draft, two views. Toggling only rewrites tool_access membership; the
      // server (set_policy) still validates every name (RFC-0273 fail-closed) and
      // the denylist keeps its own control, so no execution-gating claim is implied.
      //
      // Empty tool_access is NOT "every tool off": keeper_tool_policy.ml expands an
      // empty allowlist to the full candidate universe (runtime gates on
      // candidate-minus-denylist). So in that mode the grid shows every tool as ON
      // and read-only — an enabled toggle would silently narrow [] (all candidates)
      // to a single explicit candidate. The operator opts into an explicit allowlist
      // via the textarea below, at which point the grid becomes interactive.
      const allCandidatesMode = accessDeduped.length === 0
      const accessSet = new Set(accessDeduped)
      const toggleToolAccess = (name: string) => {
        if (allCandidatesMode) return
        const next = new Set(accessDeduped)
        if (next.has(name)) next.delete(name)
        else next.add(name)
        toolAccessDraftText.value = [...next].join('\n')
      }
      const toolState = toolInventoryState.value
      return html`
        <${SectionHeader} title="도구 정책" />
        <p class="text-3xs text-text-muted mb-2 px-1 leading-relaxed">
          저장 시 set_policy 로 tool_access 와 tool_denylist 를 함께 적용합니다. tool_access 는 후보 프로필이고 실행 차단은 denylist가 담당합니다.
        </p>
        ${toolState.status === 'loading' ? html`
          <div class="text-2xs text-[var(--color-fg-muted)] mb-2 px-1" role="status">도구 목록 로딩 중...</div>
        ` : toolState.status === 'error' ? html`
          <div class="text-2xs text-[var(--color-status-err)] mb-2 px-1">도구 목록 로드 실패: ${toolState.message}</div>
        ` : toolState.status === 'loaded' && toolState.data.length > 0 ? html`
          ${allCandidatesMode ? html`
            <div class="text-2xs text-[var(--color-fg-muted)] mb-2 px-1" role="note" data-testid="tool-all-candidates-note">
              빈 tool_access — 전체 후보 도구 허용 (실행 차단은 denylist). 개별 도구를 제한하려면 아래 tool_access 목록에 이름을 입력해 명시적 허용목록으로 전환하세요.
            </div>
          ` : null}
          <div class="kcf-tools mb-3" role="group" aria-label="tool_access 후보 도구">
            ${toolState.data.map((tool) => {
              const on = allCandidatesMode || accessSet.has(tool.name)
              return html`
                <div key=${tool.name} class=${`kcf-tool ${on ? 'on' : ''}`}>
                  <button
                    type="button"
                    class="kcf-tool-toggle"
                    role="switch"
                    aria-checked=${on ? 'true' : 'false'}
                    aria-disabled=${allCandidatesMode ? 'true' : 'false'}
                    disabled=${allCandidatesMode}
                    aria-label=${`${tool.name} ${on ? '켜짐' : '꺼짐'}`}
                    onClick=${() => { toggleToolAccess(tool.name) }}
                  >${on ? '✓' : ''}</button>
                  <span class="kcf-tool-id mono">${tool.name}</span>
                  <span class="kcf-tool-risk" title="tool_inventory.category">${tool.category}</span>
                  <span class="kcf-tool-desc">${tool.description}</span>
                </div>
              `
            })}
          </div>
        ` : null}
        <div class="py-2.5 px-4 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] mb-2 ${changed ? 'border-l-4 border-l-[var(--color-accent-fg)]' : ''} v2-monitoring-panel">
          <div class="flex items-center justify-between mb-2">
            <span class="text-sm text-[var(--color-fg-secondary)]">tool_access</span>
            <span class="text-xs text-[var(--color-fg-muted)]">${accessDeduped.length}개</span>
          </div>
          <textarea aria-label="tool_access" class="w-full text-sm font-mono bg-[var(--color-bg-hover)] border border-[var(--color-border-default)] rounded-[var(--r-1)] px-3 py-2 text-[var(--color-fg-secondary)] resize-y mb-3"
            rows=${3}
            value=${accessText}
            placeholder="예: tool_read_file"
            onInput=${(e: Event) => { toolAccessDraftText.value = (e.target as HTMLTextAreaElement).value }}
          ></textarea>
          <div class="flex items-center justify-between mb-2">
            <span class="text-sm text-[var(--color-fg-secondary)]">tool_denylist</span>
            <span class="text-xs text-[var(--color-fg-muted)]">${denyDeduped.length}개</span>
          </div>
          <textarea aria-label="tool_denylist" class="w-full text-sm font-mono bg-[var(--color-bg-hover)] border border-[var(--color-border-default)] rounded-[var(--r-1)] px-3 py-2 text-[var(--color-fg-secondary)] resize-y"
            rows=${4}
            value=${denyText}
            placeholder="예: Execute"
            onInput=${(e: Event) => { denylistDraftText.value = (e.target as HTMLTextAreaElement).value }}
          ></textarea>
          <div class="flex items-center gap-2 mt-2">
            <span class="text-3xs text-text-muted">${accessDeduped.length} access · ${denyDeduped.length} deny</span>
            <div class="flex-1"></div>
            <button type="button"
              class="${BTN_FILLED_BASE} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)] text-xs"
              onClick=${saveToolPolicy}
              disabled=${denylistSaving.value || !changed}
            >${denylistSaving.value ? '저장 중...' : '정책 저장'}</button>
            <button type="button"
              class="${BTN_FILLED_BASE} bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)] text-xs"
              title="초기화: 편집한 도구 정책을 서버 값으로 되돌립니다"
              onClick=${() => { toolAccessDraftText.value = null; denylistDraftText.value = null }}
              disabled=${denylistSaving.value || !changed}
            >초기화하기</button>
          </div>
        </div>
      `
    })()}
  `

  // access ⚿ — sandbox / network / allowed_paths + mention targets + bound namespaces
  const accessTab = html`
    ${runtimeWriteUnsupportedNotice}
    <${MajorSectionHeader} title="실행 범위 · 샌드박스" />
    ${rd && runtimeCanEdit ? html`
      <${InlineSelectRow}
        label="sandbox_profile"
        value=${rd.sandbox_profile}
        options=${['local', 'docker'] as const}
        onChange=${(value: string) => updateRuntimeDraft('sandbox_profile', value as SandboxProfile)}
        dirty=${dirtyFlags.sandbox_profile}
      />
      ${c.sandbox_profile === 'docker' && rd.sandbox_profile === 'local' ? html`
        <${Callout}
          title="격리 해제 경고"
          body="Docker → Local 전환은 컨테이너 격리를 해제하고 호스트 프로세스 네임스페이스에서 실행합니다."
          tone="warn"
        />
      ` : null}
      <${InlineSelectRow}
        label="network_mode"
        value=${rd.network_mode}
        options=${rd.sandbox_profile === 'docker' ? ['inherit', 'none'] as const : ['inherit'] as const}
        onChange=${(value: string) => updateRuntimeDraft('network_mode', value as SandboxNetworkMode)}
        dirty=${dirtyFlags.network_mode}
      />
      <div class="py-2.5 px-4 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] mb-2 ${dirtyFlags.allowed_paths ? 'border-l-4 border-l-[var(--color-accent-fg)]' : ''} v2-monitoring-panel">
        <div class="flex items-center justify-between mb-2">
          <span class="text-sm text-[var(--color-fg-secondary)]">allowed_paths</span>
          <span class="text-xs text-[var(--color-fg-muted)]">한 줄에 하나씩. 명시 경로만 허용됩니다.</span>
        </div>
        <textarea aria-label="allowed_paths" class="w-full text-sm font-mono bg-[var(--color-bg-hover)] border border-[var(--color-border-default)] rounded-[var(--r-1)] px-3 py-2 text-[var(--color-fg-secondary)] resize-y"
          rows=${4}
          value=${rd.allowed_paths_text}
          placeholder=".masc/keepers/<name>/"
          onInput=${(e: Event) => updateRuntimeDraft('allowed_paths_text', (e.target as HTMLTextAreaElement).value)}
        ></textarea>
      </div>
      ${(c.effective_allowed_paths ?? []).length > 0 ? html`
        <div class="py-1.5 px-3 text-3xs text-[var(--color-fg-muted)]">
          effective: ${(c.effective_allowed_paths ?? []).join(', ') || '(전체 허용)'}
        </div>
      ` : null}
      ${rd.sandbox_profile === 'docker' ? html`
        <${SetupGuideCard} connectorId="sandbox_hardened" />
      ` : null}
      <${Callout}
        title="기본 경로 앵커"
        body="상대 allowed_paths는 keeper 작업 경로 기준으로 해석됩니다."
      />
    ` : html`
      <${ConfigRow} label="sandbox_profile" value=${c.sandbox_profile ?? 'local'} />
      <${ConfigRow} label="network_mode" value=${c.network_mode ?? 'inherit'} />

      <${ConfigRow} label="allowed_paths" value=${(c.allowed_paths ?? []).join(', ') || '(computed default)'} />
      <${ConfigRow} label="effective_paths" value=${(c.effective_allowed_paths ?? []).join(', ') || '(전체 허용)'} />
    `}

    ${c.sandbox_last_error ? html`
      <${Callout}
        title="샌드박스 오류"
        body=${c.sandbox_last_error}
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
  `

  // goals ◎ — assigned goal-store bindings (active_goal_ids picker)
  const filteredGoalOptions = filterGoalOptions(goalOptions, goalSearchQuery.value)
  const goalsTab = html`
    ${runtimeWriteUnsupportedNotice}
    <${KcfSec}
      title="배정 목표"
      desc=${runtimeCanEdit ? 'goal store 카탈로그에서 이 keeper가 소유할 goal을 고릅니다.' : '현재 배정된 goal-store 연결을 읽기 전용으로 표시합니다.'}
      right=${html`<span class="kcf-goals-count mono">active_goal_ids · ${selectedActiveGoalIds.length} 배정</span>`}
    >
      <div class="kcf-goals">
        ${goalOptions.length > 0 && rd && runtimeCanEdit ? html`
          <div class="kcf-goals-bar">
            <div class="kcf-search">
              <span class="kcf-search-ic" aria-hidden="true">◌</span>
              <input
                type="search"
                aria-label="goal 검색"
                value=${goalSearchQuery.value}
                placeholder="goal 제목·id 검색…"
                onInput=${(e: Event) => { goalSearchQuery.value = (e.target as HTMLInputElement).value }}
              />
            </div>
            <span class="kcf-goals-count mono">${selectedActiveGoalIds.length} 배정 · ${filteredGoalOptions.length} 표시</span>
          </div>
        ` : null}
        ${goalState.status === 'loading' ? html`
          <div class="text-2xs text-[var(--color-fg-muted)]" role="status">목표 목록 로딩 중...</div>
        ` : goalState.status === 'error' ? html`
          <div class="text-2xs text-[var(--color-status-err)]">${goalState.message}</div>
        ` : goalOptions.length > 0 && rd && runtimeCanEdit ? (
          filteredGoalOptions.length > 0 ? html`
          <div class="kcf-goals-list">
            ${filteredGoalOptions.map((goal) => {
              const checked = rd.active_goal_ids.includes(goal.id)
              return html`
                <button
                  type="button"
                  key=${goal.id}
                  class=${`kcf-goal ${checked ? 'on' : ''}`}
                  aria-pressed=${checked ? 'true' : 'false'}
                  onClick=${() => { toggleRuntimeActiveGoal(goal.id, !checked) }}
                >
                  <span class="kcf-goal-check">${checked ? '✓' : ''}</span>
                  <span class="kcf-goal-body">
                    <span class="kcf-goal-title">${goal.title}</span>
                    <span class="kcf-goal-id mono">${goal.id}</span>
                  </span>
                </button>
              `
            })}
          </div>
          ` : html`
          <div class="kcf-goals-empty">검색 결과 없음</div>
          `
        ) : selectedActiveGoalIds.length > 0 ? html`
          <${ModelList} models=${selectedActiveGoalIds} />
        ` : html`
          <div class="kcf-goals-empty">활성 목표가 연결되어 있지 않습니다.</div>
        `}
        ${unknownSelectedGoalIds.length > 0 ? html`
          <div class="mt-2 text-2xs text-[var(--color-status-warn)]">
            Goal Store에서 찾을 수 없는 연결: ${unknownSelectedGoalIds.join(', ')}
          </div>
        ` : null}
      </div>
    </${KcfSec}>
  `

  // hooks ⬡ — global runtime hook architecture (keeper-agnostic, read-only)
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
            ['거부 목록 수', String(c.hooks.deny_list.length), true],
            ['파괴 검사 도구', formatHookDestructiveTools(c.hooks.destructive_check_tools), true],
            ['비용 예산 (텔레메트리·미강제)', c.hooks.cost_budget.active ? formatCost(c.hooks.cost_budget.max_cost_usd ?? 0) : '미설정'],
          ]} />
        </div>
      ` : null}
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
    goals: goalsTab,
    hooks: hooksTab,
    health: healthTab,
  }
  const activeTab = kcfTab.value
  const activeTabLabel = KCF_TABS.find((t) => t[0] === activeTab)?.[1] ?? ''
  const phaseLabel = c.runtime.paused
    ? '일시정지'
    : c.runtime.keepalive_running
      ? '실행'
      : c.runtime.registered
        ? '대기'
        : '오프라인'
  // Phase pill status dot (prototype .kcf-top-phase carries a StatusDot): green
  // when running, amber when paused, dim otherwise.
  const phaseDotColor = c.runtime.keepalive_running
    ? 'var(--status-ok)'
    : c.runtime.paused
      ? 'var(--status-warn)'
      : 'var(--text-dim)'

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
            <div class="kcf-top-name">${keeperName}</div>
            <div class="kcf-top-sub mono">${c.execution.selected_runtime_id || c.sources.default_source_kind || MISSING_DATA_DASH}</div>
          </div>
          <span class="kcf-top-phase">
            <span style=${`width:7px;height:7px;border-radius:50%;background:${phaseDotColor};display:inline-block;${c.runtime.keepalive_running ? 'box-shadow:0 0 6px ' + phaseDotColor + ';' : ''}`} aria-hidden="true"></span>
            ${phaseLabel}
          </span>
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
            ${tabContent[activeTab]}
          </div>
        </div>

        <div class="kcf-foot v2-monitoring-toolbar">
          <span class="kcf-foot-note mono">${activeTabLabel} · ${keeperName}</span>
          <div class="kcf-foot-spacer"></div>
          ${runtimeHasChanges ? html`
            <span class="text-xs font-semibold text-accent-fg mr-1">변경된 런타임 설정</span>
            <button type="button"
              class="kcf-btn ghost v2-monitoring-action"
              title="초기화: 변경한 런타임 설정 draft 를 서버 값으로 되돌립니다"
              onClick=${resetRuntimeDraft}
            >초기화하기</button>
            <button type="button"
              class="kcf-btn save v2-monitoring-action"
              onClick=${saveRuntimeConfig}
              disabled=${runtimeSaving.value}
            >${runtimeSaving.value ? '저장 중...' : '런타임 설정 저장'}</button>
          ` : null}
          ${onClose ? html`
            <button type="button" class="kcf-btn ghost v2-monitoring-action" onClick=${onClose}>닫기</button>
          ` : null}
        </div>
      </div>
    </div>
  `
}
