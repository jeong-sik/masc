import { resumeSavedModelSetup } from '../lib/model-setup-resume'
// MASC Dashboard — Settings surface
// Operator-facing settings only: runtime management, resolved paths, MCP server
// health/inventory, notification thresholds, prompt/fusion/log/display controls.

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { Effect, Option } from 'effect'
import {
  SETTINGS_ROUTE_SECTION_IDS,
  type SettingsRouteSectionId,
} from '../config/navigation'
import { navigate, route } from '../router'
import { fetchDashboardTools, fetchRuntimeDefaults, fetchRuntimeProviders, fetchRuntimeResolved, fetchRuntimeTomlConfig } from '../api/dashboard.js'
import type {
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeProvidersResponse,
  DashboardToolInventoryItem,
  CommittedRuntimeTomlConfig,
  RuntimeDefaultsResponse,
  RuntimeResolvedResponse,
} from '../api/dashboard.js'
import {
  fetchDashboardConfig,
  type ConfigEntry,
  type DashboardConfig,
  type DashboardConfigError,
} from '../api/dashboard-config'
import {
  fetchLogs,
  type LogEntry,
  type LogsError,
} from '../api/dashboard-logs'
import { dashboardRuntime, type DashboardHttp } from '../api/effect-http'
import {
  patchRuntimeLane,
  patchRuntimeMediaFailover,
  patchRuntimeRouting,
  type RuntimeLaneEdit,
  type RuntimeRoutingLane,
} from '../api/dashboard.js'
import { callMcpTool } from '../api/mcp'
import {
  refreshShell,
  shellAuthSummary,
  shellConfigResolution,
  shellRuntimeResolution,
} from '../store'
import {
  clearStoredToken,
  currentDashboardActor,
  dashboardBearerToken,
  getStoredTokenMeta,
  isRemoteAccess,
} from '../api/core'
import type { DashboardConfigResolutionItem } from '../types'
import { OnboardingSettings } from './onboarding-settings'
import { RuntimeTomlEditor } from './runtime-toml-editor'
import { SettingsRepositoriesSection } from './settings-repositories'
import { FusionSettingsPanel } from './fusion-settings-panel'
import { runtimeConfigCommitReceiptNotice } from '../lib/runtime-config-receipt'
import { declaredRuntimeLaneCandidates, declaredRuntimeLanes } from '../lib/runtime-toml-config'
import { announceRuntimeTomlWritten } from '../lib/runtime-toml-source-generation'
import { PromptRegistryPanel } from './tools/prompt-registry-panel'
import { ThemeSwitch } from './theme-switch'
import { StatusChip } from './common/status-chip'
import { showToast } from './common/toast'
import { Checkbox } from './common/checkbox'
import { ActionButton } from './common/button'
import { logDisplayKind } from './log-classification'
import { tweaksDensity, type Density } from './tweaks-panel'
import {
  NOTIFY_EVENT_KINDS,
  NOTIFY_EVENT_LABELS,
  notificationDeliveryError,
  notificationPermission,
  notifyRules,
  refreshNotificationPermission,
  requestNotificationPermission,
  setNotifyRuleEnabled,
  type NotifyEventKind,
} from '../notifications'
import type { ComponentChildren } from 'preact'
import { errorToString } from '../lib/format-string'
import { createEffectResource } from '../lib/effect-resource'
import { remotePrevious } from '../lib/remote-data'
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

const settingsConfigResource = createEffectResource<
  DashboardHttp,
  DashboardConfigError,
  DashboardConfig
>(dashboardRuntime)
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
const DEFAULT_SETTINGS_SECTION: SectionId = 'account'

const SET_SECTIONS: [SectionId, string, string][] = [
  ['account', 'Account', '계정'],
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

// keeper-v2 design settings.jsx SET_GROUPS의 부분 채택: lifecycle/
// sandbox/gate 섹션은 백엔드 계약 부재로 미구현이라 그룹에서 빠져 있고,
// 디자인이 nav에서 뺀 mcp/display는 live-backed 동작 섹션이라 유지한다
// (docs/design/keeper-v2-design-delta-audit-2026-07-03.md).
const SET_GROUPS: [string, SectionId[]][] = [
  ['계정', ['account']],
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
    id: 'account-auth-summary',
    section: 'account',
    label: 'Dashboard auth session',
    kind: 'live-read',
    source: 'dashboard shell auth projection + browser token store',
    action: 'clear local token and refresh shell auth truth',
  },
  {
    id: 'runtime-default-runtime',
    section: 'runtime',
    label: 'Default runtime',
    kind: 'live-write',
    source: 'GET /api/v1/dashboard/runtime-defaults + /api/v1/runtime/resolved + runtime provider catalog',
    action: 'PATCH /api/v1/runtime/routing lane=default',
  },
  {
    id: 'runtime-catalog-summary',
    section: 'runtime',
    label: 'Runtime catalog cards',
    kind: 'live-read',
    source: 'GET /api/v1/providers',
    action: 'read-only projection',
  },
  {
    id: 'runtime-routing-lanes',
    section: 'routing',
    label: 'Model routing lanes',
    kind: 'live-write',
    source: 'GET /api/v1/dashboard/runtime-defaults',
    action: 'PATCH /api/v1/runtime/routing for default',
  },
  {
    id: 'runtime-candidate-lanes',
    section: 'routing',
    label: 'Runtime candidate lanes',
    kind: 'live-write',
    source: 'GET /api/v1/runtime/resolved lanes (declared)',
    action: 'POST /api/v1/runtime/config/routing action=set|create|rename|remove',
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
    label: 'Browser notification delivery',
    kind: 'browser-local',
    source: 'Notification permission + dashboard:notify:rules-v1 localStorage',
    action: 'browser-local writer; delivers on typed WS events the operator opts into',
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

export type McpToolGroup = {
  readonly category: string
  readonly names: readonly string[]
}

// Group the exposed public-MCP inventory by the registry's own category so the
// list renders the design's tool-group rows (settings.jsx:410-422, .set-tg-*)
// from live data. The group id is the registry category; the kind tag is
// 'masc' because every tool on the public_mcp surface is a server-side tool —
// the design's 'local'/guard/opt-in kinds belong to tool_policy.toml groups,
// which the runtime does not read (no live signal, not rendered).
export function mcpExposedToolGroups(items: readonly DashboardToolInventoryItem[]): McpToolGroup[] {
  const byCategory = new Map<string, string[]>()
  for (const item of items) {
    if (!item.surfaces.includes(MCP_PUBLIC_SURFACE)) continue
    const category = item.category.trim() || 'general'
    const names = byCategory.get(category) ?? []
    names.push(item.name)
    byCategory.set(category, names)
  }
  return [...byCategory.entries()]
    .map(([category, names]) => ({ category, names: names.sort((a, b) => a.localeCompare(b)) }))
    .sort((a, b) => a.category.localeCompare(b.category))
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
  const identity = entry.keeperName
  // The producer's typed category alone, the way log-classification.ts states
  // it. The /masc_/ test that used to sit here read the message body, so
  // "[masc_log] WARN: ...", "[masc_agent_core_error] ..." and any line naming a
  // .masc_atomic_stage_ path were shown as tool rows (#24036 / #25853).
  const isTool = logDisplayKind(entry) === 'tool'
  return [logRowClock(entry.timestamp), level, identity, entry.message, logRowStatus(entry.level), isTool]
}

const settingsLogsResource = createEffectResource<
  DashboardHttp,
  LogsError,
  readonly SysLogRow[]
>(dashboardRuntime)

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
    <details class="set-control-ledger" data-testid="settings-control-ledger">
      <summary class="set-control-ledger-h">
        <span>이 화면을 뒷받침하는 것 ${items.length}건 — 읽기 전용 안내</span>
      </summary>
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
    </details>
  `
}

function AccountSettingsSection() {
  const [clearing, setClearing] = useState(false)
  const summary = shellAuthSummary.value
  const actor = summary?.effective_agent ?? summary?.token_agent ?? currentDashboardActor()
  const role = summary?.effective_role ?? 'unknown'
  const tokenPresent = dashboardBearerToken() !== null
  const tokenMeta = getStoredTokenMeta()
  const tokenState = summary?.token_valid === true
    ? 'verified'
    : summary?.token_present === true || tokenPresent
      ? 'unverified'
      : 'not configured'

  async function clearAccountToken() {
    if (clearing || !tokenPresent) return
    setClearing(true)
    try {
      clearStoredToken()
      const refreshed = await refreshShell({ force: true })
      if (!refreshed) {
        showToast('Token은 지웠지만 auth 상태를 다시 확인하지 못했습니다.', 'error')
        return
      }
      showToast('Dashboard token을 지우고 auth 상태를 다시 확인했습니다.', 'success')
    } catch (error) {
      showToast(`Auth 갱신 실패: ${errorToString(error)}`, 'error')
    } finally {
      setClearing(false)
    }
  }

  return html`
    <div class="set-account" data-testid="settings-account-live">
      <div class="set-hint">
        현재 dashboard shell이 검증한 actor·role과 이 브라우저에 저장된 Bearer token 상태입니다.
        토큰 생성·재발급 writer는 이 화면에 없으므로 지원한다고 가장하지 않습니다.
      </div>
      <${SetRow} label="운영자" hint="Effective dashboard actor">
        <div class="set-truth-value">
          <span class="mono">@${actor}</span>
          <span class="set-truth-source">${isRemoteAccess() ? 'remote access' : 'local access'}</span>
        </div>
      <//>
      <${SetRow} label="역할" hint="Server-resolved effective role">
        <span class="set-role-chip mono">${role}</span>
      <//>
      <${SetRow} label="API token" hint="Browser token store · MCP/dashboard authentication">
        <div class="set-account-token" data-testid="settings-account-token-presence">
          <span class=${`set-account-token-presence ${tokenPresent ? 'stored' : 'absent'}`}>
            ${tokenPresent ? '브라우저에 저장됨' : '저장된 token 없음'}
          </span>
          ${tokenMeta
            ? html`<span class="set-truth-source mono">source:${tokenMeta.source}${tokenMeta.source === 'dev' ? ` · role:${tokenMeta.role}` : ''}</span>`
            : null}
        </div>
      <//>
      <${SetRow} label="검증 상태" hint=${summary?.auth_error_code ?? 'shell auth projection'}>
        <span class=${`set-account-state ${tokenState}`}>${tokenState}</span>
      <//>
      ${summary?.auth_error_detail
        ? html`<div class="set-account-error" role="status">${summary.auth_error_detail}</div>`
        : null}
      <button
        type="button"
        class="set-account-clear"
        disabled=${!tokenPresent || clearing}
        onClick=${() => { void clearAccountToken() }}
      >${clearing ? '정리 중…' : '저장된 token 지우기'}</button>
    </div>
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

function runtimeSelectOptionsFromResolved(
  entries: RuntimeResolvedResponse['runtimes'],
): RuntimeSelectOption[] {
  return uniqueRuntimeSelectOptions(entries.map(entry => ({
    id: entry.id,
    label: `${entry.id} · ${entry.model}`,
  })))
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
    <${SetRow} label="Media failover" hint="[runtime].media_failover vision read fleet">
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
          <${StatusChip} tone="warn" uppercase=${false}>이미지 읽기<//>
          <span>턴을 넘겨받지 않아요. lane 이 이미지를 못 받을 때 이미지를 글로 읽어 주는 런타임입니다.</span>
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

// Names the routing endpoint reads as another route, never as a
// [runtime.lanes] table (route_name_space in
// server_dashboard_runtime_request.ml). A lane declared under one of them
// cannot be addressed by a lane action, and a new lane must not take one.
function runtimeLaneNameReserved(name: string): boolean {
  return name === 'default' || name === 'media_failover' || name.startsWith('exact/')
}

// The table header the runtime writer emits: a bare key when TOML allows it,
// a quoted basic string otherwise (runtime.ml lane_table_path).
function runtimeLaneTableLabel(laneId: string): string {
  const key = /^[A-Za-z0-9_-]+$/.test(laneId) ? laneId : JSON.stringify(laneId)
  return `[runtime.lanes.${key}]`
}

// One candidate change, applied to the order runtime.toml declares when the
// write is sent — never to the resolved order, which omits candidates the
// catalog did not admit.
type RuntimeLaneCandidateEdit =
  | { kind: 'move'; runtimeId: string; delta: -1 | 1 }
  | { kind: 'remove'; runtimeId: string }
  | { kind: 'add'; runtimeId: string }

type RuntimeLaneWrite =
  // [rendered] is the declared order the card showed when the operator
  // clicked; a relative edit means something only against that order.
  | { kind: 'candidates'; edit: RuntimeLaneCandidateEdit; rendered: readonly string[] }
  | { kind: 'lane'; edit: RuntimeLaneEdit }

// The declared order after [edit], or the reason the edit no longer applies
// (the file changed since the card rendered).
function applyRuntimeLaneCandidateEdit(
  declared: readonly string[],
  edit: RuntimeLaneCandidateEdit,
): string[] | string {
  const index = declared.indexOf(edit.runtimeId)
  if (edit.kind === 'add') {
    return index >= 0 ? `${edit.runtimeId} 는 이미 이 레인의 후보입니다` : [...declared, edit.runtimeId]
  }
  if (index < 0) return `${edit.runtimeId} 는 runtime.toml 의 이 레인 후보에 없습니다`
  if (edit.kind === 'remove') {
    const next = declared.filter(id => id !== edit.runtimeId)
    return next.length === 0 ? '마지막 후보는 뺄 수 없습니다 — 레인 삭제를 쓰세요' : next
  }
  const target = index + edit.delta
  if (target < 0 || target >= declared.length) return `${edit.runtimeId} 는 더 옮길 수 없습니다`
  const next = [...declared]
  next[index] = declared[target]!
  next[target] = edit.runtimeId
  return next
}

type RuntimeLaneCard = {
  id: string
  resolved: boolean
  // What /api/v1/runtime/resolved walks: declared candidates the catalog admitted.
  resolvedRuntimeIds: readonly string[]
  // What runtime.toml declares, or null when the file was not read or the lane
  // is not written as its own table with a readable candidates array.
  declared: readonly string[] | null
}

type RuntimeTomlSourceState =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; sourceText: string }

function runtimeLaneReadOnlyReason(
  lane: RuntimeLaneCard,
  source: RuntimeTomlSourceState,
): string | null {
  if (runtimeLaneNameReserved(lane.id)) {
    return 'routing API 가 이 이름을 다른 경로로 읽어 레인 편집을 보낼 수 없습니다. runtime.toml 섹션에서 직접 고치세요.'
  }
  if (!lane.resolved) {
    return '현재 런타임 해석 결과에 없는 레인입니다. routing API 로 편집할 수 없어 runtime.toml 섹션에서 고쳐야 합니다.'
  }
  if (lane.declared !== null && lane.declared.some(id => !lane.resolvedRuntimeIds.includes(id))) {
    return '카탈로그에서 빠진 후보가 있습니다. routing API 는 이런 후보를 보존한 저장을 거절하므로 runtime.toml 섹션에서 고쳐야 합니다.'
  }
  if (lane.declared !== null) return null
  if (source.status === 'loading') return 'runtime.toml 을 읽는 중입니다. 선언된 후보를 확인한 뒤 편집할 수 있습니다.'
  if (source.status === 'error') return `runtime.toml 을 읽지 못해 편집하지 않습니다: ${source.message}`
  return `runtime.toml 에 ${runtimeLaneTableLabel(lane.id)} 테이블과 candidates 배열로 적혀 있지 않아(inline·dotted 선언 등) 여기서는 읽기 전용입니다. runtime.toml 섹션에서 직접 고치세요.`
}

function RuntimeLaneEditor({
  lane,
  readOnlyReason,
  options,
  disabled,
  onWrite,
}: {
  lane: RuntimeLaneCard
  readOnlyReason: string | null
  options: readonly RuntimeSelectOption[]
  disabled: boolean
  onWrite: (lane: string, write: RuntimeLaneWrite) => Promise<boolean>
}) {
  const [renameDraft, setRenameDraft] = useState<string | null>(null)
  const editable = readOnlyReason === null && lane.declared !== null
  const chain = lane.declared ?? lane.resolvedRuntimeIds
  const resolved = new Set(lane.resolvedRuntimeIds)
  const selected = new Set(chain)
  const addOptions = options.filter(option => !selected.has(option.id))
  const editCandidates = (edit: RuntimeLaneCandidateEdit) => {
    if (lane.declared === null) return
    void onWrite(lane.id, { kind: 'candidates', edit, rendered: lane.declared })
  }
  const renameTarget = renameDraft?.trim() ?? ''
  const renameInvalid =
    renameTarget === '' || renameTarget === lane.id || runtimeLaneNameReserved(renameTarget)
  const submitRename = async () => {
    if (disabled || renameInvalid) return
    if (await onWrite(lane.id, { kind: 'lane', edit: { action: 'rename', to: renameTarget } })) setRenameDraft(null)
  }
  const removeLane = () => {
    if (window.confirm(`${runtimeLaneTableLabel(lane.id)} 레인을 runtime.toml 에서 지울까요? 이 레인을 가리키는 배정이 남아 있으면 서버가 거절합니다.`)) {
      void onWrite(lane.id, { kind: 'lane', edit: { action: 'remove' } })
    }
  }

  return html`
    <div class="rt-fo" data-testid=${`runtime-lane-${lane.id}`}>
      <div class="rt-fo-h">
        <span class="rt-fo-lane">${lane.id}</span>
        <span class="rt-fo-lane-id mono">${runtimeLaneTableLabel(lane.id)}</span>
      </div>
      ${readOnlyReason === null
        ? null
        : html`<div class="rt-fo-note" data-testid=${`runtime-lane-${lane.id}-read-only`}>${readOnlyReason}</div>`}
      <div class="rt-fo-chain">
        ${chain.map((runtimeId, index) => {
          const unavailable = lane.declared !== null && !resolved.has(runtimeId)
          return html`
          <div key=${runtimeId} class=${`rt-fo-cand ${index === 0 ? 'head' : ''}`} data-unavailable=${unavailable ? 'true' : undefined}>
            <span class="rt-fo-rank mono">${index === 0 ? '1차' : `${index + 1}`}</span>
            <span class="rt-fo-id mono">${runtimeId}</span>
            ${unavailable
              ? html`<span class="rt-fo-cap" data-testid=${`runtime-lane-${lane.id}-unavailable-${runtimeId}`} title="runtime.toml 에만 남은 후보입니다. 현재 routing API 에서는 이 레인을 저장할 수 없습니다">catalog 없음</span>`
              : null}
            ${editable
              ? html`
                <span class="rt-fo-cand-acts">
                  <button
                    type="button"
                    class="rt-fo-mv"
                    disabled=${disabled || index === 0}
                    aria-label=${`${lane.id} 레인 ${runtimeId} 위로 이동`}
                    data-testid=${`runtime-lane-${lane.id}-up-${runtimeId}`}
                    onClick=${() => editCandidates({ kind: 'move', runtimeId, delta: -1 })}
                  >↑</button>
                  <button
                    type="button"
                    class="rt-fo-mv"
                    disabled=${disabled || index === chain.length - 1}
                    aria-label=${`${lane.id} 레인 ${runtimeId} 아래로 이동`}
                    data-testid=${`runtime-lane-${lane.id}-down-${runtimeId}`}
                    onClick=${() => editCandidates({ kind: 'move', runtimeId, delta: 1 })}
                  >↓</button>
                  <button
                    type="button"
                    class="rt-fo-mv del"
                    disabled=${disabled || chain.length <= 1}
                    aria-label=${`${lane.id} 레인에서 ${runtimeId} 제거`}
                    title=${chain.length <= 1 ? '마지막 후보는 뺄 수 없습니다 — 레인 삭제를 쓰세요' : undefined}
                    data-testid=${`runtime-lane-${lane.id}-remove-${runtimeId}`}
                    onClick=${() => editCandidates({ kind: 'remove', runtimeId })}
                  >×</button>
                </span>
              `
              : null}
          </div>
        `
        })}
      </div>
      ${editable
        ? html`
          <div class="set-runtime-media-actions" style=${{ marginTop: '8px' }}>
            <select
              class="set-input mono rt-fo-add"
              data-testid=${`runtime-lane-${lane.id}-add`}
              aria-label=${`${lane.id} 레인 후보 추가`}
              value=""
              disabled=${disabled || addOptions.length === 0}
              onInput=${(event: Event) => {
                const select = event.currentTarget as HTMLSelectElement
                const next = select.value.trim()
                select.value = ''
                if (next !== '') editCandidates({ kind: 'add', runtimeId: next })
              }}
            >
              <option value="">후보 추가</option>
              ${addOptions.map(option => html`
                <option key=${option.id} value=${option.id}>${option.label}</option>
              `)}
            </select>
            ${renameDraft === null
              ? html`
                <button
                  type="button"
                  class="set-route-clear"
                  disabled=${disabled}
                  aria-label=${`${lane.id} 레인 이름 변경`}
                  data-testid=${`runtime-lane-${lane.id}-rename`}
                  onClick=${() => setRenameDraft(lane.id)}
                >이름 변경</button>
              `
              : html`
                <input
                  class="set-input mono"
                  value=${renameDraft}
                  disabled=${disabled}
                  aria-label=${`${lane.id} 레인 새 이름`}
                  data-testid=${`runtime-lane-${lane.id}-rename-input`}
                  onInput=${(event: Event) => setRenameDraft((event.currentTarget as HTMLInputElement).value)}
                  onKeyDown=${(event: KeyboardEvent) => {
                    if (event.key === 'Enter') {
                      event.preventDefault()
                      void submitRename()
                    } else if (event.key === 'Escape') {
                      event.preventDefault()
                      setRenameDraft(null)
                    }
                  }}
                />
                <button
                  type="button"
                  class="set-route-clear"
                  disabled=${disabled || renameInvalid}
                  aria-label=${`${lane.id} 레인 새 이름 저장`}
                  data-testid=${`runtime-lane-${lane.id}-rename-submit`}
                  onClick=${() => void submitRename()}
                >이름 저장</button>
                <button
                  type="button"
                  class="set-route-clear"
                  disabled=${disabled}
                  aria-label=${`${lane.id} 레인 이름 변경 취소`}
                  onClick=${() => setRenameDraft(null)}
                >취소</button>
              `}
            <button
              type="button"
              class="set-route-clear"
              disabled=${disabled}
              aria-label=${`${lane.id} 레인 삭제`}
              data-testid=${`runtime-lane-${lane.id}-delete`}
              onClick=${removeLane}
            >레인 삭제</button>
          </div>
        `
        : null}
    </div>
  `
}

function runtimeLaneCreateNameError(name: string, existingLaneIds: readonly string[]): string | null {
  if (name === '') return null
  if (runtimeLaneNameReserved(name)) return `"${name}" 는 다른 routing 경로 이름이라 레인 이름으로 쓸 수 없습니다`
  if (existingLaneIds.includes(name)) return `이미 선언된 레인입니다: ${name}`
  return null
}

// A new lane starts with one candidate; the rest are added on its lane card.
// `create` refuses a name the file already declares, so a typo cannot land on
// an existing lane's candidates.
function RuntimeLaneCreateForm({
  existingLaneIds,
  options,
  disabled,
  onWrite,
}: {
  existingLaneIds: readonly string[]
  options: readonly RuntimeSelectOption[]
  disabled: boolean
  onWrite: (lane: string, write: RuntimeLaneWrite) => Promise<boolean>
}) {
  const [name, setName] = useState('')
  const [firstRuntimeId, setFirstRuntimeId] = useState('')
  const trimmed = name.trim()
  const nameError = runtimeLaneCreateNameError(trimmed, existingLaneIds)
  // A lane named like a runtime id shadows it: the resolver reads the lane
  // first (runtime.mli create_runtime_lane), so it is allowed but noted.
  const shadowsRuntime = nameError === null && options.some(option => option.id === trimmed)
  const canSubmit = !disabled && trimmed !== '' && nameError === null && firstRuntimeId !== ''
  const submit = async () => {
    if (!canSubmit) return
    if (await onWrite(trimmed, { kind: 'lane', edit: { action: 'create', runtimeIds: [firstRuntimeId] } })) {
      setName('')
      setFirstRuntimeId('')
    }
  }

  return html`
    <div class="rt-fo" data-testid="runtime-lane-create">
      <div class="rt-fo-h">
        <span class="rt-fo-lane">새 레인</span>
        <span class="rt-fo-lane-id mono">${trimmed === '' ? '[runtime.lanes.<id>]' : runtimeLaneTableLabel(trimmed)}</span>
      </div>
      <div class="set-runtime-media-actions" style=${{ marginTop: '8px' }}>
        <input
          class="set-input mono"
          placeholder="레인 이름"
          value=${name}
          disabled=${disabled}
          aria-label="새 레인 이름"
          data-testid="runtime-lane-create-name"
          onInput=${(event: Event) => setName((event.currentTarget as HTMLInputElement).value)}
        />
        <select
          class="set-input mono rt-fo-add"
          value=${firstRuntimeId}
          disabled=${disabled || options.length === 0}
          aria-label="새 레인 1차 후보"
          data-testid="runtime-lane-create-runtime"
          onInput=${(event: Event) => setFirstRuntimeId((event.currentTarget as HTMLSelectElement).value.trim())}
        >
          <option value="">1차 후보 선택</option>
          ${options.map(option => html`
            <option key=${option.id} value=${option.id}>${option.label}</option>
          `)}
        </select>
        <button
          type="button"
          class="set-route-clear"
          disabled=${!canSubmit}
          data-testid="runtime-lane-create-submit"
          onClick=${() => void submit()}
        >레인 추가</button>
      </div>
      ${nameError ? html`<div class="set-err" data-testid="runtime-lane-create-error">${nameError}</div>` : null}
      ${shadowsRuntime
        ? html`<div class="set-hint" data-testid="runtime-lane-create-shadow">
            같은 id 의 런타임이 있습니다. 이 레인을 만들면 그 런타임을 배정한 keeper(그리고 default 가 그 id 이면 미배정 keeper)는 런타임 대신 이 레인의 후보를 순서대로 탑니다.
          </div>`
        : null}
    </div>
  `
}

function configEntry(data: DashboardConfig | undefined, env: string): ConfigEntry | undefined {
  if (data === undefined) return undefined
  for (const entries of Object.values(data.categories)) {
    const found = entries.find(entry => entry.env === env)
    if (found) return found
  }
  return undefined
}

function configEntryDisplayValue(entry: ConfigEntry | undefined): string | undefined {
  return entry?.displayValue
}

function concreteConfigValue(entry: ConfigEntry | undefined): string | undefined {
  const value = configEntryDisplayValue(entry)?.trim()
  if (!value || /^\(.+\)$/.test(value)) return undefined
  return value
}

function formatConfigSource(entry: ConfigEntry | undefined): string {
  if (!entry) return 'missing'
  return entry.sourceDetail
}

function endpointFromWindow(): string {
  if (typeof window === 'undefined') return '/mcp'
  const origin = window.location.origin
  if (!origin || origin === 'null') return '/mcp'
  return `${origin.replace(/\/$/, '')}/mcp`
}

function mcpEndpointFromConfig(config: DashboardConfig | undefined): string {
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

function formatThresholdPercent(value: string | undefined): string {
  const parsed = value === undefined ? NaN : Number.parseFloat(value)
  if (!Number.isFinite(parsed)) return value ?? '미수집'
  return `${Math.round(parsed * 100)}%`
}

function ConfigTruthRow({
  label,
  entry,
  fallback,
}: {
  label: string
  entry: ConfigEntry | undefined
  fallback?: string
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
  entry: ConfigEntry | undefined
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

// notify-permission / notify-rule-toggle — browser-local writer for
// masc issue #54's browser notification path. notificationPermission and
// notifyRules are @preact/signals values owned by ../notifications; reading
// `.value` here subscribes this render the same way `tweaksDensity.value`
// does above for display/density.
function NotifyPermissionRow() {
  const permission = notificationPermission.value
  const deliveryError = notificationDeliveryError.value
  const handleEnable = () => { void requestNotificationPermission() }
  useEffect(() => {
    const refresh = () => { refreshNotificationPermission() }
    const refreshWhenVisible = () => {
      if (document.visibilityState === 'visible') refresh()
    }
    refresh()
    window.addEventListener('focus', refresh)
    document.addEventListener('visibilitychange', refreshWhenVisible)
    return () => {
      window.removeEventListener('focus', refresh)
      document.removeEventListener('visibilitychange', refreshWhenVisible)
    }
  }, [])
  return html`
    <${SetRow} label="Browser notifications" hint="This browser's Notification permission — requested only when you click Enable">
      <div class="set-truth-value" data-testid="notify-permission-state">
        <span class="mono" data-testid="notify-permission-value">${permission}</span>
        ${permission === 'default'
          ? html`<${ActionButton} variant="primary" size="sm" testId="notify-permission-request" onClick=${handleEnable}>Enable notifications<//>`
          : null}
        ${permission === 'denied'
          ? html`<span class="set-truth-source">Blocked — re-enable from this browser's site permissions for this page.</span>`
          : null}
        ${permission === 'unsupported'
          ? html`<span class="set-truth-source">This browser has no Notification API.</span>`
          : null}
        ${permission === 'granted'
          ? html`<span class="set-truth-source">Enabled</span>`
          : null}
        ${deliveryError
          ? html`<span class="set-truth-source text-[var(--color-status-danger)]" data-testid="notify-delivery-error">${deliveryError}</span>`
          : null}
      </div>
    <//>
  `
}

function NotifyEventToggleRow({ kind }: { kind: NotifyEventKind }) {
  const enabled = notifyRules.value[kind] ?? true
  const label = NOTIFY_EVENT_LABELS[kind]
  return html`
    <${SetRow} label=${label} hint=${kind}>
      <label class="set-truth-value v2-mobile-operator-target" data-testid=${`notify-rule-row-${kind}`}>
        <${Checkbox}
          checked=${enabled}
          ariaLabel=${`Notify on ${label}`}
          testId=${`notify-rule-toggle-${kind}`}
          onChange=${(next: boolean) => setNotifyRuleEnabled(kind, next)}
        />
        <span class="set-truth-source">${enabled ? 'notify' : 'muted'}</span>
      </label>
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
  if (section === 'account') return { mode: 'mixed', label: 'live auth + browser token' }
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

  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null

    const tick = () => {
      if (settingsLogsResource.state.value._tag === 'Loading') return
      void settingsLogsResource.load(
        fetchLogs({ limit: SETTINGS_LOG_LIMIT }).pipe(
          Effect.map(resp => [...resp.entries]
            .sort((a, b) => b.seq - a.seq)
            .map(logEntryToSysRow)),
        ),
      )
    }

    settingsLogsResource.reset()
    tick()
    timer = setInterval(tick, SETTINGS_LOG_POLL_MS)

    return () => {
      if (timer) clearInterval(timer)
      settingsLogsResource.cancel()
      settingsLogsResource.reset()
    }
  }, [])

  const resourceState = settingsLogsResource.state.value
  const allRows = Option.getOrElse(
    remotePrevious(resourceState),
    () => [] as readonly SysLogRow[],
  )
  const status = resourceState._tag === 'Failure'
    ? 'error'
    : resourceState._tag === 'Success'
      ? 'ready'
      : 'loading'
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
    : '조건에 맞는 로그 없음'

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
  useEffect(() => {
    settingsConfigResource.reset()
    void settingsConfigResource.load(fetchDashboardConfig())
    return () => {
      settingsConfigResource.cancel()
      settingsConfigResource.reset()
    }
  }, [])

  const dashboardConfigState = settingsConfigResource.state.value
  const dashboardConfig = Option.getOrUndefined(
    remotePrevious(dashboardConfigState),
  )
  const dashboardConfigStatus: 'loading' | 'ready' | 'error' =
    dashboardConfigState._tag === 'Failure'
      ? 'error'
      : dashboardConfigState._tag === 'Success'
        ? 'ready'
        : 'loading'
  const dashboardConfigError = dashboardConfigState._tag === 'Failure'
    ? dashboardConfigState.error.message
    : undefined

  // mcp — exposed tools come from the live capability registry (public_mcp surface)
  const [mcpToolGroups, setMcpToolGroups] = useState<McpToolGroup[]>([])
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
        setMcpToolGroups(mcpExposedToolGroups(resp.tool_inventory?.tools ?? []))
        setMcpToolsStatus('ready')
      } catch (err) {
        if (!active) return
        // No fabricated empty inventory on failure.
        setMcpToolGroups([])
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
  // single resolved-runtime document (bugs #14/#15/#36) — effective
  // max-context + source, and the full keeper fleet joined against
  // [runtime.assignments] with the [runtime].default rider made explicit.
  const [runtimeResolved, setRuntimeResolved] = useState<RuntimeResolvedResponse | null>(null)
  const [runtimeResolvedStatus, setRuntimeResolvedStatus] = useState<'loading' | 'ready' | 'error'>('loading')
  const [runtimeProviders, setRuntimeProviders] = useState<DashboardRuntimeProvidersResponse | null>(null)
  const [runtimeCatalogStatus, setRuntimeCatalogStatus] = useState<'loading' | 'ready' | 'error'>('loading')
  const [runtimeRoutingStatus, setRuntimeRoutingStatus] = useState<RuntimeRoutingSaveState>('idle')
  const [runtimeRoutingMessage, setRuntimeRoutingMessage] = useState('')
  // Lane edits write the same runtime.toml, so they share the routing saving
  // gate, but report next to the lane cards they changed.
  const [runtimeLaneStatus, setRuntimeLaneStatus] = useState<RuntimeRoutingSaveState>('idle')
  const [runtimeLaneMessage, setRuntimeLaneMessage] = useState('')
  // The runtime.toml text the lane cards read declared candidates from. The
  // resolved projection drops candidates the catalog did not admit, so it
  // cannot be the base of a whole-order `set`.
  const [runtimeTomlSource, setRuntimeTomlSource] = useState<RuntimeTomlSourceState>({ status: 'loading' })
  // Set synchronously so a second click before the saving state renders
  // cannot send a second write.
  const runtimeWriteInFlight = useRef(false)

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
    setRuntimeResolvedStatus('loading')
    void (async () => {
      try {
        const resp = await fetchRuntimeResolved()
        if (!active) return
        setRuntimeResolved(resp)
        setRuntimeResolvedStatus('ready')
      } catch {
        if (!active) return
        setRuntimeResolved(null)
        setRuntimeResolvedStatus('error')
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

  async function reloadRuntimeTomlSourceSnapshot(): Promise<{ sourceText: string; sourceRevision: string } | null> {
    try {
      const config = await fetchRuntimeTomlConfig()
      setRuntimeTomlSource({ status: 'ready', sourceText: config.source_text })
      return { sourceText: config.source_text, sourceRevision: config.source_revision }
    } catch (err) {
      setRuntimeTomlSource({ status: 'error', message: errorToString(err) })
      return null
    }
  }

  useEffect(() => {
    if (sec !== 'routing') return
    void reloadRuntimeTomlSourceSnapshot()
  }, [sec])

  async function reloadRuntimeDefaultsSnapshot(): Promise<void> {
    try {
      const resp = await fetchRuntimeDefaults()
      setRuntimeDefaults(resp)
    } catch (err) {
      setRuntimeDefaults(null)
      throw err
    }
  }

  async function reloadRuntimeResolvedSnapshot(): Promise<void> {
    setRuntimeResolvedStatus('loading')
    try {
      const resp = await fetchRuntimeResolved()
      setRuntimeResolved(resp)
      setRuntimeResolvedStatus('ready')
    } catch (err) {
      setRuntimeResolved(null)
      setRuntimeResolvedStatus('error')
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
      reloadRuntimeResolvedSnapshot(),
      reloadRuntimeProvidersSnapshot(),
    ])
  }

  // Every Settings routing write lands here after the server committed it.
  // The receipt carries the file as written, which the lane cards read, and a
  // mounted RuntimeTomlEditor is told to re-read it.
  async function finishRuntimeRoutingWrite(receipt: CommittedRuntimeTomlConfig): Promise<void> {
    setRuntimeTomlSource({ status: 'ready', sourceText: receipt.source_text })
    announceRuntimeTomlWritten()
    await resumeSavedModelSetup()
    await refreshRuntimeSettingsSnapshot()
    await refreshRuntimeConfigConsumers()
  }

  async function handleRuntimeTomlSaved(): Promise<void> {
    try {
      await Promise.all([refreshRuntimeSettingsSnapshot(), reloadRuntimeTomlSourceSnapshot()])
    } catch (err) {
      console.warn('[Settings] runtime settings refresh failed after editor save:', err)
    }
  }

  async function applyRuntimeRoutingPatch(lane: RuntimeRoutingLane, runtimeId: string | null): Promise<void> {
    if (runtimeWriteInFlight.current) return
    runtimeWriteInFlight.current = true
    setRuntimeRoutingStatus('saving')
    setRuntimeRoutingMessage('')
    let receipt: CommittedRuntimeTomlConfig
    try {
      receipt = await patchRuntimeRouting(lane, runtimeId)
    } catch (err) {
      setRuntimeRoutingStatus('error')
      setRuntimeRoutingMessage(errorToString(err))
      runtimeWriteInFlight.current = false
      return
    }
    try {
      await finishRuntimeRoutingWrite(receipt)
      setRuntimeRoutingStatus('saved')
      setRuntimeRoutingMessage(`runtime.toml routing 저장됨 · ${runtimeConfigCommitReceiptNotice(receipt)}`)
    } catch (err) {
      setRuntimeRoutingStatus('error')
      setRuntimeRoutingMessage(`저장됨 · ${runtimeConfigCommitReceiptNotice(receipt)} · 대시보드 런타임 갱신 실패: ${errorToString(err)}`)
    } finally {
      runtimeWriteInFlight.current = false
    }
  }

  async function applyMediaFailoverPatch(runtimeIds: string[]): Promise<void> {
    if (runtimeWriteInFlight.current) return
    runtimeWriteInFlight.current = true
    setRuntimeRoutingStatus('saving')
    setRuntimeRoutingMessage('')
    let receipt: CommittedRuntimeTomlConfig
    try {
      receipt = await patchRuntimeMediaFailover(runtimeIds)
    } catch (err) {
      setRuntimeRoutingStatus('error')
      setRuntimeRoutingMessage(errorToString(err))
      runtimeWriteInFlight.current = false
      return
    }
    try {
      await finishRuntimeRoutingWrite(receipt)
      setRuntimeRoutingStatus('saved')
      setRuntimeRoutingMessage(`runtime.toml media_failover 저장됨 · ${runtimeConfigCommitReceiptNotice(receipt)}`)
    } catch (err) {
      setRuntimeRoutingStatus('error')
      setRuntimeRoutingMessage(`저장됨 · ${runtimeConfigCommitReceiptNotice(receipt)} · 대시보드 런타임 갱신 실패: ${errorToString(err)}`)
    } finally {
      runtimeWriteInFlight.current = false
    }
  }

  // A candidate edit is applied to the order runtime.toml declares, read
  // fresh just before the write: the card's order may be stale, and the
  // resolved order omits candidates the catalog did not admit, which a `set`
  // built from it would delete from the file. When the declared order cannot
  // be read, the edit is refused rather than sent from the resolved order.
  async function runtimeLaneEditOf(lane: string, write: RuntimeLaneWrite): Promise<RuntimeLaneEdit | string> {
    if (write.kind === 'lane') return write.edit
    const source = await reloadRuntimeTomlSourceSnapshot()
    if (source === null) return 'runtime.toml 을 읽지 못해 후보 편집을 보내지 않았습니다'
    const declared = declaredRuntimeLaneCandidates(source.sourceText, lane)
    if (declared === null) {
      return `runtime.toml 에서 ${runtimeLaneTableLabel(lane)} 의 candidates 를 읽지 못해 후보 편집을 보내지 않았습니다`
    }
    // Another writer changed this lane since the card rendered. Applying the
    // clicked move to the new order would save an order the operator never
    // saw, and the fresh source revision would let it pass the server CAS.
    // The reload above already re-rendered the card from the new text.
    if (declared.length !== write.rendered.length || declared.some((id, index) => id !== write.rendered[index])) {
      return `${runtimeLaneTableLabel(lane)} 후보 순서가 다른 곳에서 바뀌어 편집을 보내지 않았습니다. 새로 불러온 순서를 확인하고 다시 시도하세요.`
    }
    const next = applyRuntimeLaneCandidateEdit(declared, write.edit)
    return typeof next === 'string' ? next : {
      action: 'set', runtimeIds: next, expectedSourceRevision: source.sourceRevision,
    }
  }

  async function applyRuntimeLaneWrite(lane: string, write: RuntimeLaneWrite): Promise<boolean> {
    if (runtimeWriteInFlight.current) return false
    runtimeWriteInFlight.current = true
    setRuntimeLaneStatus('saving')
    setRuntimeLaneMessage('')
    try {
      const edit = await runtimeLaneEditOf(lane, write)
      if (typeof edit === 'string') {
        setRuntimeLaneStatus('error')
        setRuntimeLaneMessage(edit)
        return false
      }
      let receipt: CommittedRuntimeTomlConfig
      try {
        receipt = await patchRuntimeLane(lane, edit)
      } catch (err) {
        setRuntimeLaneStatus('error')
        setRuntimeLaneMessage(errorToString(err))
        return false
      }
      const target = edit.action === 'rename' ? `${lane} → ${edit.to}` : lane
      try {
        await finishRuntimeRoutingWrite(receipt)
        setRuntimeLaneStatus('saved')
        setRuntimeLaneMessage(`runtime.toml lane ${edit.action} (${target}) 저장됨 · ${runtimeConfigCommitReceiptNotice(receipt)}`)
      } catch (err) {
        setRuntimeLaneStatus('error')
        setRuntimeLaneMessage(`저장됨 · ${runtimeConfigCommitReceiptNotice(receipt)} · 대시보드 런타임 갱신 실패: ${errorToString(err)}`)
      }
      return true
    } finally {
      runtimeWriteInFlight.current = false
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

  // Resolved runtime identity, model, context, and fleet counts come from one
  // response generation. Runtime defaults remain the write-policy document;
  // provider catalog remains the capability detail document. Neither is a
  // fallback for failed resolved truth.
  const runtimeCatalogEntries = runtimeProviders?.providers ?? []
  const runtimeConfigPath = runtimeResolved?.config_path ?? null
  const defaultRuntimeId = runtimeResolved?.default_runtime?.id ?? null
  const runtimeCount = runtimeResolved?.runtimes.length ?? 0
  const mediaFailover = runtimeDefaults?.model_routing.media_failover ?? []
  // Declared runtime lanes with their ordered candidate chains — the live
  // counterpart of the design's failover section (runtime-editor.jsx:191-229,
  // .rt-fo-*). Each [runtime.lanes.<id>] is edited through the routing writer
  // (set/create/rename/remove); the server resolves and validates every write.
  // Assignment-only routes belong to Keeper assignment truth and must not be
  // mislabeled as [runtime.lanes] declarations on this configuration surface.
  const runtimeLanes = runtimeResolved?.lanes.filter(lane => lane.declared) ?? []
  // Declared lanes from the resolved projection, joined with what the file
  // declares. A lane whose every candidate the catalog rejected is absent from
  // the projection, so it is added from the file with no resolved candidate.
  const runtimeTomlSourceText = runtimeTomlSource.status === 'ready' ? runtimeTomlSource.sourceText : null
  const declaredRuntimeLanesById = useMemo(
    () => runtimeTomlSourceText === null ? null : declaredRuntimeLanes(runtimeTomlSourceText),
    [runtimeTomlSourceText],
  )
  const runtimeLaneCards: RuntimeLaneCard[] = [
    ...runtimeLanes.map(lane => ({
      id: lane.id,
      resolved: true,
      resolvedRuntimeIds: lane.runtime_ids,
      declared: declaredRuntimeLanesById?.get(lane.id) ?? null,
    })),
    ...(declaredRuntimeLanesById === null ? [] : [...declaredRuntimeLanesById.keys()])
      .filter(id => !runtimeLanes.some(lane => lane.id === id))
      .map(id => ({ id, resolved: false, resolvedRuntimeIds: [], declared: declaredRuntimeLanesById?.get(id) ?? null })),
  ]
  const runtimeSelectOptions = runtimeSelectOptionsFromResolved(runtimeResolved?.runtimes ?? [])
  const runtimeRoutingDisabled =
    runtimeRoutingStatus === 'saving' || runtimeLaneStatus === 'saving' || runtimeResolvedStatus !== 'ready'
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
  const mcpToolCount = mcpToolGroups.reduce((sum, group) => sum + group.names.length, 0)
  const mcpToolCountLabel = mcpToolsStatus === 'ready' ? String(mcpToolCount) : '—'
  const mcpUrlEntry = configEntry(dashboardConfig, 'MASC_URL')
  const httpBaseUrlEntry = configEntry(dashboardConfig, 'MASC_HTTP_BASE_URL')
  const basePathEntry = configEntry(dashboardConfig, 'MASC_BASE_PATH')
  const dataDirEntry = configEntry(dashboardConfig, 'MASC_DATA_DIR')
  const configDirEntry = configEntry(dashboardConfig, 'MASC_CONFIG_DIR')
  const ctxPreparingEntry = configEntry(dashboardConfig, 'MASC_DASHBOARD_CTX_PREPARING')
  const ctxHandoffEntry = configEntry(dashboardConfig, 'MASC_DASHBOARD_CTX_HANDOFF_IMMINENT')
  const runtimeWarningEntry = configEntry(dashboardConfig, 'MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO')
  const signalStaleEntry = configEntry(dashboardConfig, 'MASC_DASHBOARD_SIGNAL_STALE_SEC')

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
          <div class="set-nav-note">live-backed = 직접 읽고 씀 · writer 없는 값은 read-only</div>
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
            class=${`set-card-b mx-6 my-6 ${sec === 'account' || sec === 'runtime' || sec === 'routing' || sec === 'runtimes' || sec === 'paths' || sec === 'mcp' || sec === 'repositories' || sec === 'notify' || sec === 'prompts' || sec === 'fusion' ? 'set-card-b-wide' : 'ss-card'}`}
            data-preview-locked="false"
            data-settings-mode=${sectionState.mode}
          >
            <${SettingsControlLedger} section=${sec} />
            ${sec === 'account' && html`
              <${AccountSettingsSection} />
            `}
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
              <div class="set-mcp-detail mono" data-testid="settings-mcp-transport-detail">
                POST ${mcpEndpoint} · Content-Type: application/json · Authorization: Bearer ••••
              </div>
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
                  : mcpToolGroups.length === 0
                    ? html`<div class="set-hint" data-testid="mcp-tools-empty">노출된 MCP 도구가 없습니다.</div>`
                    : html`<div data-testid="mcp-tools-list">
                      ${mcpToolGroups.map(group => html`
                        <div key=${group.category} class="set-tg-row" data-testid="mcp-tool-group">
                          <div class="set-tg-l">
                            <div class="set-tg-head">
                              <span class="set-tg-id mono">${group.category}</span>
                              <span class="set-tg-kind masc">masc</span>
                            </div>
                            <div class="set-tg-tools">
                              ${group.names.map(t => html`<span key=${t} class="set-tg-chip mono">${t}</span>`)}
                            </div>
                          </div>
                        </div>
                      `)}
                    </div>`}
            `}

            ${sec === 'runtime' && html`
              <${OnboardingSettings} />
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
                ${runtimeResolvedStatus === 'loading'
                  ? html`<div class="set-hint" data-testid="runtime-resolved-loading">resolved runtime 불러오는 중...</div>`
                  : runtimeResolvedStatus === 'error'
                    ? html`<div class="set-hint" data-testid="runtime-resolved-error">resolved runtime을 불러오지 못했습니다. 이전 projection으로 대체하지 않습니다.</div>`
                    : null}

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
                  </div>
                  ${runtimeSelectOptions.length > 0
                    ? html`
                      <${RuntimeRoutingSelect}
                        label="Default runtime"
                        hint="[runtime].default · 새 keeper 가 시작될 런타임 id (provider.model)"
                        value=${defaultRuntimeId}
                        options=${runtimeSelectOptions}
                        disabled=${runtimeRoutingDisabled}
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
                          ? html`<span class="set-ro mono" data-testid="runtime-default-readonly">${defaultRuntimeId}</span>`
                          : html`<span class="set-hint" data-testid="runtime-default-empty">런타임 설정을 불러오지 못했습니다.</span>`}
                      <//>
                    `}
                  <${SetRow} label="Default model" hint="Resolved model API name">
                    <span class="set-ro mono" data-testid="runtime-default-model">${runtimeResolved?.default_runtime?.model ?? '—'}</span>
                  <//>
                  <${SetRow} label="Default context" hint="Resolved context window">
                    <span class="set-ro mono" data-testid="runtime-default-context">
                      ${formatRuntimeContext(runtimeResolved?.default_runtime?.effective_max_context ?? null)}
                    </span>
                    ${runtimeResolved?.default_runtime?.max_context_source
                      ? html`<span class="set-hint mono" data-testid="runtime-default-context-source">source: ${runtimeResolved.default_runtime.max_context_source}</span>`
                      : null}
                  <//>
                </div>

                <div class="settings-runtime-section" data-runtime-section="catalog" data-testid="runtime-catalog-section">
                  <div class="set-sub-h">Runtime catalog (${runtimeCatalogEntries.length})</div>
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
                      disabled=${runtimeRoutingDisabled}
                      testId="runtime-routing-default"
                      required=${true}
                      onChange=${(runtimeId: string | null) => {
                        if (runtimeId && runtimeId !== defaultRuntimeId) void applyRuntimeRoutingPatch('default', runtimeId)
                      }}
                    />
                    <${RuntimeMediaFailoverEditor}
                      value=${mediaFailover}
                      options=${runtimeSelectOptions}
                      disabled=${runtimeRoutingDisabled}
                      onChange=${(runtimeIds: string[]) => void applyMediaFailoverPatch(runtimeIds)}
                    />
                    ${runtimeRoutingStatus === 'saving'
                      ? html`<div class="set-hint" data-testid="runtime-routing-saving">runtime.toml 저장 중...</div>`
                      : runtimeRoutingMessage
                        ? html`<div class=${runtimeRoutingStatus === 'error' ? 'set-err' : 'set-ok'} data-testid="runtime-routing-message">${runtimeRoutingMessage}</div>`
                        : null}
                  </div>
                </div>

                ${runtimeResolved !== null
                  ? html`
                    <div class="settings-runtime-section" data-testid="runtime-lanes-section">
                      <div class="set-sub-h">Runtime lanes (${runtimeLaneCards.length})</div>
                      <div class="set-hint" data-testid="runtime-lanes-hint" style=${{ marginBottom: '8px' }}>
                        lane 별 후보 체인 — 위에서부터 순서대로 시도합니다. 편집은 runtime.toml 의 <span class="mono">${'[runtime.lanes.<id>]'}</span> 에 바로 저장되고, 이름 변경은 이 레인을 가리키는 배정·default·Fusion seat 도 함께 고칩니다. 파일에만 남은 후보나 레인은 routing API 가 저장할 수 없어 읽기 전용으로 보여 줍니다.
                      </div>
                      ${runtimeLaneCards.map(lane => html`
                        <${RuntimeLaneEditor}
                          key=${lane.id}
                          lane=${lane}
                          readOnlyReason=${runtimeLaneReadOnlyReason(lane, runtimeTomlSource)}
                          options=${runtimeSelectOptions}
                          disabled=${runtimeRoutingDisabled}
                          onWrite=${applyRuntimeLaneWrite}
                        />
                      `)}
                      <${RuntimeLaneCreateForm}
                        existingLaneIds=${runtimeLaneCards.map(lane => lane.id)}
                        options=${runtimeSelectOptions}
                        disabled=${runtimeRoutingDisabled}
                        onWrite=${applyRuntimeLaneWrite}
                      />
                    </div>
                  `
                  : null}
                ${runtimeLaneStatus === 'saving'
                  ? html`<div class="set-hint" data-testid="runtime-lane-saving">runtime.toml 저장 중...</div>`
                  : runtimeLaneMessage
                    ? html`<div class=${runtimeLaneStatus === 'error' ? 'set-err' : 'set-ok'} data-testid="runtime-lane-message">${runtimeLaneMessage}</div>`
                    : null}
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
                      <${PathTruthRow} label="Runtime TOML" fallback=${runtimeConfigPath} />
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
                알림 임계값은 서버 config projection에서 읽는 실측값입니다. 브라우저 알림 전달 규칙(아래)은 이 브라우저에만 저장되며 서버 설정을 그림자화하지 않습니다.
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
                    </div>
                  `}
              <div class="set-sub-h">Browser notification delivery</div>
              <${NotifyPermissionRow} />
              ${NOTIFY_EVENT_KINDS.map(kind => html`<${NotifyEventToggleRow} key=${kind} kind=${kind} />`)}
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
