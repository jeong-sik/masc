// PersonaForm — create/edit persona form for the dashboard.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { TextInput, TextArea } from '../common/input'
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
  mode: string
  description: string
}

const emptyForm = (): FormFields => ({
  persona_name: '',
  display_name: '',
  role: '',
  mode: '',
  description: '',
})

const formFields = signal<FormFields>(emptyForm())
const submitting = signal(false)
const nameError = signal<string | null>(null)

function resetForm(): void {
  formFields.value = emptyForm()
  nameError.value = null
  submitting.value = false
}

function initEdit(persona: PersonaSummary): void {
  formFields.value = {
    persona_name: persona.name,
    display_name: persona.displayName ?? '',
    role: persona.role ?? '',
    mode: persona.mode ?? '',
    description: persona.description ?? '',
  }
  nameError.value = null
  submitting.value = false
}

function validate(): boolean {
  const f = formFields.value
  if (!f.persona_name.trim()) {
    nameError.value = '\ud398\ub974\uc18c\ub098 \uc774\ub984\uc740 \ud544\uc218\uc785\ub2c8\ub2e4'
    return false
  }
  nameError.value = null
  return true
}

async function handleSubmit(e: Event): Promise<void> {
  e.preventDefault()
  if (!validate()) return
  submitting.value = true

  const f = formFields.value
  const fields = {
    persona_name: f.persona_name.trim(),
    display_name: f.display_name.trim() || undefined,
    role: f.role.trim() || undefined,
    mode: f.mode.trim() || undefined,
    description: f.description.trim() || undefined,
  }

  const editing = editingPersona.value
  let ok: boolean
  if (editing) {
    ok = await updatePersona(editing.name, {
      display_name: fields.display_name,
      role: fields.role,
      mode: fields.mode,
      description: fields.description,
    })
  } else {
    ok = await createPersona(fields)
  }

  submitting.value = false
  if (ok) resetForm()
}

function handleCancel(): void {
  resetForm()
  showCreateForm.value = false
  editingPersona.value = null
}

function setField(key: keyof FormFields, value: string): void {
  const f = { ...formFields.value }
  f[key] = value
  formFields.value = f
  if (key === 'persona_name' && value.trim()) {
    nameError.value = null
  }
}

let lastEditKey: string | null = null

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
    ? `\ud398\ub974\uc18c\ub098 \ud3b8\uc9d1: ${editing!.displayName ?? editing!.name}`
    : '\uc0c8 \ud398\ub974\uc18c\ub098 \uc0dd\uc131'

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 mb-3">
      <div class="flex items-center justify-between mb-3">
        <h3 class="text-sm text-[var(--color-fg-secondary)] font-medium">${title}</h3>
        <${ActionButton} variant="subtle" size="sm" onClick=${handleCancel}>\ucee4\uc2ec<//>
      </div>

      <form onSubmit=${handleSubmit} class="flex flex-col gap-3">
        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-name-input">
            \uc774\ub984 ${!isEdit ? html`<span class="text-[var(--color-status-error)]">*</span>` : ''}
          </label>
          <${TextInput}
            id="persona-name-input"
            value=${f.persona_name}
            onInput=${(e: Event) => setField('persona_name', (e.target as HTMLInputElement).value)}
            placeholder="\uc608: code-reviewer"
            disabled=${isEdit}
            required=${!isEdit}
            aria-invalid=${nameError.value !== null ? 'true' : undefined}
          />
          ${nameError.value ? html`<p class="text-3xs text-[var(--color-status-error)] mt-0.5">${nameError.value}</p>` : null}
        </div>

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-display-input">\ud45c\uc2dc \uc774\ub984</label>
          <${TextInput}
            id="persona-display-input"
            value=${f.display_name}
            onInput=${(e: Event) => setField('display_name', (e.target as HTMLInputElement).value)}
            placeholder="\uc608: \ucf54\ub4dc \ub9ac\ubdf0\uc5b4"
          />
        </div>

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-role-input">\uc5ed\ud560</label>
          <${TextInput}
            id="persona-role-input"
            value=${f.role}
            onInput=${(e: Event) => setField('role', (e.target as HTMLInputElement).value)}
            placeholder="\uc608: reviewer, assistant, operator"
          />
        </div>

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-mode-input">\ubaa8\ub4dc</label>
          <${TextInput}
            id="persona-mode-input"
            value=${f.mode}
            onInput=${(e: Event) => setField('mode', (e.target as HTMLInputElement).value)}
            placeholder="\uc608: chat, agent, tool"
          />
        </div>

        <div>
          <label class="text-2xs text-[var(--color-fg-muted)] block mb-1" for="persona-desc-input">\uc124\uba85</label>
          <${TextArea}
            id="persona-desc-input"
            value=${f.description}
            onInput=${(e: Event) => setField('description', (e.target as HTMLInputElement).value)}
            placeholder="\uc774 \ud398\ub974\uc18c\ub098\uc758 \ud2b9\uc9d5\uacfc \ubaa9\uc801\uc744 \uac04\ub7b5\ud788 \uc124\uba85\ud558\uc138\uc694"
            rows=${3}
          />
        </div>

        <div class="flex gap-2 justify-end mt-1">
          <${ActionButton} variant="ghost" size="sm" onClick=${handleCancel} type="button">\ucee4\uc2ec<//>
          <${ActionButton} variant="primary" size="sm" disabled=${submitting.value} type="submit">
            ${submitting.value
              ? (isEdit ? '\uc218\uc815 \uc911...' : '\uc0dd\uc131 \uc911...')
              : (isEdit ? '\uc218\uc815 \uc644\ub8cc' : '\uc0dd\uc131')}
          <//>
        </div>
      </form>
    </div>
  `
}