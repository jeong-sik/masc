import { html } from 'htm/preact'
import type { JsonSchema } from '../../types/json-schema'
import { SchemaField } from './schema-field'

interface SchemaFormProps {
  schema: JsonSchema
  values: Record<string, unknown>
  onChange: (values: Record<string, unknown>) => void
}

export function SchemaForm({ schema, values, onChange }: SchemaFormProps) {
  if (!schema.properties || Object.keys(schema.properties).length === 0) {
    return html`<p class="text-[var(--text-muted)] text-xs py-2">이 도구는 파라미터가 없습니다.</p>`
  }

  const required = new Set(schema.required ?? [])
  const entries = Object.entries(schema.properties)
  const sorted = [
    ...entries.filter(([k]) => required.has(k)),
    ...entries.filter(([k]) => !required.has(k)),
  ]

  const handleFieldChange = (name: string, value: unknown) => {
    onChange({ ...values, [name]: value })
  }

  return html`
    <div class="flex flex-col gap-3" role="form" aria-label="도구 파라미터">
      ${sorted.map(([name, prop]) => html`
        <${SchemaField} key=${name} name=${name} schema=${prop} value=${values[name]}
          required=${required.has(name)} onChange=${handleFieldChange} />
      `)}
    </div>
  `
}

export function buildDefaults(schema: JsonSchema): Record<string, unknown> {
  const defaults: Record<string, unknown> = {}
  if (!schema.properties) return defaults
  for (const [name, prop] of Object.entries(schema.properties)) {
    if (prop.default !== undefined) defaults[name] = prop.default
  }
  return defaults
}

export function stripEmptyOptionals(values: Record<string, unknown>, schema: JsonSchema): Record<string, unknown> {
  const required = new Set(schema.required ?? [])
  const result: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(values)) {
    if (required.has(key)) { result[key] = value; continue }
    if (value === undefined || value === null || value === '') continue
    if (Array.isArray(value) && value.length === 0) continue
    result[key] = value
  }
  return result
}

export function validateRequired(values: Record<string, unknown>, schema: JsonSchema): string[] {
  const missing: string[] = []
  for (const name of schema.required ?? []) {
    const val = values[name]
    if (val === undefined || val === null || val === '') missing.push(name)
  }
  return missing
}
