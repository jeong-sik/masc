// Keeper config panel -- structured config viewer with inline editing.
// Fetches /api/v1/keepers/:name/config and renders grouped sections.
// Redesigned: clean section headers, consistent row styling, proper form controls.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import {
  fetchCascadeProfiles,
  fetchDashboardGoalsTree,
  fetchKeeperConfig,
  patchKeeperConfig,
  updateKeeperCascade,
  type CascadeInvalidProfile,
} from '../api/dashboard'
import type { KeeperConfigUpdatePayload } from '../api/dashboard'
import type { GoalTreeNode, KeeperConfig, KeeperHookSlot } from '../types'
import type { KeeperConfigLoadStatus } from './keeper-detail-source'
import { formatTokens, formatPct, formatCost } from '../lib/format-number'
import { isVerifierRoleKeeper } from '../lib/keeper-utils'
import { showToast } from './common/toast'
import { ErrorState, LoadingState } from './common/feedback-state'
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
const configState = configResource.state
const configKeeperName = signal<string>('')
type CascadeProfileCatalog = {
  profiles: string[]
  invalid_profiles: CascadeInvalidProfile[]
}
const cascadeProfilesResource = createAsyncResource<CascadeProfileCatalog>()
const cascadeProfilesState = cascadeProfilesResource.state
const goalOptionsResource = createAsyncResource<GoalTreeNode[]>()
const goalOptionsState = goalOptionsResource.state
const editMode = signal(false)
const saving = signal(false)
const saveError = signal<string | null>(null)
const cascadeSaving = signal(false)
const cascadeSaveError = signal<string | null>(null)

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

// ── Hook slot filter ─────────────────────────────────────

export type HookSlotEntry = readonly [name: string, slot: KeeperHookSlot]

/**
 * Pure filter for hook slot entries.
 *
 * Case-insensitive substring match against, in order:
 * - slot name (the `Record<string, KeeperHookSlot>` key)
 * - `slot.source`
 * - any string in `slot.gates`, `slot.effects`, or `slot.features`
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
    const tags = slot.gates ?? slot.effects ?? slot.features ?? []
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
  if (draft.goal !== orig.prompt.goal) payload.goal = draft.goal
  if (draft.short_goal !== orig.prompt.short_goal) payload.short_goal = draft.short_goal
  if (draft.mid_goal !== orig.prompt.mid_goal) payload.mid_goal = draft.mid_goal
  if (draft.long_goal !== orig.prompt.long_goal) payload.long_goal = draft.long_goal
  if (draft.will !== orig.prompt.will) payload.will = draft.will
  if (draft.needs !== orig.prompt.needs) payload.needs = draft.needs
  if (draft.desires !== orig.prompt.desires) payload.desires = draft.desires
  if (draft.instructions !== orig.prompt.instructions) payload.instructions = draft.instructions
  return payload
}

// Runtime config draft for sandbox/proactive/compaction/handoff inline editing
export type SandboxProfile = 'local' | 'docker'
export type SandboxNetworkMode = 'none' | 'inherit'
export type SharedMemoryScope = 'disabled' | 'room'

export type RuntimeDraft = {
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
  return raw === 'room' ? 'room' : 'disabled'
}

export function initRuntimeDraftFromConfig(c: KeeperConfig): RuntimeDraft {
  return {
    sandbox_profile: coerceSandboxProfile(c.sandbox_profile),
    active_goal_ids: c.coordination.active_goal_ids.length > 0
      ? c.coordination.active_goal_ids
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
  const origActiveGoalIds = orig.coordination.active_goal_ids.length > 0
    ? orig.coordination.active_goal_ids
    : orig.active_goal_ids
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
  cascadeProfilesResource.reset()
  goalOptionsResource.reset()
  configKeeperName.value = ''
  editMode.value = false
  editDraft.value = null
  saveError.value = null
  cascadeSaveError.value = null
  cascadeSaving.value = false
  runtimeDraft.value = null
  runtimeSaving.value = false
  hookFilterQuery.value = ''
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

async function loadCascadeProfiles(options?: { force?: boolean }): Promise<void> {
  const force = options?.force === true
  if (!force && cascadeProfilesState.value.status === 'loaded') return
  if (force) cascadeProfilesResource.reset()
  await cascadeProfilesResource.load(() => fetchCascadeProfiles())
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
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-1.5">
      <${MutedLabel}>${label}</${MutedLabel}>
      <span class="text-xs font-semibold text-text-strong">${value}</span>
    </div>
  `
}

function BoolRow({ label, value }: { label: string; value: boolean }) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
      <span class="text-xs text-[var(--color-fg-muted)]">${label}</span>
      <${BoolBadge} value=${value} />
    </div>
  `
}

function formatSeconds(value: number): string {
  if (!Number.isFinite(value)) return '--'
  return value >= 60 ? `${(value / 60).toFixed(1)}m` : `${value.toFixed(value % 1 === 0 ? 0 : 1)}s`
}

function perProviderTimeoutLabel(execution: KeeperConfig['execution']): string {
  if (
    execution.per_provider_timeout_mode === 'override'
    && typeof execution.per_provider_timeout_sec === 'number'
  ) {
    return formatSeconds(execution.per_provider_timeout_sec)
  }
  return 'turn budget heuristic'
}

function MajorSectionHeader({ title }: { title: string }) {
  return html`
    <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-accent-fg mt-6 mb-3 pb-1.5 border-b border-[var(--accent-20)] flex items-center gap-2">
      <${StatusDot} size="xs" class="bg-[var(--accent-50)] shadow-[0_0_8px_rgb(var(--info-glow)/0.6)]" />
      ${title}
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
    <div class="rounded-[var(--r-1)] border px-3 py-3 shadow-[var(--shadow-1)] ${toneClass}">
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
    return value.length > 0 ? value.join(', ') : '--'
  }
  const text = value.trim()
  return text !== '' ? text : '--'
}

function ModelList({ models }: { models: string[] }) {
  if (models.length === 0) return html`<span class="text-2xs text-text-muted italic">none</span>`
  return html`
    <div class="flex flex-wrap gap-1.5">
      ${models.map(m => html`<span class="inline-flex items-center py-1 px-2.5 rounded-[var(--r-1)] text-2xs font-semibold bg-[var(--accent-10)] text-accent-fg border border-[var(--accent-20)] shadow-1 hover:bg-[var(--accent-20)] transition-colors cursor-default">${m}</span>`)}
    </div>
  `
}

function LongText({ text, truncateAt = 200 }: { text: string; truncateAt?: number | null }) {
  if (!text || text.trim() === '') return html`<span class="text-2xs text-text-muted italic">--</span>`
  const truncated =
    truncateAt !== null && truncateAt >= 0 && text.length > truncateAt
      ? text.slice(0, truncateAt) + '...'
      : text
  return html`<div class="text-xs text-text-body whitespace-pre-wrap max-h-35 overflow-y-auto custom-scrollbar border border-card-border bg-card/40 backdrop-blur-sm p-3 rounded-[var(--r-1)] mt-1.5 leading-relaxed shadow-inset hover:bg-card/60 transition-colors">${truncated}</div>`
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
    <div class="mt-2">
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

const fieldStyle = 'w-full bg-card/60 backdrop-blur-sm text-text-strong text-sm border border-card-border rounded-[var(--r-1)] py-2 px-3 font-sans focus:outline-none focus:border-accent-fg/50 focus:ring-1 focus:ring-accent-fg/50 transition-[border-color,box-shadow] duration-[var(--t-med)] shadow-inset'

// ── Inline editing components for runtime config ────────

function InlineToggleRow({ label, value, onChange }: { label: string; value: boolean; onChange: (v: boolean) => void }) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-1.5">
      <${MutedLabel}>${label}</${MutedLabel}>
      <button type="button"
        class="relative inline-flex h-5 w-9 items-center rounded-[var(--r-0)] transition-colors cursor-pointer ${value ? 'bg-ok/60' : 'bg-[var(--color-bg-hover)]'}"
        aria-label=${`${label} ${value ? '비활성화' : '활성화'}`}
        aria-pressed=${value ? 'true' : 'false'}
        onClick=${() => onChange(!value)}
      >
        <span class="inline-block h-3.5 w-3.5 rounded-[var(--r-0)] bg-white shadow-1 transition-transform ${value ? 'translate-x-[18px]' : 'translate-x-[3px]'}" />
      </button>
    </div>
  `
}

function InlineNumberRow({ label, value, onChange, min, max, step, suffix }: {
  label: string; value: number; onChange: (v: number) => void;
  min?: number; max?: number; step?: number; suffix?: string
}) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-1.5">
      <${MutedLabel}>${label}</${MutedLabel}>
      <div class="flex items-center gap-1.5">
        <input type="number"
          aria-label=${label}
          class="w-20 text-right bg-card/60 text-text-strong text-xs font-semibold border border-card-border rounded-[var(--r-1)] py-1 px-2 focus:outline-none focus:border-accent-fg/50 transition-colors"
          value=${value}
          min=${min}
          max=${max}
          step=${step}
          onInput=${(e: Event) => {
            const v = parseFloat((e.target as HTMLInputElement).value)
            if (!isNaN(v)) onChange(v)
          }}
        />
        ${suffix ? html`<span class="text-3xs text-text-dim w-4">${suffix}</span>` : null}
      </div>
    </div>
  `
}

function InlineSelectRow({
  label,
  value,
  options,
  onChange,
}: {
  label: string
  value: string
  options: readonly string[]
  onChange: (v: string) => void
}) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-4)] border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-1.5 gap-3">
      <${MutedLabel}>${label}</${MutedLabel}>
      <select
        aria-label=${label}
        class="text-xs bg-card/60 border border-card-border rounded-[var(--r-1)] px-2 py-1 text-text-strong"
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

function EditTextarea({ field, label, rows = 3 }: { field: keyof EditDraft; label: string; rows?: number }) {
  const d = editDraft.value
  if (!d) return null
  const val = d[field] as string
  return html`
    <div class="mt-3">
      <div class="text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">${label}</div>
      <textarea
        aria-label=${label}
        class="${fieldStyle} resize-y custom-scrollbar"
        rows=${rows}
        value=${val}
        onInput=${(e: Event) => updateDraft(field, (e.target as HTMLTextAreaElement).value)}
      />
    </div>
  `
}

function sandboxAnchorText(c: KeeperConfig): string {
  const basePath = c.sandbox_environment?.base_path ?? '--'
  const projectRoot = c.sandbox_environment?.project_root ?? '--'
  return `상대 allowed_paths는 project root ${projectRoot} 기준으로 해석됩니다. config base path는 ${basePath} 입니다.`
}

function dockerStatusLabel(c: KeeperConfig): string {
  if (c.sandbox_profile === 'docker') return 'docker'
  if (c.sandbox_environment?.docker_playground_enabled) return 'local + docker_playground'
  return 'local'
}

function cascadeCatalogSourceLabel(c: KeeperConfig): string {
  switch (c.sources.cascade_catalog_source_kind) {
    case 'toml':
      return 'cascade.toml (authoring SSOT)'
    case 'json':
      return 'retired json source'
    default:
      return '--'
  }
}

function cascadeSelectionSummary(c: KeeperConfig): string {
  const selected = c.execution.selected_cascade_name || '--'
  const canonical = c.execution.selected_cascade_canonical || selected
  const manifest = c.sources.default_manifest_path
  const catalog = c.sources.cascade_catalog_source_path
  const selectionPart = manifest
    ? `선택은 ${manifest} 에서 관리됩니다.`
    : '선택 source 경로를 확인할 수 없습니다.'
  const catalogPart = catalog
    ? `profile 정의는 ${catalog} 에서 materialize됩니다.`
    : 'profile catalog source 경로를 확인할 수 없습니다.'
  const canonicalPart =
    canonical !== '' && canonical !== selected
      ? ` 현재 값 ${selected} 는 runtime에서 ${canonical} 으로 정규화됩니다.`
      : ''
  return `이 keeper는 cascade profile ${selected} 를 사용합니다. ${selectionPart} ${catalogPart}${canonicalPart}`
}

// ── Main component ───────────────────────────────────────

export function KeeperConfigPanel({ keeperName }: { keeperName: string }) {
  const state = configState.value
  const cascadeState = cascadeProfilesState.value

  // Trigger load on first render or name change
  if (configKeeperName.value !== keeperName || state.status === 'idle') {
    void loadKeeperConfig(keeperName)
  }
  if (cascadeState.status === 'idle') {
    void loadCascadeProfiles()
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

  // Initialize runtime draft if not yet set
  if (!runtimeDraft.value) {
    runtimeDraft.value = initRuntimeDraftFromConfig(c)
  }
  const rd = runtimeDraft.value

  const runtimeHasChanges = rd ? Object.keys(buildRuntimePayload(rd, c)).length > 0 : false

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

  async function saveCascadeSelection(nextCascadeName: string) {
    const currentCascade = c.execution.selected_cascade_name || ''
    if (!nextCascadeName || nextCascadeName === currentCascade) return
    cascadeSaving.value = true
    cascadeSaveError.value = null
    try {
      await updateKeeperCascade(keeperName, nextCascadeName)
      await loadKeeperConfig(keeperName, { force: true })
      await loadCascadeProfiles({ force: true })
      showToast(`cascade 변경 완료: ${nextCascadeName}`, 'success')
    } catch (err) {
      const message = err instanceof Error ? err.message : 'cascade 변경 실패'
      cascadeSaveError.value = message
      showToast(message, 'error')
    } finally {
      cascadeSaving.value = false
    }
  }

  async function saveConfig() {
    const draft = editDraft.value
    if (!draft) return
    const payload = buildPayload(draft, c)
    if (Object.keys(payload).length === 0) {
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
      showToast('프롬프트 저장 완료', 'success')
    } catch (err) {
      saveError.value = err instanceof Error ? err.message : '저장 실패'
    } finally {
      saving.value = false
    }
  }

  const btnBase = 'py-1.5 px-4 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none'

  // --- Toolbar ---
  const toolbar = html`
    <div class="flex gap-2 items-center mb-3">
      ${isEditing ? html`
        <button type="button"
          class="${btnBase} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)]"
          onClick=${saveConfig}
          disabled=${isSaving}
        >${isSaving ? '저장 중...' : '저장'}</button>
        <button type="button"
          class="${btnBase} bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)]"
          onClick=${cancelEdit}
          disabled=${isSaving}
        >취소</button>
      ` : html`
        <button type="button"
          class="${btnBase} bg-[var(--purple)] text-[var(--color-bg-0)]"
          onClick=${enterEditMode}
        >편집</button>
      `}
      ${saveError.value ? html`<span class="text-xs text-[var(--color-status-err)]" role="alert">${saveError.value}</span>` : null}
    </div>
  `

  // --- Prompt section (editable) ---
  const promptSection = isEditing ? html`
    <${MajorSectionHeader} title="프롬프트 (편집)" />
    <${EditTextarea} field="goal" label="목표" rows=${3} />
    <${EditTextarea} field="short_goal" label="단기 목표" rows=${2} />
    <${EditTextarea} field="mid_goal" label="중기 목표" rows=${2} />
    <${EditTextarea} field="long_goal" label="장기 목표" rows=${2} />
    <${EditTextarea} field="will" label="의지" rows=${2} />
    <${EditTextarea} field="needs" label="필요" rows=${2} />
    <${EditTextarea} field="desires" label="욕구" rows=${2} />
    <${EditTextarea} field="instructions" label="지시사항" rows=${4} />
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
    <${SectionHeader} size="xs" class="mt-3 mb-0.5">시스템 프롬프트 블록</${SectionHeader}>
    <${PromptBlock} title="헌법" block=${c.prompt.system_prompt_blocks.constitution} />
    <${PromptBlock} title="세계관" block=${c.prompt.system_prompt_blocks.world} />
    <${PromptBlock} title="능력" block=${c.prompt.system_prompt_blocks.capabilities} />
    <details class="mt-3">
      <summary class="cursor-pointer py-2 px-3 text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)] list-none select-none rounded-[var(--r-1)] hover:bg-[var(--color-bg-surface)] transition-colors">컴파일된 시스템 프롬프트 보기</summary>
      <${LongText} text=${c.prompt.effective_system_prompt} truncateAt=${null} />
    </details>
  `

  const cascadeProfiles = cascadeState.status === 'loaded' ? cascadeState.data.profiles : []
  const invalidCascadeProfiles =
    cascadeState.status === 'loaded' ? cascadeState.data.invalid_profiles : []
  const cascadeOptions = [
    ...cascadeProfiles,
    ...invalidCascadeProfiles.map((profile) => profile.name),
  ]
  const currentCascade = c.execution.selected_cascade_name || ''
  const hasCascadeSelector =
    currentCascade !== '' || cascadeOptions.length > 0 || cascadeState.status === 'loading'
  const invalidCascadeSummary = invalidCascadeProfiles
    .map((profile) => `${profile.name}: ${profile.errors.join('; ')}`)
    .join(' | ')
  const goalState = goalOptionsState.value
  const goalOptionsLoaded = goalState.status === 'loaded'
  const goalOptions: GoalTreeNode[] = goalOptionsLoaded ? goalState.data : []
  const selectedActiveGoalIds = rd
    ? rd.active_goal_ids
    : (c.coordination.active_goal_ids.length > 0 ? c.coordination.active_goal_ids : c.active_goal_ids)
  const knownGoalIds = new Set(goalOptions.map((goal) => goal.id))
  const unknownSelectedGoalIds = goalOptionsLoaded
    ? selectedActiveGoalIds.filter((goalId) => !knownGoalIds.has(goalId))
    : []

  return html`
    <div class="flex flex-col gap-1.5">
      ${toolbar}

      <${KeeperToolAccessSummary} config=${c} />

      <${Callout}
        title="편집 가능 범위"
        body="여기서 저장되는 값은 keeper 프롬프트와 live override 계층입니다. 활성 모델은 keeper별 설정이 아니라 resolved config root의 cascade.toml 해석 결과로 결정됩니다."
      />

      ${promptSection}

      <div class="mt-2">
        <${Callout}
          title="런타임 설정"
          body="실행 범위 섹션에서 sandbox_profile, network_mode, allowed_paths를 저장할 수 있습니다. 프로액티브, 컴팩션, 핸드오프도 인라인 편집 가능하고, 소스/실행/런타임/조율은 읽기 전용입니다."
        />
      </div>

      <${MajorSectionHeader} title="소스" />
      <${Callout}
        title="Cascade 선택"
        body=${hasCascadeSelector
          ? '이 selector는 keeper TOML의 cascade_name 을 바꿉니다. catalog authoring source와 generated runtime JSON 경로는 아래 읽기 전용 메타데이터를 보세요.'
          : cascadeSelectionSummary(c)}
      />
      ${hasCascadeSelector
        ? html`
            <label class="flex flex-col gap-1.5 py-2 px-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm mb-1.5">
              <${MutedLabel}>활성 cascade profile</${MutedLabel}>
              <select
                class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-3 py-2 text-xs font-semibold text-text-strong disabled:opacity-60"
                value=${currentCascade}
                disabled=${cascadeSaving.value || cascadeState.status === 'loading' || cascadeOptions.length === 0}
                onChange=${(event: Event) => {
                  const next = (event.currentTarget as HTMLSelectElement).value
                  void saveCascadeSelection(next)
                }}
              >
                ${currentCascade !== '' && !cascadeOptions.includes(currentCascade)
                  ? html`<option value=${currentCascade}>${currentCascade}</option>`
                  : null}
                ${cascadeOptions.map((profileName) => html`
                  <option value=${profileName}>${profileName}</option>
                `)}
              </select>
              <span class="text-2xs text-[var(--color-fg-disabled)]">
                ${cascadeSaving.value
                  ? 'cascade_name 저장 중...'
                  : cascadeState.status === 'loading'
                    ? '사용 가능한 cascade profile 로딩 중...'
                    : '변경 시 keeper manifest의 cascade_name 이 즉시 갱신됩니다.'}
              </span>
              ${cascadeSaveError.value
                ? html`<span class="text-2xs text-[var(--color-status-err)]" role="alert">${cascadeSaveError.value}</span>`
                : null}
              ${invalidCascadeProfiles.length > 0
                ? html`<span class="text-2xs text-[var(--color-status-warn)]">invalid profile ${invalidCascadeProfiles.length}개: ${invalidCascadeSummary}</span>`
                : null}
            </label>
          `
        : null}
      <${ConfigRow} label="기본 소스" value=${c.sources.default_source_kind || '--'} />
      <${ConfigRow} label="선택 cascade" value=${c.execution.selected_cascade_name || '--'} />
      ${c.execution.selected_cascade_canonical
        && c.execution.selected_cascade_canonical !== c.execution.selected_cascade_name
        ? html`<${ConfigRow}
            label="정규화 cascade"
            value=${c.execution.selected_cascade_canonical}
          />`
        : null}
      <${ConfigRow} label="catalog source" value=${cascadeCatalogSourceLabel(c)} />
      <${BoolRow} label="라이브 오버라이드" value=${c.sources.has_live_override} />
      <${SectionHeader} size="xs" class="mt-2 mb-0.5">라이브 메타 경로</${SectionHeader}>
      <${LongText} text=${c.sources.live_meta_path} />
      ${c.sources.default_manifest_path ? html`
        <${SectionHeader} size="xs" class="mt-2 mb-0.5">기본 매니페스트 경로</${SectionHeader}>
        <${LongText} text=${c.sources.default_manifest_path} />
      ` : null}
      ${c.sources.cascade_catalog_source_path ? html`
        <${SectionHeader} size="xs" class="mt-2 mb-0.5">캐스케이드 카탈로그 출처</${SectionHeader}>
        <${LongText} text=${c.sources.cascade_catalog_source_path} />
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
      <${ConfigRow} label="활성 모델" value=${c.execution.active_model || '--'} />
      <${ConfigRow} label="provider timeout" value=${perProviderTimeoutLabel(c.execution)} />
      <div class="mb-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        cascade fallback 중 마지막 provider를 제외한 provider들에만 적용됩니다.
      </div>
      <${BoolRow} label="검증" value=${c.execution.verify} />
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">모델</${SectionHeader}>
        <${ModelList} models=${c.execution.models} />
      </div>

      <${SectionHeader} title="컴팩션" />
      <${ConfigRow} label="프로필" value=${c.compaction.profile || '--'} />
      ${rd ? html`
        <${InlineNumberRow} label="비율 게이트 (%)" value=${Math.round(rd.compaction_ratio_gate * 100)}
          onChange=${(v: number) => updateRuntimeDraft('compaction_ratio_gate', v / 100)}
          min=${0} max=${100} step=${5} suffix="%" />
        <${InlineNumberRow} label="메시지 게이트" value=${rd.compaction_message_gate}
          onChange=${(v: number) => updateRuntimeDraft('compaction_message_gate', v)}
          min=${0} max=${500} step=${5} />
        <${ConfigRow} label="토큰 게이트" value=${formatTokens(c.compaction.token_gate)} />
        <${InlineNumberRow} label="쿨다운 (초)" value=${rd.compaction_cooldown_sec}
          onChange=${(v: number) => updateRuntimeDraft('compaction_cooldown_sec', v)}
          min=${0} max=${3600} step=${30} suffix="s" />
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
        />
        <${InlineSelectRow}
          label="network_mode"
          value=${rd.network_mode}
          options=${rd.sandbox_profile === 'docker' ? ['inherit', 'none'] as const : ['inherit'] as const}
          onChange=${(value: string) => updateRuntimeDraft('network_mode', value as SandboxNetworkMode)}
        />
        <div class="py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
          <div class="flex items-center justify-between mb-1">
            <span class="text-xs text-[var(--color-fg-secondary)]">allowed_paths</span>
            <span class="text-3xs text-[var(--color-fg-muted)]">한 줄에 하나씩. 명시 경로만 허용됩니다.</span>
          </div>
          <textarea aria-label="allowed_paths" class="w-full text-xs font-mono bg-[var(--color-bg-hover)] border border-[var(--color-border-default)] rounded-[var(--r-1)] px-2 py-1.5 text-[var(--color-fg-secondary)] resize-y"
            rows=${3}
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
          body=${sandboxAnchorText(c)}
        />
        ${rd.sandbox_profile === 'docker' ? html`
          <${SetupGuideCard} connectorId="sandbox_hardened" />
        ` : null}
      ` : html`
        <${ConfigRow} label="sandbox_profile" value=${c.sandbox_profile ?? 'local'} />
        <${ConfigRow} label="network_mode" value=${c.network_mode ?? 'inherit'} />

        <${ConfigRow} label="effective_sandbox_image" value=${c.effective_sandbox_image || '--'} />
        <${ConfigRow} label="allowed_paths" value=${(c.allowed_paths ?? []).join(', ') || '(computed default)'} />
        <${ConfigRow} label="effective_paths" value=${(c.effective_allowed_paths ?? []).join(', ') || '(전체 허용)'} />
        <${ConfigRow} label="private_workspace_root" value=${c.private_workspace_root || '--'} />
      `}

      ${c.sandbox_environment ? html`
        <${SectionHeader} title="샌드박스 환경" />
        <${ConfigRow} label="docker_status" value=${dockerStatusLabel(c)} />
        <${ConfigRow} label="config_base_path" value=${c.sandbox_environment.base_path || '--'} />
        <${ConfigRow} label="project_root" value=${c.sandbox_environment.project_root || '--'} />
        <${BoolRow} label="docker_playground" value=${c.sandbox_environment.docker_playground_enabled} />
        <${ConfigRow} label="docker_container" value=${c.sandbox_environment.docker_container_name || '--'} />
        <${ConfigRow} label="container_playground_root" value=${c.sandbox_environment.container_playground_root || '--'} />
        <${ConfigRow} label="sandbox_docker_image" value=${c.sandbox_environment.docker_image || '--'} />
        <${ConfigRow} label="sandbox_memory" value=${c.sandbox_environment.memory || '--'} />
        <${ConfigRow} label="sandbox_pids_limit" value=${String(c.sandbox_environment.pids_limit ?? '--')} />
        <${ConfigRow} label="sandbox_tmpfs_size" value=${c.sandbox_environment.tmpfs_size || '--'} />
        <${ConfigRow} label="sandbox_seccomp_profile" value=${c.sandbox_environment.seccomp_profile || '--'} />
        <${BoolRow} label="require_rootless" value=${c.sandbox_environment.require_rootless} />
        <${BoolRow} label="require_userns" value=${c.sandbox_environment.require_userns} />
        ${c.sandbox_last_error ? html`
          <${Callout}
            title="샌드박스 오류"
            body=${c.sandbox_last_error}
            tone="warn"
          />
        ` : null}
      ` : null}

      <${SectionHeader} title="프로액티브" />
      ${rd ? html`
        <${InlineToggleRow} label="활성" value=${rd.proactive_enabled}
          onChange=${(v: boolean) => updateRuntimeDraft('proactive_enabled', v)} />
        <${InlineNumberRow} label="유휴 트리거 (초)" value=${rd.proactive_idle_sec}
          onChange=${(v: number) => updateRuntimeDraft('proactive_idle_sec', v)}
          min=${10} max=${3600} step=${10} suffix="s" />
        <${InlineNumberRow} label="쿨다운 (초)" value=${rd.proactive_cooldown_sec}
          onChange=${(v: number) => updateRuntimeDraft('proactive_cooldown_sec', v)}
          min=${10} max=${3600} step=${10} suffix="s" />
      ` : html`
        <${BoolRow} label="활성" value=${c.proactive.enabled} />
        <${ConfigRow} label="유휴 트리거" value=${c.proactive.idle_sec + 's'} />
        <${ConfigRow} label="쿨다운" value=${c.proactive.cooldown_sec + 's'} />
      `}

      <${SectionHeader} title="런타임" />
      <${BoolRow} label="일시정지" value=${c.runtime.paused} />
      <${BoolRow} label="자동 부팅 등록" value=${c.runtime.registered} />
      <${BoolRow} label="킵얼라이브 실행" value=${c.runtime.keepalive_running} />
      <${ConfigRow} label="레지스트리 상태" value=${c.runtime.registry_state || '--'} />
      <${ConfigRow} label="파이버 상태" value=${c.runtime.fiber_health || '--'} />
      <${BoolRow} label="프레즌스 킵얼라이브" value=${c.runtime.presence_keepalive} />
      <${ConfigRow} label="프레즌스 간격" value=${c.runtime.presence_keepalive_sec + 's'} />

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
      ${isVerifierRoleKeeper(c.coordination.mention_targets) ? html`
      <div class="mb-2 flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-3 py-2">
        <span class="rounded-[var(--r-1)] border border-[var(--accent-40)] bg-[var(--accent-5)] px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-accent-fg">검증자</span>
        <span class="text-2xs text-text-body">이 keeper는 task completion_contract를 독립 실측하는 검증자 역할입니다.</span>
      </div>
      ` : null}
      ${c.coordination.mention_targets.length > 0 ? html`
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">멘션 대상</${SectionHeader}>
        <${ModelList} models=${c.coordination.mention_targets} />
      </div>
      ` : null}
      <div class="mt-1.5">
        <${SectionHeader} size="xs" class="mb-1">참여 네임스페이스</${SectionHeader}>
        <${ModelList} models=${c.coordination.joined_room_ids} />
      </div>

      <${SectionHeader} title="핸드오프" />
      ${rd ? html`
        <${InlineToggleRow} label="자동" value=${rd.auto_handoff}
          onChange=${(v: boolean) => updateRuntimeDraft('auto_handoff', v)} />
        <${InlineNumberRow} label="임계값 (%)" value=${Math.round(rd.handoff_threshold * 100)}
          onChange=${(v: number) => updateRuntimeDraft('handoff_threshold', v / 100)}
          min=${0} max=${100} step=${5} suffix="%" />
        <${InlineNumberRow} label="쿨다운 (초)" value=${rd.handoff_cooldown_sec}
          onChange=${(v: number) => updateRuntimeDraft('handoff_cooldown_sec', v)}
          min=${0} max=${3600} step=${30} suffix="s" />
      ` : html`
        <${BoolRow} label="자동" value=${c.handoff.auto} />
        </div>
        <${ConfigRow} label="임계값" value=${formatPct(c.handoff.threshold)} />
        <${ConfigRow} label="쿨다운" value=${c.handoff.cooldown_sec + 's'} />
      `}

      ${runtimeHasChanges ? html`
        <div class="flex gap-2 items-center mt-4 mb-2 p-3 rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-5)]">
          <button type="button"
            class="${btnBase} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)]"
            onClick=${saveRuntimeConfig}
            disabled=${runtimeSaving.value}
          >${runtimeSaving.value ? '저장 중...' : '런타임 설정 저장'}</button>
          <button type="button"
            class="${btnBase} bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)]"
            onClick=${resetRuntimeDraft}
          >초기화</button>
          <span class="text-3xs text-accent-fg">변경된 설정이 있습니다</span>
        </div>
      ` : null}

      ${c.hooks ? (() => {
        const allEntries: readonly HookSlotEntry[] = Object.entries(c.hooks.slots) as HookSlotEntry[]
        const visibleEntries = filterHookSlots(allEntries, hookFilterQuery.value)
        const isFiltering = hookFilterQuery.value.trim() !== ''
        return html`
          <${SectionHeader} title="훅 슬롯" />
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
                    ${(slot.gates ?? slot.effects ?? slot.features ?? []).length > 0 ? html`
                      <div class="flex flex-wrap gap-1 mt-1">
                        ${(slot.gates ?? slot.effects ?? slot.features ?? []).map((d: string) => html`
                          <span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] ${d.endsWith('_off') ? 'bg-[var(--color-bg-hover)] text-[var(--color-fg-disabled)]' : 'bg-[var(--accent-10)] text-[var(--color-accent-fg)] opacity-80'}">${d}</span>
                        `)}
                      </div>
                    ` : null}
                  </div>
                </div>
              `)}
          <${ConfigRow} label="거부 목록 수" value=${String(c.hooks.deny_list_count)} />
          <${ConfigRow} label="파괴 검사 도구" value=${formatHookDestructiveTools(c.hooks.destructive_check_tools)} />
          <${ConfigRow} label="비용 예산" value=${c.hooks.cost_budget.active ? formatCost(c.hooks.cost_budget.max_cost_usd ?? 0) : '비활성'} />
        `
      })() : null}

      ${'' /* Metrics removed — duplicates KpiGrid, MetricsCharts, and header model badge */}
    </div>
  `
}
