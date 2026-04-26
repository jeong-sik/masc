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
import { Checkbox } from './common/checkbox'
import { CopyableCode } from './common/copyable-code'
import { LoadingState } from './common/feedback-state'
import { TextInput } from './common/input'
import { showToast } from './common/toast'

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
  saving: boolean
  lastSavedAt: number | null
  restarting: boolean
  autoRestart: boolean
}

const formState = signal<Record<string, FormEntry>>({})

function emptyEntry(): FormEntry {
  return {
    fields: [],
    values: {},
    reveal: {},
    loading: false,
    error: null,
    open: false,
    saving: false,
    lastSavedAt: null,
    restarting: false,
    autoRestart: false,
  }
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

// Where-to-find hints for credentials. Pydantic `description` fields cover
// "what this is"; FIELD_HINTS covers "where do I click to obtain it" — the
// question operators actually ask. Keys match the BotConfig field name
// verbatim. Absent keys render nothing (no fabrication for unknown fields).
interface FieldHint {
  where: string
  url?: string
}

const FIELD_HINTS: Record<string, FieldHint> = {
  DISCORD_BOT_TOKEN: {
    where: 'Discord Developer Portal → Applications → <your app> → Bot → Reset Token',
    url: 'https://discord.com/developers/applications',
  },
  SLACK_BOT_TOKEN: {
    where: 'Slack App → OAuth & Permissions → Bot User OAuth Token (xoxb-…)',
    url: 'https://api.slack.com/apps',
  },
  SLACK_APP_TOKEN: {
    where: 'Slack App → Basic Information → App-Level Tokens → Generate (xapp-…)',
    url: 'https://api.slack.com/apps',
  },
  SLACK_SIGNING_SECRET: {
    where: 'Slack App → Basic Information → App Credentials → Signing Secret',
    url: 'https://api.slack.com/apps',
  },
  TELEGRAM_BOT_TOKEN: {
    where: '@BotFather → /newbot (또는 기존 봇이면 /token)',
    url: 'https://t.me/BotFather',
  },
}

function getFieldHint(name: string): FieldHint | null {
  return FIELD_HINTS[name] ?? null
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

interface ConfigReadResponse {
  ok: boolean
  exists: boolean
  values: Record<string, string>
}

async function fetchCurrentValues(id: string): Promise<Record<string, string>> {
  // 4xx is fine here — most likely cause is "config.toml never written" or
  // tool_auth not configured for the read. Either way the form should fall
  // back to schema defaults rather than block on the prefill.
  try {
    const res = await fetch(`/api/v1/sidecar/config?name=${encodeURIComponent(id)}`, {
      headers: { Accept: 'application/json' },
    })
    if (!res.ok) return {}
    const data = (await res.json()) as ConfigReadResponse
    if (!data.ok || !data.exists) return {}
    return data.values ?? {}
  } catch {
    return {}
  }
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
    const current = await fetchCurrentValues(id)
    const values: Record<string, string> = {}
    for (const f of fields) {
      // Operator's saved value wins over schema default; we keep the
      // empty string only when the operator has explicitly cleared it.
      values[f.name] = current[f.name] ?? defaultToString(f.default)
    }
    setEntry(id, { fields, values, loading: false })
  } catch (err) {
    setEntry(id, {
      loading: false,
      error: err instanceof Error ? err.message : 'schema fetch failed',
    })
  }
}

function missingRequired(entry: FormEntry): string[] {
  return entry.fields
    .filter(f => f.required && (entry.values[f.name] ?? '').trim() === '')
    .map(f => f.name)
}

async function saveConfig(id: string) {
  const entry = getEntry(id)
  const missing = missingRequired(entry)
  if (missing.length > 0) {
    showToast(`필수 필드 비어있음: ${missing.join(', ')}`, 'error')
    return
  }
  setEntry(id, { saving: true })
  try {
    const res = await fetch(`/api/v1/sidecar/config?name=${encodeURIComponent(id)}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify(entry.values),
    })
    if (!res.ok) {
      const text = await res.text()
      throw new Error(`HTTP ${res.status}${text ? `: ${text.slice(0, 200)}` : ''}`)
    }
    setEntry(id, { saving: false, lastSavedAt: Date.now() })
    if (getEntry(id).autoRestart) {
      // Auto-restart path: apply-config chains save → apply so the
      // operator doesn't have to click 🔄. "apply" is a soft restart —
      // stop is best-effort (sidecar may be down), start is strict.
      showToast(`${id} config 저장됨 — 자동 적용 중...`, 'success', 1500)
      await applyConfigChange(id)
    } else {
      showToast(`${id} config 저장됨 — sidecar 재시작 시 반영`, 'success', 2400)
    }
  } catch (err) {
    setEntry(id, { saving: false })
    showToast(err instanceof Error ? err.message : 'config save failed', 'error')
  }
}

/** Soft restart: stop (best-effort — sidecar may already be down),
    800ms grace, then start (strict). Used both as the backing for the
    manual 🔄 button and as the auto-restart step after save. */
async function applyConfigChange(id: string) {
  setEntry(id, { restarting: true })
  try {
    try {
      await fetch(`/api/v1/sidecar/stop?name=${encodeURIComponent(id)}`, {
        method: 'POST',
        headers: { Accept: 'application/json' },
      })
    } catch {
      // Stop failures are non-fatal here — target might not be running.
    }
    await new Promise(r => setTimeout(r, 800))
    const startRes = await fetch(`/api/v1/sidecar/start?name=${encodeURIComponent(id)}`, {
      method: 'POST',
      headers: { Accept: 'application/json' },
    })
    if (!startRes.ok) throw new Error(`start HTTP ${startRes.status}`)
    showToast(`${id} 재시작 완료 — 새 config 적용됨`, 'success', 2400)
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'apply failed', 'error')
  } finally {
    setEntry(id, { restarting: false })
  }
}

async function restartSidecar(id: string) {
  // Manual 🔄 button and auto-restart both route through the same soft
  // restart — the only difference is who triggered it.
  await applyConfigChange(id)
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
      class="cursor-pointer rounded border border-[var(--white-8)] px-2 py-0.5 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)] hover:bg-[var(--white-8)] hover:text-[var(--color-fg-primary)]"
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
  const onCheckbox = (checked: boolean) => {
    setEntry(id, { values: { ...getEntry(id).values, [field.name]: checked ? 'true' : 'false' } })
  }
  const toggleReveal = () => {
    setEntry(id, { reveal: { ...getEntry(id).reveal, [field.name]: !revealed } })
  }

  // baseInput — preserved for the type=number branch which still uses
  // a raw <input type="number"> until NumberInput migration handles
  // signal-typed numeric values across the form.
  const baseInput = 'w-full rounded border border-[var(--white-8)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-2xs text-[var(--color-fg-primary)] focus:border-[var(--accent-1)] focus:outline-none'
  // tightMonoOverride — TextInput class extension. INPUT_BASE owns
  // border/text/placeholder/focus-visible. Only the size/font/bg need
  // overrides to match the compact mono-style of the connector form
  // (INPUT_BASE defaults to text-sm + py-2 + bg-white-4).
  const tightMonoOverride = '!border-[var(--white-8)] !bg-[var(--color-bg-page)] !px-2 !py-1 !text-2xs font-mono'

  switch (field.type) {
    case 'boolean':
      return html`
        <label class="flex items-center gap-2 text-2xs text-[var(--color-fg-primary)]">
          <${Checkbox}
            checked=${value === 'true'}
            ariaLabel=${field.name}
            onChange=${onCheckbox}
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
            <${TextInput}
              type=${revealed ? 'text' : 'password'}
              value=${value}
              onInput=${onInput}
              placeholder=${field.required ? '필수 — 토큰을 붙여넣으세요' : ''}
              class=${tightMonoOverride}
            />
            <button
              type="button"
              class="shrink-0 cursor-pointer rounded border border-[var(--white-8)] p-1 text-[var(--color-fg-disabled)] hover:bg-[var(--white-8)] hover:text-[var(--color-fg-primary)]"
              aria-label=${revealed ? '값 숨기기' : '값 표시'}
              onClick=${toggleReveal}
            >
              ${revealed ? html`<${EyeOff} size=${12} />` : html`<${Eye} size=${12} />`}
            </button>
          </div>
        `
      }
      return html`
        <${TextInput}
          type="text"
          value=${value}
          onInput=${onInput}
          placeholder=${defaultToString(field.default)}
          class=${tightMonoOverride}
        />
      `
    default:
      return html`
        <div class="rounded border border-[var(--warn-20)] bg-[var(--warn-10)] px-2 py-1 text-3xs text-[var(--color-status-warn)]">
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
      <div id=${`connector-config-${connectorId}`} class="mt-3 rounded border border-[var(--white-8)] bg-[var(--color-bg-surface)] p-3">
        <${LoadingState}>config schema 불러오는 중...<//>
      </div>
    `
  }

  if (entry.error !== null) {
    return html`
      <div id=${`connector-config-${connectorId}`} class="mt-3 rounded border border-[var(--bad-20)] bg-[var(--bad-10)] p-3 text-2xs text-[var(--bad-light)]">
        <div class="font-semibold">schema 가져오기 실패</div>
        <div class="mt-1 text-3xs opacity-80">${entry.error}</div>
        <button
          type="button"
          class="mt-2 cursor-pointer rounded border border-[var(--bad-20)] px-2 py-1 text-3xs hover:bg-[var(--bad-10)]"
          onClick=${() => fetchSchema(connectorId)}
        >다시 시도</button>
      </div>
    `
  }

  if (entry.fields.length === 0) {
    return html`
      <div id=${`connector-config-${connectorId}`} class="mt-3 rounded border border-[var(--white-8)] bg-[var(--color-bg-surface)] p-3 text-2xs text-[var(--color-fg-disabled)]">
        schema가 비어있습니다. backend가 sidecar venv를 못 찾았을 수 있어요.
      </div>
    `
  }

  const envBlock = buildEnvBlock(entry)

  return html`
    <div id=${`connector-config-${connectorId}`} class="mt-3 rounded border border-[var(--white-8)] bg-[var(--color-bg-surface)] p-3">
      <div class="mb-2 flex items-center justify-between">
        <div class="text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">
          ${entry.fields.length} fields · ${entry.fields.filter(f => f.required).length} required
          ${entry.lastSavedAt
            ? html`
                <span class="ml-2 text-[var(--color-status-ok)]">· 저장됨 ${new Date(entry.lastSavedAt).toLocaleTimeString()}</span>
                <button
                  type="button"
                  class="ml-2 cursor-pointer rounded border border-[var(--ok-20)] bg-[var(--ok-10)] px-1.5 py-0.5 text-3xs text-[var(--color-status-ok)] hover:bg-[var(--ok-10)] disabled:cursor-not-allowed disabled:opacity-50"
                  disabled=${entry.restarting}
                  title="POST /sidecar/stop → 800ms → POST /sidecar/start"
                  onClick=${() => { void restartSidecar(connectorId) }}
                >
                  ${entry.restarting ? '재시작 중...' : '🔄 재시작'}
                </button>
              `
            : null}
        </div>
        <div class="flex items-center gap-2">
          <label
            class="flex cursor-pointer items-center gap-1 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)]"
            title="저장 직후 자동으로 sidecar 재시작 (stop → 800ms → start)"
          >
            <${Checkbox}
              checked=${entry.autoRestart}
              testId="auto-restart-toggle"
              ariaLabel="자동 재시작"
              onChange=${(checked: boolean) => {
                setEntry(connectorId, { autoRestart: checked })
              }}
            />
            <span>자동 재시작</span>
          </label>
          <${ActionButton}
            variant="ghost"
            size="sm"
            disabled=${entry.saving || entry.restarting || missingRequired(entry).length > 0}
            title=${missingRequired(entry).length > 0
              ? `필수 필드: ${missingRequired(entry).join(', ')}`
              : entry.autoRestart
                ? 'POST /sidecar/config → stop → 800ms → start'
                : 'POST /api/v1/sidecar/config — sidecar 재시작 시 반영'}
            onClick=${() => { void saveConfig(connectorId) }}
          >
            ${entry.saving
              ? '저장 중...'
              : entry.restarting
                ? '적용 중...'
                : entry.autoRestart
                  ? 'Save & Apply'
                  : 'Save'}
          <//>
        </div>
      </div>

      <div class="space-y-2.5">
        ${entry.fields.map(field => html`
          <div class="flex flex-col gap-1">
            <label class="flex items-center gap-1.5 text-2xs font-medium text-[var(--color-fg-primary)]" for=${`field-${connectorId}-${field.name}`}>
              <span>${field.name}</span>
              ${field.required ? html`<span class="text-[var(--bad-light)]" aria-label="required">*</span>` : null}
              <span class="text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">${field.type}</span>
            </label>
            <${FieldWidget}
              id=${connectorId}
              field=${field}
              value=${entry.values[field.name] ?? ''}
              revealed=${entry.reveal[field.name] === true}
            />
            ${field.description
              ? html`<div class="text-3xs text-[var(--color-fg-disabled)]">${field.description}</div>`
              : null}
            ${(() => {
              const hint = getFieldHint(field.name)
              if (hint === null) return null
              return html`
                <div class="rounded border border-[var(--accent-20)] bg-[var(--accent-10)]0/5 px-2 py-1 text-3xs text-[var(--color-accent-fg)]" data-field-hint=${field.name}>
                  <span class="mr-1" aria-hidden="true">📍</span>
                  <span>${hint.where}</span>
                  ${hint.url
                    ? html`
                        <a
                          href=${hint.url}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="ml-1 underline hover:text-[var(--color-accent-fg)]"
                        >열기 ↗</a>
                      `
                    : null}
                </div>
              `
            })()}
          </div>
        `)}
      </div>

      <div class="mt-3 border-t border-[var(--white-8)] pt-2.5">
        <div class="mb-1 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">
          .env 블록 (현재 입력값)
        </div>
        ${envBlock === ''
          ? html`<div class="text-3xs text-[var(--color-fg-disabled)]">(필수 필드를 채우면 여기에 표시됩니다)</div>`
          : html`<${CopyableCode} command=${envBlock} ariaLabel=${`Copy ${connectorId} .env block`} />`}
      </div>
    </div>
  `
}

export function resetConnectorConfigState() {
  formState.value = {}
}

/** Open the config form panel for [id], lazily fetching schema if not loaded.
    Used by ConnectorReadinessRail when the operator clicks the Token pill. */
export function openConnectorConfig(id: string) {
  const entry = getEntry(id)
  if (!entry.open) {
    setEntry(id, { open: true })
    if (entry.fields.length === 0 && !entry.loading) {
      void fetchSchema(id)
    }
  }
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

export function _testGetFieldHint(name: string): FieldHint | null {
  return getFieldHint(name)
}
