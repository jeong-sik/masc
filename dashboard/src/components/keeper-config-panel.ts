// Keeper config panel -- structured config viewer with inline editing.
// Fetches /api/v1/keepers/:name/config and renders grouped sections.
// Redesigned: clean section headers, consistent row styling, proper form controls.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { signal } from '@preact/signals'
import {
  fetchDashboardGoalsTree,
  fetchKeeperConfig,
  patchKeeperConfig,
} from '../api/dashboard'
import type { KeeperConfigUpdatePayload, SandboxProfile, SandboxNetworkMode, SharedMemoryScope } from '../api/dashboard'
import type { GoalTreeNode, KeeperConfig, KeeperHookSlot } from '../types'
import type { KeeperConfigLoadStatus } from './keeper-detail-source'
import { formatTokens, formatPct, formatCost } from '../lib/format-number'
import { isVerifierRoleKeeper } from '../lib/keeper-utils'
import { MISSING_DATA_DASH } from '../lib/format-string'
import { showToast } from './common/toast'
import { ErrorState, LoadingState } from './common/feedback-state'
import { BTN_FILLED_BASE } from './common/button-filled-base'
import { ExpandableTextarea } from './common/expandable-textarea'
import { KeeperToolAccessSummary } from './keeper-tool-access'
import { createAsyncResource, loaded } from '../lib/async-state'
import { SetupGuideCard } from './setup-guide-card'
import { SectionHeader } from './common/section-header'
import { StatusDot } from './common/status-dot'

function MutedLabel({ children }: { children: unknown }) {
  return html`<span class="text-xs font-medium text-text-muted">${children}</span>`
}

// ── State ────────────────────────────────────────────────

const configResource = createAsyncResource<KeeperConfig>()
// Exported so sibling surfaces (e.g. the runtime-model editor in the
// 진단/운영 section) subscribe to the SAME loaded config instead of issuing
// a second fetch and drifting. Single source of truth for a keeper's config.
export const configState = configResource.state
const configKeeperName = signal<string>('')
const goalOptionsResource = createAsyncResource<GoalTreeNode[]>()
const goalOptionsState = goalOptionsResource.state
const editMode = signal(false)
const saving = signal(false)
const saveError = signal<string | null>(null)

// Draft values for editable fields (only used in edit mode)
type EditDraft = {
  goal: string
  short_goal: string
  mid_goal: string
  long_goal: string
  will: string
  needs: string
  desires: string
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
    short_goal: c.prompt.short_goal,
    mid_goal: c.prompt.mid_goal,
    long_goal: c.prompt.long_goal,
    will: c.prompt.will,
    needs: c.prompt.needs,
    desires: c.prompt.desires,
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
  setIfChanged('short_goal')
  setIfChanged('mid_goal')
  setIfChanged('long_goal')
  setIfChanged('will')
  setIfChanged('needs')
  setIfChanged('desires')
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

export type RuntimeDraft = {
  runtime_id: string
  sandbox_profile: SandboxProfile
  active_goal_ids: string[]
  network_mode: SandboxNetworkMode
  allowed_paths_text: string
  proactive_enabled: boolean
  proactive_idle_sec: number
  proactive_cooldown_sec: number
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

export function coerceSandboxProfile(raw: string | undefined): SandboxProfile {
  return raw === 'docker' ? 'docker' : 'local'
}

export function coerceNetworkMode(raw: string | undefined): SandboxNetworkMode {
  return raw === 'none' ? 'none' : 'inherit'
}

export function coerceSharedMemoryScope(raw: string | undefined): SharedMemoryScope {
  return raw === 'workspace' ? 'workspace' : 'disabled'
}

export function initRuntimeDraftFromConfig(c: KeeperConfig): RuntimeDraft {
  return {
    runtime_id: c.execution.selected_runtime_id ?? '',
    sandbox_profile: coerceSandboxProfile(c.sandbox_profile),
    active_goal_ids: c.workspace.active_goal_ids.length > 0
      ? c.workspace.active_goal_ids
      : c.active_goal_ids,
    network_mode: coerceNetworkMode(c.network_mode),
    allowed_paths_text: (c.allowed_paths ?? []).join('\n'),
    proactive_enabled: c.proactive.enabled,
    proactive_idle_sec: c.proactive.idle_sec,
    proactive_cooldown_sec: c.proactive.cooldown_sec,
    compaction_ratio_gate: c.compaction.ratio_gate,
    compaction_message_gate: c.compaction.message_gate,
    compaction_token_gate: c.compaction.token_gate,
    compaction_cooldown_sec: c.compaction.cooldown_sec,
    auto_handoff: c.handoff.auto,
    handoff_threshold: c.handoff.threshold,
    handoff_cooldown_sec: c.handoff.cooldown_sec,
  }
}

export function buildRuntimePayload(draft: RuntimeDraft, orig: KeeperConfig): KeeperConfigUpdatePayload {
  const payload: KeeperConfigUpdatePayload = {}
  const newPaths = draft.allowed_paths_text.split('\n').map(s => s.trim()).filter(Boolean)
  const origPaths = orig.allowed_paths ?? []
  const origActiveGoalIds = orig.workspace.active_goal_ids.length > 0
    ? orig.workspace.active_goal_ids
    : orig.active_goal_ids
  if (draft.runtime_id.trim() !== (orig.execution.selected_runtime_id ?? '').trim()) payload.runtime_id = draft.runtime_id.trim()
  if (!sameStringArray(draft.active_goal_ids, origActiveGoalIds)) payload.active_goal_ids = draft.active_goal_ids
  if (JSON.stringify(newPaths) !== JSON.stringify(origPaths)) payload.allowed_paths = newPaths
  if (draft.sandbox_profile !== coerceSandboxProfile(orig.sandbox_profile)) payload.sandbox_profile = draft.sandbox_profile
  if (draft.network_mode !== coerceNetworkMode(orig.network_mode)) payload.network_mode = draft.network_mode
  if (draft.proactive_enabled !== orig.proactive.enabled) payload.proactive_enabled = draft.proactive_enabled
  if (draft.proactive_idle_sec !== orig.proactive.idle_sec) payload.proactive_idle_sec = draft.proactive_idle_sec
  if (draft.proactive_cooldown_sec !== orig.proactive.cooldown_sec) payload.proactive_cooldown_sec = draft.proactive_cooldown_sec
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

function computeRuntimeDirtyFlags(rd: RuntimeDraft, c: KeeperConfig): Record<string, boolean> {
  const payload = buildRuntimePayload(rd, c)
  return {
    runtime_id: 'runtime_id' in payload,
    active_goal_ids: 'active_goal_ids' in payload,
    allowed_paths: 'allowed_paths' in payload,
    sandbox_profile: 'sandbox_profile' in payload,
    network_mode: 'network_mode' in payload,
    proactive_enabled: 'proactive_enabled' in payload,
    proactive_idle_sec: 'proactive_idle_sec' in payload,
    proactive_cooldown_sec: 'proactive_cooldown_sec' in payload,
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

export async function loadKeeperConfig(
  name: string,
  options?: { force?: boolean },
): Promise<void> {
  const force = options?.force === true
  if (!force && configKeeperName.value === name && configState.value.status === 'loaded') return
  if (configKeeperName.value !== name || force) {
    configResource.reset()
  }
  configKeeperName.value = name
  await configResource.load(() => fetchKeeperConfig(name))
}

export function resetKeeperConfig(): void {
  configResource.reset()
  goalOptionsResource.reset()
  configKeeperName.value = ''
  editMode.value = false
  editDraft.value = null
  saveError.value = null
  lastSavedAt.value = null
  promptPreviewTab.value = 'blocks'
  runtimeDraft.value = null
  runtimeSaving.value = false
  hookFilterQuery.value = ''
  globalArchExpanded.value = false
}

/**
 * Replace the shared loaded config for [name] with a freshly-patched value.
 *
 * Used by sibling editors (e.g. the runtime-model card) after a successful
 * [patchKeeperConfig] so both this panel and the card reflect the same
 * server-confirmed state without a second fetch. No-op semantics match the
 * panel's own post-save update (`configState.value = loaded(updated)`).
 */
export function applyKeeperConfigUpdate(name: string, updated: KeeperConfig): void {
  configKeeperName.value = name
  configState.value = loaded(updated)
  runtimeDraft.value = initRuntimeDraftFromConfig(updated)
}

export function peekLoadedKeeperConfig(name: string): KeeperConfig | null {
  const state = configState.value
  if (configKeeperName.value !== name || state.status !== 'loaded') return null
  return state.data
}

export function peekKeeperConfigLoadStatus(
  name: string,
): KeeperConfigLoadStatus {
  const state = configState.value
  if (configKeeperName.value !== name) return 'other'
  return state.status
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

// ── Helpers ──────────────────────────────────────────────

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

function InlineToggleRow({ label, value, onChange, dirty = false }: { label: string; value: boolean; onChange: (v: boolean) => void; dirty?: boolean }) {
  return html`
    <div class="flex items-center justify-between py-2.5 px-4 rounded-[var(--r-1)] border ${dirty ? 'border-l-4 border-l-[var(--color-accent-fg)] border-card-border/50' : 'border-card-border/50'} bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-2 v2-monitoring-row">
      <span class="text-sm font-medium text-text-muted">${label}${dirty ? html`<span class="ml-2 text-2xs text-[var(--color-accent-fg)] font-semibold">●</span>` : null}</span>
      <button type="button"
        class="relative inline-flex h-6 w-11 items-center rounded-[var(--r-0)] transition-colors cursor-pointer ${value ? 'bg-ok/60' : 'bg-[var(--color-bg-hover)]'}"
        aria-label=${`${label} ${value ? '비활성화' : '활성화'}`}
        aria-pressed=${value ? 'true' : 'false'}
        onClick=${() => onChange(!value)}
      >
        <span class="inline-block h-4 w-4 rounded-[var(--r-0)] bg-white shadow-1 transition-transform ${value ? 'translate-x-[22px]' : 'translate-x-[3px]'}" />
      </button>
    </div>
  `
}

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

// ── Main component ───────────────────────────────────────

export function KeeperConfigPanel({ keeperName }: { keeperName: string }) {
  const state = configState.value

  // Trigger load on first render or name change
  if (configKeeperName.value !== keeperName || state.status === 'idle') {
    void loadKeeperConfig(keeperName)
  }
  if (goalOptionsState.value.status === 'idle') {
    void loadGoalOptions()
  }

  if (state.status === 'loading') {
    return html`<${LoadingState}>설정 불러오는 중...<//>`
  }

  if (state.status === 'error') {
    return html`<${ErrorState} message=${state.message} />`
  }

  if (state.status !== 'loaded') return null

  const c = state.data
  const isEditing = editMode.value
  const isSaving = saving.value
  const runtimeCanEdit = c.sources.default_source_kind === 'toml' && Boolean(c.sources.default_manifest_path)

  // Initialize runtime draft if not yet set
  if (!runtimeDraft.value) {
    runtimeDraft.value = initRuntimeDraftFromConfig(c)
  }
  const rd = runtimeDraft.value
  const dirtyFlags = rd ? computeRuntimeDirtyFlags(rd, c) : {}

  const runtimeHasChanges = rd ? Object.keys(buildRuntimePayload(rd, c)).length > 0 : false
  const runtimeOptions = rd
    ? dedupeStrings([
        rd.runtime_id,
        c.execution.selected_runtime_id ?? '',
        c.execution.selected_runtime_canonical ?? '',
        ...(c.execution.runtime_options ?? []),
      ])
    : []

  async function saveRuntimeConfig() {
    if (!rd) return
    const payload = buildRuntimePayload(rd, c)
    if (Object.keys(payload).length === 0) return
    runtimeSaving.value = true
    try {
      const updated = await patchKeeperConfig(keeperName, payload)
      configState.value = loaded(updated)
      runtimeDraft.value = initRuntimeDraftFromConfig(updated)
      showToast('런타임 설정 저장 완료', 'success')
    } catch (err) {
      const msg = err instanceof Error ? err.message : '저장 실패'
      showToast(msg, 'error')
    } finally {
      runtimeSaving.value = false
    }
  }

  function resetRuntimeDraft() {
    runtimeDraft.value = initRuntimeDraftFromConfig(c)
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
      configState.value = loaded(updated)
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
    <${EditTextarea} field="short_goal" label="단기 목표" rows=${5} />
    <${EditTextarea} field="mid_goal" label="중기 목표" rows=${5} />
    <${EditTextarea} field="long_goal" label="장기 목표" rows=${5} />
    <${EditTextarea} field="will" label="의지" rows=${4} />
    <${EditTextarea} field="needs" label="필요" rows=${4} />
    <${EditTextarea} field="desires" label="욕구" rows=${4} />
    <${EditTextarea} field="instructions" label="지시사항" rows=${10} />
  ` : html`
    <${MajorSectionHeader} title="프롬프트" />
    <${SectionHeader} size="xs" class="mb-0.5">목표</${SectionHeader}>
    <${LongText} text=${c.prompt.goal} />
    ${c.prompt.short_goal ? html`
      <${SectionHeader} size="xs" class="mt-2 mb-0.5">단기 목표</${SectionHeader}>
      <${LongText} text=${c.prompt.short_goal} />
    ` : null}
    ${c.prompt.mid_goal ? html`
      <${SectionHeader} size="xs" class="mt-2 mb-0.5">중기 목표</${SectionHeader}>
      <${LongText} text=${c.prompt.mid_goal} />
    ` : null}
    ${c.prompt.long_goal ? html`
      <${SectionHeader} size="xs" class="mt-2 mb-0.5">장기 목표</${SectionHeader}>
      <${LongText} text=${c.prompt.long_goal} />
    ` : null}
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
  const knownGoalIds = new Set(goalOptions.map((goal) => goal.id))
  const unknownSelectedGoalIds = goalOptionsLoaded
    ? selectedActiveGoalIds.filter((goalId) => !knownGoalIds.has(goalId))
    : []

  return html`
    <div class="flex flex-col gap-1.5 v2-monitoring-surface">
      ${toolbar}

      <${KeeperToolAccessSummary} config=${c} />

      <${Callout}
        title="편집 가능 범위"
        body="여기서 저장되는 값은 keeper 프롬프트, live override 계층, runtime.toml의 [runtime.assignments]입니다."
      />

      ${promptSection}

      <div class="mt-2">
        <${Callout}
          title="런타임 설정"
          body="Runtime 선택, 실행 범위, 프로액티브, 컴팩션, 핸드오프를 인라인 편집할 수 있습니다. 레지스트리 상태와 소스 경로는 읽기 전용입니다."
        />
      </div>

      ${runtimeHasChanges ? html`
        <div class="sticky top-0 z-20 flex flex-wrap items-center gap-2 p-3 rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-5)] shadow-[var(--shadow-2)] mb-3 v2-monitoring-toolbar">
          <span class="text-xs font-semibold text-accent-fg">변경된 런타임 설정이 있습니다</span>
          <div class="flex-1"></div>
          <button type="button"
            class="${BTN_FILLED_BASE} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)] text-sm v2-monitoring-action"
            onClick=${saveRuntimeConfig}
            disabled=${runtimeSaving.value}
          >${runtimeSaving.value ? '저장 중...' : '런타임 설정 저장'}</button>
          <button type="button"
            class="${BTN_FILLED_BASE} bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)] text-sm v2-monitoring-action"
            title="초기화: 변경한 런타임 설정 draft 를 서버 값으로 되돌립니다"
            onClick=${resetRuntimeDraft}
          >초기화하기</button>
        </div>
      ` : null}

      <${MajorSectionHeader} title="소스" />
      <${Callout}
        title="Runtime 선택"
        body=${runtimeSelectionSummary(c)}
      />
      <${ConfigRow} label="기본 소스" value=${c.sources.default_source_kind || MISSING_DATA_DASH} />
      ${rd && runtimeCanEdit ? html`
        <${InlineSelectRow}
          label="runtime_id"
          value=${rd.runtime_id}
          options=${runtimeOptions}
          onChange=${(value: string) => updateRuntimeDraft('runtime_id', value)}
          dirty=${dirtyFlags.runtime_id}
        />
      ` : html`
        <${ConfigRow} label="선택 runtime" value=${c.execution.selected_runtime_id || MISSING_DATA_DASH} />
      `}
      ${c.execution.selected_runtime_canonical
        && c.execution.selected_runtime_canonical !== c.execution.selected_runtime_id
        ? html`<${ConfigRow}
            label="정규화 runtime"
            value=${c.execution.selected_runtime_canonical}
          />`
        : null}
      <${BoolRow} label="라이브 오버라이드" value=${c.sources.has_live_override} />
      <${SectionHeader} size="xs" class="mt-2 mb-0.5">라이브 메타 경로</${SectionHeader}>
      <${LongText} text=${c.sources.live_meta_path} />
      ${c.sources.default_manifest_path ? html`
        <${SectionHeader} size="xs" class="mt-2 mb-0.5">기본 매니페스트 경로</${SectionHeader}>
        <${LongText} text=${c.sources.default_manifest_path} />
      ` : null}
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">우선순위</${SectionHeader}>
        <${ModelList} models=${c.sources.precedence} />
      </div>
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">오버라이드 필드</${SectionHeader}>
        <${ModelList} models=${c.sources.override_fields} />
      </div>

      <${MajorSectionHeader} title="실행" />
      <${ConfigRow} label="활성 런타임" value=${c.execution.active_model ? 'runtime' : MISSING_DATA_DASH} />
      <${ConfigRow} label="runtime timeout" value=${perProviderTimeoutLabel(c.execution)} />
      <div class="mb-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        runtime fallback 중 마지막 runtime을 제외한 runtime들에만 적용됩니다.
      </div>
      <${BoolRow} label="검증" value=${c.execution.verify} />
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">런타임 후보</${SectionHeader}>
        <${RuntimeList} runtimes=${c.execution.models} />
      </div>

      <${SectionHeader} title="컴팩션" />
      <${ConfigRow} label="프로필" value=${c.compaction.profile || MISSING_DATA_DASH} />
      ${rd ? html`
        <${InlineNumberRow} label="비율 게이트 (%)" value=${Math.round(rd.compaction_ratio_gate * 100)}
          onChange=${(v: number) => updateRuntimeDraft('compaction_ratio_gate', v / 100)}
          min=${0} max=${100} step=${5} suffix="%"
          dirty=${dirtyFlags.compaction_ratio_gate} />
        <${InlineNumberRow} label="메시지 게이트" value=${rd.compaction_message_gate}
          onChange=${(v: number) => updateRuntimeDraft('compaction_message_gate', v)}
          min=${0} max=${500} step=${5}
          dirty=${dirtyFlags.compaction_message_gate} />
        <${InlineNumberRow} label="토큰 게이트" value=${rd.compaction_token_gate}
          onChange=${(v: number) => updateRuntimeDraft('compaction_token_gate', v)}
          min=${0} max=${1000000} step=${1000} suffix="tok"
          dirty=${dirtyFlags.compaction_token_gate} />
        <${InlineNumberRow} label="쿨다운 (초)" value=${rd.compaction_cooldown_sec}
          onChange=${(v: number) => updateRuntimeDraft('compaction_cooldown_sec', v)}
          min=${0} max=${3600} step=${30} suffix="s"
          dirty=${dirtyFlags.compaction_cooldown_sec} />
      ` : html`
        <${ConfigRow} label="비율 게이트" value=${formatPct(c.compaction.ratio_gate)} />
        <${ConfigRow} label="메시지 게이트" value=${String(c.compaction.message_gate)} />
        <${ConfigRow} label="토큰 게이트" value=${formatTokens(c.compaction.token_gate)} />
        <${ConfigRow} label="쿨다운" value=${c.compaction.cooldown_sec + 's'} />
      `}

      <${SectionHeader} title="실행 범위" />
      ${rd ? html`
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
        ${rd.sandbox_profile === 'docker' ? html`
          <${SetupGuideCard} connectorId="sandbox_hardened" />
        ` : null}
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

      <${SectionHeader} title="프로액티브" />
      ${rd ? html`
        <${InlineToggleRow} label="활성" value=${rd.proactive_enabled}
          onChange=${(v: boolean) => updateRuntimeDraft('proactive_enabled', v)}
          dirty=${dirtyFlags.proactive_enabled} />
        <${InlineNumberRow} label="유휴 트리거 (초)" value=${rd.proactive_idle_sec}
          onChange=${(v: number) => updateRuntimeDraft('proactive_idle_sec', v)}
          min=${10} max=${3600} step=${10} suffix="s"
          dirty=${dirtyFlags.proactive_idle_sec} />
        <${InlineNumberRow} label="쿨다운 (초)" value=${rd.proactive_cooldown_sec}
          onChange=${(v: number) => updateRuntimeDraft('proactive_cooldown_sec', v)}
          min=${10} max=${3600} step=${10} suffix="s"
          dirty=${dirtyFlags.proactive_cooldown_sec} />
      ` : html`
        <${BoolRow} label="활성" value=${c.proactive.enabled} />
        <${ConfigRow} label="유휴 트리거" value=${c.proactive.idle_sec + 's'} />
        <${ConfigRow} label="쿨다운" value=${c.proactive.cooldown_sec + 's'} />
      `}

      <${SectionHeader} title="런타임" />
      <${BoolRow} label="일시정지" value=${c.runtime.paused} />
      <${BoolRow} label="자동 부팅 등록" value=${c.runtime.registered} />
      <${BoolRow} label="킵얼라이브 실행" value=${c.runtime.keepalive_running} />
      <${ConfigRow} label="레지스트리 상태" value=${c.runtime.registry_state || MISSING_DATA_DASH} />
      <${ConfigRow} label="파이버 상태" value=${c.runtime.fiber_health || MISSING_DATA_DASH} />

      <${SectionHeader} title="네임스페이스 조율" />
      <div class="py-2 px-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm mb-1.5">
        <div class="flex items-center justify-between gap-3 mb-2">
          <${MutedLabel}>active_goal_ids</${MutedLabel}>
          <span class="text-3xs text-[var(--color-fg-muted)]">${selectedActiveGoalIds.length}개 선택</span>
        </div>
        ${goalState.status === 'loading' ? html`
          <div class="text-2xs text-[var(--color-fg-muted)]" role="status">목표 목록 로딩 중...</div>
        ` : goalState.status === 'error' ? html`
          <div class="text-2xs text-[var(--color-status-err)]">${goalState.message}</div>
        ` : goalOptions.length > 0 && rd ? html`
          <div class="grid gap-1.5">
            ${goalOptions.map((goal) => {
              const checked = rd.active_goal_ids.includes(goal.id)
              return html`
                <label class="flex items-center gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] px-2 py-1.5 text-xs text-[var(--color-fg-secondary)]">
                  <input
                    type="checkbox"
                    checked=${checked}
                    onChange=${(event: Event) => {
                      toggleRuntimeActiveGoal(goal.id, (event.currentTarget as HTMLInputElement).checked)
                    }}
                  />
                  <span class="min-w-[4.5rem] font-mono text-3xs text-[var(--color-fg-muted)]">${goal.horizon}</span>
                  <span class="flex-1 truncate">${goal.title}</span>
                  <span class="font-mono text-3xs text-[var(--color-fg-disabled)]">${goal.id}</span>
                </label>
              `
            })}
          </div>
        ` : selectedActiveGoalIds.length > 0 ? html`
          <${ModelList} models=${selectedActiveGoalIds} />
        ` : html`
          <div class="text-2xs text-[var(--color-fg-muted)]">활성 목표가 연결되어 있지 않습니다.</div>
        `}
        ${unknownSelectedGoalIds.length > 0 ? html`
          <div class="mt-2 text-2xs text-[var(--color-status-warn)]">
            Goal Store에서 찾을 수 없는 연결: ${unknownSelectedGoalIds.join(', ')}
          </div>
        ` : null}
      </div>
      ${isVerifierRoleKeeper(c.workspace.mention_targets) ? html`
      <div class="mb-2 flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-3 py-2">
        <span class="rounded-[var(--r-1)] border border-[var(--accent-40)] bg-[var(--accent-5)] px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-accent-fg">검증자</span>
        <span class="text-2xs text-text-body">이 keeper는 task completion_contract를 독립 실측하는 검증자 역할입니다.</span>
      </div>
      ` : null}
      ${c.workspace.mention_targets.length > 0 ? html`
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">멘션 대상</${SectionHeader}>
        <${ModelList} models=${c.workspace.mention_targets} />
      </div>
      ` : null}
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">참여 네임스페이스</${SectionHeader}>
        <${ModelList} models=${c.workspace.bound_workspace_ids} />
      </div>

      <${SectionHeader} title="핸드오프" />
      ${rd ? html`
        <${InlineToggleRow} label="자동" value=${rd.auto_handoff}
          onChange=${(v: boolean) => updateRuntimeDraft('auto_handoff', v)}
          dirty=${dirtyFlags.auto_handoff} />
        <${InlineNumberRow} label="임계값 (%)" value=${Math.round(rd.handoff_threshold * 100)}
          onChange=${(v: number) => updateRuntimeDraft('handoff_threshold', v / 100)}
          min=${0} max=${100} step=${5} suffix="%"
          dirty=${dirtyFlags.handoff_threshold} />
        <${InlineNumberRow} label="쿨다운 (초)" value=${rd.handoff_cooldown_sec}
          onChange=${(v: number) => updateRuntimeDraft('handoff_cooldown_sec', v)}
          min=${0} max=${3600} step=${30} suffix="s"
          dirty=${dirtyFlags.handoff_cooldown_sec} />
      ` : html`
        <${BoolRow} label="자동" value=${c.handoff.auto} />
        </div>
        <${ConfigRow} label="임계값" value=${formatPct(c.handoff.threshold)} />
        <${ConfigRow} label="쿨다운" value=${c.handoff.cooldown_sec + 's'} />
      `}

      ${runtimeHasChanges ? html`
        <div class="sticky bottom-4 z-20 flex flex-wrap items-center gap-2 mt-4 mb-2 p-4 rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-5)] shadow-[var(--shadow-2)]">
          <span class="text-sm font-semibold text-accent-fg">변경된 설정을 저장하세요</span>
          <div class="flex-1"></div>
          <button type="button"
            class="${BTN_FILLED_BASE} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)] text-sm"
            onClick=${saveRuntimeConfig}
            disabled=${runtimeSaving.value}
          >${runtimeSaving.value ? '저장 중...' : '런타임 설정 저장'}</button>
          <button type="button"
            class="${BTN_FILLED_BASE} bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)] text-sm"
            title="초기화: 변경한 런타임 설정 draft 를 서버 값으로 되돌립니다"
            onClick=${resetRuntimeDraft}
          >초기화하기</button>
        </div>
      ` : null}

      ${c.hooks ? (() => {
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
            class="w-full text-left rounded-[var(--r-3)] border border-[var(--accent-20)] bg-[var(--accent-5)] px-4 py-3 mt-8 mb-4 flex items-center gap-2 shadow-[var(--shadow-1)] v2-monitoring-panel"
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
              : visibleEntries.map(([name, slot]) => html`
                  <div class="flex items-start gap-2 py-2 px-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 mb-1.5">
                    <span class="mt-1 w-2 h-2 rounded-full shrink-0 ${slot.active ? 'bg-[var(--color-status-ok)] shadow-[0_0_6px_var(--ok-48)]' : 'bg-[var(--color-fg-disabled)]'}" aria-hidden="true"></span>
                    <div class="flex-1 min-w-0">
                      <div class="flex justify-between">
                        <span class="text-xs font-semibold text-text-strong">${name}</span>
                        <span class="text-3xs text-text-muted">${slot.source}</span>
                      </div>
                      ${hookSlotDetails(slot).length > 0 ? html`
                        <div class="flex flex-wrap gap-1 mt-1">
                          ${hookSlotDetails(slot).map((d: string) => html`
                            <span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] ${d.endsWith('_off') ? 'bg-[var(--color-bg-hover)] text-[var(--color-fg-disabled)]' : 'bg-[var(--accent-10)] text-[var(--color-accent-fg)] opacity-80'}">${d}</span>
                          `)}
                        </div>
                      ` : null}
                    </div>
                  </div>
                `)}
            <${ConfigRow} label="거부 목록 수" value=${String(c.hooks.deny_list.length)} />
            <${ConfigRow} label="파괴 검사 도구" value=${formatHookDestructiveTools(c.hooks.destructive_check_tools)} />
            <${ConfigRow} label="비용 예산 (텔레메트리 · 미강제)" value=${c.hooks.cost_budget.active ? formatCost(c.hooks.cost_budget.max_cost_usd ?? 0) : '미설정'} />
          ` : null}
        `
      })() : null}

      ${'' /* Metrics removed — duplicates KpiGrid, MetricsCharts, and header model badge */}
    </div>
  `
}
