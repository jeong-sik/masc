import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { Option } from 'effect'
import { SectionCard } from './common/card'
import { TextInput } from './common/input'
import { TransportHealthPanel } from './transport-health'
import { ConfigResolutionPanel } from './tools/config-resolution-panel'
import {
  fetchDashboardConfig,
  type DashboardConfig,
  type DashboardConfigError,
  type ConfigEntry,
} from '../api/dashboard-config'
import { dashboardRuntime, type DashboardHttp } from '../api/effect-http'
import { createEffectResource } from '../lib/effect-resource'
import { remotePrevious } from '../lib/remote-data'
import { formatElapsedCompact } from '../lib/format-time'
import { LoadingState } from './common/feedback-state'
import { Eyebrow } from './common/eyebrow'
import { refreshShell, shellConfigResolution, shellRuntimeResolution } from '../store'

const configResource = createEffectResource<
  DashboardHttp,
  DashboardConfigError,
  DashboardConfig
>(dashboardRuntime)
const searchQuery = signal('')
const expandedCategories = signal<Set<string>>(new Set())

export function refreshServerConfig(): Promise<void> {
  void refreshShell({ force: true })
  return configResource.load(fetchDashboardConfig()).then(() => {
    const data = Option.getOrUndefined(remotePrevious(configResource.state.value))
    if (data !== undefined && expandedCategories.value.size === 0) {
      expandedCategories.value = new Set(Object.keys(data.categories))
    }
  })
}

function toggleCategory(name: string) {
  const next = new Set(expandedCategories.value)
  if (next.has(name)) next.delete(name)
  else next.add(name)
  expandedCategories.value = next
}

// Delegated to lib/format-time (SSOT)
const formatUptime = formatElapsedCompact

function matchesSearch(entry: ConfigEntry, query: string): boolean {
  if (!query) return true
  const lower = query.toLowerCase()
  return (
    entry.env.toLowerCase().includes(lower) ||
    entry.description.toLowerCase().includes(lower) ||
    entry.source.toLowerCase().includes(lower) ||
    entry.sourceDetail.toLowerCase().includes(lower) ||
    entry.displayValue.toLowerCase().includes(lower)
  )
}

function EntryRow({ entry }: { entry: ConfigEntry }) {
  const isEnv = entry.source === 'env'
  const isDefault = entry.source !== 'env'
  const valueClass = entry.sensitive
    ? 'text-[var(--color-fg-muted)] italic'
    : isDefault
      ? 'text-[var(--color-fg-muted)]'
      : 'text-[var(--color-accent-fg)] font-medium'

  return html`
    <div class="v2-connector-row flex items-start gap-3 py-2 px-3 rounded-[var(--r-1)] hover:bg-[var(--color-bg-hover)] transition-colors">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <code class="text-xs font-mono text-[var(--color-fg-secondary)]">${entry.env}</code>
          ${isEnv ? html`
            <span class="text-3xs uppercase tracking-wider px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-accent-fg)]/10 text-[var(--color-accent-fg)]">custom</span>
          ` : null}
          ${!isEnv && entry.source !== 'default' ? html`
            <span class="text-3xs uppercase tracking-wider px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]">${entry.source}</span>
          ` : null}
          ${entry.sensitive ? html`
            <span class="text-3xs uppercase tracking-wider px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--warn-10)] text-[var(--color-status-warn)]">sensitive</span>
          ` : null}
        </div>
        <div class="text-xs text-[var(--color-fg-muted)] mt-0.5">${entry.description}</div>
        <div class="text-3xs text-[var(--color-fg-muted)] mt-0.5">source: ${entry.sourceDetail}</div>
      </div>
      <div class="text-right shrink-0">
        <div class=${`text-xs font-mono ${valueClass}`}>
          ${entry.displayValue}
        </div>
        ${isEnv && entry.defaultValue ? html`
          <div class="text-3xs text-[var(--color-fg-muted)] mt-0.5">
            default: ${entry.defaultValue}
          </div>
        ` : null}
      </div>
    </div>
  `
}

function CategoryPanel({ name, entries }: { name: string; entries: readonly ConfigEntry[] }) {
  const query = searchQuery.value
  const filtered = entries.filter(e => matchesSearch(e, query))
  const isExpanded = expandedCategories.value.has(name)
  const customCount = filtered.filter(e => e.source === 'env').length

  if (filtered.length === 0) return null

  return html`
    <div class="v2-connector-detail border border-[var(--color-border-divider)] rounded-[var(--r-1)] overflow-hidden mb-3">
      <button
        class="w-full flex items-center justify-between px-4 py-2.5 bg-[var(--bg-surface)] hover:bg-[var(--color-bg-hover)] transition-colors text-left"
        aria-expanded=${isExpanded ? 'true' : 'false'}
        onClick=${() => toggleCategory(name)}
      >
        <div class="flex items-center gap-2">
          <span class="text-xs text-[var(--color-fg-muted)]">${isExpanded ? '\u25BC' : '\u25B6'}</span>
          <span class="text-sm font-medium text-[var(--color-fg-secondary)] capitalize">${name}</span>
          <span class="text-xs text-[var(--color-fg-muted)]">(${filtered.length})</span>
        </div>
        ${customCount > 0 ? html`
          <span class="text-3xs px-2 py-0.5 rounded-[var(--r-0)] bg-[var(--color-accent-fg)]/10 text-[var(--color-accent-fg)]">
            ${customCount} custom
          </span>
        ` : null}
      </button>
      ${isExpanded ? html`
        <div class="divide-y divide-[var(--color-border-divider)]">
          ${filtered.map(entry => html`<${EntryRow} entry=${entry} />`)}
        </div>
      ` : null}
    </div>
  `
}

function ServerMeta({ server }: { server: DashboardConfig['server'] }) {
  return html`
    <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
      <div class="v2-connector-card px-3 py-2 rounded-[var(--r-1)] bg-[var(--bg-surface)] border border-[var(--color-border-divider)]">
        <${Eyebrow}>버전</${Eyebrow}>
        <div class="text-sm font-mono text-[var(--color-fg-secondary)]">${server.version}</div>
      </div>
      <div class="v2-connector-card px-3 py-2 rounded-[var(--r-1)] bg-[var(--bg-surface)] border border-[var(--color-border-divider)]">
        <${Eyebrow}>가동시간</${Eyebrow}>
        <div class="text-sm font-mono text-[var(--color-fg-secondary)]">${formatUptime(server.uptimeSeconds)}</div>
      </div>
      <div class="v2-connector-card px-3 py-2 rounded-[var(--r-1)] bg-[var(--bg-surface)] border border-[var(--color-border-divider)]">
        <${Eyebrow}>OCaml</${Eyebrow}>
        <div class="text-sm font-mono text-[var(--color-fg-secondary)]">${server.ocamlVersion}</div>
      </div>
      <div class="v2-connector-card px-3 py-2 rounded-[var(--r-1)] bg-[var(--bg-surface)] border border-[var(--color-border-divider)]">
        <${Eyebrow}>PID</${Eyebrow}>
        <div class="text-sm font-mono text-[var(--color-fg-secondary)]">${server.pid}</div>
      </div>
    </div>
  `
}

export function ServerConfig() {
  useEffect(() => {
    if (configResource.state.value._tag === 'Initial') {
      void refreshServerConfig()
    }
    return () => configResource.cancel()
  }, [])

  const s = configResource.state.value
  const data = Option.getOrUndefined(remotePrevious(s))
  const loading = s._tag === 'Initial' || s._tag === 'Loading'
  const error = s._tag === 'Failure' ? s.error.message : null
  const configResolution = shellConfigResolution.value
  const runtimeResolution = shellRuntimeResolution.value

  return html`
    <div class="v2-connector-surface">
      <${SectionCard} label="서버 설정" class="section">
        <div class="v2-connector-toolbar mb-3 flex items-center gap-2">
          <${TextInput}
            class="flex-1"
            placeholder="환경변수 또는 설명으로 검색..."
            value=${searchQuery.value}
            onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
          />
          <button
            class="v2-connector-action px-3 py-1.5 text-xs rounded-[var(--r-1)] bg-[var(--bg-surface)] border border-[var(--color-border-divider)] text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] transition-colors"
            onClick=${() => void refreshServerConfig()}
            disabled=${loading}
          >
            ${loading ? '...' : '새로고침'}
          </button>
        </div>

        ${error ? html`
          <div class="v2-connector-panel text-sm text-[var(--color-status-err)] mb-3" role="alert">${error}</div>
        ` : null}

        ${loading && !data ? html`
          <${LoadingState}>설정 불러오는 중...<//>
        ` : null}

        <${ConfigResolutionPanel}
          resolution=${configResolution ?? undefined}
          runtimeResolution=${runtimeResolution ?? undefined}
        />

        ${data ? html`
          <${ServerMeta} server=${data.server} />
          ${Object.entries(data.categories).map(([name, entries]) =>
            html`<${CategoryPanel} name=${name} entries=${entries} />`
          )}
        ` : null}
      <//>

      <div class="mt-4">
        <${TransportHealthPanel} />
      </div>
    </div>
  `
}
