// MASC Dashboard — Settings surface (keeper-v2 port)
// Read surfaces (MCP exposed-tools list, system-log tail, runtime defaults /
// model routing) are wired to live backend data. Most write surfaces remain
// read-only previews; runtime.toml management is live-backed.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  SETTINGS_ROUTE_SECTION_IDS,
  type SettingsRouteSectionId,
} from '../config/navigation'
import { navigate, route } from '../router'
import {
  fetchDashboardTools,
  fetchKeeperConfig,
  fetchLogs,
  fetchRuntimeDefaults,
  fetchRuntimeProviders,
  patchKeeperConfig,
} from '../api/dashboard.js'
import type {
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeProvidersResponse,
  DashboardToolInventoryItem,
  KeeperConfigUpdatePayload,
  LogEntry,
  RuntimeDefaultsResponse,
  SandboxNetworkMode,
  SandboxProfile,
} from '../api/dashboard.js'
import { fetchGateConnectors, type GateConnectorInfo, type GateConnectorsData } from '../api/gate'
import { fetchKeepersComposite } from '../api/keeper'
import { envBool } from '../config/env'
import { keepers } from '../store'
import type { KeeperConfig } from '../types'
import { RuntimeTomlEditor } from './runtime-toml-editor'
import { FusionSettingsPanel } from './fusion-settings-panel'
import { PromptRegistryPanel } from './tools/prompt-registry-panel'
import { ThemeSwitch } from './theme-switch'
import type { ComponentChildren } from 'preact'
import { errorToString } from '../lib/format-string'

type SectionId = SettingsRouteSectionId

type LogFilter = 'all' | 'tool' | 'success' | 'failure'
type PathCheckTarget = 'mcp' | 'store' | 'worktree'
type PathCheckResult = {
  readonly ok: boolean
  readonly message: string
}
type BoolRecordUpdater = Record<string, boolean> | ((prev: Record<string, boolean>) => Record<string, boolean>)
const SETTINGS_ROUTE_SECTION_SET = new Set<string>(SETTINGS_ROUTE_SECTION_IDS)
const SETTINGS_LOCAL_STORAGE_PREFIX = 'masc.settings.local.'

const SET_SECTIONS: [SectionId, string, string][] = [
  ['account', 'Account', '계정'],
  ['mcp', 'MCP', 'MCP 서버'],
  ['runtime', 'Runtime', '런타임 기본값'],
  ['runtimes', 'Runtimes', '런타임 관리'],
  ['routing', 'Routing', '모델 라우팅'],
  ['prompts', 'Prompts', '기본 프롬프트'],
  // keeper-v2 settings.jsx:35-36 — Fusion '패널·심판 심의', Policy '도구 정책'.
  ['fusion', 'Fusion', '패널·심판 심의'],
  ['policy', 'Policy', '도구 정책'],
  ['lifecycle', 'Lifecycle', 'keeper 수명'],
  ['sandbox', 'Sandbox', '샌드박스'],
  ['ide', 'IDE', 'IDE · 편집기'],
  ['gate', 'Gate', '커넥터 게이트'],
  ['paths', 'Paths', '경로 · Basepath'],
  ['logs', 'Logs', '관측 · 시스템 로그'],
  ['notify', 'Notify', '알림'],
  ['display', 'Display', '표시'],
]

const SET_GROUPS: [string, SectionId[]][] = [
  // KO group labels per keeper-v2 settings.jsx SET_GROUPS — matches the
  // Korean section names below (avoids EN-header / KO-item bilingual mismatch).
  ['계정', ['account']],
  // keeper-v2 settings.jsx:49 — 'Keeper 운영' group order: runtime · routing ·
  // prompts · fusion · lifecycle · policy.
  ['Keeper 운영', ['runtime', 'routing', 'prompts', 'fusion', 'lifecycle', 'policy']],
  ['인프라 · 실행', ['runtimes', 'sandbox', 'paths']],
  ['연결 · 통합', ['mcp', 'gate', 'ide']],
  ['관측 · 표시', ['logs', 'notify', 'display']],
]

// Tools exposed over the public MCP server, derived from the live capability
// registry (`/api/v1/dashboard/tools`). The "public_mcp" surface is the
// registry's own exposure signal — see lib/tool_misc_introspection.ml
// (Tool_catalog.is_public_mcp). Unknown/empty inventory yields an empty list
// (no fabricated tool names).
const MCP_PUBLIC_SURFACE = 'public_mcp'
const MCP_TRANSPORT_OPTIONS = ['http', 'stdio', 'sse']
const SETTINGS_LOG_LIMIT = 50
const SETTINGS_LOG_POLL_MS = 3000
const DEFAULT_NOTIFY_EVENT_PREVIEW: Record<string, boolean> = {
  '컨텍스트 임계치 초과': true,
  '연속 실패': true,
  'keeper crash/dead': true,
  '핸드오프 완료': false,
  '승인 요청': true,
}

export function normalizeSettingsSection(value: string | null | undefined): SectionId {
  return SETTINGS_ROUTE_SECTION_SET.has(value ?? '') ? (value as SectionId) : 'account'
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

export function checkSettingsStoreUrl(value: string): PathCheckResult {
  const trimmed = value.trim()
  if (trimmed === '') return { ok: false, message: 'URL required' }
  try {
    const url = new URL(trimmed)
    if (url.protocol !== 'postgres:' && url.protocol !== 'postgresql:') {
      return { ok: false, message: 'expected postgres URL' }
    }
    if (url.hostname.trim() === '') return { ok: false, message: 'host required' }
    return { ok: true, message: 'valid store URL' }
  } catch {
    return { ok: false, message: 'invalid URL' }
  }
}

export function checkSettingsWorktreeBase(value: string): PathCheckResult {
  const trimmed = value.trim()
  if (trimmed === '') return { ok: false, message: 'path required' }
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    return { ok: false, message: 'expected filesystem path' }
  }
  if (
    trimmed.startsWith('~/') ||
    trimmed === '~' ||
    trimmed.startsWith('/') ||
    trimmed.startsWith('./') ||
    trimmed.startsWith('../')
  ) {
    return { ok: true, message: 'valid local path' }
  }
  return { ok: false, message: 'use absolute, ./, ../, or ~/' }
}

function readLocalPreviewString(key: string, fallback: string): string {
  try {
    if (typeof sessionStorage === 'undefined') return fallback
    return sessionStorage.getItem(`${SETTINGS_LOCAL_STORAGE_PREFIX}${key}`) ?? fallback
  } catch {
    return fallback
  }
}

function writeLocalPreviewString(key: string, value: string) {
  try {
    if (typeof sessionStorage === 'undefined') return
    sessionStorage.setItem(`${SETTINGS_LOCAL_STORAGE_PREFIX}${key}`, value)
  } catch {
    // Local preview settings are best-effort; blocked storage should not break Settings.
  }
}

function readLocalPreviewNumber(key: string, fallback: number): number {
  const parsed = Number(readLocalPreviewString(key, String(fallback)))
  return Number.isFinite(parsed) ? parsed : fallback
}

function readLocalPreviewBoolRecord(key: string, fallback: Record<string, boolean>): Record<string, boolean> {
  const next = { ...fallback }
  try {
    if (typeof sessionStorage === 'undefined') return next
    const raw = sessionStorage.getItem(`${SETTINGS_LOCAL_STORAGE_PREFIX}${key}`)
    if (raw === null) return next
    const parsed: unknown = JSON.parse(raw)
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return next
    const values = parsed as Record<string, unknown>
    for (const id of Object.keys(next)) {
      if (typeof values[id] === 'boolean') next[id] = values[id]
    }
  } catch {
    return next
  }
  return next
}

function writeLocalPreviewBoolRecord(key: string, value: Record<string, boolean>) {
  try {
    if (typeof sessionStorage === 'undefined') return
    sessionStorage.setItem(`${SETTINGS_LOCAL_STORAGE_PREFIX}${key}`, JSON.stringify(value))
  } catch {
    // Local preview settings are best-effort; blocked storage should not break Settings.
  }
}

function useLocalPreviewString(key: string, initialValue: string): [string, (next: string) => void] {
  const [value, setValue] = useState(() => readLocalPreviewString(key, initialValue))
  const setStoredValue = (next: string) => {
    setValue(next)
    writeLocalPreviewString(key, next)
  }
  return [value, setStoredValue]
}

function useLocalPreviewNumber(key: string, initialValue: number): [number, (next: number) => void] {
  const [value, setValue] = useState(() => readLocalPreviewNumber(key, initialValue))
  const setStoredValue = (next: number) => {
    setValue(next)
    writeLocalPreviewString(key, String(next))
  }
  return [value, setStoredValue]
}

function useLocalPreviewBoolRecord(
  key: string,
  initialValue: Record<string, boolean>,
): [Record<string, boolean>, (next: BoolRecordUpdater) => void] {
  const [value, setValue] = useState(() => readLocalPreviewBoolRecord(key, initialValue))
  const setStoredValue = (nextOrUpdate: BoolRecordUpdater) => {
    setValue(prev => {
      const next = typeof nextOrUpdate === 'function' ? nextOrUpdate(prev) : nextOrUpdate
      writeLocalPreviewBoolRecord(key, next)
      return next
    })
  }
  return [value, setStoredValue]
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
    'ollama_cloud.deepseek-v4-flash',
    'glm-coding.glm-5-turbo',
    'ollama_cloud.minimax-m3',
  ],
  judge: 'deepseek.deepseek-v4-pro',
  panelTimeoutS: 300,
  judgeTimeoutS: 300,
  maxToolCallsPerPanel: 0,
}

// Tool-group catalog for the prototype settings surface snapshot.
// keeper-v2 settings.jsx:85-97 (TOOL_GROUPS). kind 'local' = [groups.*]
// (keeper-local), 'masc' = [masc.*] (server). guard/optin map to the
// [groups.execute] 3-layer guard and opt-in voice group.
// NOTE: read-only snapshot only; live tool_policy/tier policy data is not yet
// projected from backend policy SSOT.
type ToolGroup = {
  readonly id: string
  readonly kind: 'local' | 'masc'
  readonly tools: readonly string[]
  readonly guard?: boolean
  readonly optin?: boolean
}
const TOOL_GROUPS: readonly ToolGroup[] = [
  { id: 'base', kind: 'local', tools: ['keeper_time_now', 'keeper_context_status', 'keeper_memory_search', 'keeper_memory_write', 'keeper_tool_search', 'keeper_tools_list'] },
  { id: 'board_core', kind: 'local', tools: ['keeper_board_get', 'keeper_board_post', 'keeper_board_comment', 'keeper_board_vote', 'keeper_board_list', 'keeper_board_curation_read', 'keeper_board_curation_submit'] },
  { id: 'workspace_core', kind: 'local', tools: ['keeper_tasks_list', 'keeper_task_claim', 'keeper_task_create', 'keeper_task_done', 'keeper_broadcast'] },
  { id: 'filesystem', kind: 'local', tools: ['tool_read_file'] },
  { id: 'workspace_write', kind: 'local', tools: ['tool_edit_file', 'tool_write_file'] },
  { id: 'execute', kind: 'local', guard: true, tools: ['tool_execute'] },
  { id: 'library', kind: 'local', tools: ['keeper_library_search', 'keeper_library_read'] },
  { id: 'voice', kind: 'local', optin: true, tools: ['keeper_voice_speak', 'keeper_voice_listen', 'keeper_voice_agent', 'keeper_voice_sessions'] },
  { id: 'masc.essential', kind: 'masc', tools: ['masc_status', 'masc_web_search', 'masc_web_fetch'] },
  { id: 'masc.workspace', kind: 'masc', tools: ['masc_tasks', 'masc_claim_next', 'masc_transition', 'masc_add_task', 'masc_agents', 'masc_broadcast', 'masc_messages', 'masc_heartbeat'] },
  { id: 'masc.goal', kind: 'masc', tools: ['masc_goal_list', 'masc_goal_upsert', 'masc_goal_transition', 'masc_goal_verify'] },
]
const DEFAULT_TOOL_GROUP_GRANTS: Record<string, boolean> = Object.fromEntries(
  TOOL_GROUPS.map(g => [g.id, !g.optin]),
)
// [groups.last_turn_safe] — keeper-v2 settings.jsx:99. On a keeper's final
// turn, allowed tools are intersected with this set. Snapshot from the
// prototype settings view; backend parity is deferred.
const LAST_TURN_SAFE: readonly string[] = ['keeper_board_post', 'keeper_board_comment', 'keeper_board_curation_submit', 'keeper_context_status', 'extend_turns', 'keeper_time_now', 'keeper_tool_search', 'keeper_broadcast', 'keeper_tasks_list', 'keeper_task_done', 'masc_tasks', 'masc_transition', 'tool_read_file', 'tool_search_files', 'tool_execute', 'masc_web_search', 'masc_web_fetch']
// tool_execute 3-layer deterministic guard — keeper-v2 settings.jsx:101
// ([groups.execute]).
const EXEC_GUARD: readonly string[] = ['validate_command', 'destructive_guard', 'write_gate']
// System-log row: [time, level, identity, message, status]. Derived from live
// ring entries (`/api/v1/dashboard/logs`) — the same source the Logs surface
// polls. Status is derived from the entry level only (error→fail, warn→warn,
// else→ok); the in-progress "run" state is not knowable from a settled ring
// entry, so it is never fabricated.
type SysLogRow = [string, string, string, string, string]

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
  return [logRowClock(entry.ts), level, identity, entry.message, logRowStatus(entry.level)]
}

function SetToggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return html`
    <button
      type="button"
      class=${`set-toggle ${on ? 'on' : ''}`}
      role="switch"
      aria-checked=${on}
      data-testid="set-toggle"
      data-active=${on ? 'true' : 'false'}
      onClick=${() => onChange(!on)}
    >
      <span class="knob"></span>
    </button>
  `
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

function SetStepper({
  v,
  set,
  min,
  max,
}: {
  v: number
  set: (n: number) => void
  min: number
  max: number
}) {
  return html`
    <div class="set-stepper" data-testid="set-stepper">
      <button type="button" disabled=${v <= min} onClick=${() => set(Math.max(min, v - 1))}>−</button>
      <span class="mono">${v}</span>
      <button type="button" disabled=${v >= max} onClick=${() => set(Math.min(max, v + 1))}>+</button>
    </div>
  `
}

function SetSlider({
  value,
  min,
  max,
  step,
  suffix,
  onChange,
}: {
  value: number
  min: number
  max: number
  step?: number
  suffix?: string
  onChange: (n: number) => void
}) {
  return html`
    <div class="set-slider" data-testid="set-slider">
      <input
        type="range"
        min=${min}
        max=${max}
        step=${step ?? 1}
        value=${value}
        onInput=${(e: Event) => onChange(Number((e.target as HTMLInputElement).value))}
      />
      <span class="mono">${value}${suffix ?? ''}</span>
    </div>
  `
}

function PreviewBadge({ label = 'local only' }: { label?: string }) {
  return html`
    <span
      class="set-preview-badge"
      data-testid="settings-preview-badge"
    >
      ${label}
    </span>
  `
}

function PathCheckBadge({
  result,
  target,
}: {
  result: PathCheckResult | undefined
  target: PathCheckTarget
}) {
  if (!result) return null
  return html`
    <span
      class=${`set-path-check-result ${result.ok ? 'ok' : 'fail'}`}
      data-testid=${`settings-path-check-result-${target}`}
      data-ok=${result.ok ? 'true' : 'false'}
    >
      ${result.message}
    </span>
  `
}

function RolePill({ children }: { children: ComponentChildren }) {
  return html`<span class="set-rolepill">${children}</span>`
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
  const isOn = value === true
  return html`<span class=${`rt-cap ${isOn ? 'on' : ''}`}>${isOn ? '✓' : '·'} ${label}</span>`
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

type SandboxDraft = {
  sandbox_profile: SandboxProfile
  network_mode: SandboxNetworkMode
  allowed_paths_text: string
}

function coerceSandboxProfile(raw: string | null | undefined): SandboxProfile {
  return raw === 'docker' ? 'docker' : 'local'
}

function coerceNetworkMode(raw: string | null | undefined): SandboxNetworkMode {
  return raw === 'none' ? 'none' : 'inherit'
}

function dedupeListText(text: string): string[] {
  const seen = new Set<string>()
  const values: string[] = []
  for (const raw of text.split('\n')) {
    const item = raw.trim()
    if (!item || seen.has(item)) continue
    seen.add(item)
    values.push(item)
  }
  return values
}

function sameStringArray(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index])
}

function sandboxDraftFromConfig(config: KeeperConfig): SandboxDraft {
  return {
    sandbox_profile: coerceSandboxProfile(config.sandbox_profile),
    network_mode: coerceNetworkMode(config.network_mode),
    allowed_paths_text: (config.allowed_paths ?? []).join('\n'),
  }
}

function buildSandboxPayload(draft: SandboxDraft, config: KeeperConfig): KeeperConfigUpdatePayload {
  const payload: KeeperConfigUpdatePayload = {}
  const allowedPaths = dedupeListText(draft.allowed_paths_text)
  if (draft.sandbox_profile !== coerceSandboxProfile(config.sandbox_profile)) {
    payload.sandbox_profile = draft.sandbox_profile
  }
  if (draft.network_mode !== coerceNetworkMode(config.network_mode)) {
    payload.network_mode = draft.network_mode
  }
  if (!sameStringArray(allowedPaths, config.allowed_paths ?? [])) {
    payload.allowed_paths = allowedPaths
  }
  return payload
}

function connectorState(connector: GateConnectorInfo): 'connected' | 'stale' | 'offline' {
  if (!connector.available) return 'offline'
  if (connector.stale) return 'stale'
  return connector.connected ? 'connected' : 'offline'
}

function connectorStateText(connector: GateConnectorInfo): string {
  const state = connectorState(connector)
  if (state === 'connected') return 'connected'
  if (state === 'stale') return 'stale'
  return connector.status || 'offline'
}

function uniqueConnectorGateBaseUrls(connectors: readonly GateConnectorInfo[]): string[] {
  return Array.from(new Set(
    connectors
      .map(connector => connector.gate_base_url.trim())
      .filter(Boolean),
  )).sort((a, b) => a.localeCompare(b))
}

function uniqueNonEmptyStrings(values: readonly (string | null | undefined)[]): string[] {
  const seen = new Set<string>()
  const names: string[] = []
  for (const value of values) {
    const name = value?.trim()
    if (!name || seen.has(name)) continue
    seen.add(name)
    names.push(name)
  }
  return names
}

type SettingsSectionMode = 'live' | 'local'

function settingsSectionState(
  section: SectionId,
  fusionSettingsWritable: boolean,
): { mode: SettingsSectionMode; label: string } {
  if (section === 'runtime') return { mode: 'live', label: 'runtime.toml live-backed' }
  if (section === 'runtimes') return { mode: 'live', label: 'runtime.toml live-backed' }
  if (section === 'routing') return { mode: 'live', label: 'runtime.toml live-backed' }
  if (section === 'prompts') return { mode: 'live', label: 'prompt registry live-backed' }
  if (section === 'sandbox') return { mode: 'live', label: 'keeper config live-backed' }
  if (section === 'gate') return { mode: 'live', label: 'gate connector live-backed' }
  if (section === 'fusion' && fusionSettingsWritable) {
    return { mode: 'live', label: 'runtime.toml live-backed' }
  }
  if (section === 'mcp') return { mode: 'local', label: 'live inventory + local controls' }
  if (section === 'logs') return { mode: 'local', label: 'live logs + local controls' }
  return { mode: 'local', label: 'local preview only' }
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
    if (filter === 'tool') return /masc_/.test(r[3])
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
    navigate('settings', id === 'account' ? {} : { section: id })
  }

  // account
  const [sessionExpiry, setSessionExpiry] = useState('8시간')

  // mcp — exposed tools come from the live capability registry (public_mcp surface)
  const [mcpUrl, setMcpUrl] = useLocalPreviewString('mcpUrl', 'https://masc.local/mcp')
  const [transport, setTransport] = useLocalPreviewString('mcpTransport', 'http')
  const [mcpTools, setMcpTools] = useState<string[]>([])
  const [tools, setTools] = useState<Record<string, boolean>>({})

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const resp = await fetchDashboardTools()
        if (!active) return
        const names = mcpExposedToolNames(resp.tool_inventory?.tools ?? [])
        setMcpTools(names)
        setTools(readLocalPreviewBoolRecord('mcpToolPreview', Object.fromEntries(names.map(n => [n, true]))))
      } catch {
        if (!active) return
        // No fabricated tool names on failure.
        setMcpTools([])
        setTools({})
      }
    })()
    return () => { active = false }
  }, [])

  function updateMcpToolPreview(tool: string, enabled: boolean) {
    setTools(prev => {
      const next = { ...prev, [tool]: enabled }
      writeLocalPreviewBoolRecord('mcpToolPreview', next)
      return next
    })
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

  // policy — tool-group grants (namespace default-grant per [groups.*]); opt-in groups
  // start off. keeper-v2 settings.jsx:177.
  const [grant, setGrant] = useLocalPreviewBoolRecord('policyGrant', DEFAULT_TOOL_GROUP_GRANTS)

  // fusion (config/runtime.toml [fusion]) — keeper-v2 settings.jsx:178-182
  const fusionSettingsWritable = envBool('VITE_FUSION_SETTINGS_WRITABLE', false)
  const [fusionOn, setFusionOn] = useState(FUSION.enabled)
  const [fusionPreset, setFusionPreset] = useState(FUSION.defaultPreset)
  const [fusionPanels, setFusionPanels] = useState(FUSION.maxConcurrentPanels)
  const [fusionWeb, setFusionWeb] = useState(FUSION.webTools)

  // lifecycle
  const [idleDrain, setIdleDrain] = useState(30)
  const [autoRestart, setAutoRestart] = useState(true)
  const [restartMax, setRestartMax] = useState(3)
  const [onOverflow, setOnOverflow] = useState('자동 compact')

  // gate / paths
  const [gateConnectorsData, setGateConnectorsData] = useState<GateConnectorsData | null>(null)
  const [gateConnectorsStatus, setGateConnectorsStatus] = useState<'idle' | 'loading' | 'ready' | 'error'>('idle')
  const [gateConnectorsError, setGateConnectorsError] = useState<string | null>(null)
  const [wtBase, setWtBase] = useLocalPreviewString('wtBase', '~/wt')
  const [storeUrl, setStoreUrl] = useLocalPreviewString('storeUrl', 'postgres://masc.local:5432/masc')
  const [pathChecks, setPathChecks] = useState<Partial<Record<PathCheckTarget, PathCheckResult>>>({})

  function runPathCheck(target: PathCheckTarget) {
    let result: PathCheckResult
    switch (target) {
      case 'mcp':
        result = checkSettingsMcpEndpoint(mcpUrl)
        break
      case 'store':
        result = checkSettingsStoreUrl(storeUrl)
        break
      case 'worktree':
        result = checkSettingsWorktreeBase(wtBase)
        break
    }
    setPathChecks(current => ({ ...current, [target]: result }))
  }

  // sandbox — per-keeper live config, not a global sandbox policy.
  const [sandboxFallbackKeeperNames, setSandboxFallbackKeeperNames] = useState<string[]>([])
  const [sandboxKeeperListStatus, setSandboxKeeperListStatus] = useState<'idle' | 'loading' | 'ready' | 'error'>('idle')
  const [sandboxKeeperListError, setSandboxKeeperListError] = useState<string | null>(null)
  const liveKeeperCount = keepers.value.length
  const keeperList = liveKeeperCount > 0
    ? keepers.value
    : sandboxFallbackKeeperNames.map(name => ({ name, status: 'unknown' }))
  const keeperNamesKey = keeperList.map(keeper => keeper.name).join('\u0000')
  const [sandboxKeeperName, setSandboxKeeperName] = useState('')
  const [sandboxConfig, setSandboxConfig] = useState<KeeperConfig | null>(null)
  const [sandboxDraft, setSandboxDraft] = useState<SandboxDraft | null>(null)
  const [sandboxStatus, setSandboxStatus] = useState<'idle' | 'loading' | 'ready' | 'saving' | 'error'>('idle')
  const [sandboxError, setSandboxError] = useState<string | null>(null)

  useEffect(() => {
    if (sec !== 'sandbox') return
    setSandboxKeeperName(current => {
      if (current && keeperList.some(keeper => keeper.name === current)) return current
      return keeperList[0]?.name ?? ''
    })
  }, [keeperNamesKey, sec])

  useEffect(() => {
    if (sec !== 'sandbox' || liveKeeperCount > 0) return undefined
    const controller = new AbortController()
    setSandboxKeeperListStatus('loading')
    setSandboxKeeperListError(null)
    void (async () => {
      try {
        const fleet = await fetchKeepersComposite({ signal: controller.signal })
        if (controller.signal.aborted) return
        const names = uniqueNonEmptyStrings(fleet.snapshots.map(snapshot => snapshot.keeper))
        setSandboxFallbackKeeperNames(names)
        setSandboxKeeperListStatus('ready')
      } catch (err: unknown) {
        if (controller.signal.aborted) return
        setSandboxFallbackKeeperNames([])
        setSandboxKeeperListStatus('error')
        setSandboxKeeperListError(errorToString(err))
      }
    })()
    return () => controller.abort()
  }, [liveKeeperCount, sec])

  useEffect(() => {
    if (sec !== 'gate') return undefined
    const controller = new AbortController()
    setGateConnectorsStatus('loading')
    setGateConnectorsError(null)
    void (async () => {
      try {
        const resp = await fetchGateConnectors(controller.signal)
        setGateConnectorsData(resp)
        setGateConnectorsStatus('ready')
      } catch (err: unknown) {
        if (controller.signal.aborted) return
        setGateConnectorsData(null)
        setGateConnectorsStatus('error')
        setGateConnectorsError(errorToString(err))
      }
    })()
    return () => controller.abort()
  }, [sec])

  useEffect(() => {
    if (sec !== 'sandbox' || !sandboxKeeperName) return undefined
    let active = true
    setSandboxStatus('loading')
    setSandboxError(null)
    setSandboxConfig(null)
    setSandboxDraft(null)
    void (async () => {
      try {
        const config = await fetchKeeperConfig(sandboxKeeperName)
        if (!active) return
        setSandboxConfig(config)
        setSandboxDraft(sandboxDraftFromConfig(config))
        setSandboxStatus('ready')
      } catch (err: unknown) {
        if (!active) return
        setSandboxStatus('error')
        setSandboxError(errorToString(err))
      }
    })()
    return () => { active = false }
  }, [sandboxKeeperName, sec])

  function updateSandboxDraft(field: keyof SandboxDraft, value: string) {
    setSandboxDraft(current => {
      if (!current) return current
      const next = { ...current, [field]: value } as SandboxDraft
      if (field === 'sandbox_profile' && next.sandbox_profile !== 'docker' && next.network_mode === 'none') {
        next.network_mode = 'inherit'
      }
      if (field === 'network_mode' && next.sandbox_profile !== 'docker' && next.network_mode === 'none') {
        next.network_mode = 'inherit'
      }
      return next
    })
  }

  async function saveSandboxConfig() {
    if (!sandboxConfig || !sandboxDraft || sandboxStatus === 'saving') return
    const payload = buildSandboxPayload(sandboxDraft, sandboxConfig)
    if (Object.keys(payload).length === 0) return
    setSandboxStatus('saving')
    setSandboxError(null)
    try {
      const updated = await patchKeeperConfig(sandboxConfig.name, payload)
      setSandboxConfig(updated)
      setSandboxDraft(sandboxDraftFromConfig(updated))
      setSandboxStatus('ready')
      keepers.value = keepers.value.map(keeper =>
        keeper.name === updated.name
          ? { ...keeper, sandbox_profile: coerceSandboxProfile(updated.sandbox_profile) }
          : keeper,
      )
    } catch (err: unknown) {
      setSandboxStatus('error')
      setSandboxError(errorToString(err))
    }
  }

  // ide
  const [ideView, setIdeView] = useState('split-diff')
  const [diffStyle, setDiffStyle] = useState('side-by-side')
  const [tabWidth, setTabWidth] = useState(2)
  const [formatOnSave, setFormatOnSave] = useState(true)
  const [wrapLines, setWrapLines] = useState(false)
  const [liveCursors, setLiveCursors] = useState(true)
  const [ideOwnership, setIdeOwnership] = useState(true)
  const [convRail, setConvRail] = useState(true)
  const [contextLens, setContextLens] = useState(true)
  const [blameGutter, setBlameGutter] = useState(true)
  const [ideAnnos, setIdeAnnos] = useState(true)
  const [annoAutoLink, setAnnoAutoLink] = useState(true)
  const [embedTerminal, setEmbedTerminal] = useState(true)
  const [searchIndex, setSearchIndex] = useState(true)
  const [ideRepo, setIdeRepo] = useLocalPreviewString('ideRepo', 'masc/masc-mcp')

  // logs
  const [traceKeep, setTraceKeep] = useState('30일')
  const [logLevel, setLogLevel] = useState('info')
  const [sampling, setSampling] = useState(100)

  // notify / display
  const [notifyCtx, setNotifyCtx] = useLocalPreviewNumber('notifyContextThreshold', 85)
  const [notifyFails, setNotifyFails] = useLocalPreviewNumber('notifyFailureThreshold', 3)
  const [notifyCh, setNotifyCh] = useLocalPreviewString('notifyChannel', 'Slack')
  const [notifyOn, setNotifyOn] = useLocalPreviewBoolRecord('notifyEventPreview', DEFAULT_NOTIFY_EVENT_PREVIEW)
  const [density, setDensity] = useState('regular')
  const [tz, setTz] = useState('Asia/Seoul')
  const [locale, setLocale] = useState('KO')
  const [clock24, setClock24] = useState(true)

  const cur = SET_SECTIONS.find(s => s[0] === sec) ?? SET_SECTIONS[0]!
  const sectionState = settingsSectionState(sec, fusionSettingsWritable)
  const grantedGroupCount = Object.values(grant).filter(Boolean).length
  const liveGateConnectors = gateConnectorsData?.connectors ?? []
  const liveGateBaseUrls = uniqueConnectorGateBaseUrls(liveGateConnectors)
  const sandboxDirty = sandboxConfig !== null && sandboxDraft !== null
    && Object.keys(buildSandboxPayload(sandboxDraft, sandboxConfig)).length > 0

  // Resolved runtime options (de-duplicated, derived from the live registry).
  const runtimeEntries = runtimeDefaults?.runtimes ?? []
  const runtimeCatalogEntries = runtimeProviders?.providers ?? []
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
  const mcpPreviewEnabledCount = Object.values(tools).filter(Boolean).length
  const notifyPreviewEnabledCount = Object.values(notifyOn).filter(Boolean).length

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
          <!-- keeper-v2 settings.jsx:262 — KO nav-note copy. -->
          <div class="set-nav-note">live-backed 섹션은 API에 저장됩니다. local preview 섹션은 이 브라우저 세션에서만 바뀝니다.</div>
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
            class=${`set-card-b mx-6 my-6 ${sec === 'runtime' || sec === 'runtimes' || sec === 'routing' || sec === 'prompts' ? 'set-card-b-wide' : 'ss-card'}`}
            data-preview-locked="false"
            data-settings-mode=${sectionState.mode}
          >
            ${sec === 'account' && html`
              <${SetRow} label="Operator" hint="Currently logged-in operator">
                <span class="mono" style=${{ color: 'var(--text-bright)' }}>@operator</span>
              <//>
              <${SetRow} label="Role" hint="MASC role — DM / player / keeper / operator">
                <${RolePill}>operator<//>
              <//>
              <${SetRow} label="API token" hint="Used for MCP·gate authentication">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    readOnly
                    value="••••••••••••••"
                  />
                  <${PreviewBadge} label="redacted" />
                </div>
              <//>
              <${SetRow} label="Session expiry" hint="Auto-logout timeout">
                <${SetSeg} value=${sessionExpiry} options=${['1시간', '8시간', '안 함']} onChange=${setSessionExpiry} />
              <//>
            `}

            ${sec === 'mcp' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Live <span class="mono">public_mcp</span> inventory is read from the backend. Endpoint, transport and per-tool switches below are browser-session exposure previews only; they do not rewrite MCP server policy.
              </div>
              <div class="set-local-summary" data-testid="mcp-local-summary">
                Previewing ${transport} against ${mcpUrl}; ${mcpPreviewEnabledCount}/${mcpTools.length} listed tools selected in this browser session.
              </div>
              <${SetRow} label="MCP endpoint" hint="GET/POST /mcp">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    data-testid="settings-mcp-endpoint-input"
                    value=${mcpUrl}
                    onInput=${(e: Event) => setMcpUrl((e.target as HTMLInputElement).value)}
                  />
                  <${PreviewBadge} />
                </div>
              <//>
              <${SetRow} label="Transport" hint="browser-session preview">
                <div class="set-tg-control">
                  <${PreviewBadge} />
                  <${SetSeg} value=${transport} options=${MCP_TRANSPORT_OPTIONS} onChange=${setTransport} />
                </div>
              <//>
              <div class="set-mcp-detail mono">
                ${transport === 'http' && html`<span>POST ${mcpUrl} · Content-Type: application/json · Authorization: Bearer ••••</span>`}
                ${transport === 'stdio' && html`<span>spawn: masc-mcp serve --stdio · framing: ndjson</span>`}
                ${transport === 'sse' && html`<span>GET ${mcpUrl}/sse · keep-alive 15s · event: message</span>`}
              </div>
              <div class="set-sub-h">Local tool exposure preview (${mcpPreviewEnabledCount}/${mcpTools.length})</div>
              ${mcpTools.length === 0
                ? html`<div class="set-hint" data-testid="mcp-tools-empty">노출된 MCP 도구가 없습니다.</div>`
                : mcpTools.map(t => html`
                <${SetRow} key=${t} label=${html`<span class="mono" style=${{ fontSize: '12.5px' }}>${t}</span>`}>
                  <div class="set-tg-control">
                    <${PreviewBadge} />
                    <${SetToggle}
                      on=${tools[t] ?? false}
                      onChange=${(v: boolean) => updateMcpToolPreview(t, v)}
                    />
                  </div>
                <//>
              `)}
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
                </div>

                <div class="set-sub-h">Runtime catalog (${runtimeCatalogEntries.length})</div>
                ${runtimeCatalogStatus === 'loading'
                  ? html`<div class="set-hint" data-testid="runtime-catalog-loading">runtime catalog 불러오는 중...</div>`
                  : runtimeCatalogStatus === 'error'
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
            `}

            ${sec === 'runtimes' && html`
              <${RuntimeTomlEditor} />
            `}

            ${sec === 'routing' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                runtime.toml 의 라우팅 레인과 keeper 배정을 직접 수정합니다. 기본 런타임, memory-os 라이브러리안, cross-verifier, keeper별 배정은 모두 같은 SSOT에 저장됩니다.
              </div>
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
                <${SetRow} label="Fusion 심의" hint="끄면 masc_fusion 호출이 게이트에서 Deny 반환">
                  <${SetToggle} on=${fusionOn} onChange=${setFusionOn} />
                <//>
                ${fusionOn && html`
                  <${SetRow} label="기본 프리셋" hint="default_preset">
                    <${SetSeg} value=${fusionPreset} options=${['trio']} onChange=${setFusionPreset} />
                  <//>
                  <${SetRow} label="동시 패널 수" hint="max_concurrent_panels · Async_agent.all 상한">
                    <${SetStepper} v=${fusionPanels} set=${setFusionPanels} min=${1} max=${8} />
                  <//>
                  <${SetRow} label="패널·심판 웹 도구" hint="web_search / web_fetch 주입 여부">
                    <${SetToggle} on=${fusionWeb} onChange=${setFusionWeb} />
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
                `}
              `}
            `}

            ${sec === 'policy' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                keeper 의 <span class="mono">tool_access</span> 는 named 그룹(<span class="mono">tool_policy.toml</span>)의 도구를 참조합니다. 이 섹션은 runtime 정책을 저장하지 않고 browser-session grant preview만 조정합니다.
              </div>
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                현재는 live tool-policy writer가 없어 prototype group catalog 스냅샷으로 표시합니다. 런타임 도구 정책이 SSOT로 연동되면 값이 교체됩니다.
              </div>
              <div class="set-local-summary" data-testid="policy-local-summary">
                <span>local grant preview</span>
                <span class="mono">${grantedGroupCount}/${TOOL_GROUPS.length} enabled</span>
                <${PreviewBadge} />
              </div>
              <div class="set-sub-h">도구 그룹 부여</div>
              ${TOOL_GROUPS.map(g => html`
                <div key=${g.id} class="set-tg-row" data-testid="set-tg-row">
                  <div class="set-tg-l">
                    <div class="set-tg-head">
                      <span class="set-tg-id mono">${g.id}</span>
                      <span class=${`set-tg-kind ${g.kind}`}>${g.kind}</span>
                      ${g.guard ? html`<span class="set-tg-kind guard">3-layer guard</span>` : null}
                      ${g.optin ? html`<span class="set-tg-kind optin">opt-in</span>` : null}
                    </div>
                    <div class="set-tg-tools">${g.tools.map(t => html`<span key=${t} class="set-tg-chip mono">${t}</span>`)}</div>
                  </div>
                  <div class="set-tg-control">
                    <${PreviewBadge} />
                    <${SetToggle}
                      on=${grant[g.id] ?? false}
                      onChange=${(v: boolean) => setGrant(p => ({ ...p, [g.id]: v }))}
                    />
                  </div>
                </div>
              `)}

              <div class="set-sub-h">tool_execute 가드 — 3계층 결정적</div>
              <div class="set-hint" style=${{ marginBottom: '8px' }}>
                셸 타입된 argv 명령은 세 계층을 순차 통과해야 실행됩니다. redirection/tee 또는 직접 file write 우회는 여기서 막힙니다.
              </div>
              <div class="set-guard" data-testid="set-guard">
                ${EXEC_GUARD.map((step, i) => html`
                  ${i > 0 ? html`<span key=${`a${i}`} class="set-guard-arrow">→</span>` : null}
                  <span key=${step} class="set-guard-step mono">${step}</span>
                `)}
              </div>

              <div class="set-sub-h">마지막 턴 안전 도구 — last_turn_safe</div>
              <div class="set-hint" style=${{ marginBottom: '8px' }}>
                keeper 의 마지막 턴에서는 허용 도구가 이 집합과 교집합됩니다 (${LAST_TURN_SAFE.length}개).
              </div>
              <div class="set-tg-tools">${LAST_TURN_SAFE.map(t => html`<span key=${t} class="set-tg-chip mono safe">${t}</span>`)}</div>
            `}

            ${sec === 'lifecycle' && html`
              <${SetRow} label="Idle auto-drain" hint="Minutes until graceful shutdown">
                <${SetSlider} value=${idleDrain} min=${0} max=${120} step=${5} suffix=${idleDrain ? '분' : '안 함'} onChange=${setIdleDrain} />
              <//>
              <${SetRow} label="Crash auto-restart" hint="Crashed → Restarting attempts">
                <${SetToggle} on=${autoRestart} onChange=${setAutoRestart} />
              <//>
              ${autoRestart && html`
                <${SetRow} label="Max restart attempts" hint="Transition to Dead when exceeded">
                  <${SetStepper} v=${restartMax} set=${setRestartMax} min=${1} max=${10} />
                <//>
              `}
              <${SetRow} label="Overflowed action" hint="When context window overflows">
                <${SetSeg} value=${onOverflow} options=${['자동 compact', '자동 종료', 'operator 대기']} onChange=${setOnOverflow} />
              <//>
            `}

            ${sec === 'sandbox' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Keeper별 <span class="mono">sandbox_profile</span>, <span class="mono">network_mode</span>, <span class="mono">allowed_paths</span>를 live keeper config에 저장합니다. 선택한 keeper의 source path와 effective_paths를 함께 표시합니다.
              </div>
              ${keeperList.length === 0
                ? sandboxKeeperListStatus === 'loading'
                  ? html`<div class="set-hint" data-testid="settings-sandbox-keepers-loading">keeper 목록을 불러오는 중...</div>`
                  : sandboxKeeperListStatus === 'error'
                    ? html`<div class="set-hint" data-testid="settings-sandbox-keepers-error">${sandboxKeeperListError ?? 'keeper 목록을 불러오지 못했습니다.'}</div>`
                    : html`<div class="set-hint" data-testid="settings-sandbox-empty">표시할 keeper가 없습니다.</div>`
                : html`
                  <${SetRow} label="Keeper" hint="config/keepers/<name>.toml + live override">
                    <select
                      class="set-select mono"
                      data-testid="settings-sandbox-keeper-select"
                      value=${sandboxKeeperName}
                      onInput=${(event: Event) => setSandboxKeeperName((event.currentTarget as HTMLSelectElement).value)}
                      onChange=${(event: Event) => setSandboxKeeperName((event.currentTarget as HTMLSelectElement).value)}
                    >
                      ${keeperList.map(keeper => html`<option key=${keeper.name} value=${keeper.name}>${keeper.name}</option>`)}
                    </select>
                  <//>
                  ${sandboxStatus === 'loading'
                    ? html`<div class="set-hint" data-testid="settings-sandbox-loading">keeper sandbox 설정을 불러오는 중...</div>`
                    : sandboxStatus === 'error'
                      ? html`<div class="set-hint" data-testid="settings-sandbox-error">${sandboxError ?? 'keeper sandbox 설정을 불러오지 못했습니다.'}</div>`
                      : sandboxConfig && sandboxDraft
                        ? html`
                          <${SetRow} label="sandbox_profile" hint="local 또는 docker">
                            <select
                              class="set-select mono"
                              data-testid="settings-sandbox-profile"
                              value=${sandboxDraft.sandbox_profile}
                              disabled=${sandboxStatus === 'saving'}
                              onInput=${(event: Event) => updateSandboxDraft('sandbox_profile', (event.currentTarget as HTMLSelectElement).value)}
                              onChange=${(event: Event) => updateSandboxDraft('sandbox_profile', (event.currentTarget as HTMLSelectElement).value)}
                            >
                              <option value="local">local</option>
                              <option value="docker">docker</option>
                            </select>
                          <//>
                          <${SetRow} label="network_mode" hint="docker일 때 none 선택 가능">
                            <select
                              class="set-select mono"
                              data-testid="settings-sandbox-network"
                              value=${sandboxDraft.network_mode}
                              disabled=${sandboxStatus === 'saving'}
                              onInput=${(event: Event) => updateSandboxDraft('network_mode', (event.currentTarget as HTMLSelectElement).value)}
                              onChange=${(event: Event) => updateSandboxDraft('network_mode', (event.currentTarget as HTMLSelectElement).value)}
                            >
                              <option value="inherit">inherit</option>
                              ${sandboxDraft.sandbox_profile === 'docker' ? html`<option value="none">none</option>` : null}
                            </select>
                          <//>
                          <${SetRow} label="allowed_paths" hint="한 줄에 하나, 비우면 computed default">
                            <textarea
                              class="set-input mono"
                              data-testid="settings-sandbox-allowed-paths"
                              rows=${4}
                              disabled=${sandboxStatus === 'saving'}
                              value=${sandboxDraft.allowed_paths_text}
                              onInput=${(event: Event) => updateSandboxDraft('allowed_paths_text', (event.currentTarget as HTMLTextAreaElement).value)}
                            ></textarea>
                          <//>
                          <div class="set-mcp-detail mono" data-testid="settings-sandbox-effective-paths">
                            effective_paths ${(sandboxConfig.effective_allowed_paths ?? []).join(', ') || '(computed default)'}
                          </div>
                          <div class="set-actions">
                            <button
                              type="button"
                              class="set-verify"
                              data-testid="settings-sandbox-save"
                              disabled=${!sandboxDirty || sandboxStatus === 'saving'}
                              onClick=${() => { void saveSandboxConfig() }}
                            >
                              ${sandboxStatus === 'saving' ? 'Saving' : 'Save'}
                            </button>
                            <span class="set-hint" data-testid="settings-sandbox-source">
                              ${sandboxConfig.sources.live_meta_path || sandboxConfig.sources.default_manifest_path || sandboxConfig.name}
                            </span>
                          </div>
                        `
                        : null}
                `}
            `}

            ${sec === 'ide' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Shared IDE behaviour for every keeper: editor, collaboration, code insight and version-control defaults.
              </div>
              <div class="set-sub-h">Editor</div>
              <${SetRow} label="Default view" hint="View when opening a file">
                <${SetSeg} value=${ideView} options=${['source', 'unified', 'split-diff']} onChange=${setIdeView} />
              <//>
              <${SetRow} label="Diff style" hint="Change comparison mode">
                <${SetSeg} value=${diffStyle} options=${['inline', 'side-by-side']} onChange=${setDiffStyle} />
              <//>
              <${SetRow} label="Tab width" hint="Indent columns">
                <${SetStepper} v=${tabWidth} set=${setTabWidth} min=${2} max=${8} />
              <//>
              <${SetRow} label="Format on save" hint="format-on-save">
                <${SetToggle} on=${formatOnSave} onChange=${setFormatOnSave} />
              <//>
              <${SetRow} label="Wrap long lines" hint="word wrap">
                <${SetToggle} on=${wrapLines} onChange=${setWrapLines} />
              <//>

              <div class="set-sub-h">Collaboration (presence)</div>
              <${SetRow} label="Other keeper cursors" hint="Live cursor·selection·focus_mode">
                <${SetToggle} on=${liveCursors} onChange=${setLiveCursors} />
              <//>
              <${SetRow} label="Ownership tint" hint="Keeper color per file/region">
                <${SetToggle} on=${ideOwnership} onChange=${setIdeOwnership} />
              <//>
              <${SetRow} label="Conversation rail" hint="Context panel beside editor">
                <${SetToggle} on=${convRail} onChange=${setConvRail} />
              <//>
              <${SetRow} label="Context lens" hint="Turn·tool event overlay">
                <${SetToggle} on=${contextLens} onChange=${setContextLens} />
              <//>

              <div class="set-sub-h">Code insight</div>
              <${SetRow} label="Blame gutter" hint="Last-change keeper·turn per line">
                <${SetToggle} on=${blameGutter} onChange=${setBlameGutter} />
              <//>
              <${SetRow} label="Inline annotations" hint="goal·task·PR-linked annotations">
                <${SetToggle} on=${ideAnnos} onChange=${setIdeAnnos} />
              <//>
              ${ideAnnos && html`
                <${SetRow} label="Auto-link annotations" hint="Link new annotations to active goal/task/PR">
                  <${SetToggle} on=${annoAutoLink} onChange=${setAnnoAutoLink} />
                <//>
              `}

              <div class="set-sub-h">Execution · Version control</div>
              <${SetRow} label="Embedded terminal" hint="Shell inside IDE — sandbox policy applies">
                <${SetToggle} on=${embedTerminal} onChange=${setEmbedTerminal} />
              <//>
              <${SetRow} label="Search index" hint="Maintain symbol·full-text search index">
                <${SetToggle} on=${searchIndex} onChange=${setSearchIndex} />
              <//>
              <${SetRow} label="Linked repo" hint="diff·PR·blame source — e.g. #7732">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    data-testid="settings-ide-repo-input"
                    value=${ideRepo}
                    onInput=${(e: Event) => setIdeRepo((e.target as HTMLInputElement).value)}
                  />
                  <${PreviewBadge} />
                </div>
              <//>
            `}

            ${sec === 'gate' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Live connector runtime, availability, trigger policy and channel→keeper bindings are read from <span class="mono">GET /api/v1/gate/connectors</span>. Add, remove, bind and sidecar lifecycle actions live in
                <button
                  type="button"
                  class="set-link"
                  data-testid="settings-connectors-link"
                  onClick=${() => navigate('connectors')}
                >
                  Connectors →
                </button>.
              </div>
              <div class="set-local-summary" data-testid="gate-live-summary">
                <span>live connector status</span>
                <span class="mono">
                  ${gateConnectorsStatus === 'ready'
                    ? `${gateConnectorsData?.active_count ?? 0}/${gateConnectorsData?.total ?? liveGateConnectors.length} active`
                    : gateConnectorsStatus}
                </span>
              </div>
              ${gateConnectorsStatus === 'loading'
                ? html`<div class="set-hint" data-testid="settings-gate-loading">connector 상태를 불러오는 중...</div>`
                : gateConnectorsStatus === 'error'
                  ? html`<div class="set-hint" data-testid="settings-gate-error">${gateConnectorsError ?? 'connector 상태를 불러오지 못했습니다.'}</div>`
                  : html`
                    <${SetRow} label="Discord trigger policy" hint="live connector payload">
                      <span class="mono" data-testid="settings-gate-discord-trigger">${gateConnectorsData?.discord_trigger_policy ?? 'unknown'}</span>
                    <//>
                    <${SetRow} label="Gate base URL" hint="connector-advertised URLs">
                      <span class="mono" data-testid="settings-gate-base-live">
                        ${liveGateBaseUrls.length > 0 ? liveGateBaseUrls.join(', ') : '미수집'}
                      </span>
                    <//>
                    <div class="set-sub-h">Configured connectors (${liveGateConnectors.length})</div>
                    ${liveGateConnectors.length === 0
                      ? html`<div class="set-hint" data-testid="settings-gate-empty">설정된 connector가 없습니다.</div>`
                      : html`
                        <div class="settings-gate-connectors" data-testid="settings-gate-connectors">
                          ${liveGateConnectors.map(connector => html`
                            <div key=${connector.connector_id} class="settings-gate-connector" data-testid="settings-gate-connector">
                              <div class="settings-gate-connector-head">
                                <span class="mono">${connector.connector_id}</span>
                                <span class=${`settings-gate-state ${connectorState(connector)}`}>${connectorStateText(connector)}</span>
                              </div>
                              <div class="settings-gate-connector-name">${connector.display_name || connector.channel}</div>
                              <div class="settings-gate-connector-meta mono">
                                bindings ${connector.configured_bindings.length} · reply ${connector.reply_mode || 'manual'} · pid ${connector.pid || '-'}
                              </div>
                              ${connector.error
                                ? html`<div class="settings-gate-connector-error">${connector.error}</div>`
                                : null}
                            </div>
                          `)}
                        </div>
                      `}
                  `}
            `}

            ${sec === 'paths' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Server·store basepaths and keeper worktree root. Local preview values can be format-checked only.
              </div>
              <${SetRow} label="MCP endpoint" hint="/mcp HTTP entrypoint">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    data-testid="settings-mcp-endpoint-input"
                    value=${mcpUrl}
                    onInput=${(e: Event) => setMcpUrl((e.target as HTMLInputElement).value)}
                  />
                  <${PreviewBadge} />
                  <button
                    type="button"
                    class="set-verify"
                    data-testid="settings-path-check-mcp"
                    onClick=${() => runPathCheck('mcp')}
                  >
                    Check
                  </button>
                  <${PathCheckBadge} target="mcp" result=${pathChecks.mcp} />
                </div>
              <//>
              <${SetRow} label="Store (DB)" hint="trace·audit persistence">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    data-testid="settings-store-url-input"
                    value=${storeUrl}
                    onInput=${(e: Event) => setStoreUrl((e.target as HTMLInputElement).value)}
                  />
                  <${PreviewBadge} />
                  <button
                    type="button"
                    class="set-verify"
                    data-testid="settings-path-check-store"
                    onClick=${() => runPathCheck('store')}
                  >
                    Check
                  </button>
                  <${PathCheckBadge} target="store" result=${pathChecks.store} />
                </div>
              <//>
              <${SetRow} label="Default worktree basepath" hint="keeper worktree root — e.g. ~/wt/<keeper>">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    data-testid="settings-worktree-base-input"
                    value=${wtBase}
                    onInput=${(e: Event) => setWtBase((e.target as HTMLInputElement).value)}
                  />
                  <${PreviewBadge} />
                  <button
                    type="button"
                    class="set-verify"
                    data-testid="settings-path-check-worktree"
                    onClick=${() => runPathCheck('worktree')}
                  >
                    Check
                  </button>
                  <${PathCheckBadge} target="worktree" result=${pathChecks.worktree} />
                </div>
              <//>
            `}

            ${sec === 'logs' && html`
              <${SetRow} label="Trace retention" hint="Auto-archive after">
                <${SetSeg} value=${traceKeep} options=${['7일', '30일', '90일']} onChange=${setTraceKeep} />
              <//>
              <${SetRow} label="Log level" hint="Keeper runtime log level">
                <${SetSeg} value=${logLevel} options=${['error', 'warn', 'info', 'debug']} onChange=${setLogLevel} />
              <//>
              <${SetRow} label="Telemetry sampling" hint="Trace collection ratio">
                <${SetSlider} value=${sampling} min=${1} max=${100} suffix="%" onChange=${setSampling} />
              <//>
              <div class="set-sub-h">System log (all keepers · live)</div>
              <${LogViewer} />
            `}

            ${sec === 'notify' && html`
              <div class="set-local-summary" data-testid="notify-local-summary">
                Browser-session preview: ${notifyCh} channel, context ${notifyCtx}%, failures ${notifyFails}, ${notifyPreviewEnabledCount}/${Object.keys(notifyOn).length} events enabled.
              </div>
              <div class="set-notify-section">
              <${SetRow} label="Context threshold alert" hint="Notify when context exceeds this %">
                <div class="set-tg-control">
                  <${PreviewBadge} />
                  <${SetSlider} value=${notifyCtx} min=${70} max=${98} suffix="%" onChange=${setNotifyCtx} />
                </div>
              <//>
              <${SetRow} label="Consecutive failure alert" hint="Notify after this many consecutive failures">
                <div class="set-tg-control">
                  <${PreviewBadge} />
                  <${SetStepper} v=${notifyFails} set=${setNotifyFails} min=${1} max=${10} />
                </div>
              <//>
              <${SetRow} label="Notify channel" hint="Where to send">
                <div class="set-tg-control">
                  <${PreviewBadge} />
                  <${SetSeg} value=${notifyCh} options=${['Slack', 'Discord', '없음']} onChange=${setNotifyCh} />
                </div>
              <//>
              <div class="set-sub-h">Notify events</div>
              ${Object.keys(notifyOn).map(k => html`
                <${SetRow} key=${k} label=${k}>
                  <div class="set-tg-control">
                    <${PreviewBadge} />
                    <${SetToggle} on=${notifyOn[k]} onChange=${(v: boolean) => setNotifyOn(p => ({ ...p, [k]: v }))} />
                  </div>
                <//>
              `)}
              </div>
            `}

            ${sec === 'display' && html`
              <${SetRow} label="Theme" hint="Color palette — Dark / StyleSeed / Paper">
                <${ThemeSwitch} />
              <//>
              <${SetRow} label="Density" hint="List/card spacing">
                <${SetSeg} value=${density} options=${['compact', 'regular']} onChange=${setDensity} />
              <//>
              <${SetRow} label="Language" hint="UI labels">
                <${SetSeg} value=${locale} options=${['KO', 'EN']} onChange=${setLocale} />
              <//>
              <${SetRow} label="Timezone" hint="Timestamp basis">
                <${SetSeg} value=${tz} options=${['Asia/Seoul', 'Asia/Tokyo', 'UTC']} onChange=${setTz} />
              <//>
              <${SetRow} label="24-hour clock" hint="Time format">
                <${SetToggle} on=${clock24} onChange=${setClock24} />
              <//>
            `}
          </div>
        </div>
      </div>
    </main>
  `
}
