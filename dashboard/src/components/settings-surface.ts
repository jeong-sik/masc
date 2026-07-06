// MASC Dashboard — Settings surface
// Operator-facing settings only: runtime management, resolved paths, MCP server
// health/inventory, notification thresholds, prompt/fusion/log/display controls.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  SETTINGS_ROUTE_SECTION_IDS,
  type SettingsRouteSectionId,
} from '../config/navigation'
import { navigate, route } from '../router'
import { fetchDashboardConfig, fetchDashboardTools, fetchLogs, fetchRuntimeDefaults, fetchRuntimeProviders } from '../api/dashboard.js'
import type {
  ConfigEntry,
  DashboardConfigResponse,
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeProvidersResponse,
  DashboardToolInventoryItem,
  LogEntry,
  RuntimeEntry,
  RuntimeDefaultsResponse,
} from '../api/dashboard.js'
import {
  patchRuntimeMediaFailover,
  patchRuntimeRouting,
  type RuntimeRoutingLane,
} from '../api/dashboard.js'
import { callMcpTool } from '../api/mcp'
import { shellConfigResolution, shellRuntimeResolution } from '../store'
import type { DashboardConfigResolutionItem } from '../types'
import { RuntimeTomlEditor } from './runtime-toml-editor'
import { SettingsRepositoriesSection } from './settings-repositories'
import { FusionSettingsPanel } from './fusion-settings-panel'
import { PromptRegistryPanel } from './tools/prompt-registry-panel'
import { ThemeSwitch } from './theme-switch'
import { StatusChip } from './common/status-chip'
import { logDisplayKind } from './log-classification'
import { tweaksDensity, type Density } from './tweaks-panel'
import type { ComponentChildren } from 'preact'
import { errorToString } from '../lib/format-string'
import { refreshRuntimeConfigConsumers } from '../lib/runtime-config-refresh'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
  runtimeCatalogSnapshotFacts,
} from '../lib/runtime-provider-summary'

type SectionId = SettingsRouteSectionId

type LogFilter = 'all' | 'tool' | 'success' | 'failure'
type RuntimeRoutingSaveState = 'idle' | 'saving' | 'saved' | 'error'
type SettingsControlKind = 'live-read' | 'live-write' | 'browser-local' | 'unsupported'
type RuntimeSelectOption = {
  readonly id: string
  readonly label: string
}
export type SettingsControlInventoryItem = {
  readonly id: string
  readonly section: SectionId
  readonly label: string
  readonly kind: SettingsControlKind
  readonly source: string
  readonly action: string
}
const SETTINGS_ROUTE_SECTION_SET = new Set<string>(SETTINGS_ROUTE_SECTION_IDS)
const DEFAULT_SETTINGS_SECTION: SectionId = 'runtime'

const SET_SECTIONS: [SectionId, string, string][] = [
  ['runtime', 'Runtime', '런타임'],
  ['routing', 'Routing', '모델 라우팅'],
  ['runtimes', 'Runtimes', '런타임 관리'],
  ['paths', 'Paths', '경로 · Path'],
  ['mcp', 'MCP', 'MCP 서버'],
  ['repositories', 'Repositories', '저장소'],
  ['notify', 'Notify', '알림'],
  ['prompts', 'Prompts', '기본 프롬프트'],
  ['fusion', 'Fusion', '패널·심판 심의'],
  ['logs', 'Logs', '관측 · 시스템 로그'],
  ['display', 'Display', '표시'],
]

// keeper-v2 design settings.jsx SET_GROUPS의 부분 채택: account/lifecycle/
// sandbox/gate 섹션은 백엔드 계약 부재로 미구현이라 그룹에서 빠져 있고,
// 디자인이 nav에서 뺀 mcp/display는 live-backed 동작 섹션이라 유지한다
// (docs/design/keeper-v2-design-delta-audit-2026-07-03.md).
const SET_GROUPS: [string, SectionId[]][] = [
  ['Keeper 운영', ['runtime', 'routing', 'prompts', 'fusion']],
  ['인프라 · 실행', ['runtimes', 'paths']],
  ['연결 · 통합', ['mcp', 'repositories']],
  ['관측 · 알림', ['logs', 'notify', 'display']],
]

// Tools exposed over the public MCP server, derived from the live capability
// registry (`/api/v1/dashboard/tools`). The "public_mcp" surface is the
// registry's own exposure signal — see lib/tool_misc_introspection.ml
// (Tool_catalog.is_public_mcp). Unknown/empty inventory yields an empty list
// (no fabricated tool names).
const MCP_PUBLIC_SURFACE = 'public_mcp'
const SETTINGS_LOG_LIMIT = 50
const SETTINGS_LOG_POLL_MS = 3000
const DISPLAY_DENSITY_OPTIONS: Density[] = ['compact', 'regular', 'spacious']

const SETTINGS_CONTROL_INVENTORY: readonly SettingsControlInventoryItem[] = [
  {
    id: 'runtime-default-runtime',
    section: 'runtime',
    label: 'Default runtime',
    kind: 'live-write',
    source: 'GET /api/v1/dashboard/runtime-defaults + runtime provider catalog',
    action: 'PATCH /api/v1/runtime/routing lane=default',
  },
  {
    id: 'runtime-catalog-summary',
    section: 'runtime',
    label: 'Runtime catalog cards',
    kind: 'live-read',
    source: 'GET /api/v1/dashboard/runtime-providers, fallback runtime-defaults projection',
    action: 'read-only projection',
  },
  {
    id: 'runtime-routing-lanes',
    section: 'routing',
    label: 'Model routing lanes',
    kind: 'live-write',
    source: 'GET /api/v1/dashboard/runtime-defaults',
    action: 'PATCH /api/v1/runtime/routing for default/librarian/structured_judge/cross_verifier',
  },
  {
    id: 'runtime-media-failover',
    section: 'routing',
    label: 'Media failover list',
    kind: 'live-write',
    source: '[runtime].media_failover in runtime.toml',
    action: 'PATCH /api/v1/runtime/media-failover',
  },
  {
    id: 'runtime-toml-editor',
    section: 'runtimes',
    label: 'runtime.toml editor',
    kind: 'live-write',
    source: 'GET /api/v1/runtime/config/raw',
    action: 'PUT /api/v1/runtime/config/raw',
  },
  {
    id: 'settings-path-resolution',
    section: 'paths',
    label: 'Resolved paths',
    kind: 'live-read',
    source: 'dashboard shell path/config resolution + config projection',
    action: 'read-only projection',
  },
  {
    id: 'settings-mcp-status',
    section: 'mcp',
    label: 'MCP status check',
    kind: 'live-read',
    source: 'public MCP server + dashboard tool inventory',
    action: 'call masc_status; no settings mutation',
  },
  {
    id: 'settings-repositories',
    section: 'repositories',
    label: 'Repository settings',
    kind: 'live-write',
    source: 'repositories API',
    action: 'SettingsRepositoriesSection owned writer',
  },
  {
    id: 'settings-notify-thresholds',
    section: 'notify',
    label: 'Alert thresholds',
    kind: 'live-read',
    source: 'GET /api/v1/dashboard/config',
    action: 'read-only projection',
  },
  {
    id: 'settings-notify-routing',
    section: 'notify',
    label: 'Notification routing',
    kind: 'unsupported',
    source: 'no dashboard writer exposed',
    action: 'render read-only unsupported state',
  },
  {
    id: 'settings-prompts',
    section: 'prompts',
    label: 'Prompt registry',
    kind: 'live-write',
    source: 'prompt registry API',
    action: 'PromptRegistryPanel owned writer',
  },
  {
    id: 'settings-fusion',
    section: 'fusion',
    label: 'Fusion settings',
    kind: 'live-write',
    source: 'runtime.toml fusion settings',
    action: 'FusionSettingsPanel owned writer',
  },
  {
    id: 'settings-logs',
    section: 'logs',
    label: 'System log filters',
    kind: 'live-read',
    source: 'GET /api/v1/dashboard/logs',
    action: 'client-side filter only',
  },
  {
    id: 'settings-theme-density',
    section: 'display',
    label: 'Theme and density',
    kind: 'browser-local',
    source: 'DOM dataset + localStorage persistent signals',
    action: 'browser shell only; no server settings write',
  },
  {
    id: 'settings-display-locale',
    section: 'display',
    label: 'Locale / time format',
    kind: 'unsupported',
    source: 'no renderer-wide setting exposed',
    action: 'render read-only unsupported state',
  },
  {
    id: 'settings-html-snapshot',
    section: 'display',
    label: 'HTML snapshot export',
    kind: 'browser-local',
    source: 'current DOM outerHTML',
    action: 'download DOM snapshot; no standalone resource claim',
  },
]

export function settingsControlInventory(section: SectionId): readonly SettingsControlInventoryItem[] {
  return SETTINGS_CONTROL_INVENTORY.filter(item => item.section === section)
}

export function normalizeSettingsSection(value: string | null | undefined): SectionId {
  return SETTINGS_ROUTE_SECTION_SET.has(value ?? '') ? (value as SectionId) : DEFAULT_SETTINGS_SECTION
}

export function mcpExposedToolNames(items: readonly DashboardToolInventoryItem[]): string[] {
  return items
    .filter(item => item.surfaces.includes(MCP_PUBLIC_SURFACE))
    .map(item => item.name)
    .sort((a, b) => a.localeCompare(b))
}

// System-log row: [time, level, identity, message, status, isTool]. Derived from live
// ring entries (`/api/v1/dashboard/logs`) — the same source the Logs surface
// polls. Status is derived from the entry level only (error→fail, warn→warn,
// else→ok); the in-progress "run" state is not knowable from a settled ring
// entry, so it is never fabricated.
type SysLogRow = [string, string, string, string, string, boolean]

const SETTINGS_LOG_LEVEL_FAIL = 'error'
const SETTINGS_LOG_LEVEL_WARN = 'warn'

export function logRowStatus(level: string): 'ok' | 'warn' | 'fail' {
  const normalized = level.toLowerCase()
  if (normalized === SETTINGS_LOG_LEVEL_FAIL) return 'fail'
  if (normalized === SETTINGS_LOG_LEVEL_WARN) return 'warn'
  return 'ok'
}

function logRowClock(ts: string): string {
  const match = ts.match(/T(\d{2}:\d{2}:\d{2})/)
  if (match?.[1]) return match[1]
  const date = new Date(ts)
  if (!Number.isNaN(date.getTime())) {
    return date.toLocaleTimeString('ko-KR', {
      hour12: false,
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
  }
  return ts
}

export function logEntryToSysRow(entry: LogEntry): SysLogRow {
  const level = entry.level.toLowerCase()
  const identity = entry.keeper_name?.trim() || entry.module?.trim() || '(root)'
  const isTool = logDisplayKind(entry) === 'tool' || /masc_/.test(entry.message)
  return [logRowClock(entry.ts), level, identity, entry.message, logRowStatus(entry.level), isTool]
}

function SetSeg({
  value,
  options,
  onChange,
}: {
  value: string
  options: string[]
  onChange: (v: string) => void
}) {
  return html`
    <div class="set-seg" data-testid="set-seg">
      ${options.map(o => html`
        <button
          type="button"
          key=${o}
          class=${`set-seg-b ${value === o ? 'on' : ''}`}
          data-active=${value === o ? 'true' : 'false'}
          aria-pressed=${value === o}
          onClick=${() => onChange(o)}
        >
          ${o}
        </button>
      `)}
    </div>
  `
}

function SetRow({ label, hint, children }: { label: ComponentChildren; hint?: string; children: ComponentChildren }) {
  return html`
    <div class="set-row" data-testid="set-row">
      <div class="set-row-l">
        <div class="set-label">${label}</div>
        ${hint ? html`<div class="set-hint">${hint}</div>` : null}
      </div>
      <div class="set-row-c">${children}</div>
    </div>
  `
}

function PreviewBadge({ label }: { label: string }) {
  return html`
    <span
      class="set-preview-badge"
      data-testid="settings-preview-badge"
    >
      ${label}
    </span>
  `
}

function settingsControlKindLabel(kind: SettingsControlKind): string {
  if (kind === 'live-write') return 'live write'
  if (kind === 'live-read') return 'live read'
  if (kind === 'browser-local') return 'browser local'
  return 'unsupported'
}

function SettingsControlLedger({ section }: { section: SectionId }) {
  const items = settingsControlInventory(section)
  if (items.length === 0) return null
  return html`
    <section class="set-control-ledger" data-testid="settings-control-ledger">
      <div class="set-control-ledger-h">
        <span>Control backing</span>
        <span class="mono" data-testid="settings-control-ledger-count">${items.length}</span>
      </div>
      <div class="set-control-ledger-grid">
        ${items.map(item => html`
          <div
            key=${item.id}
            class=${`set-control-ledger-row ${item.kind}`}
            data-testid="settings-control-ledger-row"
            data-control-id=${item.id}
            data-control-kind=${item.kind}
          >
            <span class="set-control-kind">${settingsControlKindLabel(item.kind)}</span>
            <span class="set-control-label">${item.label}</span>
            <span class="set-control-source mono" title=${item.source}>${item.source}</span>
            <span class="set-control-action" title=${item.action}>${item.action}</span>
          </div>
        `)}
      </div>
    </section>
  `
}

function formatRuntimeContext(value: number | null | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return 'ctx 미수집'
  if (value >= 1_000_000) return `${Number.parseFloat((value / 1_000_000).toFixed(1))}M ctx`
  if (value >= 1_000) return `${Math.round(value / 1_000)}K ctx`
  return `${value} ctx`
}

function runtimeCatalogKey(item: DashboardRuntimeProviderSnapshot): string {
  return item.runtime_id?.trim() || item.provider.trim()
}

function findRuntimeCatalogSnapshot(
  catalog: readonly DashboardRuntimeProviderSnapshot[],
  runtimeId: string | null | undefined,
): DashboardRuntimeProviderSnapshot | null {
  const needle = runtimeId?.trim() ?? ''
  if (needle === '') return null
  return catalog.find(item => runtimeCatalogKey(item) === needle || item.provider_id === needle) ?? null
}

function RuntimeCatalogCapability({ label, value }: { label: string; value: boolean | undefined }) {
  if (value === undefined) {
    return html`<span class="rt-cap unknown" title="capability not reported">? ${label}</span>`
  }
  const isOn = value === true
  return html`<span class=${`rt-cap ${isOn ? 'on' : ''}`}>${isOn ? '✓' : '·'} ${label}</span>`
}

type RuntimeCatalogFact = {
  readonly id: string
  readonly label: string
  readonly value: string
}

function RuntimeCatalogDiagnostics({ facts }: { facts: readonly RuntimeCatalogFact[] }) {
  if (facts.length === 0) return null
  return html`
    <details class="set-rt-facts" data-testid="runtime-catalog-diagnostics">
      <summary>Diagnostics <span class="mono">${facts.length}</span></summary>
      <div class="set-rt-facts-body">
        ${facts.map(fact => html`
          <div
            key=${fact.id}
            class="set-rt-fact"
            data-testid=${`runtime-catalog-fact-${fact.id}`}
          >
            <span class="set-rt-fact-k">${fact.label}:</span>
            <span class="set-rt-fact-v mono" title=${fact.value}>${fact.value}</span>
          </div>
        `)}
      </div>
    </details>
  `
}

function runtimeCatalogFromDefaults(defaults: RuntimeDefaultsResponse | null): DashboardRuntimeProviderSnapshot[] {
  if (!defaults) return []
  return defaults.runtimes.map((entry: RuntimeEntry) => ({
    provider: entry.id,
    runtime_id: entry.id,
    provider_display_name: entry.provider,
    model_id: entry.model,
    model_api_name: entry.model,
    transport: 'runtime-defaults',
    kind: 'resolved',
    runtime_kind: 'runtime',
    status: entry.is_default ? 'default' : 'resolved',
    is_default_runtime: entry.is_default,
    max_context: entry.max_context,
    model_count: 1,
    models: [entry.model],
    source: defaults.source ?? 'runtime-defaults',
    endpoint_url: null,
    note: 'fallback from /api/v1/dashboard/runtime-defaults',
  }))
}

function RuntimeCatalogCard({
  item,
  defaultRuntimeId,
}: {
  item: DashboardRuntimeProviderSnapshot
  defaultRuntimeId: string | null | undefined
}) {
  const runtimeId = runtimeCatalogKey(item)
  const providerName = item.provider_display_name ?? item.provider_id ?? item.provider
  const modelName = item.model_api_name ?? item.model_id ?? item.models[0] ?? 'model 미수집'
  const transport = item.endpoint_url ?? item.transport ?? item.kind ?? 'transport 미수집'
  const status = item.available === false ? 'unavailable' : item.status ?? 'configured'
  const isDefault = runtimeId === (defaultRuntimeId ?? '')
  const effectiveCapabilities = runtimeCatalogEffectiveCapabilities(item)
  const parameterPolicy = runtimeCatalogParameterPolicy(item)
  const requestConfig = runtimeCatalogRequestConfig(item)
  const declaredSpec = runtimeCatalogDeclaredSpec(item)
  const snapshotFacts = runtimeCatalogSnapshotFacts(item)
  const diagnosticFacts = [
    snapshotFacts ? { id: 'snapshot', label: 'snapshot', value: snapshotFacts } : null,
    effectiveCapabilities ? { id: 'effective', label: 'effective', value: effectiveCapabilities } : null,
    parameterPolicy ? { id: 'policy', label: 'policy', value: parameterPolicy } : null,
    requestConfig ? { id: 'request', label: 'request', value: requestConfig } : null,
    declaredSpec ? { id: 'declared', label: 'declared', value: declaredSpec } : null,
  ].filter((fact): fact is RuntimeCatalogFact => fact !== null)

  return html`
    <div class="set-rt" data-testid="runtime-catalog-card">
      <div class="set-rt-top">
        <span class="set-rt-name mono">${runtimeId}</span>
        <span class="set-rt-kind">${item.runtime_kind ?? item.kind ?? 'runtime'}</span>
        ${isDefault ? html`<span class="set-rt-kind" data-testid="runtime-catalog-default">default</span>` : null}
        <span class="set-rt-keepers">${status}</span>
      </div>
      <div class="set-rt-row">
        <span class="sub-k">provider</span>
        <span class="mono set-rt-value" title=${providerName}>${providerName}</span>
      </div>
      <div class="set-rt-row">
        <span class="sub-k">model</span>
        <span class="mono set-rt-value" title=${modelName}>${modelName}</span>
      </div>
      <div class="set-rt-row">
        <span class="sub-k">context</span>
        <span class="mono">${formatRuntimeContext(item.max_context)}</span>
      </div>
      <div class="rt-caps">
        <${RuntimeCatalogCapability} label="tools" value=${item.tools_support} />
        <${RuntimeCatalogCapability} label="thinking" value=${item.thinking_support} />
        <${RuntimeCatalogCapability} label="streaming" value=${item.streaming} />
      </div>
      <${RuntimeCatalogDiagnostics} facts=${diagnosticFacts} />
      <div class="set-rt-row">
        <span class="sub-k">transport</span>
        <span class="mono set-rt-value set-runtime-transport" title=${transport}>${transport}</span>
      </div>
    </div>
  `
}

function uniqueRuntimeSelectOptions(options: RuntimeSelectOption[]): RuntimeSelectOption[] {
  const seen = new Set<string>()
  const result: RuntimeSelectOption[] = []
  for (const option of options) {
    const id = option.id.trim()
    if (id === '' || seen.has(id)) continue
    seen.add(id)
    result.push({ id, label: option.label })
  }
  return result
}

function runtimeSelectOptionsFromDefaults(entries: readonly RuntimeEntry[]): RuntimeSelectOption[] {
  return uniqueRuntimeSelectOptions(entries.map(entry => ({
    id: entry.id,
    label: `${entry.id} · ${entry.model}`,
  })))
}

function runtimeSelectOptionsFromCatalog(entries: readonly DashboardRuntimeProviderSnapshot[]): RuntimeSelectOption[] {
  return uniqueRuntimeSelectOptions(entries.map(entry => {
    const id = runtimeCatalogKey(entry)
    const model = entry.model_api_name ?? entry.model_id ?? entry.models[0] ?? 'model 미수집'
    return { id, label: `${id} · ${model}` }
  }))
}

function RuntimeRoutingSelect({
  label,
  hint,
  value,
  fallbackLabel,
  options,
  disabled,
  testId,
  onChange,
  required = false,
}: {
  label: string
  hint: string
  value: string | null
  fallbackLabel?: string
  options: readonly RuntimeSelectOption[]
  disabled: boolean
  testId: string
  onChange: (runtimeId: string | null) => void
  // The server rejects clearing the default lane (400 "default runtime_id
  // required"), so required lanes must not offer an empty option.
  required?: boolean
}) {
  return html`
    <${SetRow} label=${label} hint=${hint}>
      <select
        class="set-input mono set-runtime-route-select"
        data-testid=${testId}
        value=${value ?? ''}
        disabled=${disabled || options.length === 0}
        onInput=${(event: Event) => {
          const next = (event.currentTarget as HTMLSelectElement).value.trim()
          if (required && next === '') return
          onChange(next === '' ? null : next)
        }}
      >
        ${required ? null : html`<option value="">${fallbackLabel ?? ''}</option>`}
        ${options.map(option => html`
          <option key=${option.id} value=${option.id}>${option.label}</option>
        `)}
      </select>
    <//>
  `
}

function RuntimeMediaFailoverEditor({
  value,
  options,
  disabled,
  onChange,
}: {
  value: readonly string[]
  options: readonly RuntimeSelectOption[]
  disabled: boolean
  onChange: (runtimeIds: string[]) => void
}) {
  const selected = new Set(value)
  const addOptions = options.filter(option => !selected.has(option.id))
  const move = (index: number, delta: number) => {
    const target = index + delta
    if (target < 0 || target >= value.length) return
    const next = [...value]
    const current = next[index]
    if (current === undefined) return
    next[index] = next[target] ?? current
    next[target] = current
    onChange(next)
  }
  const remove = (runtimeId: string) => {
    onChange(value.filter(id => id !== runtimeId))
  }

  return html`
    <${SetRow} label="Media failover" hint="[runtime].media_failover ordered reroute list">
      <div class="set-runtime-media" data-testid="runtime-media-failover-editor">
        <div class="set-runtime-media-list">
          ${value.length === 0
            ? html`<span class="set-hint" data-testid="runtime-media-failover-empty">none</span>`
            : value.map((runtimeId, index) => html`
              <span class="set-runtime-media-chip" key=${`${runtimeId}-${index}`}>
                <span class="mono">${runtimeId}</span>
                <button
                  type="button"
                  class="set-route-icon"
                  disabled=${disabled || index === 0}
                  aria-label=${`${runtimeId} 위로 이동`}
                  onClick=${() => move(index, -1)}
                >↑</button>
                <button
                  type="button"
                  class="set-route-icon"
                  disabled=${disabled || index === value.length - 1}
                  aria-label=${`${runtimeId} 아래로 이동`}
                  onClick=${() => move(index, 1)}
                >↓</button>
                <button
                  type="button"
                  class="set-route-icon danger"
                  disabled=${disabled}
                  data-testid="runtime-media-failover-remove"
                  aria-label=${`${runtimeId} 제거`}
                  onClick=${() => remove(runtimeId)}
                >×</button>
              </span>
            `)}
        </div>
        <div class="set-hint flex flex-wrap items-center gap-2" data-testid="runtime-media-failover-reality">
          <${StatusChip} tone="warn" uppercase=${false}>수동 reroute<//>
          <span>provider 실패 자동 전환이 아니라 <span class="mono">runtime.toml</span>의 media lane 후보 목록입니다.</span>
        </div>
        <div class="set-runtime-media-actions">
          <select
            class="set-input mono set-runtime-route-select"
            data-testid="runtime-media-failover-add"
            value=""
            disabled=${disabled || addOptions.length === 0}
            onInput=${(event: Event) => {
              const select = event.currentTarget as HTMLSelectElement
              const next = select.value.trim()
              select.value = ''
              if (next !== '') onChange([...value, next])
            }}
          >
            <option value="">failover 추가</option>
            ${addOptions.map(option => html`
              <option key=${option.id} value=${option.id}>${option.label}</option>
            `)}
          </select>
          <button
            type="button"
            class="set-route-clear"
            disabled=${disabled || value.length === 0}
            data-testid="runtime-media-failover-clear"
            onClick=${() => onChange([])}
          >
            비우기
          </button>
        </div>
      </div>
    <//>
  `
}

function configEntry(data: DashboardConfigResponse | null, env: string): ConfigEntry | null {
  if (!data) return null
  for (const entries of Object.values(data.categories)) {
    const found = entries.find(entry => entry.env === env)
    if (found) return found
  }
  return null
}

function configEntryDisplayValue(entry: ConfigEntry | null): string | null {
  if (!entry) return null
  return entry.value ?? entry.default
}

function concreteConfigValue(entry: ConfigEntry | null): string | null {
  const value = configEntryDisplayValue(entry)?.trim()
  if (!value || /^\(.+\)$/.test(value)) return null
  return value
}

function formatConfigSource(entry: ConfigEntry | null): string {
  if (!entry) return 'missing'
  return entry.source_detail ?? entry.source
}

function endpointFromWindow(): string {
  if (typeof window === 'undefined') return '/mcp'
  const origin = window.location.origin
  if (!origin || origin === 'null') return '/mcp'
  return `${origin.replace(/\/$/, '')}/mcp`
}

function mcpEndpointFromConfig(config: DashboardConfigResponse | null): string {
  const mcpUrl = concreteConfigValue(configEntry(config, 'MASC_URL'))
  if (mcpUrl) return mcpUrl
  const httpBaseUrl = concreteConfigValue(configEntry(config, 'MASC_HTTP_BASE_URL'))
  if (httpBaseUrl) {
    try {
      return new URL('/mcp', httpBaseUrl).toString()
    } catch {
      return `${httpBaseUrl.replace(/\/$/, '')}/mcp`
    }
  }
  return endpointFromWindow()
}

function formatThresholdPercent(value: string | null): string {
  const parsed = value == null ? NaN : Number.parseFloat(value)
  if (!Number.isFinite(parsed)) return value ?? '미수집'
  return `${Math.round(parsed * 100)}%`
}

function ConfigTruthRow({
  label,
  entry,
  fallback,
}: {
  label: string
  entry: ConfigEntry | null
  fallback?: string | null
}) {
  const value = configEntryDisplayValue(entry) ?? fallback ?? '미수집'
  return html`
    <${SetRow} label=${label} hint=${entry?.description ?? 'dashboard config projection'}>
      <div class="set-truth-value">
        <span class="mono" data-testid=${`settings-config-${label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}>${value}</span>
        <span class="set-truth-source">${formatConfigSource(entry)}</span>
      </div>
    <//>
  `
}

function ThresholdTruthRow({
  label,
  entry,
  value,
}: {
  label: string
  entry: ConfigEntry | null
  value: string
}) {
  return html`
    <${SetRow} label=${label} hint=${entry?.env ?? 'dashboard alert threshold'}>
      <div class="set-truth-value">
        <span class="mono">${value}</span>
        <span class="set-truth-source">${formatConfigSource(entry)}</span>
      </div>
    <//>
  `
}

function PathTruthRow({
  label,
  item,
  fallback,
}: {
  label: string
  item?: DashboardConfigResolutionItem | null
  fallback?: string | null
}) {
  const path = item?.path ?? fallback ?? '미수집'
  const exists = item ? item.exists : null
  const status =
    exists === null ? 'unknown'
    : exists ? 'exists'
    : 'missing'
  return html`
    <${SetRow} label=${label} hint=${item?.source ?? 'runtime resolution'}>
      <div class="set-path-truth">
        <span class="mono set-path-truth-path" title=${path}>${path}</span>
        <span class=${`set-path-truth-state ${status}`} data-testid=${`settings-path-${status}`}>${status}</span>
      </div>
    <//>
  `
}

type SettingsSectionMode = 'live' | 'mixed' | 'local'
type PathResolutionAvailability = 'ready' | 'partial' | 'loading' | 'unavailable'

function settingsSectionState(
  section: SectionId,
  pathResolutionAvailability: PathResolutionAvailability = 'ready',
): { mode: SettingsSectionMode; label: string } {
  if (section === 'runtime') return { mode: 'live', label: 'runtime.toml + provider catalog' }
  if (section === 'routing') return { mode: 'live', label: 'runtime.toml live-backed' }
  if (section === 'runtimes') return { mode: 'live', label: 'runtime.toml live-backed' }
  if (section === 'prompts') return { mode: 'live', label: 'prompt registry live-backed' }
  if (section === 'fusion') return { mode: 'live', label: 'runtime.toml live-backed' }
  if (section === 'paths') {
    if (pathResolutionAvailability === 'ready') return { mode: 'live', label: 'resolved by server' }
    if (pathResolutionAvailability === 'partial') return { mode: 'mixed', label: 'partial path resolution' }
    if (pathResolutionAvailability === 'loading') return { mode: 'mixed', label: 'path resolution loading' }
    return { mode: 'local', label: 'path resolution unavailable' }
  }
  if (section === 'mcp') return { mode: 'mixed', label: 'live MCP check + inventory' }
  if (section === 'repositories') return { mode: 'live', label: 'repositories API live-backed' }
  if (section === 'logs') return { mode: 'mixed', label: 'live logs + local filters' }
  if (section === 'notify') return { mode: 'live', label: 'live thresholds read-only' }
  if (section === 'display') return { mode: 'local', label: 'browser-local shell state' }
  return { mode: 'local', label: 'read-only preview' }
}

function pathResolutionAvailability(
  dashboardConfigStatus: 'loading' | 'ready' | 'error',
  hasShellPathResolution: boolean,
  hasPartialPathProjection: boolean,
): PathResolutionAvailability {
  if (hasShellPathResolution) return 'ready'
  if (hasPartialPathProjection) return 'partial'
  if (dashboardConfigStatus === 'loading') return 'loading'
  return 'unavailable'
}

function LogFilter({
  filter,
  active,
  onClick,
}: {
  filter: LogFilter
  active: boolean
  onClick: () => void
}) {
  const label =
    filter === 'all' ? 'All'
    : filter === 'tool' ? 'Tool'
    : filter === 'success' ? 'Success'
    : 'Failure'

  return html`
    <button
      type="button"
      class=${`log-f ${active ? 'on' : ''}`}
      data-filter=${filter}
      data-active=${active ? 'true' : 'false'}
      onClick=${onClick}
    >
      ${label}
    </button>
  `
}

function LogViewer() {
  const [filter, setFilter] = useState<LogFilter>('all')
  const [allRows, setAllRows] = useState<SysLogRow[]>([])
  const [status, setStatus] = useState<'loading' | 'ready' | 'error'>('loading')

  useEffect(() => {
    let active = true
    let timer: ReturnType<typeof setInterval> | null = null

    const tick = async () => {
      try {
        const resp = await fetchLogs({ limit: SETTINGS_LOG_LIMIT })
        if (!active) return
        const rows = [...resp.entries]
          .sort((a, b) => b.seq - a.seq)
          .map(logEntryToSysRow)
        setAllRows(rows)
        setStatus('ready')
      } catch {
        if (!active) return
        // No fabricated rows on failure — surface the error state instead.
        setStatus('error')
      }
    }

    void tick()
    timer = setInterval(() => { void tick() }, SETTINGS_LOG_POLL_MS)

    return () => {
      active = false
      if (timer) clearInterval(timer)
    }
  }, [])

  const rows = allRows.filter(r => {
    if (filter === 'all') return true
    if (filter === 'tool') return r[5]
    if (filter === 'success') return r[4] === 'ok'
    if (filter === 'failure') return r[4] === 'fail'
    return true
  })

  const filters: LogFilter[] = ['all', 'tool', 'success', 'failure']
  const emptyLabel =
    status === 'loading' ? '로그를 불러오는 중…'
    : status === 'error' ? '시스템 로그를 불러오지 못했습니다.'
    : '조건에 맞는 로그가 없습니다.'

  return html`
    <div class="log-view" data-testid="log-viewer">
      <div class="log-filters">
        ${filters.map(f => html`
          <${LogFilter}
            key=${f}
            filter=${f}
            active=${filter === f}
            onClick=${() => setFilter(f)}
          />
        `)}
        <span class="log-live"><span class="tps-dot"></span>tail -f</span>
      </div>
      <div class="log-stream mono" data-testid="log-stream">
        ${rows.length === 0
          ? html`<div class="log-empty" data-testid="log-empty">${emptyLabel}</div>`
          : rows.map((r, i) => html`
          <div key=${i} class=${`log-line ${r[1]}`} data-testid="log-row">
            <span class="lt">${r[0]}</span>
            <span class=${`ll ${r[1]}`}>${r[1]}</span>
            <span class="lk">${r[2]}</span>
            <span class="lm">${r[3]}</span>
            <span class=${`ls ${r[4]}`}>
              ${r[4] === 'ok' ? '✓' : r[4] === 'fail' ? '✕' : r[4] === 'warn' ? '⚠' : '·'}
            </span>
          </div>
        `)}
      </div>
    </div>
  `
}

export function SettingsSurface() {
  const routeSection = route.value.params.section
  const [sec, setSec] = useState<SectionId>(() => normalizeSettingsSection(routeSection))

  useEffect(() => {
    const next = normalizeSettingsSection(routeSection)
    setSec(current => current === next ? current : next)
  }, [routeSection])

  function openSection(id: SectionId) {
    setSec(id)
    navigate('settings', id === DEFAULT_SETTINGS_SECTION ? {} : { section: id })
  }

  function handleExportHtmlSnapshot() {
    const htmlContent = document.documentElement.outerHTML
    const blob = new Blob([htmlContent], { type: 'text/html;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `MASC_Dashboard_snapshot.html`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)
  }

  // Server config projection — used by Paths, MCP and Notifications.
  const [dashboardConfig, setDashboardConfig] = useState<DashboardConfigResponse | null>(null)
  const [dashboardConfigStatus, setDashboardConfigStatus] = useState<'loading' | 'ready' | 'error'>('loading')
  const [dashboardConfigError, setDashboardConfigError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setDashboardConfigStatus('loading')
    setDashboardConfigError(null)
    void (async () => {
      try {
        const resp = await fetchDashboardConfig()
        if (!active) return
        setDashboardConfig(resp)
        setDashboardConfigStatus('ready')
        setDashboardConfigError(null)
      } catch (err) {
        if (!active) return
        setDashboardConfig(null)
        setDashboardConfigStatus('error')
        setDashboardConfigError(err instanceof Error ? err.message : String(err))
      }
    })()
    return () => { active = false }
  }, [])

  // mcp — exposed tools come from the live capability registry (public_mcp surface)
  const [mcpTools, setMcpTools] = useState<string[]>([])
  const [mcpToolsStatus, setMcpToolsStatus] = useState<'loading' | 'ready' | 'error'>('loading')
  const [mcpToolsError, setMcpToolsError] = useState('')
  const [mcpCheck, setMcpCheck] = useState<{ status: 'idle' | 'checking' | 'ok' | 'error'; message: string }>({
    status: 'idle',
    message: '아직 확인하지 않음',
  })

  useEffect(() => {
    let active = true
    setMcpToolsStatus('loading')
    setMcpToolsError('')
    void (async () => {
      try {
        const resp = await fetchDashboardTools()
        if (!active) return
        const names = mcpExposedToolNames(resp.tool_inventory?.tools ?? [])
        setMcpTools(names)
        setMcpToolsStatus('ready')
      } catch (err) {
        if (!active) return
        // No fabricated empty inventory on failure.
        setMcpTools([])
        setMcpToolsStatus('error')
        const message = err instanceof Error ? err.message : String(err)
        setMcpToolsError(`도구 inventory를 불러오지 못했습니다: ${message}`)
      }
    })()
    return () => { active = false }
  }, [])

  async function runMcpServerCheck() {
    setMcpCheck({ status: 'checking', message: 'masc_status 호출 중...' })
    try {
      const text = await callMcpTool('masc_status', {})
      const summary = text.trim().replace(/\s+/g, ' ').slice(0, 140)
      setMcpCheck({ status: 'ok', message: summary || 'masc_status 응답 확인' })
    } catch (err) {
      setMcpCheck({
        status: 'error',
        message: err instanceof Error ? err.message : String(err),
      })
    }
  }

  // runtime defaults / model routing — resolved from runtime.toml (SSOT)
  const [runtimeDefaults, setRuntimeDefaults] = useState<RuntimeDefaultsResponse | null>(null)
  const [runtimeProviders, setRuntimeProviders] = useState<DashboardRuntimeProvidersResponse | null>(null)
  const [runtimeCatalogStatus, setRuntimeCatalogStatus] = useState<'loading' | 'ready' | 'error'>('loading')
  const [runtimeRoutingStatus, setRuntimeRoutingStatus] = useState<RuntimeRoutingSaveState>('idle')
  const [runtimeRoutingMessage, setRuntimeRoutingMessage] = useState('')

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const resp = await fetchRuntimeDefaults()
        if (!active) return
        setRuntimeDefaults(resp)
      } catch {
        if (!active) return
        setRuntimeDefaults(null)
      }
    })()
    return () => { active = false }
  }, [])

  useEffect(() => {
    let active = true
    setRuntimeCatalogStatus('loading')
    void (async () => {
      try {
        const resp = await fetchRuntimeProviders()
        if (!active) return
        setRuntimeProviders(resp)
        setRuntimeCatalogStatus('ready')
      } catch {
        if (!active) return
        setRuntimeProviders(null)
        setRuntimeCatalogStatus('error')
      }
    })()
    return () => { active = false }
  }, [])

  async function reloadRuntimeDefaultsSnapshot(): Promise<void> {
    try {
      const resp = await fetchRuntimeDefaults()
      setRuntimeDefaults(resp)
    } catch (err) {
      setRuntimeDefaults(null)
      throw err
    }
  }

  async function reloadRuntimeProvidersSnapshot(): Promise<void> {
    setRuntimeCatalogStatus('loading')
    try {
      const resp = await fetchRuntimeProviders()
      setRuntimeProviders(resp)
      setRuntimeCatalogStatus('ready')
    } catch (err) {
      setRuntimeProviders(null)
      setRuntimeCatalogStatus('error')
      throw err
    }
  }

  async function refreshRuntimeSettingsSnapshot(): Promise<void> {
    await Promise.all([
      reloadRuntimeDefaultsSnapshot(),
      reloadRuntimeProvidersSnapshot(),
    ])
  }

  async function finishRuntimeRoutingWrite(): Promise<void> {
    await refreshRuntimeSettingsSnapshot()
    await refreshRuntimeConfigConsumers()
  }

  async function handleRuntimeTomlSaved(): Promise<void> {
    try {
      await refreshRuntimeSettingsSnapshot()
    } catch (err) {
      console.warn('[Settings] runtime settings refresh failed after editor save:', err)
    }
  }

  async function applyRuntimeRoutingPatch(lane: RuntimeRoutingLane, runtimeId: string | null): Promise<void> {
    if (runtimeRoutingStatus === 'saving') return
    setRuntimeRoutingStatus('saving')
    setRuntimeRoutingMessage('')
    try {
      await patchRuntimeRouting(lane, runtimeId)
    } catch (err) {
      setRuntimeRoutingStatus('error')
      setRuntimeRoutingMessage(errorToString(err))
      return
    }
    try {
      await finishRuntimeRoutingWrite()
      setRuntimeRoutingStatus('saved')
      setRuntimeRoutingMessage('runtime.toml routing 저장됨')
    } catch (err) {
      setRuntimeRoutingStatus('error')
      setRuntimeRoutingMessage(`저장됨, 대시보드 런타임 갱신 실패: ${errorToString(err)}`)
    }
  }

  async function applyMediaFailoverPatch(runtimeIds: string[]): Promise<void> {
    if (runtimeRoutingStatus === 'saving') return
    setRuntimeRoutingStatus('saving')
    setRuntimeRoutingMessage('')
    try {
      await patchRuntimeMediaFailover(runtimeIds)
    } catch (err) {
      setRuntimeRoutingStatus('error')
      setRuntimeRoutingMessage(errorToString(err))
      return
    }
    try {
      await finishRuntimeRoutingWrite()
      setRuntimeRoutingStatus('saved')
      setRuntimeRoutingMessage('runtime.toml media_failover 저장됨')
    } catch (err) {
      setRuntimeRoutingStatus('error')
      setRuntimeRoutingMessage(`저장됨, 대시보드 런타임 갱신 실패: ${errorToString(err)}`)
    }
  }

  // display
  const density = tweaksDensity.value
  const setDensity = (next: string) => {
    if ((DISPLAY_DENSITY_OPTIONS as string[]).includes(next)) {
      tweaksDensity.value = next as Density
    }
  }
  const cur = SET_SECTIONS.find(s => s[0] === sec) ?? SET_SECTIONS[0]!

  // Resolved runtime options (de-duplicated, derived from the live registry).
  const runtimeEntries = runtimeDefaults?.runtimes ?? []
  const richRuntimeCatalogEntries = runtimeProviders?.providers ?? []
  const fallbackRuntimeCatalogEntries = runtimeCatalogFromDefaults(runtimeDefaults)
  const runtimeCatalogEntries = richRuntimeCatalogEntries.length > 0
    ? richRuntimeCatalogEntries
    : fallbackRuntimeCatalogEntries
  const runtimeCatalogIsFallback =
    runtimeCatalogStatus === 'error' && richRuntimeCatalogEntries.length === 0 && fallbackRuntimeCatalogEntries.length > 0
  const runtimeConfigPath = runtimeProviders?.config_path ?? runtimeDefaults?.config_path ?? null
  const defaultRuntimeId = runtimeDefaults?.default_runtime_id ?? runtimeProviders?.summary?.default_runtime_id ?? null
  const defaultCatalogEntry = findRuntimeCatalogSnapshot(runtimeCatalogEntries, defaultRuntimeId)
  const keeperAssignments = runtimeDefaults?.model_routing.keeper_assignments ?? []
  const runtimeCount = runtimeEntries.length > 0
    ? runtimeEntries.length
    : runtimeProviders?.summary?.runtimes ?? runtimeCatalogEntries.length
  const keeperAssignmentCount = keeperAssignments.length > 0
    ? keeperAssignments.length
    : runtimeProviders?.assignment_governance?.assignment_count ?? 0
  const librarianRuntime = runtimeDefaults?.model_routing.librarian_runtime_id ?? null
  const structuredJudgeRuntime = runtimeDefaults?.model_routing.structured_judge_runtime_id ?? null
  const crossVerifierRuntime = runtimeDefaults?.model_routing.cross_verifier_runtime_id ?? null
  const mediaFailover = runtimeDefaults?.model_routing.media_failover ?? []
  const runtimeSelectOptions = runtimeEntries.length > 0
    ? runtimeSelectOptionsFromDefaults(runtimeEntries)
    : runtimeSelectOptionsFromCatalog(runtimeCatalogEntries)
  const runtimeRoutingSaving = runtimeRoutingStatus === 'saving'
  const runtimeResolution = shellRuntimeResolution.value
  const configResolution = shellConfigResolution.value
  const hasRuntimePathResolution = runtimeResolution !== null
  const hasConfigPathResolution = configResolution !== null
  const hasShellPathResolution = hasRuntimePathResolution || hasConfigPathResolution
  const hasPartialPathProjection = dashboardConfigStatus === 'ready' || runtimeConfigPath !== null
  const pathAvailability = pathResolutionAvailability(dashboardConfigStatus, hasShellPathResolution, hasPartialPathProjection)
  const baseSectionState = settingsSectionState(sec, pathAvailability)
  const sectionState =
    sec === 'notify' && dashboardConfigStatus === 'loading'
      ? { mode: 'mixed' as const, label: 'thresholds loading' }
      : sec === 'notify' && dashboardConfigStatus === 'error'
        ? { mode: 'mixed' as const, label: 'config unavailable' }
        : baseSectionState
  const mcpEndpoint = mcpEndpointFromConfig(dashboardConfig)
  const mcpToolCountLabel = mcpToolsStatus === 'ready' ? String(mcpTools.length) : '—'
  const mcpUrlEntry = configEntry(dashboardConfig, 'MASC_URL')
  const httpBaseUrlEntry = configEntry(dashboardConfig, 'MASC_HTTP_BASE_URL')
  const basePathEntry = configEntry(dashboardConfig, 'MASC_BASE_PATH')
  const dataDirEntry = configEntry(dashboardConfig, 'MASC_DATA_DIR')
  const configDirEntry = configEntry(dashboardConfig, 'MASC_CONFIG_DIR')
  const ctxPreparingEntry = configEntry(dashboardConfig, 'MASC_DASHBOARD_CTX_PREPARING')
  const ctxHandoffEntry = configEntry(dashboardConfig, 'MASC_DASHBOARD_CTX_HANDOFF_IMMINENT')
  const runtimeWarningEntry = configEntry(dashboardConfig, 'MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO')
  const signalStaleEntry = configEntry(dashboardConfig, 'MASC_DASHBOARD_SIGNAL_STALE_SEC')
  const alertDedupEntry = configEntry(dashboardConfig, 'MASC_ALERT_DEDUP_WINDOW_SEC')

  return html`
    <main class="v2-shell-surface settings-surf ss-surface bg-surface-page text-text-primary" data-screen-label="설정" data-testid="settings-surface">
      <div class="set-shell">
        <nav class="set-nav" aria-label="Settings categories">
          <div class="set-nav-h">
            <div class="eyebrow">Operator</div>
            <!-- keeper-v2 settings.jsx:244-247 — nav header is eyebrow + KO title
                 only; the prototype does not render a sub-line here. -->
            <div class="set-nav-title">설정</div>
          </div>
          ${SET_GROUPS.map(([glabel, ids]) => html`
            <div key=${glabel} class="set-nav-group">
              <div class="set-nav-glabel">${glabel}</div>
              ${ids.map(id => {
                const s = SET_SECTIONS.find(x => x[0] === id)
                if (!s) return null
                return html`
                  <button
                    type="button"
                    key=${id}
                    class=${`set-nav-item ${sec === id ? 'on' : ''}`}
                    data-testid=${`settings-nav-${id}`}
                    data-active=${sec === id ? 'true' : 'false'}
                    onClick=${() => openSection(id)}
                  >
                    <span class="ko">${s[2]}</span>
                    <span class="en mono">${s[1]}</span>
                  </button>
                `
              })}
            </div>
          `)}
          <div class="set-nav-note">live-backed 섹션은 API나 대시보드 shell 상태를 직접 읽고 씁니다. writer가 없는 값은 read-only로만 표시합니다.</div>
        </nav>

        <div class="set-content">
          <header class="set-content-h">
            <h1 data-testid="settings-section-title">${cur[2]}</h1>
            <span
              class=${`set-section-state ${sectionState.mode}`}
              data-testid="settings-section-state"
            >
              ${sectionState.label}
            </span>
          </header>

          <div
            class=${`set-card-b mx-6 my-6 ${sec === 'runtime' || sec === 'routing' || sec === 'runtimes' || sec === 'paths' || sec === 'mcp' || sec === 'repositories' || sec === 'notify' || sec === 'prompts' || sec === 'fusion' ? 'set-card-b-wide' : 'ss-card'}`}
            data-preview-locked="false"
            data-settings-mode=${sectionState.mode}
          >
            <${SettingsControlLedger} section=${sec} />
            ${sec === 'mcp' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                현재 대시보드가 사용하는 HTTP MCP 서버 상태와 public MCP 도구 노출 목록입니다. 도구 노출은 서버 capability registry가 SSOT입니다.
              </div>
              <${SetRow} label="MCP endpoint" hint="Resolved from MASC_URL / MASC_HTTP_BASE_URL / current origin">
                <div class="set-truth-value">
                  <span class="mono" data-testid="settings-mcp-endpoint">${mcpEndpoint}</span>
                  <span class="set-truth-source">${formatConfigSource(mcpUrlEntry ?? httpBaseUrlEntry)}</span>
                </div>
              <//>
              <${SetRow} label="Transport" hint="Dashboard client transport">
                <div class="set-truth-value">
                  <span class="mono">streamable HTTP</span>
                  <span class="set-truth-source">POST /mcp · Accept: application/json, text/event-stream</span>
                </div>
              <//>
              <${SetRow} label="Server check" hint="Calls masc_status through the same MCP client used by dashboard actions">
                <div class="set-mcp-check">
                  <button
                    type="button"
                    class=${`set-verify ${mcpCheck.status}`}
                    data-testid="settings-mcp-check"
                    disabled=${mcpCheck.status === 'checking'}
                    onClick=${() => void runMcpServerCheck()}
                  >
                    ${mcpCheck.status === 'checking' ? 'Checking...' : 'Check MCP'}
                  </button>
                  <span class=${`set-mcp-check-result ${mcpCheck.status}`} data-testid="settings-mcp-check-result">${mcpCheck.message}</span>
                </div>
              <//>
              <div class="set-sub-h">Exposed public MCP tools (${mcpToolCountLabel})</div>
              ${mcpToolsStatus === 'loading'
                ? html`<div class="set-hint" data-testid="mcp-tools-loading">MCP 도구 inventory를 불러오는 중...</div>`
                : mcpToolsStatus === 'error'
                  ? html`<div class="set-err" data-testid="mcp-tools-error">${mcpToolsError}</div>`
                  : mcpTools.length === 0
                    ? html`<div class="set-hint" data-testid="mcp-tools-empty">노출된 MCP 도구가 없습니다.</div>`
                    : html`<div class="set-tg-tools" data-testid="mcp-tools-list">
                      ${mcpTools.map(t => html`<span key=${t} class="set-tg-chip mono">${t}</span>`)}
                    </div>`}
            `}

            ${sec === 'runtime' && html`
              <div class="settings-runtime-live" data-testid="runtime-settings-live">
                <div class="settings-runtime-live-h">
                  <div>
                    <div class="set-sub-h">runtime.toml</div>
                    <div class="set-hint">현재 서버가 해석한 런타임 기본값과 provider 카탈로그입니다.</div>
                  </div>
                  <button
                    type="button"
                    class="set-rt-open"
                    data-testid="runtime-settings-edit"
                    onClick=${() => openSection('runtimes')}
                  >
                    런타임 관리 열기
                  </button>
                </div>
                <div class="settings-runtime-live-source mono" data-testid="runtime-settings-config-path">
                  ${runtimeConfigPath ?? 'runtime.toml 경로 미확인'}
                </div>

                <div class="set-rt-launch" data-testid="runtime-settings-summary">
                  <div class="set-rt-launch-stats">
                    <div class="set-rt-launch-stat">
                      <span class="v mono">${runtimeCount}</span>
                      <span class="k">resolved runtimes</span>
                    </div>
                    <div class="set-rt-launch-stat">
                      <span class="v mono">${runtimeCatalogEntries.length}</span>
                      <span class="k">catalog entries</span>
                    </div>
                    <div class="set-rt-launch-stat">
                      <span class="v mono">${keeperAssignmentCount}</span>
                      <span class="k">keeper assignments</span>
                    </div>
                  </div>
                  ${runtimeSelectOptions.length > 0
                    ? html`
                      <${RuntimeRoutingSelect}
                        label="Default runtime"
                        hint="[runtime].default · 새 keeper 가 시작될 런타임 id (provider.model)"
                        value=${defaultRuntimeId}
                        options=${runtimeSelectOptions}
                        disabled=${runtimeRoutingSaving}
                        testId="runtime-default-runtime"
                        required=${true}
                        onChange=${(runtimeId: string | null) => {
                          if (runtimeId && runtimeId !== defaultRuntimeId) void applyRuntimeRoutingPatch('default', runtimeId)
                        }}
                      />
                    `
                    : html`
                      <${SetRow} label="Default runtime" hint="[runtime].default">
                        ${defaultRuntimeId
                          ? html`<span class="mono" data-testid="runtime-default-readonly">${defaultRuntimeId}</span>`
                          : html`<span class="set-hint" data-testid="runtime-default-empty">런타임 설정을 불러오지 못했습니다.</span>`}
                      <//>
                    `}
                  <${SetRow} label="Default model" hint="Resolved model API name">
                    <span class="mono" data-testid="runtime-default-model">${runtimeDefaults?.default_model ?? defaultCatalogEntry?.model_api_name ?? '—'}</span>
                  <//>
                  <${SetRow} label="Default context" hint="Resolved context window">
                    <span class="mono" data-testid="runtime-default-context">
                      ${formatRuntimeContext(runtimeDefaults?.default_max_context ?? defaultCatalogEntry?.max_context ?? null)}
                    </span>
                  <//>
                </div>

                <div class="settings-runtime-section" data-runtime-section="catalog" data-testid="runtime-catalog-section">
                  <div class="set-sub-h">Runtime catalog (${runtimeCatalogEntries.length})</div>
                  ${runtimeCatalogIsFallback ? html`
                    <div class="set-hint" data-testid="runtime-catalog-fallback">
                      provider 카탈로그를 불러오지 못해 live runtime defaults projection으로 표시합니다.
                    </div>
                  ` : null}
                  ${runtimeCatalogStatus === 'loading' && runtimeCatalogEntries.length === 0
                    ? html`<div class="set-hint" data-testid="runtime-catalog-loading">runtime catalog 불러오는 중...</div>`
                    : runtimeCatalogStatus === 'error' && runtimeCatalogEntries.length === 0
                      ? html`<div class="set-hint" data-testid="runtime-catalog-error">runtime catalog를 불러오지 못했습니다.</div>`
                      : runtimeCatalogEntries.length === 0
                        ? html`<div class="set-hint" data-testid="runtime-catalog-empty">표시할 runtime catalog entry가 없습니다.</div>`
                        : html`
                          <div class="settings-runtime-catalog" data-testid="runtime-catalog-summary">
                            ${runtimeCatalogEntries.map(item => html`
                              <${RuntimeCatalogCard}
                                key=${runtimeCatalogKey(item)}
                                item=${item}
                                defaultRuntimeId=${defaultRuntimeId}
                              />
                            `)}
                          </div>
                        `}
                </div>

                ${runtimeRoutingStatus === 'saving'
                  ? html`<div class="set-hint" data-testid="runtime-routing-saving">runtime.toml 저장 중...</div>`
                  : runtimeRoutingMessage
                    ? html`<div class=${runtimeRoutingStatus === 'error' ? 'set-err' : 'set-ok'} data-testid="runtime-routing-message">${runtimeRoutingMessage}</div>`
                    : null}
              </div>
            `}

            ${sec === 'routing' && html`
              <div class="settings-runtime-live" data-testid="routing-settings-live">
                <div class="set-hint" style=${{ marginBottom: '12px' }}>
                  <span class="mono">[runtime]</span> 라우팅 레인. keeper 채팅은 <b>default</b> 를 쓰고, 특정 작업만 전용 런타임으로 분기됩니다.
                </div>

                <div class="settings-runtime-section" data-runtime-section="routing" data-testid="runtime-routing-section">
                  <div class="set-sub-h">Model routing</div>
                  <div class="settings-runtime-routing-editor" data-testid="runtime-routing-summary">
                    <${RuntimeRoutingSelect}
                      label="Default"
                      hint="[runtime].default · 기본 — keeper 채팅, 미할당 keeper 가 상속"
                      value=${defaultRuntimeId}
                      options=${runtimeSelectOptions}
                      disabled=${runtimeRoutingSaving}
                      testId="runtime-routing-default"
                      required=${true}
                      onChange=${(runtimeId: string | null) => {
                        if (runtimeId && runtimeId !== defaultRuntimeId) void applyRuntimeRoutingPatch('default', runtimeId)
                      }}
                    />
                    <${RuntimeRoutingSelect}
                      label="Librarian"
                      hint="[runtime].librarian · 턴 후 에피소드 추출"
                      value=${librarianRuntime}
                      fallbackLabel="default runtime"
                      options=${runtimeSelectOptions}
                      disabled=${runtimeRoutingSaving}
                      testId="runtime-routing-librarian"
                      onChange=${(runtimeId: string | null) => void applyRuntimeRoutingPatch('librarian', runtimeId)}
                    />
                    <${RuntimeRoutingSelect}
                      label="Structured judge"
                      hint="[runtime].structured_judge"
                      value=${structuredJudgeRuntime}
                      fallbackLabel="librarian/default fallback"
                      options=${runtimeSelectOptions}
                      disabled=${runtimeRoutingSaving}
                      testId="runtime-routing-structured-judge"
                      onChange=${(runtimeId: string | null) => void applyRuntimeRoutingPatch('structured_judge', runtimeId)}
                    />
                    <${RuntimeRoutingSelect}
                      label="Cross verifier"
                      hint="[runtime].cross_verifier · 반-합리화 평가자"
                      value=${crossVerifierRuntime}
                      fallbackLabel="default runtime"
                      options=${runtimeSelectOptions}
                      disabled=${runtimeRoutingSaving}
                      testId="runtime-routing-cross-verifier"
                      onChange=${(runtimeId: string | null) => void applyRuntimeRoutingPatch('cross_verifier', runtimeId)}
                    />
                    <${RuntimeMediaFailoverEditor}
                      value=${mediaFailover}
                      options=${runtimeSelectOptions}
                      disabled=${runtimeRoutingSaving}
                      onChange=${(runtimeIds: string[]) => void applyMediaFailoverPatch(runtimeIds)}
                    />
                    ${runtimeRoutingStatus === 'saving'
                      ? html`<div class="set-hint" data-testid="runtime-routing-saving">runtime.toml 저장 중...</div>`
                      : runtimeRoutingMessage
                        ? html`<div class=${runtimeRoutingStatus === 'error' ? 'set-err' : 'set-ok'} data-testid="runtime-routing-message">${runtimeRoutingMessage}</div>`
                        : null}
                  </div>
                </div>

                <div class="settings-runtime-section" data-runtime-section="assignments" data-testid="runtime-assignments-section">
                  <div class="set-sub-h">Keeper assignments (${keeperAssignments.length})</div>
                  ${keeperAssignments.length === 0
                    ? html`<div class="set-hint" data-testid="routing-assignments-empty">명시적 keeper 할당이 없습니다 — 모두 기본 런타임을 사용합니다.</div>`
                    : html`<div class="settings-runtime-routing" data-testid="routing-assignments-list">
                      ${keeperAssignments.map(a => html`
                        <div class="set-routing-row" key=${a.keeper}>
                          <span class="mono">${a.keeper}</span>
                          <span class="set-routing-arrow">→</span>
                          <span class="mono" data-testid="routing-assignment">${a.runtime_id}</span>
                        </div>
                      `)}
                    </div>`}
                  <div class="set-hint" style=${{ marginTop: '8px' }}>
                    키퍼별 고정 배정(<span class="mono">[runtime.assignments]</span>) 편집은 런타임 관리에서.
                  </div>
                </div>
              </div>
            `}

            ${sec === 'runtimes' && html`
              <${RuntimeTomlEditor} onSaved=${handleRuntimeTomlSaved} />
            `}

            ${sec === 'prompts' && html`
              <${PromptRegistryPanel} embedded=${true} />
            `}

            ${sec === 'fusion' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                <span class="mono">masc_fusion</span> 의 out-of-band 심의 루프 (RFC-0252). 서로 다른 모델 패밀리로 패널을 구성해 관점 다양성을 확보하고, 심판이 종합합니다. fusion이 발화 가치 있는지는 keeper가 판단하고 게이트는 남용만 막습니다.
              </div>
              <${FusionSettingsPanel} />
            `}

            ${sec === 'paths' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                서버가 실제로 해석한 base path, data/config root, runtime.toml 경로입니다. 값은 dashboard shell/config projection에서 읽고, 입력 필드로 덮어쓰지 않습니다.
              </div>
              ${pathAvailability === 'loading'
                ? html`<div class="set-hint" data-testid="settings-path-resolution-loading">dashboard shell path resolution을 기다리는 중입니다.</div>`
                : null}
              ${pathAvailability === 'unavailable'
                ? html`
                  <div class="set-hint" data-testid="settings-path-resolution-error">
                    dashboard shell path resolution과 config projection을 불러오지 못했습니다. 경로 행을 추정값으로 표시하지 않습니다.
                  </div>
                `
                : null}
              ${pathAvailability === 'partial'
                ? html`
                  <div class="set-hint" data-testid="settings-runtime-path-resolution-missing">
                    dashboard shell path resolution을 아직 받지 못했습니다. config projection/runtime provider에서 확인 가능한 값만 표시합니다.
                  </div>
                `
                : null}
              ${dashboardConfigStatus === 'error' && pathAvailability !== 'unavailable'
                ? html`<div class="set-hint" data-testid="settings-config-error">dashboard config projection을 불러오지 못했습니다.</div>`
                : null}
              ${pathAvailability === 'loading' || pathAvailability === 'unavailable'
                ? null
                : html`
                  ${hasRuntimePathResolution
                    ? html`
                      <div class="set-sub-h">Runtime path resolution</div>
                      <${PathTruthRow} label="Base path" item=${runtimeResolution?.base_path ?? null} fallback=${concreteConfigValue(basePathEntry)} />
                      <${PathTruthRow} label="Resolved base path" item=${runtimeResolution?.resolved_base_path ?? null} />
                      <${PathTruthRow} label="Workspace path" item=${runtimeResolution?.workspace_path ?? null} />
                      <${PathTruthRow} label="Data root" item=${runtimeResolution?.data_root ?? null} fallback=${concreteConfigValue(dataDirEntry)} />
                      <${PathTruthRow} label="Prompt markdown dir" item=${runtimeResolution?.prompt_markdown_dir ?? null} />
                    `
                    : null}
                  ${hasConfigPathResolution || runtimeConfigPath
                    ? html`
                      <div class="set-sub-h">Config path resolution</div>
                      <${PathTruthRow} label="Runtime TOML" item=${configResolution?.runtime ?? null} fallback=${runtimeConfigPath} />
                      ${hasConfigPathResolution || dashboardConfigStatus === 'ready'
                        ? html`<${PathTruthRow} label="Config root" item=${configResolution?.config_root ?? null} fallback=${concreteConfigValue(configDirEntry)} />`
                        : null}
                    `
                    : null}
                  ${dashboardConfigStatus === 'ready'
                    ? html`
                      <div class="set-sub-h">Config env inputs</div>
                      <${ConfigTruthRow} label="MASC_BASE_PATH" entry=${basePathEntry} />
                      <${ConfigTruthRow} label="MASC_CONFIG_DIR" entry=${configDirEntry} />
                      <${ConfigTruthRow} label="MASC_DATA_DIR" entry=${dataDirEntry} />
                      <${ConfigTruthRow} label="MCP endpoint" entry=${mcpUrlEntry} fallback=${mcpEndpoint} />
                    `
                    : null}
                `}
            `}

            ${sec === 'repositories' && html`
              <${SettingsRepositoriesSection} />
            `}

            ${sec === 'logs' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                시스템 로그는 <span class="mono">/api/v1/dashboard/logs</span> ring에서 직접 읽습니다. 필터는 화면 표시만 바꾸며 서버 설정을 쓰지 않습니다.
              </div>
              <div class="set-sub-h">System log (all keepers · live)</div>
              <${LogViewer} />
            `}

            ${sec === 'notify' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                알림 임계값은 현재 서버 config projection에서 읽습니다. 이 화면은 아직 알림 라우팅 writer를 노출하지 않으므로 브라우저-only 토글을 만들지 않습니다.
              </div>
              ${dashboardConfigStatus === 'loading'
                ? html`<div class="set-hint" data-testid="notify-config-loading">알림 임계값을 불러오는 중...</div>`
                : dashboardConfigStatus === 'error'
                  ? html`
                    <div class="set-hint" data-testid="notify-config-error">
                      dashboard config projection을 불러오지 못했습니다${dashboardConfigError ? `: ${dashboardConfigError}` : ''}.
                    </div>
                  `
                  : html`
                    <div data-testid="notify-thresholds">
                      <div class="set-sub-h">Live alert thresholds</div>
                      <${ThresholdTruthRow}
                        label="Preparing context"
                        entry=${ctxPreparingEntry}
                        value=${formatThresholdPercent(configEntryDisplayValue(ctxPreparingEntry))}
                      />
                      <${ThresholdTruthRow}
                        label="Handoff imminent"
                        entry=${ctxHandoffEntry}
                        value=${formatThresholdPercent(configEntryDisplayValue(ctxHandoffEntry))}
                      />
                      <${ThresholdTruthRow}
                        label="Runtime warning"
                        entry=${runtimeWarningEntry}
                        value=${formatThresholdPercent(configEntryDisplayValue(runtimeWarningEntry))}
                      />
                      <${ConfigTruthRow} label="Signal stale seconds" entry=${signalStaleEntry} />
                      <${ConfigTruthRow} label="Alert dedup window" entry=${alertDedupEntry} />
                      <${SetRow} label="Notification routing" hint="No dashboard writer is exposed for alert channels or event toggles yet">
                        <div class="set-truth-value" data-testid="notify-routing-readonly">
                          <span class="mono">read-only</span>
                          <span class="set-truth-source">no writer</span>
                        </div>
                      <//>
                    </div>
                  `}
            `}

            ${sec === 'display' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Theme and density apply to this browser immediately. Locale, timezone and clock format are not shown here until the dashboard has a real renderer-wide setting.
              </div>
              <div class="set-local-summary" data-testid="display-live-summary">
                <span>display shell</span>
                <span class="mono">${density}</span>
              </div>
              <${SetRow} label="Theme" hint="Live color palette — Dark / StyleSeed / Paper">
                <${ThemeSwitch} />
              <//>
              <${SetRow} label="Density" hint="Live list/card spacing on the dashboard shell">
                <div class="set-tg-control">
                  <${PreviewBadge} label="live shell" />
                  <${SetSeg} value=${density} options=${DISPLAY_DENSITY_OPTIONS} onChange=${setDensity} />
                </div>
              <//>
              <${SetRow} label="Locale / time format" hint="No dashboard-wide renderer setting is exposed yet">
                <div class="set-truth-value" data-testid="display-locale-readonly">
                  <span class="mono">read-only</span>
                  <span class="set-truth-source">no writer</span>
                </div>
              <//>

              <${SetRow} label="HTML 스냅샷 내보내기" hint="현재 렌더링된 DOM을 HTML 파일로 저장하여 다운로드합니다.">
                <button
                  type="button"
                  class="cn-act act"
                  style=${{ background: 'var(--color-brand)', color: 'var(--volt-ink)', fontWeight: '600' }}
                  onClick=${handleExportHtmlSnapshot}
                >
                  내보내기 ⤓
                </button>
              <//>
            `}
          </div>
        </div>
      </div>
    </main>
  `
}
