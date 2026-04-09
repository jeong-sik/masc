import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { TextInput } from './common/input'
import { TransportHealthPanel } from './transport-health'
import { fetchDashboardConfig } from '../api/dashboard'
import type { DashboardConfigResponse, ConfigEntry } from '../api/dashboard'
import { createAsyncResource } from '../lib/async-state'
import { formatElapsedCompact } from '../lib/format-time'

const configResource = createAsyncResource<DashboardConfigResponse>()
const searchQuery = signal('')
const expandedCategories = signal<Set<string>>(new Set())

export function refreshServerConfig(): Promise<void> {
  configResource.reset()
  return configResource.load(async () => {
    const data = await fetchDashboardConfig()
    if (expandedCategories.value.size === 0) {
      expandedCategories.value = new Set(Object.keys(data.categories))
    }
    return data
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
    (entry.value ?? '').toLowerCase().includes(lower)
  )
}

function EntryRow({ entry }: { entry: ConfigEntry }) {
  const isDefault = entry.source === 'default'
  const valueClass = entry.sensitive
    ? 'text-[var(--text-muted)] italic'
    : isDefault
      ? 'text-[var(--text-muted)]'
      : 'text-[var(--accent-primary)] font-medium'

  return html`
    <div class="flex items-start gap-3 py-2 px-3 rounded hover:bg-[var(--bg-panel-hover)] transition-colors">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <code class="text-xs font-mono text-[var(--text-primary)]">${entry.env}</code>
          ${!isDefault ? html`
            <span class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-[var(--accent-primary)]/10 text-[var(--accent-primary)]">custom</span>
          ` : null}
          ${entry.sensitive ? html`
            <span class="text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-amber-500/10 text-amber-400">sensitive</span>
          ` : null}
        </div>
        <div class="text-xs text-[var(--text-muted)] mt-0.5">${entry.description}</div>
      </div>
      <div class="text-right shrink-0">
        <div class=${`text-xs font-mono ${valueClass}`}>
          ${entry.value ?? entry.default}
        </div>
        ${!isDefault && entry.default ? html`
          <div class="text-[10px] text-[var(--text-muted)] mt-0.5">
            default: ${entry.default}
          </div>
        ` : null}
      </div>
    </div>
  `
}

function CategoryPanel({ name, entries }: { name: string; entries: ConfigEntry[] }) {
  const query = searchQuery.value
  const filtered = entries.filter(e => matchesSearch(e, query))
  const isExpanded = expandedCategories.value.has(name)
  const customCount = filtered.filter(e => e.source !== 'default').length

  if (filtered.length === 0) return null

  return html`
    <div class="border border-[var(--border-subtle)] rounded-lg overflow-hidden mb-3">
      <button
        class="w-full flex items-center justify-between px-4 py-2.5 bg-[var(--bg-surface)] hover:bg-[var(--bg-panel-hover)] transition-colors text-left"
        onClick=${() => toggleCategory(name)}
      >
        <div class="flex items-center gap-2">
          <span class="text-xs text-[var(--text-muted)]">${isExpanded ? '\u25BC' : '\u25B6'}</span>
          <span class="text-sm font-medium text-[var(--text-primary)] capitalize">${name}</span>
          <span class="text-xs text-[var(--text-muted)]">(${filtered.length})</span>
        </div>
        ${customCount > 0 ? html`
          <span class="text-[10px] px-2 py-0.5 rounded-full bg-[var(--accent-primary)]/10 text-[var(--accent-primary)]">
            ${customCount} custom
          </span>
        ` : null}
      </button>
      ${isExpanded ? html`
        <div class="divide-y divide-[var(--border-subtle)]">
          ${filtered.map(entry => html`<${EntryRow} entry=${entry} />`)}
        </div>
      ` : null}
    </div>
  `
}

function ServerMeta() {
  const sm = configResource.state.value
  const data = sm.status === 'loaded' ? sm.data : undefined
  if (!data) return null
  const { server } = data

  return html`
    <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
      <div class="px-3 py-2 rounded-lg bg-[var(--bg-surface)] border border-[var(--border-subtle)]">
        <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Version</div>
        <div class="text-sm font-mono text-[var(--text-primary)]">${server.version}</div>
      </div>
      <div class="px-3 py-2 rounded-lg bg-[var(--bg-surface)] border border-[var(--border-subtle)]">
        <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Uptime</div>
        <div class="text-sm font-mono text-[var(--text-primary)]">${formatUptime(server.uptime_seconds)}</div>
      </div>
      <div class="px-3 py-2 rounded-lg bg-[var(--bg-surface)] border border-[var(--border-subtle)]">
        <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">OCaml</div>
        <div class="text-sm font-mono text-[var(--text-primary)]">${server.ocaml_version}</div>
      </div>
      <div class="px-3 py-2 rounded-lg bg-[var(--bg-surface)] border border-[var(--border-subtle)]">
        <div class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">PID</div>
        <div class="text-sm font-mono text-[var(--text-primary)]">${server.pid}</div>
      </div>
    </div>
  `
}

export function ServerConfig() {
  const s = configResource.state.value
  const data = s.status === 'loaded' ? s.data : undefined
  const loading = s.status === 'loading'
  const error = s.status === 'error' ? s.message : null

  if (s.status === 'idle') {
    void refreshServerConfig()
  }

  return html`
    <${Card} title="서버 설정" class="section">
      <div class="mb-3 flex items-center gap-2">
        <${TextInput}
          class="flex-1"
          placeholder="환경변수 또는 설명으로 검색..."
          value=${searchQuery.value}
          onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
        />
        <button
          class="px-3 py-1.5 text-xs rounded-lg bg-[var(--bg-surface)] border border-[var(--border-subtle)] text-[var(--text-muted)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-panel-hover)] transition-colors"
          onClick=${() => void refreshServerConfig()}
          disabled=${loading}
        >
          ${loading ? '...' : '새로고침'}
        </button>
      </div>

      ${error ? html`
        <div class="text-sm text-[var(--bad)] mb-3">${error}</div>
      ` : null}

      ${loading && !data ? html`
        <div class="text-sm text-[var(--text-muted)] py-8 text-center">로딩 중...</div>
      ` : null}

      ${data ? html`
        <${ServerMeta} />
        ${Object.entries(data.categories).map(([name, entries]) =>
          html`<${CategoryPanel} name=${name} entries=${entries} />`
        )}
      ` : null}
    <//>

    <div class="mt-4">
      <${TransportHealthPanel} />
    </div>
  `
}
