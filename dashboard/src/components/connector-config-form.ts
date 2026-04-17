// ConnectorConfigForm — schema-driven config editor for a sidecar.
//
// Fetches `/api/v1/sidecar/schema?name=<id>` (served by backend that shells
// out to `python -m src.schema_dump`) and renders one widget per BotConfig
// field. The form is editable in-browser so operators can paste tokens and
// confirm shape, but Save is disabled until the backend PUT endpoint lands —
// today the operator copies the rendered .env block into their shell.
//
// Sensitive fields (anything matching /token|secret|password|api_key/i in
// the field name) get a password-masked input + reveal toggle so the value
// doesn't sit in plain text on the operator's screen.
//
// We don't try to parse the schema's full JSON Schema vocabulary — only
// type ∈ {string, integer, number, boolean}, default, and the top-level
// `required` array. Nested objects/$defs would mean the BotConfig got
// refactored in a way the form can't represent; we surface that as
// "unsupported field" so the regression is visible instead of silent.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { Eye, EyeOff } from 'lucide-preact'
import { ActionButton } from './common/button'
import { CopyableCode } from './common/copyable-code'
import { LoadingState } from './common/feedback-state'

type FieldType = 'string' | 'integer' | 'number' | 'boolean' | 'unknown'

interface FieldShape {
  name: string
  type: FieldType
  required: boolean
  default: string | number | boolean | null
  title: string | null
  description: string | null
}

interface SchemaResponse {
  ok: boolean
  id: string
  schema: {
    description?: string
    properties?: Record<string, {
      title?: string
      description?: string
      type?: string
      default?: unknown
    }>
    required?: string[]
  }
}

interface FormEntry {
  fields: FieldShape[]
  values: Record<string, string>
  reveal: Record<string, boolean>
  loading: boolean
  error: string | null
  open: boolean
}

const formState = signal<Record<string, FormEntry>>({})

function emptyEntry(): FormEntry {
  return { fields: [], values: {}, reveal: {}, loading: false, error: null, open: false }
}

function getEntry(id: string): FormEntry {
  return formState.value[id] ?? emptyEntry()
}

function setEntry(id: string, patch: Partial<FormEntry>) {
  formState.value = { ...formState.value, [id]: { ...getEntry(id), ...patch } }
}

function classifyType(raw: string | undefined): FieldType {
  switch (raw) {
    case 'string':
    case 'integer':
    case 'number':
    case 'boolean':
      return raw
    default:
      return 'unknown'
  }
}

function isSensitive(name: string): boolean {
  return /token|secret|password|api[_-]?key/i.test(name)
}

function defaultToString(value: unknown): string {
  if (value === undefined || value === null) return ''
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  return String(value)
}

function parseSchema(payload: SchemaResponse): FieldShape[] {
  const props = payload.schema.properties ?? {}
  const required = new Set(payload.schema.required ?? [])
  return Object.entries(props)
    .map(([name, spec]) => ({
      name,
      type: classifyType(spec.type),
      required: required.has(name),
      default: (spec.default ?? null) as FieldShape['default'],
      title: spec.title ?? null,
      description: spec.description ?? null,
    }))
    .sort((a, b) => {
      if (a.required !== b.required) return a.required ? -1 : 1
      return a.name.localeCompare(b.name)
    })
}

async function fetchSchema(id: string) {
  setEntry(id, { loading: true, error: null })
  try {
    const res = await fetch(`/api/v1/sidecar/schema?name=${encodeURIComponent(id)}`, {
      headers: { Accept: 'application/json' },
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const data = (await res.json()) as SchemaResponse
    if (!data.ok) throw new Error('schema response missing ok=true')
    const fields = parseSchema(data)
    const values: Record<string, string> = {}
    for (const f of fields) values[f.name] = defaultToString(f.default)
    setEntry(id, { fields, values, loading: false })
  } catch (err) {
    setEntry(id, {
      loading: false,
      error: err instanceof Error ? err.message : 'schema fetch failed',
    })
  }
}

function buildEnvBlock(entry: FormEntry): string {
  const lines: string[] = []
  for (const f of entry.fields) {
    const value = entry.values[f.name] ?? ''
    if (value === '' && !f.required) continue
    lines.push(`${f.name}=${value}`)
  }
  return lines.join('\n')
}

export function ConnectorConfigToggle({ connectorId }: { connectorId: string }) {
  const entry = getEntry(connectorId)
  const onClick = () => {
    if (entry.open) {
      setEntry(connectorId, { open: false })
    } else {
      setEntry(connectorId, { open: true })
      if (entry.fields.length === 0 && !entry.loading) {
        void fetchSchema(connectorId)
      }
    }
  }
  return html`
    <button
      type="button"
      class="cursor-pointer rounded border border-[var(--white-8)] px-2 py-0.5 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:text-[var(--text-body)]"
      aria-expanded=${entry.open}
      aria-controls=${`connector-config-${connectorId}`}
      onClick=${onClick}
    >⚙ Config</button>
  `
}

function FieldWidget({ id, field, value, revealed }: {
  id: string
  field: FieldShape
  value: string
  revealed: boolean
}) {
  const onInput = (ev: Event) => {
    const target = ev.target as HTMLInputElement
    setEntry(id, { values: { ...getEntry(id).values, [field.name]: target.value } })
  }
  const onCheckbox = (ev: Event) => {
    const target = ev.target as HTMLInputElement
    setEntry(id, { values: { ...getEntry(id).values, [field.name]: target.checked ? 'true' : 'false' } })
  }
  const toggleReveal = () => {
    setEntry(id, { reveal: { ...getEntry(id).reveal, [field.name]: !revealed } })
  }

  const baseInput = 'w-full rounded border border-[var(--white-8)] bg-[var(--bg-0)] px-2 py-1 font-mono text-[11px] text-[var(--text-body)] focus:border-[var(--accent-1)] focus:outline-none'

  switch (field.type) {
    case 'boolean':
      return html`
        <label class="flex items-center gap-2 text-[11px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${value === 'true'}
            onInput=${onCheckbox}
            class="cursor-pointer"
          />
          <span>${value === 'true' ? 'enabled' : 'disabled'}</span>
        </label>
      `
    case 'integer':
    case 'number':
      return html`
        <input
          type="number"
          value=${value}
          onInput=${onInput}
          step=${field.type === 'integer' ? 1 : 'any'}
          placeholder=${defaultToString(field.default)}
          class=${baseInput}
        />
      `
    case 'string':
      if (isSensitive(field.name)) {
        return html`
          <div class="flex items-center gap-1">
            <input
              type=${revealed ? 'text' : 'password'}
              value=${value}
              onInput=${onInput}
              placeholder=${field.required ? '필수 — 토큰을 붙여넣으세요' : ''}
              class=${baseInput}
            />
            <button
              type="button"
              class="shrink-0 cursor-pointer rounded border border-[var(--white-8)] p-1 text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:text-[var(--text-body)]"
              aria-label=${revealed ? 'Hide value' : 'Reveal value'}
              onClick=${toggleReveal}
            >
              ${revealed ? html`<${EyeOff} size=${12} />` : html`<${Eye} size=${12} />`}
            </button>
          </div>
        `
      }
      return html`
        <input
          type="text"
          value=${value}
          onInput=${onInput}
          placeholder=${defaultToString(field.default)}
          class=${baseInput}
        />
      `
    default:
      return html`
        <div class="rounded border border-amber-400/30 bg-amber-500/10 px-2 py-1 text-[10px] text-amber-100">
          unsupported type — refactor BotConfig?
        </div>
      `
  }
}

export function ConnectorConfigForm({ connectorId }: { connectorId: string }) {
  const entry = getEntry(connectorId)
  if (!entry.open) return null

  useEffect(() => {
    if (entry.fields.length === 0 && !entry.loading && !entry.error) {
      void fetchSchema(connectorId)
    }
  }, [connectorId])

  if (entry.loading) {
    return html`
      <div id=${`connector-config-${connectorId}`} class="mt-3 rounded-md border border-[var(--white-8)] bg-[var(--bg-1)] p-3">
        <${LoadingState}>config schema 불러오는 중...<//>
      </div>
    `
  }

  if (entry.error !== null) {
    return html`
      <div id=${`connector-config-${connectorId}`} class="mt-3 rounded-md border border-rose-400/30 bg-rose-500/10 p-3 text-[11px] text-rose-100">
        <div class="font-semibold">schema 가져오기 실패</div>
        <div class="mt-1 text-[10px] opacity-80">${entry.error}</div>
        <button
          type="button"
          class="mt-2 cursor-pointer rounded border border-rose-400/40 px-2 py-1 text-[10px] hover:bg-rose-500/20"
          onClick=${() => fetchSchema(connectorId)}
        >다시 시도</button>
      </div>
    `
  }

  if (entry.fields.length === 0) {
    return html`
      <div id=${`connector-config-${connectorId}`} class="mt-3 rounded-md border border-[var(--white-8)] bg-[var(--bg-1)] p-3 text-[11px] text-[var(--text-dim)]">
        schema가 비어있습니다. backend가 sidecar venv를 못 찾았을 수 있어요.
      </div>
    `
  }

  const envBlock = buildEnvBlock(entry)

  return html`
    <div id=${`connector-config-${connectorId}`} class="mt-3 rounded-md border border-[var(--white-8)] bg-[var(--bg-1)] p-3">
      <div class="mb-2 flex items-center justify-between">
        <div class="text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">
          ${entry.fields.length} fields · ${entry.fields.filter(f => f.required).length} required
        </div>
        <${ActionButton}
          variant="ghost"
          size="sm"
          disabled=${true}
          title="저장 endpoint 준비 중 — 지금은 .env 복사 후 셸에서 적용"
        >
          Save (TODO)
        <//>
      </div>

      <div class="space-y-2.5">
        ${entry.fields.map(field => html`
          <div class="flex flex-col gap-1">
            <label class="flex items-center gap-1.5 text-[11px] font-medium text-[var(--text-body)]" for=${`field-${connectorId}-${field.name}`}>
              <span>${field.name}</span>
              ${field.required ? html`<span class="text-rose-400" aria-label="required">*</span>` : null}
              <span class="text-[9px] uppercase tracking-[0.14em] text-[var(--text-dim)]">${field.type}</span>
            </label>
            <${FieldWidget}
              id=${connectorId}
              field=${field}
              value=${entry.values[field.name] ?? ''}
              revealed=${entry.reveal[field.name] === true}
            />
            ${field.description
              ? html`<div class="text-[10px] text-[var(--text-dim)]">${field.description}</div>`
              : null}
          </div>
        `)}
      </div>

      <div class="mt-3 border-t border-[var(--white-8)] pt-2.5">
        <div class="mb-1 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">
          .env 블록 (현재 입력값)
        </div>
        ${envBlock === ''
          ? html`<div class="text-[10px] text-[var(--text-dim)]">(필수 필드를 채우면 여기에 표시됩니다)</div>`
          : html`<${CopyableCode} command=${envBlock} ariaLabel=${`Copy ${connectorId} .env block`} />`}
      </div>
    </div>
  `
}

export function resetConnectorConfigState() {
  formState.value = {}
}

export function _testParseSchema(payload: SchemaResponse): FieldShape[] {
  return parseSchema(payload)
}

export function _testBuildEnvBlock(fields: FieldShape[], values: Record<string, string>): string {
  return buildEnvBlock({ ...emptyEntry(), fields, values })
}

export function _testIsSensitive(name: string): boolean {
  return isSensitive(name)
}
