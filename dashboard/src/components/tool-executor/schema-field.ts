import { html } from 'htm/preact'
import { TextInput, TextArea } from '../common/input'
import { Select } from '../common/select'
import { NumberInput } from '../common/number-input'
import { Checkbox } from '../common/checkbox'
import type { JsonSchemaProperty } from '../../types/json-schema'

const LONG_TEXT_PATTERN = /body|content|description|message|text|reason|prompt|query|markdown/i

interface SchemaFieldProps {
  name: string
  schema: JsonSchemaProperty
  value: unknown
  required: boolean
  onChange: (name: string, value: unknown) => void
}

export function SchemaField({ name, schema, value, required, onChange }: SchemaFieldProps) {
  const requiredMark = required
    ? html`<span class="text-[var(--color-status-err)] ml-0.5">*</span>`
    : null

  const hint = schema.description
    ? html`<span class="text-3xs text-[var(--color-fg-muted)] mt-0.5">${schema.description}</span>`
    : null

  if (schema.type === 'string' && schema.enum) {
    return html`
      <div class="v2-lab-row flex flex-col gap-1">
        <label class="text-2xs text-[var(--color-fg-muted)] font-medium">${name}${requiredMark}</label>
        ${hint}
        <${Select} value=${(value as string) ?? ''} options=${schema.enum} placeholder="-- 선택 --"
          onInput=${(v: string) => onChange(name, v)} />
      </div>
    `
  }

  if (schema.type === 'string') {
    const isLong = LONG_TEXT_PATTERN.test(name)
    if (isLong) {
      return html`
        <div class="v2-lab-row flex flex-col gap-1">
          <label class="text-2xs text-[var(--color-fg-muted)] font-medium">${name}${requiredMark}</label>
          ${hint}
          <${TextArea} value=${(value as string) ?? (schema.default as string) ?? ''} placeholder=${name} rows=${3}
            onInput=${(e: Event) => onChange(name, (e.target as HTMLTextAreaElement).value)} />
        </div>
      `
    }
    return html`
      <div class="v2-lab-row flex flex-col gap-1">
        <label class="text-2xs text-[var(--color-fg-muted)] font-medium">${name}${requiredMark}</label>
        ${hint}
        <${TextInput} value=${(value as string) ?? (schema.default as string) ?? ''} placeholder=${name}
          onInput=${(e: Event) => onChange(name, (e.target as HTMLInputElement).value)} />
      </div>
    `
  }

  if (schema.type === 'integer' || schema.type === 'number') {
    return html`
      <div class="v2-lab-row flex flex-col gap-1">
        <label class="text-2xs text-[var(--color-fg-muted)] font-medium">${name}${requiredMark}</label>
        ${hint}
        <${NumberInput} value=${(value as number) ?? (schema.default as number) ?? ''} placeholder=${name}
          step=${schema.type === 'integer' ? 1 : 'any'} onInput=${(v: number | undefined) => onChange(name, v)} />
      </div>
    `
  }

  if (schema.type === 'boolean') {
    return html`
      <label class="v2-lab-row v2-mobile-operator-target flex items-center gap-2 py-1">
        <${Checkbox} checked=${(value as boolean) ?? (schema.default as boolean) ?? false}
          onChange=${(v: boolean) => onChange(name, v)} />
        <span class="text-xs text-[var(--color-fg-primary)]">${name}${requiredMark}</span>
        ${schema.description ? html`<span class="text-3xs text-[var(--color-fg-muted)]">- ${schema.description}</span>` : null}
      </label>
    `
  }

  if (schema.type === 'array' && schema.items?.type === 'string') {
    const strValue = Array.isArray(value) ? (value as string[]).join('\n') : ''
    return html`
      <div class="v2-lab-row flex flex-col gap-1">
        <label class="text-2xs text-[var(--color-fg-muted)] font-medium">${name}${requiredMark}
          <span class="font-normal"> (줄바꿈으로 구분)</span></label>
        ${hint}
        <${TextArea} value=${strValue} placeholder=${name} rows=${3}
          onInput=${(e: Event) => {
            const lines = (e.target as HTMLTextAreaElement).value.split('\n').filter(Boolean)
            onChange(name, lines)
          }} />
      </div>
    `
  }

  const rawValue = value === undefined || value === null ? ''
    : typeof value === 'string' ? value : JSON.stringify(value, null, 2)
  return html`
    <div class="v2-lab-row flex flex-col gap-1">
      <label class="text-2xs text-[var(--color-fg-muted)] font-medium">${name}${requiredMark}
        <span class="font-normal"> (JSON)</span></label>
      ${hint}
      <${TextArea} value=${rawValue} placeholder=${'{ ... }'} rows=${4} class="font-mono text-xs"
        onInput=${(e: Event) => {
          const raw = (e.target as HTMLTextAreaElement).value
          try { onChange(name, JSON.parse(raw)) } catch { /* typing */ }
        }} />
    </div>
  `
}
