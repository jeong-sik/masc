// Keeper config panel -- structured config viewer with inline editing.
// Fetches /api/v1/keepers/:name/config and renders grouped sections.
// Redesigned: clean section headers, consistent row styling, proper form controls.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { fetchKeeperConfig, patchKeeperConfig } from '../api/dashboard'
import type { KeeperConfigUpdatePayload } from '../api/dashboard'
import type { KeeperConfig } from '../types'
import { formatTokens } from './keeper-detail-panels'

// ── State ────────────────────────────────────────────────

type ConfigState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; config: KeeperConfig }
  | { status: 'error'; message: string }

const configState = signal<ConfigState>({ status: 'idle' })
const configKeeperName = signal<string>('')
const editMode = signal(false)
const saving = signal(false)
const saveError = signal<string | null>(null)

// Draft values for editable fields (only used in edit mode)
type EditDraft = {
  goal: string
  short_goal: string
  mid_goal: string
  long_goal: string
  soul_profile: string
  will: string
  needs: string
  desires: string
  instructions: string
}

const editDraft = signal<EditDraft | null>(null)

function initDraftFromConfig(c: KeeperConfig): EditDraft {
  return {
    goal: c.prompt.goal,
    short_goal: c.prompt.short_goal,
    mid_goal: c.prompt.mid_goal,
    long_goal: c.prompt.long_goal,
    soul_profile: c.prompt.soul_profile,
    will: c.prompt.will,
    needs: c.prompt.needs,
    desires: c.prompt.desires,
    instructions: c.prompt.instructions,
  }
}

function buildPayload(draft: EditDraft, orig: KeeperConfig): KeeperConfigUpdatePayload {
  const payload: KeeperConfigUpdatePayload = {}
  if (draft.goal !== orig.prompt.goal) payload.new_goal = draft.goal
  if (draft.short_goal !== orig.prompt.short_goal) payload.new_short_goal = draft.short_goal
  if (draft.mid_goal !== orig.prompt.mid_goal) payload.new_mid_goal = draft.mid_goal
  if (draft.long_goal !== orig.prompt.long_goal) payload.new_long_goal = draft.long_goal
  if (draft.soul_profile !== orig.prompt.soul_profile) payload.new_soul_profile = draft.soul_profile
  if (draft.will !== orig.prompt.will) payload.new_will = draft.will
  if (draft.needs !== orig.prompt.needs) payload.new_needs = draft.needs
  if (draft.desires !== orig.prompt.desires) payload.new_desires = draft.desires
  if (draft.instructions !== orig.prompt.instructions) payload.new_instructions = draft.instructions
  return payload
}

export async function loadKeeperConfig(name: string): Promise<void> {
  if (configKeeperName.value === name && configState.value.status === 'loaded') return
  configKeeperName.value = name
  configState.value = { status: 'loading' }
  try {
    const config = await fetchKeeperConfig(name)
    configState.value = { status: 'loaded', config }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to load config'
    configState.value = { status: 'error', message }
  }
}

export function resetKeeperConfig(): void {
  configState.value = { status: 'idle' }
  configKeeperName.value = ''
  editMode.value = false
  editDraft.value = null
  saveError.value = null
}

// ── Helpers ──────────────────────────────────────────────

function ConfigRow({ label, value }: { label: string; value: string }) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-xl border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-sm mb-1.5">
      <span class="text-[12px] font-medium text-text-muted">${label}</span>
      <span class="text-[12px] font-semibold text-text-strong">${value}</span>
    </div>
  `
}

function SectionHeader({ title }: { title: string }) {
  return html`
    <div class="text-[11px] font-bold uppercase tracking-widest text-accent mt-6 mb-3 pb-1.5 border-b border-accent/20 flex items-center gap-2">
      <span class="w-1.5 h-1.5 rounded-full bg-accent/50 shadow-[0_0_8px_rgba(71,184,255,0.6)]"></span>
      ${title}
    </div>
  `
}

function BoolBadge({ value }: { value: boolean }) {
  return value
    ? html`<span class="text-[11px] font-bold px-2 py-0.5 rounded-md bg-ok/10 text-ok border border-ok/20 shadow-sm shadow-ok/5">ON</span>`
    : html`<span class="text-[11px] font-bold px-2 py-0.5 rounded-md bg-white/5 text-text-dim border border-white/10 shadow-sm">OFF</span>`
}

function FeatureBadge({
  status,
  value,
}: {
  status?: string
  value: boolean | null
}) {
  if (status && status !== 'wired') {
    const label = status === 'source_only' ? 'SOURCE ONLY' : 'UNWIRED'
    return html`<span class="text-[11px] font-bold px-2 py-0.5 rounded-md bg-amber-500/10 text-amber-300 border border-amber-400/20 shadow-sm">${label}</span>`
  }
  if (value === null) {
    return html`<span class="text-[11px] font-bold px-2 py-0.5 rounded-md bg-white/5 text-text-dim border border-white/10 shadow-sm">--</span>`
  }
  return html`<${BoolBadge} value=${value} />`
}

function ModelList({ models }: { models: string[] }) {
  if (models.length === 0) return html`<span class="text-[11px] text-text-muted italic">none</span>`
  return html`
    <div class="flex flex-wrap gap-1.5">
      ${models.map(m => html`<span class="inline-flex items-center py-1 px-2.5 rounded-lg text-[11px] font-semibold bg-accent/10 text-accent border border-accent/20 shadow-sm hover:bg-accent/20 transition-colors cursor-default">${m}</span>`)}
    </div>
  `
}

function LongText({ text, truncateAt = 200 }: { text: string; truncateAt?: number | null }) {
  if (!text || text.trim() === '') return html`<span class="text-[11px] text-text-muted italic">--</span>`
  const truncated =
    truncateAt !== null && truncateAt >= 0 && text.length > truncateAt
      ? text.slice(0, truncateAt) + '...'
      : text
  return html`<div class="text-[12px] text-text-body whitespace-pre-wrap max-h-[140px] overflow-y-auto custom-scrollbar border border-card-border bg-card/40 backdrop-blur-md p-3 rounded-xl mt-1.5 leading-relaxed shadow-inner hover:bg-card/60 transition-colors">${truncated}</div>`
}

function formatMaybeNumber(value: number | null, suffix = ''): string {
  return value === null ? '--' : `${value}${suffix}`
}

function formatMaybeFloat(value: number | null, digits = 1, suffix = ''): string {
  return value === null ? '--' : `${value.toFixed(digits)}${suffix}`
}

function PromptSourceBadge({ source }: { source: string }) {
  const tone =
    source === 'override'
      ? 'bg-amber-500/10 text-amber-300 border-amber-400/20'
      : source === 'file'
        ? 'bg-emerald-500/10 text-emerald-300 border-emerald-400/20'
        : 'bg-white/5 text-text-dim border-white/10'
  return html`<span class="text-[10px] font-bold px-2 py-0.5 rounded-md border ${tone} shadow-sm">${source.toUpperCase()}</span>`
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
      <div class="flex items-center justify-between gap-2 mb-1">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">${title}</div>
        <div class="flex items-center gap-2">
          <span class="text-[10px] text-text-dim">${block.key}</span>
          <${PromptSourceBadge} source=${block.source} />
        </div>
      </div>
      <${LongText} text=${block.text} truncateAt=${null} />
    </div>
  `
}

const SOUL_PROFILES = ['balanced', 'safety', 'delivery', 'research', 'relationship', 'minimal'] as const

const fieldStyle = 'w-full bg-card/60 backdrop-blur-md text-text-strong text-[13px] border border-card-border rounded-xl py-2 px-3 font-sans focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 transition-all duration-200 shadow-inner'

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
      <div class="text-[11px] font-semibold uppercase tracking-wider text-text-muted mb-1.5">${label}</div>
      <textarea
        class="${fieldStyle} resize-y custom-scrollbar"
        rows=${rows}
        value=${val}
        onInput=${(e: Event) => updateDraft(field, (e.target as HTMLTextAreaElement).value)}
      />
    </div>
  `
}

function EditSelect({ field, label, options }: { field: keyof EditDraft; label: string; options: readonly string[] }) {
  const d = editDraft.value
  if (!d) return null
  const val = d[field] as string
  return html`
    <div class="mt-3">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-text-muted mb-1.5">${label}</div>
      <select
        class="${fieldStyle} appearance-none cursor-pointer hover:border-accent/30"
        value=${val}
        onChange=${(e: Event) => updateDraft(field, (e.target as HTMLSelectElement).value)}
      >
        ${options.map(o => html`<option value=${o} class="bg-bg-1">${o}</option>`)}
      </select>
    </div>
  `
}

// ── Main component ───────────────────────────────────────

export function KeeperConfigPanel({ keeperName }: { keeperName: string }) {
  const state = configState.value

  // Trigger load on first render or name change
  if (configKeeperName.value !== keeperName || state.status === 'idle') {
    void loadKeeperConfig(keeperName)
  }

  if (state.status === 'loading') {
    return html`<div class="py-3 text-xs text-[var(--text-muted)]">Loading config...</div>`
  }

  if (state.status === 'error') {
    return html`<div class="py-3 text-xs text-[#ef4444]">${state.message}</div>`
  }

  if (state.status !== 'loaded') return null

  const c = state.config
  const isEditing = editMode.value
  const isSaving = saving.value

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
      cancelEdit()
      return
    }
    saving.value = true
    saveError.value = null
    try {
      const updated = await patchKeeperConfig(keeperName, payload)
      configState.value = { status: 'loaded', config: updated }
      editMode.value = false
      editDraft.value = null
    } catch (err) {
      saveError.value = err instanceof Error ? err.message : 'Save failed'
    } finally {
      saving.value = false
    }
  }

  const btnBase = 'py-1.5 px-4 rounded-lg text-xs font-semibold cursor-pointer border-none'

  // --- Toolbar ---
  const toolbar = html`
    <div class="flex gap-2 items-center mb-3">
      ${isEditing ? html`
        <button type="button"
          class="${btnBase} bg-[#4ade80] text-[#000]"
          onClick=${saveConfig}
          disabled=${isSaving}
        >${isSaving ? 'Saving...' : 'Save'}</button>
        <button type="button"
          class="${btnBase} bg-[var(--white-10)] text-[var(--text-body)]"
          onClick=${cancelEdit}
          disabled=${isSaving}
        >Cancel</button>
      ` : html`
        <button type="button"
          class="${btnBase} bg-[var(--purple)] text-[#000]"
          onClick=${enterEditMode}
        >Edit</button>
      `}
      ${saveError.value ? html`<span class="text-xs text-[#ef4444]">${saveError.value}</span>` : null}
    </div>
  `

  // --- Prompt section (editable) ---
  const promptSection = isEditing ? html`
    <${SectionHeader} title="Prompt (editing)" />
    <${EditTextarea} field="goal" label="Goal" rows=${3} />
    <${EditTextarea} field="short_goal" label="Short-term goal" rows=${2} />
    <${EditTextarea} field="mid_goal" label="Mid-term goal" rows=${2} />
    <${EditTextarea} field="long_goal" label="Long-term goal" rows=${2} />
    <${EditSelect} field="soul_profile" label="Soul profile" options=${SOUL_PROFILES} />
    <${EditTextarea} field="will" label="Will" rows=${2} />
    <${EditTextarea} field="needs" label="Needs" rows=${2} />
    <${EditTextarea} field="desires" label="Desires" rows=${2} />
    <${EditTextarea} field="instructions" label="Instructions" rows=${4} />
  ` : html`
    <${SectionHeader} title="Prompt" />
    <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-0.5">Goal</div>
    <${LongText} text=${c.prompt.goal} />
    ${c.prompt.short_goal ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Short-term goal</div>
      <${LongText} text=${c.prompt.short_goal} />
    ` : null}
    ${c.prompt.mid_goal ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Mid-term goal</div>
      <${LongText} text=${c.prompt.mid_goal} />
    ` : null}
    ${c.prompt.long_goal ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Long-term goal</div>
      <${LongText} text=${c.prompt.long_goal} />
    ` : null}
    ${c.prompt.soul_profile ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Soul profile</div>
      <${LongText} text=${c.prompt.soul_profile} />
    ` : null}
    ${c.prompt.instructions ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Instructions</div>
      <${LongText} text=${c.prompt.instructions} />
    ` : null}
    <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-3 mb-0.5">System prompt blocks</div>
    <${PromptBlock} title="Constitution" block=${c.prompt.system_prompt_blocks.constitution} />
    <${PromptBlock} title="World" block=${c.prompt.system_prompt_blocks.world} />
    <${PromptBlock} title="Capabilities" block=${c.prompt.system_prompt_blocks.capabilities} />
    <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-3 mb-0.5">Effective system prompt</div>
    <${LongText} text=${c.prompt.effective_system_prompt} truncateAt=${null} />
  `

  return html`
    <div class="flex flex-col gap-1.5">

      ${toolbar}

      ${'' /* --- Execution (read-only) --- */}
      <${SectionHeader} title="Execution" />
      <${ConfigRow} label="Active model" value=${c.execution.active_model || '--'} />
      <${ConfigRow} label="Shell mode" value=${c.execution.policy_shell_mode || '--'} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Verify</span>
        <${BoolBadge} value=${c.execution.verify} />
      </div>
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Models</div>
        <${ModelList} models=${c.execution.models} />
      </div>
      ${c.execution.allowed_models.length > 0 ? html`
        <div class="mt-1.5">
          <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Allowed models</div>
          <${ModelList} models=${c.execution.allowed_models} />
        </div>
      ` : null}

      ${'' /* --- Compaction (read-only) --- */}
      <${SectionHeader} title="Compaction" />
      <${ConfigRow} label="Profile" value=${c.compaction.profile || '--'} />
      <${ConfigRow} label="Ratio gate" value=${(c.compaction.ratio_gate * 100).toFixed(0) + '%'} />
      <${ConfigRow} label="Message gate" value=${String(c.compaction.message_gate)} />
      <${ConfigRow} label="Token gate" value=${formatTokens(c.compaction.token_gate)} />
      <${ConfigRow} label="Cooldown" value=${c.compaction.cooldown_sec + 's'} />

      ${'' /* --- Proactive (read-only) --- */}
      <${SectionHeader} title="Proactive" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Enabled</span>
        <${BoolBadge} value=${c.proactive.enabled} />
      </div>
      <${ConfigRow} label="Idle trigger" value=${c.proactive.idle_sec + 's'} />
      <${ConfigRow} label="Cooldown" value=${c.proactive.cooldown_sec + 's'} />

      ${'' /* --- Runtime (read-only) --- */}
      <${SectionHeader} title="Runtime" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Paused</span>
        <${BoolBadge} value=${c.runtime.paused} />
      </div>
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Desired</span>
        <${BoolBadge} value=${c.runtime.desired} />
      </div>
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Resident registered</span>
        <${BoolBadge} value=${c.runtime.resident_registered} />
      </div>
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Keepalive running</span>
        <${BoolBadge} value=${c.runtime.keepalive_running} />
      </div>
      <${ConfigRow} label="Fiber health" value=${c.runtime.fiber_health || '--'} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Presence keepalive</span>
        <${BoolBadge} value=${c.runtime.presence_keepalive} />
      </div>
      <${ConfigRow} label="Presence interval" value=${c.runtime.presence_keepalive_sec + 's'} />

      ${'' /* --- Coordination (read-only) --- */}
      <${SectionHeader} title="Coordination" />
      <${ConfigRow} label="Room scope" value=${c.coordination.room_scope || '--'} />
      <${ConfigRow} label="Scope kind" value=${c.coordination.scope_kind || '--'} />
      <${ConfigRow} label="Trigger mode" value=${c.coordination.trigger_mode || '--'} />
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Mention targets</div>
        <${ModelList} models=${c.coordination.mention_targets} />
      </div>
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Joined rooms</div>
        <${ModelList} models=${c.coordination.joined_room_ids} />
      </div>

      ${'' /* --- Drift (read-only) --- */}
      <${SectionHeader} title="Drift" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">State</span>
        <${FeatureBadge} status=${c.drift.status} value=${c.drift.enabled} />
      </div>
      <${ConfigRow} label="Min turn gap" value=${formatMaybeNumber(c.drift.min_turn_gap)} />
      <${ConfigRow} label="Count total" value=${formatMaybeNumber(c.drift.count_total)} />
      ${c.drift.last_reason ? html`<${ConfigRow} label="Last reason" value=${c.drift.last_reason} />` : null}

      ${'' /* --- Initiative (read-only) --- */}
      <${SectionHeader} title="Initiative" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">State</span>
        <${FeatureBadge} status=${c.initiative.status} value=${c.initiative.enabled} />
      </div>
      <${ConfigRow} label="Scope" value=${c.initiative.scope || '--'} />
      <${ConfigRow} label="Idle trigger" value=${formatMaybeNumber(c.initiative.idle_sec, 's')} />
      <${ConfigRow} label="Cooldown" value=${formatMaybeNumber(c.initiative.cooldown_sec, 's')} />
      <${ConfigRow} label="Context mode" value=${c.initiative.context_mode || '--'} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Configured in defaults</span>
        <${BoolBadge} value=${c.initiative.configured_in_source} />
      </div>
      ${c.initiative.source_defaults ? html`
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-1">Source defaults</div>
        <${ConfigRow} label="Enabled" value=${c.initiative.source_defaults.enabled === null ? '--' : String(c.initiative.source_defaults.enabled)} />
        <${ConfigRow} label="Scope" value=${c.initiative.source_defaults.scope || '--'} />
        <${ConfigRow} label="Idle trigger" value=${formatMaybeNumber(c.initiative.source_defaults.idle_sec, 's')} />
        <${ConfigRow} label="Cooldown" value=${formatMaybeNumber(c.initiative.source_defaults.cooldown_sec, 's')} />
        <${ConfigRow} label="Context mode" value=${c.initiative.source_defaults.context_mode || '--'} />
        <${ConfigRow} label="Post TTL" value=${formatMaybeNumber(c.initiative.source_defaults.post_ttl_hours, 'h')} />
      ` : null}

      ${'' /* --- Team Session (read-only) --- */}
      <${SectionHeader} title="Auto Team Session" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">State</span>
        <${FeatureBadge} status=${c.auto_team_session.status} value=${c.auto_team_session.enabled} />
      </div>

      ${'' /* --- Handoff (read-only) --- */}
      <${SectionHeader} title="Handoff" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Auto</span>
        <${BoolBadge} value=${c.handoff.auto} />
      </div>
      <${ConfigRow} label="Threshold" value=${(c.handoff.threshold * 100).toFixed(0) + '%'} />
      <${ConfigRow} label="Cooldown" value=${c.handoff.cooldown_sec + 's'} />

      ${'' /* --- Metrics (read-only) --- */}
      <${SectionHeader} title="Metrics" />
      <${ConfigRow} label="Generation" value=${String(c.metrics.generation)} />
      <${ConfigRow} label="Total turns" value=${String(c.metrics.total_turns)} />
      <${ConfigRow} label="Total input tokens" value=${formatTokens(c.metrics.total_input_tokens)} />
      <${ConfigRow} label="Total output tokens" value=${formatTokens(c.metrics.total_output_tokens)} />
      <${ConfigRow} label="Total tokens" value=${formatTokens(c.metrics.total_tokens)} />
      <${ConfigRow} label="Total cost" value=${'$' + c.metrics.total_cost_usd.toFixed(4)} />
      <${ConfigRow} label="Last model" value=${c.metrics.last_model_used || '--'} />
      <${ConfigRow} label="Last input tokens" value=${formatTokens(c.metrics.last_input_tokens)} />
      <${ConfigRow} label="Last output tokens" value=${formatTokens(c.metrics.last_output_tokens)} />
      <${ConfigRow} label="Last total tokens" value=${formatTokens(c.metrics.last_total_tokens)} />
      <${ConfigRow} label="Last latency" value=${formatMaybeNumber(c.metrics.last_latency_ms, 'ms')} />
      <${ConfigRow} label="Last throughput" value=${formatMaybeFloat(c.metrics.last_total_tokens_per_sec, 1, ' tok/s')} />
      <${ConfigRow} label="Last output throughput" value=${formatMaybeFloat(c.metrics.last_output_tokens_per_sec, 1, ' tok/s')} />
      <${ConfigRow} label="Compactions" value=${String(c.metrics.compaction_count)} />

      ${'' /* --- Sources (read-only) --- */}
      <${SectionHeader} title="Sources" />
      <${ConfigRow} label="Default source" value=${c.sources.default_source_kind || '--'} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Live override</span>
        <${BoolBadge} value=${c.sources.has_live_override} />
      </div>
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Resident spec exists</span>
        <${BoolBadge} value=${c.sources.resident_spec_exists} />
      </div>
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Live meta path</div>
      <${LongText} text=${c.sources.live_meta_path} />
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Resident spec path</div>
      <${LongText} text=${c.sources.resident_spec_path} />
      ${c.sources.default_manifest_path ? html`
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">Default manifest path</div>
        <${LongText} text=${c.sources.default_manifest_path} />
      ` : null}
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Precedence</div>
        <${ModelList} models=${c.sources.precedence} />
      </div>
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">Override fields</div>
        <${ModelList} models=${c.sources.override_fields} />
      </div>

      ${'' /* --- Prompt (editable) --- */}
      ${promptSection}
    </div>
  `
}
