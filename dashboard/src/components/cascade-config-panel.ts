// CascadeConfigPanel — renders cascade.json profiles + health tracker state
// side-by-side so operators can see *why* a given provider is picked first.
//
// Consumes:
//   GET /api/v1/cascade/config  — profiles + per-candidate weight/health
//   GET /api/v1/cascade/health  — global health tracker snapshot
//
// Pattern mirrors RuntimeMonitor: managed async resource + manual refresh.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchCascadeClientCapacity,
  fetchCascadeClientCapacityHistory,
  fetchCascadeStrategyTrace,
  fetchCascadeConfig,
  fetchCascadeHealth,
  type CascadeCandidate,
  type CascadeCapacityEventKind,
  type CascadeClientCapacityEntry,
  type CascadeClientCapacityHistoryEvent,
  type CascadeClientCapacityHistoryResponse,
  type CascadeClientCapacityResponse,
  type CascadeConfigResponse,
  type CascadeHealthProvider,
  type CascadeHealthResponse,
  type CascadeProfile,
  type CascadeStrategyTraceEvent,
  type CascadeStrategyTraceKind,
  type CascadeStrategyTraceResponse,
} from '../api/dashboard'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { TextInput } from './common/input'
import { StatCell } from './common/stat-cell'
import { StatusChip } from './common/status-chip'
import { createManagedAsyncResource, type ManagedAsyncResource } from '../lib/async-state'

interface CascadeData {
  config: CascadeConfigResponse | null
  health: CascadeHealthResponse | null
  capacity: CascadeClientCapacityResponse | null
  history: CascadeClientCapacityHistoryResponse | null
  trace: CascadeStrategyTraceResponse | null
}

async function loadCascadeData(resource: ManagedAsyncResource<CascadeData>) {
  await resource.load(async (signal) => {
    const [config, health, capacity, history, trace] = await Promise.all([
      fetchCascadeConfig({ signal }),
      fetchCascadeHealth({ signal }),
      fetchCascadeClientCapacity({ signal }),
      fetchCascadeClientCapacityHistory({ limit: 50, signal }),
      fetchCascadeStrategyTrace({ limit: 50, signal }),
    ])
    return { config, health, capacity, history, trace }
  })
}

export function fmtPct(value: number): string {
  if (Number.isNaN(value)) return '--'
  return `${(value * 100).toFixed(1)}%`
}

export function candidateTone(c: CascadeCandidate): string {
  if (c.in_cooldown) return 'bad'
  if (c.effective_weight === 0) return 'bad'
  if (c.success_rate < 0.5) return 'bad'
  if (c.success_rate < 0.9) return 'warn'
  return 'ok'
}

export function sourceLabel(source: CascadeProfile['source']): string {
  switch (source) {
    case 'named': return 'named'
    case 'default_fallback': return 'default'
    case 'hardcoded_defaults': return 'hardcoded'
  }
}

export function sourceTone(source: CascadeProfile['source']): string {
  switch (source) {
    case 'named': return 'ok'
    case 'default_fallback': return 'warn'
    case 'hardcoded_defaults': return 'warn'
  }
}

function fmtCooldownExpiry(expiresAt: number | null): string {
  if (expiresAt == null) return '—'
  const delta = expiresAt - Date.now() / 1000
  if (delta <= 0) return '만료됨'
  if (delta < 60) return `${Math.ceil(delta)}초 후`
  return `${Math.ceil(delta / 60)}분 후`
}

function ProfileCard({ profile }: { profile: CascadeProfile }) {
  return html`
    <article class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] p-3">
      <header class="flex items-center gap-2 mb-2">
        <span class="font-semibold text-[var(--text-strong)]">${profile.name}</span>
        <${StatusChip} tone=${sourceTone(profile.source)}>
          ${sourceLabel(profile.source)}
        <//>
        <span class="text-xs text-[var(--text-muted)]">
          ${profile.candidates.length} candidate${profile.candidates.length === 1 ? '' : 's'}
        </span>
      </header>
      ${profile.candidates.length === 0
        ? html`<div class="text-xs text-[var(--text-muted)]">no candidates resolved</div>`
        : html`
          <ol class="flex flex-col gap-1 text-xs">
            ${profile.candidates.map((c, idx) => html`
              <li class="flex items-center gap-2 py-1 border-b border-[var(--card-border)] last:border-b-0">
                <span class="tabular-nums text-[var(--text-muted)] w-5">${idx + 1}.</span>
                <${StatusChip} tone=${candidateTone(c)}>
                  ${c.in_cooldown ? 'cooldown' : fmtPct(c.success_rate)}
                <//>
                <code class="flex-1 truncate text-[var(--text-strong)]">${c.model}</code>
                <span class="tabular-nums text-[var(--text-muted)]">
                  w ${c.config_weight}${c.effective_weight === c.config_weight ? '' : ` → ${c.effective_weight}`}
                </span>
              </li>
            `)}
          </ol>
        `}
    </article>
  `
}

function KeeperMapping({ config }: { config: CascadeConfigResponse }) {
  const mapping = config.keeper_profiles
  if (mapping.length === 0) {
    return html`<${EmptyState}>활성 keeper 없음<//>`
  }
  return html`
    <table class="w-full text-xs">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th class="text-left py-1">Keeper</th>
          <th class="text-left py-1">Cascade Name</th>
          <th class="text-left py-1">Canonical</th>
        </tr>
      </thead>
      <tbody>
        ${mapping.map(m => html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0">
            <td class="py-1 font-semibold text-[var(--text-strong)]">${m.keeper}</td>
            <td class="py-1"><code>${m.cascade_name}</code></td>
            <td class="py-1">
              ${m.cascade_name === m.canonical
                ? html`<span class="text-[var(--text-muted)]">—</span>`
                : html`<code>${m.canonical}</code>`}
            </td>
          </tr>
        `)}
      </tbody>
    </table>
  `
}

export function providerTone(p: CascadeHealthProvider): 'ok' | 'warn' | 'bad' {
  if (p.in_cooldown) return 'bad'
  if (p.success_rate < 0.7) return 'bad'
  if (p.success_rate < 0.9) return 'warn'
  return 'ok'
}

const TONE_DOT: Record<string, string> = {
  ok: 'bg-[var(--ok)]',
  warn: 'bg-[var(--warn)]',
  bad: 'bg-[var(--bad)]',
}

function HealthTable({ health }: { health: CascadeHealthResponse }) {
  if (health.providers.length === 0) {
    return html`<${EmptyState}>아직 기록된 provider 이벤트가 없습니다.<//>`
  }
  return html`
    <table class="w-full text-xs">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th class="text-left py-1 w-4"></th>
          <th class="text-left py-1">Provider</th>
          <th class="text-right py-1">Success</th>
          <th class="text-right py-1">Consec. fail</th>
          <th class="text-right py-1">Events</th>
          <th class="text-right py-1">Cooldown</th>
        </tr>
      </thead>
      <tbody>
        ${health.providers.map((p: CascadeHealthProvider) => {
          const tone = providerTone(p)
          return html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0">
            <td class="py-1"><span class=${`inline-block w-2 h-2 rounded-full ${TONE_DOT[tone]}`}></span></td>
            <td class="py-1"><code class="text-[var(--text-strong)]">${p.provider_key}</code></td>
            <td class="py-1 text-right tabular-nums">${fmtPct(p.success_rate)}</td>
            <td class="py-1 text-right tabular-nums">${p.consecutive_failures}</td>
            <td class="py-1 text-right tabular-nums">${p.events_in_window}</td>
            <td class="py-1 text-right">
              ${p.in_cooldown
                ? html`<${StatusChip} tone="bad">${fmtCooldownExpiry(p.cooldown_expires_at)}<//>`
                : html`<span class="text-[var(--text-muted)]">—</span>`}
            </td>
          </tr>
        `})}
      </tbody>
    </table>
  `
}

export function capacityTone(entry: CascadeClientCapacityEntry): 'ok' | 'warn' | 'bad' {
  if (entry.total === 0) return 'bad'
  if (entry.available === 0) return 'warn'
  return 'ok'
}

function fmtRelativeTime(tsSec: number): string {
  const deltaSec = Date.now() / 1000 - tsSec
  if (!Number.isFinite(deltaSec) || deltaSec < 0) return '방금'
  if (deltaSec < 1) return '방금'
  if (deltaSec < 60) return `${Math.floor(deltaSec)}초 전`
  if (deltaSec < 3600) return `${Math.floor(deltaSec / 60)}분 전`
  if (deltaSec < 86400) return `${Math.floor(deltaSec / 3600)}시간 전`
  return `${Math.floor(deltaSec / 86400)}일 전`
}

export function eventKindTone(kind: CascadeCapacityEventKind): 'ok' | 'neutral' | 'bad' {
  switch (kind) {
    case 'acquired': return 'ok'
    case 'released': return 'neutral'
    case 'rejected_full': return 'bad'
  }
}

export function eventKindLabel(kind: CascadeCapacityEventKind): string {
  switch (kind) {
    case 'acquired': return 'acquired'
    case 'released': return 'released'
    case 'rejected_full': return 'rejected'
  }
}

export function capacityKindLabel(kind: CascadeClientCapacityEntry['kind']): string {
  switch (kind) {
    case 'cli': return 'CLI'
    case 'ollama': return 'Ollama'
    case 'other': return 'Other'
  }
}

export function traceKindTone(k: CascadeStrategyTraceKind): 'ok' | 'warn' | 'bad' {
  switch (k) {
    case 'ordered': return 'ok'
    case 'filtered_empty': return 'warn'
    case 'exhausted': return 'bad'
  }
}

export function traceKindLabel(k: CascadeStrategyTraceKind): string {
  switch (k) {
    case 'ordered': return '정렬'
    case 'filtered_empty': return '전부 차단'
    case 'exhausted': return '소진'
  }
}

export function traceEventMatchesSearch(
  e: CascadeStrategyTraceEvent,
  query: string,
): boolean {
  const q = query.toLowerCase()
  if (e.cascade_name.toLowerCase().includes(q)) return true
  if (e.strategy.toLowerCase().includes(q)) return true
  if (e.kind.toLowerCase().includes(q)) return true
  if (traceKindLabel(e.kind).toLowerCase().includes(q)) return true
  if (String(e.cycle).includes(q)) return true
  if (String(e.candidates_in).includes(q)) return true
  if (String(e.candidates_out).includes(q)) return true
  return false
}

function StrategyTraceTable({
  trace,
  searchQuery,
}: { trace: CascadeStrategyTraceResponse; searchQuery: { value: string } }) {
  if (trace.events.length === 0) {
    return html`<${EmptyState}>최근 strategy decision 이 없습니다. (cascade 호출이 아직 발생하지 않음)<//>`
  }
  const query = searchQuery.value.trim().toLowerCase()
  const filtered = query
    ? trace.events.filter(e => traceEventMatchesSearch(e, query))
    : trace.events
  return html`
    ${query ? html`<div class="text-xs text-[var(--text-muted)] mb-2">${filtered.length}/${trace.events.length}건</div>` : null}
    <table class="w-full text-xs">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th class="text-left py-1 w-20">시간</th>
          <th class="text-left py-1">Cascade</th>
          <th class="text-left py-1">Strategy</th>
          <th class="text-right py-1">Cycle</th>
          <th class="text-right py-1">In/Out</th>
          <th class="text-right py-1">Backoff(ms)</th>
          <th class="text-left py-1">결과</th>
        </tr>
      </thead>
      <tbody>
        ${filtered.map((e: CascadeStrategyTraceEvent) => {
          const tone = traceKindTone(e.kind)
          return html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0">
            <td class="py-1 text-[var(--text-muted)] tabular-nums">${fmtRelativeTime(e.ts)}</td>
            <td class="py-1"><code class="text-[var(--text-strong)]">${e.cascade_name}</code></td>
            <td class="py-1 text-[var(--text-muted)]">${e.strategy}</td>
            <td class="py-1 text-right tabular-nums">${e.cycle}</td>
            <td class="py-1 text-right tabular-nums">${e.candidates_in}/${e.candidates_out}</td>
            <td class="py-1 text-right tabular-nums">${e.backoff_ms > 0 ? e.backoff_ms : '–'}</td>
            <td class="py-1"><${StatusChip} tone=${tone}>${traceKindLabel(e.kind)}<//></td>
          </tr>
        `})}
      </tbody>
    </table>
  `
}

function ClientCapacityHistoryTable({
  history,
}: { history: CascadeClientCapacityHistoryResponse }) {
  if (history.events.length === 0) {
    return html`<${EmptyState}>최근 capacity 이벤트가 없습니다. (acquire/release가 아직 발생하지 않음)<//>`
  }
  return html`
    <table class="w-full text-xs">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th class="text-left py-1 w-20">시간</th>
          <th class="text-left py-1">종류</th>
          <th class="text-left py-1">키</th>
          <th class="text-right py-1">활성</th>
        </tr>
      </thead>
      <tbody>
        ${history.events.map((e: CascadeClientCapacityHistoryEvent) => {
          const tone = eventKindTone(e.kind)
          return html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0">
            <td class="py-1 text-[var(--text-muted)] tabular-nums">${fmtRelativeTime(e.ts)}</td>
            <td class="py-1"><${StatusChip} tone=${tone}>${eventKindLabel(e.kind)}<//></td>
            <td class="py-1"><code class="text-[var(--text-strong)]">${e.key}</code></td>
            <td class="py-1 text-right tabular-nums">${e.active_after}</td>
          </tr>
        `})}
      </tbody>
    </table>
  `
}

function ClientCapacityTable({ capacity }: { capacity: CascadeClientCapacityResponse }) {
  if (capacity.entries.length === 0) {
    return html`<${EmptyState}>등록된 client-capacity 슬롯이 없습니다. (cascade가 한 번도 호출되지 않았거나 CLI/ollama provider 미사용)<//>`
  }
  return html`
    <table class="w-full text-xs">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th class="text-left py-1 w-4"></th>
          <th class="text-left py-1">Kind</th>
          <th class="text-left py-1">Key</th>
          <th class="text-right py-1">Active</th>
          <th class="text-right py-1">Available</th>
          <th class="text-right py-1">Total</th>
        </tr>
      </thead>
      <tbody>
        ${capacity.entries.map((e: CascadeClientCapacityEntry) => {
          const tone = capacityTone(e)
          return html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0">
            <td class="py-1"><span class=${`inline-block w-2 h-2 rounded-full ${TONE_DOT[tone]}`}></span></td>
            <td class="py-1"><${StatusChip} tone=${tone === 'ok' ? 'neutral' : tone}>${capacityKindLabel(e.kind)}<//></td>
            <td class="py-1"><code class="text-[var(--text-strong)]">${e.key}</code></td>
            <td class="py-1 text-right tabular-nums">${e.active}</td>
            <td class="py-1 text-right tabular-nums">${e.available}</td>
            <td class="py-1 text-right tabular-nums">${e.total}</td>
          </tr>
        `})}
      </tbody>
    </table>
  `
}

export function CascadeConfigPanel() {
  const traceSearch = useSignal('')
  const resourceRef = useRef<ManagedAsyncResource<CascadeData> | null>(null)
  if (resourceRef.current === null) {
    resourceRef.current = createManagedAsyncResource<CascadeData>()
  }
  const resource = resourceRef.current

  useEffect(() => {
    void loadCascadeData(resource)
    const id = setInterval(() => void loadCascadeData(resource), 30_000)
    return () => { clearInterval(id); resource.cancel() }
  }, [resource])

  const current = resource.state.value
  const config = current.data?.config ?? null
  const health = current.data?.health ?? null
  const capacity = current.data?.capacity ?? null
  const history = current.data?.history ?? null
  const trace = current.data?.trace ?? null

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void loadCascadeData(resource)}
        >
          새로고침
        </button>
        ${current.loading ? html`<span class="text-xs text-[var(--text-muted)]">로딩 중...</span>` : null}
        ${config?.updated_at
          ? html`<span class="text-xs text-[var(--text-muted)]">config · ${config.updated_at}</span>`
          : null}
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !config && !health
        ? html`<${LoadingState}>cascade snapshot 불러오는 중...<//>`
        : null}

      <${Card} title="Cascade Profiles">
        ${config
          ? html`
            <div class="grid grid-cols-2 gap-3 mb-3">
              <${StatCell}
                label="Profiles"
                value=${config.profiles.length}
                detail=${config.config_path ?? 'config 없음'}
              />
              <${StatCell}
                label="Keepers"
                value=${config.keeper_profiles.length}
                detail="cascade_name 등록됨"
              />
            </div>
            <div class="grid gap-3 md:grid-cols-2">
              ${config.profiles.map(p => html`<${ProfileCard} profile=${p} />`)}
            </div>
          `
          : null}
      <//>

      <${Card} title="Keeper → Cascade Mapping">
        ${config ? html`<${KeeperMapping} config=${config} />` : null}
      <//>

      <${Card} title="Health Tracker">
        ${health
          ? html`
            <div class="grid grid-cols-3 gap-3 mb-3">
              <${StatCell}
                label="Window"
                value=${`${health.window_sec}s`}
                detail=${`${health.providers.length} tracked`}
              />
              <${StatCell}
                label="Cooldown Threshold"
                value=${health.cooldown_threshold}
                detail="연속 실패"
              />
              <${StatCell}
                label="Cooldown"
                value=${`${health.cooldown_sec}s`}
                detail="활성 시 차단 시간"
              />
            </div>
            <${HealthTable} health=${health} />
          `
          : null}
      <//>

      <${Card} title="Client Capacity">
        ${capacity
          ? html`<${ClientCapacityTable} capacity=${capacity} />`
          : null}
      <//>

      <${Card} title="Client Capacity — 최근 이벤트">
        ${history
          ? html`<${ClientCapacityHistoryTable} history=${history} />`
          : null}
      <//>

      <${Card} title="Strategy Decisions — cycle 추적">
        ${trace
          ? html`
            <div class="flex items-center gap-3 mb-3">
              <${TextInput}
                class="max-w-[280px]"
                placeholder="검색 (cascade, strategy, 결과...)"
                ariaLabel="strategy trace 검색"
                value=${traceSearch.value}
                onInput=${(e: Event) => { traceSearch.value = (e.target as HTMLInputElement).value }}
              />
            </div>
            <${StrategyTraceTable} trace=${trace} searchQuery=${traceSearch} />
          `
          : null}
      <//>
    </div>
  `
}
