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
  drift_enabled: boolean
  drift_min_turn_gap: number
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
    drift_enabled: c.drift.enabled,
    drift_min_turn_gap: c.drift.min_turn_gap,
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
  if (draft.drift_enabled !== orig.drift.enabled) payload.new_drift_enabled = draft.drift_enabled
  if (draft.drift_min_turn_gap !== orig.drift.min_turn_gap) payload.new_drift_min_turn_gap = draft.drift_min_turn_gap
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

function ModelList({ models }: { models: string[] }) {
  if (models.length === 0) return html`<span class="text-[11px] text-text-muted italic">none</span>`
  return html`
    <div class="flex flex-wrap gap-1.5">
      ${models.map(m => html`<span class="inline-flex items-center py-1 px-2.5 rounded-lg text-[11px] font-semibold bg-accent/10 text-accent border border-accent/20 shadow-sm hover:bg-accent/20 transition-colors cursor-default">${m}</span>`)}
    </div>
  `
}

function LongText({ text }: { text: string }) {
  if (!text || text.trim() === '') return html`<span class="text-[11px] text-text-muted italic">--</span>`
  const truncated = text.length > 200 ? text.slice(0, 200) + '...' : text
  return html`<div class="text-[12px] text-text-body whitespace-pre-wrap max-h-[140px] overflow-y-auto custom-scrollbar border border-card-border bg-card/40 backdrop-blur-md p-3 rounded-xl mt-1.5 leading-relaxed shadow-inner hover:bg-card/60 transition-colors">${truncated}</div>`
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

function EditCheckbox({ field, label }: { field: keyof EditDraft; label: string }) {
  const d = editDraft.value
  if (!d) return null
  const val = d[field] as boolean
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)] mt-1">
      <span class="text-xs text-[var(--text-muted)]">${label}</span>
      <input
        type="checkbox"
        checked=${val}
        class="cursor-pointer"
        onChange=${(e: Event) => updateDraft(field, (e.target as HTMLInputElement).checked)}
      />
    </div>
  `
}

function EditNumber({ field, label, min, max }: { field: keyof EditDraft; label: string; min: number; max: number }) {
  const d = editDraft.value
  if (!d) return null
  const val = d[field] as number
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)] mt-1">
      <span class="text-xs text-[var(--text-muted)]">${label}</span>
      <input
        type="number"
        class="w-16 bg-[rgba(11,18,32,0.8)] text-[var(--text-body)] border border-[var(--card-border)] rounded-md py-1 px-2 text-xs"
        value=${val}
        min=${min}
        max=${max}
        onInput=${(e: Event) => {
          const n = parseInt((e.target as HTMLInputElement).value, 10)
          if (!Number.isNaN(n)) updateDraft(field, Math.max(min, Math.min(max, n)))
        }}
      />
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
        <button
          class="${btnBase} bg-[#4ade80] text-[#000]"
          onClick=${saveConfig}
          disabled=${isSaving}
        >${isSaving ? 'Saving...' : 'Save'}</button>
        <button
          class="${btnBase} bg-[var(--white-10)] text-[var(--text-body)]"
          onClick=${cancelEdit}
          disabled=${isSaving}
        >Cancel</button>
      ` : html`
        <button
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
  `

  // --- Drift section (editable) ---
  const driftSection = isEditing ? html`
    <${SectionHeader} title="Drift (editing)" />
    <${EditCheckbox} field="drift_enabled" label="Enabled" />
    <${EditNumber} field="drift_min_turn_gap" label="Min turn gap" min=${1} max=${50} />
    <${ConfigRow} label="Count total" value=${String(c.drift.count_total)} />
    ${c.drift.last_reason ? html`<${ConfigRow} label="Last reason" value=${c.drift.last_reason} />` : null}
  ` : html`
    <${SectionHeader} title="Drift" />
    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
      <span class="text-xs text-[var(--text-muted)]">Enabled</span>
      <${BoolBadge} value=${c.drift.enabled} />
    </div>
    <${ConfigRow} label="Min turn gap" value=${String(c.drift.min_turn_gap)} />
    <${ConfigRow} label="Count total" value=${String(c.drift.count_total)} />
    ${c.drift.last_reason ? html`<${ConfigRow} label="Last reason" value=${c.drift.last_reason} />` : null}
  `

  return html`
    <div class="flex flex-col gap-1.5">

      ${toolbar}

      ${'' /* --- Execution (read-only) --- */}
      <${SectionHeader} title="Execution" />
      <${ConfigRow} label="Active model" value=${c.execution.active_model || '--'} />
      <${ConfigRow} label="Policy mode" value=${c.execution.policy_mode || '--'} />
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

      ${'' /* --- Drift (editable) --- */}
      ${driftSection}

      ${'' /* --- Initiative (read-only) --- */}
      <${SectionHeader} title="Initiative" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Enabled</span>
        <${BoolBadge} value=${c.initiative.enabled} />
      </div>
      <${ConfigRow} label="Scope" value=${c.initiative.scope || '--'} />
      <${ConfigRow} label="Idle trigger" value=${c.initiative.idle_sec + 's'} />
      <${ConfigRow} label="Cooldown" value=${c.initiative.cooldown_sec + 's'} />
      <${ConfigRow} label="Context mode" value=${c.initiative.context_mode || '--'} />

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
      <${ConfigRow} label="Total tokens" value=${formatTokens(c.metrics.total_tokens)} />
      <${ConfigRow} label="Total cost" value=${'$' + c.metrics.total_cost_usd.toFixed(4)} />
      <${ConfigRow} label="Compactions" value=${String(c.metrics.compaction_count)} />

      ${'' /* --- Prompt (editable) --- */}
      ${promptSection}
    </div>
  `
}
