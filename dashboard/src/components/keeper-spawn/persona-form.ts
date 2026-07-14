// PersonaForm — create/edit persona form for the dashboard.
//
// A persona has two field layers (see keeper-spawn-state.ts): identity
// (display_name/role/trait) and keeper-template defaults
// (goal/instructions/mention_targets/proactive_enabled). The form groups them
// so the two layers stay visually distinct.
//
// masc_persona_list returns only identity fields, so on edit the identity
// section pre-fills but the keeper-template text fields start blank and are
// treated as "leave blank to keep the current value" (update uses partial
// merge). proactive_enabled is a boolean with no blank state, so it is only
// offered on create; editing it (and showing current keeper-template values)
// needs a persona-detail fetch, tracked as a follow-up.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { TextInput, TextArea } from '../common/input'
import { Checkbox } from '../common/checkbox'
import { ActionButton } from '../common/button'
import {
  showCreateForm,
  editingPersona,
  createPersona,
  updatePersona,
  type PersonaSummary,
} from './keeper-spawn-state'

interface FormFields {
  persona_name: string
  display_name: string
  role: string
  trait: string
  goal: string
  instructions: string
  mention_targets: string
  proactive_enabled: boolean
}

const emptyForm = (): FormFields => ({
  persona_name: '',
  display_name: '',
  role: '',
  trait: '',
  goal: '',
  instructions: '',
  mention_targets: '',
  proactive_enabled: false,
})

const formFields = signal<FormFields>(emptyForm())
const submitting = signal(false)
const nameError = signal<string | null>(null)
const displayNameError = signal<string | null>(null)

// Identifies which persona (or the create form) the fields were last seeded
// for, so re-opening re-seeds. Reset to null on close so re-opening the SAME
// persona after a cancel/submit re-seeds instead of showing the emptied form.
let lastEditKey: string | null = null

function resetForm(): void {
  formFields.value = emptyForm()
  nameError.value = null
  displayNameError.value = null
  submitting.value = false
}

function initEdit(persona: PersonaSummary): void {
  // Only identity fields are available from the persona list summary; the
  // keeper-template fields start blank (blank = keep current on update).
  formFields.value = {
    ...emptyForm(),
    persona_name: persona.name,
    display_name: persona.displayName ?? '',
    role: persona.role ?? '',
    trait: persona.description ?? '',
  }
  nameError.value = null
  displayNameError.value = null
  submitting.value = false
}

function validate(isEdit: boolean): boolean {
  const f = formFields.value
  let ok = true
  if (!isEdit && !f.persona_name.trim()) {
    nameError.value = '페르소나 이름은 필수입니다'
    ok = false
  } else {
    nameError.value = null
  }
  // display_name maps to the profile's top-level "name" and is required by
  // masc_persona_create; validate here to avoid a round-trip error.
  if (!f.display_name.trim()) {
    displayNameError.value = '표시 이름은 필수입니다'
    ok = false
  } else {
    displayNameError.value = null
  }
  return ok
}

function parseMentionTargets(raw: string): string[] {
  return raw
    .split(',')
    .map(s => s.trim())
    .filter(s => s.length > 0)
}

async function handleSubmit(e: Event): Promise<void> {
  e.preventDefault()
  const editing = editingPersona.value
  const isEdit = editing !== null
  if (!validate(isEdit)) return
  submitting.value = true

  const f = formFields.value
  const mentionTargets = parseMentionTargets(f.mention_targets)
  // Keeper-template text fields: on edit an empty field means "keep current"
  // (omitted from the partial-merge update); on create an empty field is just
  // omitted. Either way we forward only non-empty values.
  const shared = {
    display_name: f.display_name.trim(),
    role: f.role.trim() || undefined,
    trait: f.trait.trim() || undefined,
    goal: f.goal.trim() || undefined,
    instructions: f.instructions.trim() || undefined,
    mention_targets: mentionTargets.length > 0 ? mentionTargets : undefined,
  }

  let ok: boolean
  if (editing) {
    ok = await updatePersona(editing.name, shared)
  } else {
    // proactive_enabled has no blank state, so it is only set on create.
    ok = await createPersona({
      persona_name: f.persona_name.trim(),
      ...shared,
      proactive_enabled: f.proactive_enabled,
    })
  }

  submitting.value = false
  if (ok) closeForm()
}

function closeForm(): void {
  resetForm()
  lastEditKey = null
  showCreateForm.value = false
  editingPersona.value = null
}

function handleCancel(): void {
  closeForm()
}

function setField<K extends keyof FormFields>(key: K, value: FormFields[K]): void {
  const f = { ...formFields.value }
  f[key] = value
  formFields.value = f
  if (key === 'persona_name' && typeof value === 'string' && value.trim()) {
    nameError.value = null
  }
  if (key === 'display_name' && typeof value === 'string' && value.trim()) {
    displayNameError.value = null
  }
}

export function PersonaForm(): any {
  const editing = editingPersona.value
  const isEdit = editing !== null
  const isVisible = isEdit || showCreateForm.value

  if (!isVisible) return null

  const editKey = editing ? editing.name : '__create__'
  if (editKey !== lastEditKey) {
    lastEditKey = editKey
    if (editing) {
      initEdit(editing)
    } else {
      resetForm()
    }
  }

  const f = formFields.value
  const title = isEdit
    ? `페르소나 편집: ${editing!.displayName ?? editing!.name}`
    : '새 페르소나 생성'

  const sectionLabel = (text: string) => html`
    <p class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-wide mt-1">${text}</p>
  `

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 mb-3">
      <div class="flex items-center justify-between mb-3">
        <h3 class="text-sm text-[var(--color-fg-secondary)] font-medium">${title}</h3>
        <${ActionButton} variant="subtle" size="sm" onClick=${handleCancel}>취소<//>
      </div>

      <form onSubmit=${handleSubmit} class="flex flex-col gap-3">
        ${sectionLabel('정체성')}
        ${isEdit ? null : html`
        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-name-input">
            이름 <span class="text-[var(--color-status-error)]">*</span>
          </label>
          <${TextInput}
            id="persona-name-input"
            value=${f.persona_name}
            onInput=${(e: Event) => setField('persona_name', (e.target as HTMLInputElement).value)}
            placeholder="예: code-reviewer"
            required=${true}
            aria-invalid=${nameError.value !== null ? 'true' : undefined}
          />
          ${nameError.value ? html`<p class="text-3xs text-[var(--color-status-error)] mt-0.5">${nameError.value}</p>` : null}
        </div>
        `}

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-display-input">
            표시 이름 <span class="text-[var(--color-status-error)]">*</span>
          </label>
          <${TextInput}
            id="persona-display-input"
            value=${f.display_name}
            onInput=${(e: Event) => setField('display_name', (e.target as HTMLInputElement).value)}
            placeholder="예: 코드 리뷰어"
            aria-invalid=${displayNameError.value !== null ? 'true' : undefined}
          />
          ${displayNameError.value ? html`<p class="text-3xs text-[var(--color-status-error)] mt-0.5">${displayNameError.value}</p>` : null}
        </div>

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-role-input">역할</label>
          <${TextInput}
            id="persona-role-input"
            value=${f.role}
            onInput=${(e: Event) => setField('role', (e.target as HTMLInputElement).value)}
            placeholder="예: reviewer, assistant, operator"
          />
        </div>

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-trait-input">특성</label>
          <${TextArea}
            id="persona-trait-input"
            value=${f.trait}
            onInput=${(e: Event) => setField('trait', (e.target as HTMLTextAreaElement).value)}
            placeholder="이 페르소나의 성향을 간략히 설명하세요"
            rows=${2}
          />
        </div>

        ${sectionLabel('키퍼 기본값')}
        ${isEdit ? html`<p class="text-3xs text-[var(--color-fg-muted)]">비워두면 기존 값이 유지됩니다.</p>` : null}
        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-goal-input">목표</label>
          <${TextArea}
            id="persona-goal-input"
            value=${f.goal}
            onInput=${(e: Event) => setField('goal', (e.target as HTMLTextAreaElement).value)}
            placeholder="이 페르소나로 생성된 키퍼가 추구할 목표"
            rows=${2}
          />
        </div>

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-instructions-input">행동 지침</label>
          <${TextArea}
            id="persona-instructions-input"
            value=${f.instructions}
            onInput=${(e: Event) => setField('instructions', (e.target as HTMLTextAreaElement).value)}
            placeholder="키퍼의 행동 규칙과 지침"
            rows=${3}
          />
        </div>

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-mentions-input">멘션 대상</label>
          <${TextInput}
            id="persona-mentions-input"
            value=${f.mention_targets}
            onInput=${(e: Event) => setField('mention_targets', (e.target as HTMLInputElement).value)}
            placeholder="쉼표로 구분 (예: reviewer, 리뷰어)"
          />
        </div>

        ${isEdit ? null : html`
        <label class="v2-mobile-operator-target cursor-pointer flex items-center gap-2 text-2xs text-[var(--color-fg-secondary)]">
          <${Checkbox}
            checked=${f.proactive_enabled}
            ariaLabel="능동 활성화"
            onChange=${(checked: boolean) => setField('proactive_enabled', checked)}
          />
          능동적 동작 활성화 (지시 없이도 스스로 행동)
        </label>
        `}

        <div class="flex gap-2 justify-end mt-1">
          <${ActionButton} variant="ghost" size="sm" onClick=${handleCancel} type="button">취소<//>
          <${ActionButton} variant="primary" size="sm" disabled=${submitting.value} type="submit">
            ${submitting.value
              ? (isEdit ? '수정 중...' : '생성 중...')
              : (isEdit ? '수정 완료' : '생성')}
          <//>
        </div>
      </form>
    </div>
  `
}
