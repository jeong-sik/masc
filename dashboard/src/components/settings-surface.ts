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
import { callMcpTool } from '../api/mcp'
import { envBool } from '../config/env'
import { shellConfigResolution, shellRuntimeResolution } from '../store'
import type { DashboardConfigResolutionItem } from '../types'
import { RuntimeTomlEditor } from './runtime-toml-editor'
import { FusionSettingsPanel } from './fusion-settings-panel'
import { PromptRegistryPanel } from './tools/prompt-registry-panel'
import { ThemeSwitch } from './theme-switch'
import { logDisplayKind } from './log-classification'
import { tweaksDensity, type Density } from './tweaks-panel'
import type { ComponentChildren } from 'preact'

type SectionId = SettingsRouteSectionId

type LogFilter = 'all' | 'tool' | 'success' | 'failure'
type PathCheckResult = {
  readonly ok: boolean
  readonly message: string
}
const SETTINGS_ROUTE_SECTION_SET = new Set<string>(SETTINGS_ROUTE_SECTION_IDS)
const DEFAULT_SETTINGS_SECTION: SectionId = 'runtime'

const SET_SECTIONS: [SectionId, string, string][] = [
  ['runtime', 'Runtime', '런타임'],
  ['runtimes', 'Runtimes', '런타임 관리'],
  ['paths', 'Paths', '경로 · Path'],
  ['mcp', 'MCP', 'MCP 서버'],
  ['notify', 'Notify', '알림'],
  ['prompts', 'Prompts', '기본 프롬프트'],
  ['fusion', 'Fusion', '패널·심판 심의'],
  ['logs', 'Logs', '관측 · 시스템 로그'],
  ['display', 'Display', '표시'],
]

const SET_GROUPS: [string, SectionId[]][] = [
  ['런타임', ['runtime', 'runtimes']],
  ['경로 · 연결', ['paths', 'mcp']],
  ['운영 알림', ['notify', 'logs']],
  ['고급 설정', ['prompts', 'fusion', 'display']],
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

export function normalizeSettingsSection(value: string | null | undefined): SectionId {
  return SETTINGS_ROUTE_SECTION_SET.has(value ?? '') ? (value as SectionId) : DEFAULT_SETTINGS_SECTION
}

export function mcpExposedToolNames(items: readonly DashboardToolInventoryItem[]): string[] {
  return items
    .filter(item => item.surfaces.includes(MCP_PUBLIC_SURFACE))
    .map(item => item.name)
    .sort((a, b) => a.localeCompare(b))
}

export function checkSettingsMcpEndpoint(value: string): PathCheckResult {
  const trimmed = value.trim()
  if (trimmed === '') return { ok: false, message: 'URL required' }
  try {
    const url = new URL(trimmed)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      return { ok: false, message: 'expected http(s) URL' }
    }
    if (url.hostname.trim() === '') return { ok: false, message: 'host required' }
    if (!url.pathname.toLowerCase().includes('mcp')) {
      return { ok: false, message: 'path should include /mcp' }
    }
    return { ok: true, message: 'valid MCP URL' }
  } catch {
    return { ok: false, message: 'invalid URL' }
  }
}

// [fusion] preset shape from config/runtime.toml [fusion] — keeper-v2
// settings.jsx:68-81 (FUSION). Describes the trio preset structure (panel
// families, judge, timeouts). Read-only preview; no fusion config write
// endpoint exists yet, so these are the documented config defaults, not live
// values.
type FusionConfig = {
  readonly enabled: boolean
  readonly defaultPreset: string
  readonly maxConcurrentPanels: number
  readonly webTools: boolean
  readonly panel: readonly string[]
  readonly judge: string
  readonly panelTimeoutS: number
  readonly judgeTimeoutS: number
  readonly maxToolCallsPerPanel: number
}
const FUSION: FusionConfig = {
  enabled: true,
  defaultPreset: 'trio',
  maxConcurrentPanels: 2,
  webTools: false,
  panel: [
    'ollama_cloud.ollama-cloud-devstral-2-123b',
    'ollama_cloud.ollama-cloud-devstral-small-2-24b',
    'ollama_cloud.ollama-cloud-ministral-3-14b',
  ],
  judge: 'ollama_cloud.ollama-cloud-devstral-2-123b',
  panelTimeoutS: 300,
  judgeTimeoutS: 300,
  maxToolCallsPerPanel: 0,
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
        <span class="mono">${providerName}</span>
      </div>
      <div class="set-rt-row">
        <span class="sub-k">model</span>
        <span class="mono">${modelName}</span>
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
      <div class="set-rt-row">
        <span class="sub-k">transport</span>
        <span class="mono set-runtime-transport">${transport}</span>
      </div>
    </div>
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

function settingsSectionState(
  section: SectionId,
  fusionSettingsWritable: boolean,
): { mode: SettingsSectionMode; label: string } {
  if (section === 'runtime') return { mode: 'live', label: 'runtime.toml + provider catalog' }
  if (section === 'runtimes') return { mode: 'live', label: 'runtime.toml live-backed' }
  if (section === 'prompts') return { mode: 'live', label: 'prompt registry live-backed' }
  if (section === 'fusion' && fusionSettingsWritable) {
    return { mode: 'live', label: 'runtime.toml live-backed' }
  }
  if (section === 'fusion') return { mode: 'local', label: 'documented defaults preview' }
  if (section === 'paths') return { mode: 'live', label: 'resolved by server' }
  if (section === 'mcp') return { mode: 'mixed', label: 'live MCP check + inventory' }
  if (section === 'logs') return { mode: 'mixed', label: 'live logs + local filters' }
  if (section === 'notify') return { mode: 'live', label: 'live thresholds read-only' }
  if (section === 'display') return { mode: 'live', label: 'theme/density live' }
  return { mode: 'local', label: 'read-only preview' }
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

  // Server config projection — used by Paths, MCP and Notifications.
  const [dashboardConfig, setDashboardConfig] = useState<DashboardConfigResponse | null>(null)
  const [dashboardConfigStatus, setDashboardConfigStatus] = useState<'loading' | 'ready' | 'error'>('loading')

  useEffect(() => {
    let active = true
    setDashboardConfigStatus('loading')
    void (async () => {
      try {
        const resp = await fetchDashboardConfig()
        if (!active) return
        setDashboardConfig(resp)
        setDashboardConfigStatus('ready')
      } catch {
        if (!active) return
        setDashboardConfig(null)
        setDashboardConfigStatus('error')
      }
    })()
    return () => { active = false }
  }, [])

  // mcp — exposed tools come from the live capability registry (public_mcp surface)
  const [mcpTools, setMcpTools] = useState<string[]>([])
  const [mcpCheck, setMcpCheck] = useState<{ status: 'idle' | 'checking' | 'ok' | 'error'; message: string }>({
    status: 'idle',
    message: '아직 확인하지 않음',
  })

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const resp = await fetchDashboardTools()
        if (!active) return
        const names = mcpExposedToolNames(resp.tool_inventory?.tools ?? [])
        setMcpTools(names)
      } catch {
        if (!active) return
        // No fabricated tool names on failure.
        setMcpTools([])
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

  // fusion (config/runtime.toml [fusion]) — keeper-v2 settings.jsx:178-182
  const fusionSettingsWritable = envBool('VITE_FUSION_SETTINGS_WRITABLE', false)

  // display
  const density = tweaksDensity.value
  const setDensity = (next: string) => {
    if ((DISPLAY_DENSITY_OPTIONS as string[]).includes(next)) {
      tweaksDensity.value = next as Density
    }
  }
  const cur = SET_SECTIONS.find(s => s[0] === sec) ?? SET_SECTIONS[0]!
  const sectionState = settingsSectionState(sec, fusionSettingsWritable)

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
  const crossVerifierRuntime = runtimeDefaults?.model_routing.cross_verifier_runtime_id ?? null
  const mediaFailover = runtimeDefaults?.model_routing.media_failover ?? []
  const runtimeResolution = shellRuntimeResolution.value
  const configResolution = shellConfigResolution.value
  const mcpEndpoint = mcpEndpointFromConfig(dashboardConfig)
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
            class=${`set-card-b mx-6 my-6 ${sec === 'runtime' || sec === 'runtimes' || sec === 'paths' || sec === 'mcp' || sec === 'notify' || sec === 'prompts' ? 'set-card-b-wide' : 'ss-card'}`}
            data-preview-locked="false"
            data-settings-mode=${sectionState.mode}
          >
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
              <div class="set-sub-h">Exposed public MCP tools (${mcpTools.length})</div>
              ${mcpTools.length === 0
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
                  <${SetRow} label="Default runtime" hint="[runtime].default">
                    ${defaultRuntimeId
                      ? html`<span class="mono" data-testid="runtime-default-runtime">${defaultRuntimeId}</span>`
                      : html`<span class="set-hint" data-testid="runtime-default-empty">런타임 설정을 불러오지 못했습니다.</span>`}
                  <//>
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

                <div class="settings-runtime-section" data-runtime-section="routing" data-testid="runtime-routing-section">
                  <div class="set-sub-h">Model routing</div>
                  <div class="set-route-summary" data-testid="runtime-routing-summary">
                    ${librarianRuntime
                      ? html`<span><span class="sub-k">librarian</span><span class="mono">${librarianRuntime}</span></span>`
                      : html`<span><span class="sub-k">librarian</span><span class="mono">default runtime</span></span>`}
                    ${crossVerifierRuntime
                      ? html`<span><span class="sub-k">cross verifier</span><span class="mono">${crossVerifierRuntime}</span></span>`
                      : html`<span><span class="sub-k">cross verifier</span><span class="mono">default runtime</span></span>`}
                    <span><span class="sub-k">media failover</span><span class="mono">${mediaFailover.length > 0 ? mediaFailover.join(', ') : 'none'}</span></span>
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
                </div>
              </div>
            `}

            ${sec === 'runtimes' && html`
              <${RuntimeTomlEditor} />
            `}

            ${sec === 'prompts' && html`
              <${PromptRegistryPanel} embedded=${true} />
            `}

            ${sec === 'fusion' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                <span class="mono">masc_fusion</span> 의 out-of-band 심의 루프 (RFC-0252). 서로 다른 모델 패밀리로 패널을 구성해 관점 다양성을 확보하고, 심판이 종합합니다. fusion이 발화 가치 있는지는 keeper가 판단하고 게이트는 남용만 막습니다.
              </div>
              ${fusionSettingsWritable
                ? html`<${FusionSettingsPanel} />`
                : html`
                <div data-testid="fusion-readonly-preview">
                  <${SetRow} label="Fusion 심의" hint="[fusion].enabled · 문서화된 기본값">
                    <div class="set-truth-value">
                      <span class="mono" data-testid="fusion-readonly-enabled">${FUSION.enabled ? 'enabled' : 'disabled'}</span>
                      <span class="set-truth-source">read-only</span>
                    </div>
                  <//>
                  <${SetRow} label="기본 프리셋" hint="default_preset">
                    <div class="set-truth-value">
                      <span class="mono" data-testid="fusion-readonly-preset">${FUSION.defaultPreset}</span>
                      <span class="set-truth-source">read-only</span>
                    </div>
                  <//>
                  <${SetRow} label="동시 패널 수" hint="max_concurrent_panels · Async_agent.all 상한">
                    <div class="set-truth-value">
                      <span class="mono" data-testid="fusion-readonly-panels">${FUSION.maxConcurrentPanels}</span>
                      <span class="set-truth-source">read-only</span>
                    </div>
                  <//>
                  <${SetRow} label="패널·심판 웹 도구" hint="web_search / web_fetch 주입 여부">
                    <div class="set-truth-value">
                      <span class="mono" data-testid="fusion-readonly-web-tools">${FUSION.webTools ? 'enabled' : 'disabled'}</span>
                      <span class="set-truth-source">read-only</span>
                    </div>
                  <//>
                  <div class="set-sub-h">trio 프리셋</div>
                  <div class="set-fus-preset">
                    <div class="set-fus-lane">
                      <div class="set-fus-lane-h">panel · ${FUSION.panel.length}</div>
                      ${FUSION.panel.map(id => html`<div key=${id} class="set-fus-model mono">${id}</div>`)}
                    </div>
                    <div class="set-fus-lane">
                      <div class="set-fus-lane-h">judge</div>
                      <div class="set-fus-model judge mono">${FUSION.judge}</div>
                    </div>
                  </div>
                  <div class="set-mcp-detail mono" style=${{ marginTop: '10px' }}>
                    panel_timeout ${FUSION.panelTimeoutS}s · judge_timeout ${FUSION.judgeTimeoutS}s · max_tool_calls_per_panel ${FUSION.maxToolCallsPerPanel} (0 = 무제한)
                  </div>
                </div>
              `}
            `}

            ${sec === 'paths' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                서버가 실제로 해석한 base path, data/config root, runtime.toml 경로입니다. 값은 dashboard shell/config projection에서 읽고, 입력 필드로 덮어쓰지 않습니다.
              </div>
              ${dashboardConfigStatus === 'error'
                ? html`<div class="set-hint" data-testid="settings-config-error">dashboard config projection을 불러오지 못했습니다.</div>`
                : null}
              <div class="set-sub-h">Runtime path resolution</div>
              <${PathTruthRow} label="Base path" item=${runtimeResolution?.base_path ?? null} fallback=${concreteConfigValue(basePathEntry)} />
              <${PathTruthRow} label="Resolved base path" item=${runtimeResolution?.resolved_base_path ?? null} />
              <${PathTruthRow} label="Workspace path" item=${runtimeResolution?.workspace_path ?? null} />
              <${PathTruthRow} label="Data root" item=${runtimeResolution?.data_root ?? null} fallback=${concreteConfigValue(dataDirEntry)} />
              <${PathTruthRow} label="Prompt markdown dir" item=${runtimeResolution?.prompt_markdown_dir ?? null} />
              <${PathTruthRow} label="Runtime TOML" item=${configResolution?.runtime ?? null} fallback=${runtimeConfigPath} />
              <${PathTruthRow} label="Config root" item=${configResolution?.config_root ?? null} fallback=${concreteConfigValue(configDirEntry)} />

              <div class="set-sub-h">Config env inputs</div>
              <${ConfigTruthRow} label="MASC_BASE_PATH" entry=${basePathEntry} />
              <${ConfigTruthRow} label="MASC_CONFIG_DIR" entry=${configDirEntry} />
              <${ConfigTruthRow} label="MASC_DATA_DIR" entry=${dataDirEntry} />
              <${ConfigTruthRow} label="MCP endpoint" entry=${mcpUrlEntry} fallback=${mcpEndpoint} />
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
            `}
          </div>
        </div>
      </div>
    </main>
  `
}
