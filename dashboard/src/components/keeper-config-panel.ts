// Keeper config panel -- structured config viewer with inline editing.
// Fetches /api/v1/keepers/:name/config and renders grouped sections.
// Redesigned: clean section headers, consistent row styling, proper form controls.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { fetchKeeperConfig, patchKeeperConfig } from '../api/dashboard'
import type { KeeperConfigUpdatePayload } from '../api/dashboard'
import type { KeeperConfig } from '../types'
import type { KeeperConfigLoadStatus } from './keeper-detail-source'
import { formatTokens } from '../lib/format-number'
import { showToast } from './common/toast'
import { createAsyncResource, loaded } from '../lib/async-state'

// ── State ────────────────────────────────────────────────

const configResource = createAsyncResource<KeeperConfig>()
const configState = configResource.state
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

// Runtime config draft for proactive/compaction/handoff inline editing
type ExecutionScope = 'observe_only' | 'workspace' | 'local'

type RuntimeDraft = {
  execution_scope: ExecutionScope
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

function initRuntimeDraftFromConfig(c: KeeperConfig): RuntimeDraft {
  return {
    execution_scope: (c.execution_scope as ExecutionScope) ?? 'workspace',
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

function buildRuntimePayload(draft: RuntimeDraft, orig: KeeperConfig): KeeperConfigUpdatePayload {
  const payload: KeeperConfigUpdatePayload = {}
  if (draft.execution_scope !== (orig.execution_scope ?? 'workspace')) payload.execution_scope = draft.execution_scope
  const newPaths = draft.allowed_paths_text.split('\n').map(s => s.trim()).filter(Boolean)
  const origPaths = orig.allowed_paths ?? []
  if (JSON.stringify(newPaths) !== JSON.stringify(origPaths)) payload.allowed_paths = newPaths
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
  runtimeDraft.value = { ...d, [field]: value }
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
  configKeeperName.value = ''
  editMode.value = false
  editDraft.value = null
  saveError.value = null
  runtimeDraft.value = null
  runtimeSaving.value = false
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
      ? 'border-amber-400/20 bg-amber-500/10 text-amber-100'
      : 'border-card-border/60 bg-card/35 text-text-body'
  return html`
    <div class="rounded-xl border px-3 py-3 shadow-sm ${toneClass}">
      <div class="text-[11px] font-bold uppercase tracking-widest text-text-muted mb-1">${title}</div>
      <div class="text-[12px] leading-relaxed">${body}</div>
    </div>
  `
}

function BoolBadge({ value }: { value: boolean }) {
  return value
    ? html`<span class="text-[11px] font-bold px-2 py-0.5 rounded-md bg-ok/10 text-ok border border-ok/20 shadow-sm shadow-ok/5">ON</span>`
    : html`<span class="text-[11px] font-bold px-2 py-0.5 rounded-md bg-white/5 text-text-dim border border-white/10 shadow-sm">OFF</span>`
}

function formatHookDestructiveTools(value: string[] | string): string {
  if (Array.isArray(value)) {
    return value.length > 0 ? value.join(', ') : '--'
  }
  const text = value.trim()
  return text !== '' ? text : '--'
}

function ModelList({ models }: { models: string[] }) {
  if (models.length === 0) return html`<span class="text-[11px] text-text-muted italic">none</span>`
  return html`
    <div class="flex flex-wrap gap-1.5">
      ${models.map(m => html`<span class="inline-flex items-center py-1 px-2.5 rounded-lg text-[11px] font-semibold bg-[var(--accent-10)] text-accent border border-accent/20 shadow-sm hover:bg-accent/20 transition-colors cursor-default">${m}</span>`)}
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

const fieldStyle = 'w-full bg-card/60 backdrop-blur-md text-text-strong text-[13px] border border-card-border rounded-xl py-2 px-3 font-sans focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 transition-all duration-200 shadow-inner'

// ── Inline editing components for runtime config ────────

function InlineToggleRow({ label, value, onChange }: { label: string; value: boolean; onChange: (v: boolean) => void }) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-xl border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-sm mb-1.5">
      <span class="text-[12px] font-medium text-text-muted">${label}</span>
      <button type="button"
        class="relative inline-flex h-5 w-9 items-center rounded-full transition-colors cursor-pointer ${value ? 'bg-ok/60' : 'bg-white/10'}"
        onClick=${() => onChange(!value)}
      >
        <span class="inline-block h-3.5 w-3.5 rounded-full bg-white shadow-sm transition-transform ${value ? 'translate-x-[18px]' : 'translate-x-[3px]'}" />
      </button>
    </div>
  `
}

function InlineNumberRow({ label, value, onChange, min, max, step, suffix }: {
  label: string; value: number; onChange: (v: number) => void;
  min?: number; max?: number; step?: number; suffix?: string
}) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-xl border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-sm mb-1.5">
      <span class="text-[12px] font-medium text-text-muted">${label}</span>
      <div class="flex items-center gap-1.5">
        <input type="number"
          class="w-20 text-right bg-card/60 text-text-strong text-[12px] font-semibold border border-card-border rounded-lg py-1 px-2 focus:outline-none focus:border-accent/50 transition-colors"
          value=${value}
          min=${min}
          max=${max}
          step=${step}
          onInput=${(e: Event) => {
            const v = parseFloat((e.target as HTMLInputElement).value)
            if (!isNaN(v)) onChange(v)
          }}
        />
        ${suffix ? html`<span class="text-[10px] text-text-dim w-4">${suffix}</span>` : null}
      </div>
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

// ── Main component ───────────────────────────────────────

export function KeeperConfigPanel({ keeperName }: { keeperName: string }) {
  const state = configState.value

  // Trigger load on first render or name change
  if (configKeeperName.value !== keeperName || state.status === 'idle') {
    void loadKeeperConfig(keeperName)
  }

  if (state.status === 'loading') {
    return html`<div class="py-3 text-xs text-[var(--text-muted)]">설정 로딩 중...</div>`
  }

  if (state.status === 'error') {
    return html`<div class="py-3 text-xs text-[var(--bad)]">${state.message}</div>`
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

  const btnBase = 'py-1.5 px-4 rounded-lg text-xs font-semibold cursor-pointer border-none'

  // --- Toolbar ---
  const toolbar = html`
    <div class="flex gap-2 items-center mb-3">
      ${isEditing ? html`
        <button type="button"
          class="${btnBase} bg-[var(--ok)] text-[#000]"
          onClick=${saveConfig}
          disabled=${isSaving}
        >${isSaving ? '저장 중...' : '저장'}</button>
        <button type="button"
          class="${btnBase} bg-[var(--white-10)] text-[var(--text-body)]"
          onClick=${cancelEdit}
          disabled=${isSaving}
        >취소</button>
      ` : html`
        <button type="button"
          class="${btnBase} bg-[var(--purple)] text-[#1e1b4b]"
          onClick=${enterEditMode}
        >편집</button>
      `}
      ${saveError.value ? html`<span class="text-xs text-[var(--bad)]">${saveError.value}</span>` : null}
    </div>
  `

  // --- Prompt section (editable) ---
  const promptSection = isEditing ? html`
    <${SectionHeader} title="프롬프트 (편집)" />
    <${EditTextarea} field="goal" label="목표" rows=${3} />
    <${EditTextarea} field="short_goal" label="단기 목표" rows=${2} />
    <${EditTextarea} field="mid_goal" label="중기 목표" rows=${2} />
    <${EditTextarea} field="long_goal" label="장기 목표" rows=${2} />
    <${EditTextarea} field="will" label="의지" rows=${2} />
    <${EditTextarea} field="needs" label="필요" rows=${2} />
    <${EditTextarea} field="desires" label="욕구" rows=${2} />
    <${EditTextarea} field="instructions" label="지시사항" rows=${4} />
  ` : html`
    <${SectionHeader} title="프롬프트" />
    <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-0.5">목표</div>
    <${LongText} text=${c.prompt.goal} />
    ${c.prompt.short_goal ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">단기 목표</div>
      <${LongText} text=${c.prompt.short_goal} />
    ` : null}
    ${c.prompt.mid_goal ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">중기 목표</div>
      <${LongText} text=${c.prompt.mid_goal} />
    ` : null}
    ${c.prompt.long_goal ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">장기 목표</div>
      <${LongText} text=${c.prompt.long_goal} />
    ` : null}
    ${c.prompt.instructions ? html`
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">지시사항</div>
      <${LongText} text=${c.prompt.instructions} />
    ` : null}
    <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-3 mb-0.5">시스템 프롬프트 블록</div>
    <${PromptBlock} title="헌법" block=${c.prompt.system_prompt_blocks.constitution} />
    <${PromptBlock} title="세계관" block=${c.prompt.system_prompt_blocks.world} />
    <${PromptBlock} title="능력" block=${c.prompt.system_prompt_blocks.capabilities} />
    <details class="mt-3">
      <summary class="cursor-pointer py-2 px-3 text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] list-none select-none rounded-lg hover:bg-[var(--white-3)] transition-colors">컴파일된 시스템 프롬프트 보기</summary>
      <${LongText} text=${c.prompt.effective_system_prompt} truncateAt=${null} />
    </details>
  `

  return html`
    <div class="flex flex-col gap-1.5">
      ${toolbar}

      <${Callout}
        title="편집 가능 범위"
        body="여기서 저장되는 값은 keeper 프롬프트와 live override 계층입니다. 활성 모델은 keeper별 설정이 아니라 config/cascade.json 해석 결과로 결정됩니다."
      />

      ${promptSection}

      <div class="mt-2">
        <${Callout}
          title="런타임 설정"
          body="프로액티브, 컴팩션, 핸드오프 섹션은 인라인 편집이 가능합니다. 소스/실행/런타임/조율은 읽기 전용입니다."
        />
      </div>

      <${SectionHeader} title="소스" />
      <${ConfigRow} label="기본 소스" value=${c.sources.default_source_kind || '--'} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">라이브 오버라이드</span>
        <${BoolBadge} value=${c.sources.has_live_override} />
      </div>
      <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">라이브 메타 경로</div>
      <${LongText} text=${c.sources.live_meta_path} />
      ${c.sources.default_manifest_path ? html`
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mt-2 mb-0.5">기본 매니페스트 경로</div>
        <${LongText} text=${c.sources.default_manifest_path} />
      ` : null}
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">우선순위</div>
        <${ModelList} models=${c.sources.precedence} />
      </div>
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">오버라이드 필드</div>
        <${ModelList} models=${c.sources.override_fields} />
      </div>

      <${SectionHeader} title="실행" />
      <${ConfigRow} label="활성 모델" value=${c.execution.active_model || '--'} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">검증</span>
        <${BoolBadge} value=${c.execution.verify} />
      </div>
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">모델</div>
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
        <${ConfigRow} label="비율 게이트" value=${(c.compaction.ratio_gate * 100).toFixed(0) + '%'} />
        <${ConfigRow} label="메시지 게이트" value=${String(c.compaction.message_gate)} />
        <${ConfigRow} label="토큰 게이트" value=${formatTokens(c.compaction.token_gate)} />
        <${ConfigRow} label="쿨다운" value=${c.compaction.cooldown_sec + 's'} />
      `}

      <${SectionHeader} title="실행 범위" />
      ${rd ? html`
        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
          <span class="text-xs text-[var(--text-body)]">execution_scope</span>
          <select class="text-xs bg-[var(--white-6)] border border-[var(--card-border)] rounded px-2 py-1 text-[var(--text-body)]"
            value=${rd.execution_scope}
            onChange=${(e: Event) => updateRuntimeDraft('execution_scope', (e.target as HTMLSelectElement).value as ExecutionScope)}>
            <option value="observe_only">observe_only</option>
            <option value="workspace">workspace</option>
            <option value="local">local</option>
          </select>
        </div>
        <div class="py-2 px-3 rounded-lg bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1">
            <span class="text-xs text-[var(--text-body)]">allowed_paths</span>
            <span class="text-[10px] text-[var(--text-muted)]">한 줄에 하나씩. * = 전체 허용</span>
          </div>
          <textarea class="w-full text-xs font-mono bg-[var(--white-6)] border border-[var(--card-border)] rounded px-2 py-1.5 text-[var(--text-body)] resize-y"
            rows=${3}
            value=${rd.allowed_paths_text}
            placeholder=".masc/keepers/<name>/"
            onInput=${(e: Event) => updateRuntimeDraft('allowed_paths_text', (e.target as HTMLTextAreaElement).value)}
          ></textarea>
        </div>
        ${(c.effective_allowed_paths ?? []).length > 0 ? html`
          <div class="py-1.5 px-3 text-[10px] text-[var(--text-muted)]">
            effective: ${(c.effective_allowed_paths ?? []).join(', ') || '(전체 허용)'}
          </div>
        ` : null}
      ` : html`
        <${ConfigRow} label="execution_scope" value=${c.execution_scope ?? 'workspace'} />
        <${ConfigRow} label="allowed_paths" value=${(c.allowed_paths ?? []).join(', ') || '(computed default)'} />
        <${ConfigRow} label="effective_paths" value=${(c.effective_allowed_paths ?? []).join(', ') || '(전체 허용)'} />
      `}

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
        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
          <span class="text-xs text-[var(--text-muted)]">활성</span>
          <${BoolBadge} value=${c.proactive.enabled} />
        </div>
        <${ConfigRow} label="유휴 트리거" value=${c.proactive.idle_sec + 's'} />
        <${ConfigRow} label="쿨다운" value=${c.proactive.cooldown_sec + 's'} />
      `}

      <${SectionHeader} title="런타임" />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">일시정지</span>
        <${BoolBadge} value=${c.runtime.paused} />
      </div>
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">자동 부팅 등록</span>
        <${BoolBadge} value=${c.runtime.registered} />
      </div>
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">킵얼라이브 실행</span>
        <${BoolBadge} value=${c.runtime.keepalive_running} />
      </div>
      <${ConfigRow} label="레지스트리 상태" value=${c.runtime.registry_state || '--'} />
      <${ConfigRow} label="파이버 상태" value=${c.runtime.fiber_health || '--'} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">프레즌스 킵얼라이브</span>
        <${BoolBadge} value=${c.runtime.presence_keepalive} />
      </div>
      <${ConfigRow} label="프레즌스 간격" value=${c.runtime.presence_keepalive_sec + 's'} />

      <${SectionHeader} title="네임스페이스 조율" />
      <${ConfigRow} label="프로젝트 범위" value=${c.coordination.room_scope || '--'} />
      ${c.coordination.mention_targets.length > 0 ? html`
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">멘션 대상</div>
        <${ModelList} models=${c.coordination.mention_targets} />
      </div>
      ` : null}
      <div class="mt-1.5">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1">참여 네임스페이스</div>
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
        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
          <span class="text-xs text-[var(--text-muted)]">자동</span>
          <${BoolBadge} value=${c.handoff.auto} />
        </div>
        <${ConfigRow} label="임계값" value=${(c.handoff.threshold * 100).toFixed(0) + '%'} />
        <${ConfigRow} label="쿨다운" value=${c.handoff.cooldown_sec + 's'} />
      `}

      ${runtimeHasChanges ? html`
        <div class="flex gap-2 items-center mt-4 mb-2 p-3 rounded-xl border border-accent/30 bg-accent/5">
          <button type="button"
            class="${btnBase} bg-[var(--ok)] text-[#000]"
            onClick=${saveRuntimeConfig}
            disabled=${runtimeSaving.value}
          >${runtimeSaving.value ? '저장 중...' : '런타임 설정 저장'}</button>
          <button type="button"
            class="${btnBase} bg-[var(--white-10)] text-[var(--text-body)]"
            onClick=${resetRuntimeDraft}
          >초기화</button>
          <span class="text-[10px] text-accent">변경된 설정이 있습니다</span>
        </div>
      ` : null}

      ${c.hooks ? html`
        <${SectionHeader} title="훅 슬롯" />
        ${Object.entries(c.hooks.slots).map(([name, slot]) => html`
          <div class="flex items-start gap-2 py-2 px-3 rounded-xl border border-card-border/50 bg-card/20 mb-1.5">
            <span class="mt-1 w-2 h-2 rounded-full shrink-0 ${slot.active ? 'bg-[var(--ok)] shadow-[0_0_6px_var(--ok-48)]' : 'bg-[var(--text-dim)]'}"></span>
            <div class="flex-1 min-w-0">
              <div class="flex justify-between">
                <span class="text-[12px] font-semibold text-text-strong">${name}</span>
                <span class="text-[10px] text-text-muted">${slot.source}</span>
              </div>
              ${(slot.gates ?? slot.effects ?? slot.features ?? []).length > 0 ? html`
                <div class="flex flex-wrap gap-1 mt-1">
                  ${(slot.gates ?? slot.effects ?? slot.features ?? []).map((d: string) => html`
                    <span class="text-[9px] px-1.5 py-0.5 rounded-md ${d.endsWith('_off') ? 'bg-[var(--white-10)] text-[var(--text-dim)]' : 'bg-[var(--accent-10)] text-[var(--accent)] opacity-80'}">${d}</span>
                  `)}
                </div>
              ` : null}
            </div>
          </div>
        `)}
        <${ConfigRow} label="거부 목록 수" value=${String(c.hooks.deny_list_count)} />
        <${ConfigRow} label="파괴 검사 도구" value=${formatHookDestructiveTools(c.hooks.destructive_check_tools)} />
        <${ConfigRow} label="비용 예산" value=${c.hooks.cost_budget.active ? '$' + (c.hooks.cost_budget.max_cost_usd ?? 0).toFixed(2) : '비활성'} />
      ` : null}

      ${'' /* Metrics removed — duplicates KpiGrid, MetricsCharts, and header model badge */}
    </div>
  `
}
