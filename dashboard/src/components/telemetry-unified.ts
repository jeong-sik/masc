// Telemetry Unified — runtime diagnosis view.
// Keeps MASC telemetry stores and OAS proof/runtime evidence separate in data flow,
// then composes them in the UI so the boundary stays explicit.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchDashboardProof,
  fetchTelemetry,
  fetchTelemetrySummary,
  type TelemetryEntry,
  type TelemetrySource,
  type TelemetrySourceSummary,
} from '../api/dashboard'
import { route } from '../router'
import { formatTimeAgo } from '../lib/format-time'
import type { DashboardProofWorkerRunEvidence } from '../types'

const SOURCE_META: Record<TelemetrySource, { label: string; color: string; icon: string }> = {
  keeper_metric: { label: 'Keeper 메트릭', color: 'text-blue-400', icon: 'K' },
  agent_event: { label: '에이전트 이벤트', color: 'text-emerald-400', icon: 'A' },
  tool_call_io: { label: '도구 호출 I/O', color: 'text-amber-400', icon: 'T' },
  tool_usage: { label: '도구 사용', color: 'text-purple-400', icon: 'U' },
  tool_metric: { label: '도구 메트릭', color: 'text-cyan-400', icon: 'M' },
}

interface TelemetryState {
  entries: TelemetryEntry[]
  summary: TelemetrySourceSummary[]
  totalEntries: number
  proofWorkerRuns: DashboardProofWorkerRunEvidence[]
  proofSourceLabel: string | null
  loading: boolean
  error: string | null
}

function sourceMeta(source: string) {
  return SOURCE_META[source as TelemetrySource] ?? { label: source, color: 'text-gray-400', icon: '?' }
}

function entryTimestamp(e: TelemetryEntry): number {
  const numeric = (e.ts_unix as number) ?? (e.ts as number) ?? (e.timestamp as number) ?? 0
  if (numeric > 0) return numeric
  if (typeof e.ts_iso === 'string') {
    const parsed = Date.parse(e.ts_iso)
    if (!Number.isNaN(parsed)) return parsed / 1000
  }
  return 0
}

function formatTs(ts: number): string {
  if (ts === 0) return '-'
  const d = new Date(ts * 1000)
  return d.toLocaleString('ko-KR', {
    month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

function timeAgo(ts: number): string {
  if (ts === 0) return ''
  return formatTimeAgo(ts)
}

function normalizeText(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function normalizeStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string' && item.trim() !== '') : []
}

function compactId(value: string | null | undefined, prefix: string): string | null {
  if (!value) return null
  return `${prefix} ${value}`
}

function telemetryScopeBadges(entry: TelemetryEntry): string[] {
  return [
    compactId(normalizeText(entry.session_id), 'S'),
    compactId(normalizeText(entry.operation_id), 'OP'),
    compactId(normalizeText(entry.worker_run_id), 'WR'),
  ].filter((value): value is string => Boolean(value))
}

function entryPreview(e: TelemetryEntry): string {
  switch (e.source) {
    case 'keeper_metric': {
      const name = normalizeText(e.name) ?? '-'
      const channel = normalizeText(e.channel) ?? '-'
      const model = normalizeText(e.model_used) ?? '-'
      const tools = normalizeStringArray(e.tools_used)
      const toolCount = typeof e.tool_call_count === 'number' ? e.tool_call_count : tools.length
      return `${name} [${channel}] model=${model} tools=${toolCount}`
    }
    case 'agent_event': {
      const event = e.event
      if (Array.isArray(event)) return `${event[0] ?? 'unknown'}`
      return String(event ?? '')
    }
    case 'tool_call_io': {
      const tool = normalizeText(e.tool) ?? ''
      const keeper = normalizeText(e.keeper) ?? ''
      return `${keeper} -> ${tool}`
    }
    case 'tool_usage': {
      const tool = normalizeText(e.tool_name) ?? ''
      const caller = normalizeText(e.caller) ?? ''
      return `${caller || 'unknown'} -> ${tool}`
    }
    case 'tool_metric': {
      const tool = normalizeText(e.tool_name) ?? ''
      const dur = typeof e.duration_ms === 'number' ? e.duration_ms : null
      return `${tool} ${dur != null ? dur.toFixed(0) + 'ms' : ''}`
    }
    default:
      return JSON.stringify(e).slice(0, 80)
  }
}

function SummaryCard({ src }: { src: TelemetrySourceSummary }) {
  const meta = sourceMeta(src.source)
  const hasData = src.entry_count > 0

  return html`
    <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3 min-w-[140px]">
      <div class="flex items-center gap-2 mb-1">
        <span class="font-mono font-bold ${meta.color}">${meta.icon}</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${meta.label}</span>
      </div>
      <div class="text-2xl font-bold ${hasData ? 'text-[var(--text-strong)]' : 'text-[var(--text-muted)]'}">
        ${src.entry_count.toLocaleString()}
      </div>
      ${src.keeper_count != null ? html`
        <div class="text-xs text-[var(--text-muted)]">${src.keeper_count} keepers</div>
      ` : null}
      ${src.exists === false ? html`
        <div class="text-xs text-[var(--text-muted)] italic">store not found</div>
      ` : null}
    </div>
  `
}

function DiagnosisCard({
  title,
  value,
  detail,
  tone = 'neutral',
}: {
  title: string
  value: string
  detail: string
  tone?: 'neutral' | 'ok' | 'warn'
}) {
  const toneClass =
    tone === 'ok'
      ? 'border-green-500/20 bg-green-500/5'
      : tone === 'warn'
        ? 'border-amber-500/20 bg-amber-500/5'
        : 'border-[var(--card-border)] bg-[rgba(255,255,255,0.02)]'
  return html`
    <div class="rounded-lg border ${toneClass} p-3 min-w-[180px]">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">${title}</div>
      <div class="mt-1 text-xl font-bold text-[var(--text-strong)]">${value}</div>
      <div class="mt-1 text-[11px] leading-relaxed text-[var(--text-muted)]">${detail}</div>
    </div>
  `
}

function EntryRow({ entry }: { entry: TelemetryEntry }) {
  const expanded = useSignal(false)
  const meta = sourceMeta(entry.source)
  const ts = entryTimestamp(entry)
  const success = entry.success as boolean | undefined
  const scopeBadges = telemetryScopeBadges(entry)

  return html`
    <div class="border-b border-[var(--card-border)] hover:bg-[var(--bg-panel-hover)] transition-colors">
      <div
        class="flex items-center gap-2 px-3 py-1.5 text-xs cursor-pointer select-none"
        role="button"
        tabIndex=${0}
        onClick=${() => { expanded.value = !expanded.value }}
        onKeyDown=${(e: KeyboardEvent) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            expanded.value = !expanded.value
          }
        }}
      >
        <span class="font-mono font-bold ${meta.color} w-4 text-center flex-shrink-0">${meta.icon}</span>
        <span class="font-mono text-[var(--text-muted)] w-28 flex-shrink-0" title=${formatTs(ts)}>
          ${timeAgo(ts)}
        </span>
        ${success != null ? html`
          <span class="flex-shrink-0 w-4 ${success ? 'text-green-400' : 'text-red-400'}">
            ${success ? 'O' : 'X'}
          </span>
        ` : html`<span class="w-4"></span>`}
        <span class="font-mono text-[var(--text-strong)] truncate flex-1" title=${entryPreview(entry)}>
          ${entryPreview(entry)}
        </span>
        ${scopeBadges.length > 0 ? html`
          <span class="hidden xl:flex items-center gap-1 flex-shrink-0">
            ${scopeBadges.map(badge => html`<span class="rounded bg-[var(--white-4)] px-1.5 py-0.5 text-[10px] text-[var(--text-dim)] font-mono">${badge}</span>`)}
          </span>
        ` : null}
        <span class="flex-shrink-0 w-4 text-[var(--text-muted)]">${expanded.value ? '-' : '+'}</span>
      </div>
      ${expanded.value ? html`
        <div class="px-3 pb-3 flex flex-col gap-2">
          ${scopeBadges.length > 0 ? html`
            <div class="flex flex-wrap gap-1.5">
              ${scopeBadges.map(badge => html`<span class="rounded bg-[var(--white-4)] px-2 py-1 text-[10px] text-[var(--text-dim)] font-mono">${badge}</span>`)}
            </div>
          ` : null}
          <pre class="text-[10px] font-mono text-[var(--text-muted)] bg-[rgba(0,0,0,0.3)] rounded p-2 overflow-x-auto max-h-[300px] overflow-y-auto whitespace-pre-wrap break-all">
${JSON.stringify(entry, null, 2)}</pre>
        </div>
      ` : null}
    </div>
  `
}

function filterWorkerRuns(
  runs: DashboardProofWorkerRunEvidence[],
  sessionId: string,
  operationId: string,
  workerRunId: string,
): DashboardProofWorkerRunEvidence[] {
  return runs.filter(item => {
    if (sessionId && item.session_id !== sessionId) return false
    if (operationId && item.operation_id !== operationId) return false
    if (workerRunId && item.worker_run_id !== workerRunId) return false
    return true
  })
}

function mismatchCount(items: DashboardProofWorkerRunEvidence[]): number {
  return items.filter(item =>
    (item.requested_model && item.resolved_model && item.requested_model !== item.resolved_model)
    || (item.requested_runtime && item.resolved_runtime && item.requested_runtime !== item.resolved_runtime)
  ).length
}

export function TelemetryUnified() {
  const params = route.value.params
  const state = useSignal<TelemetryState>({
    entries: [],
    summary: [],
    totalEntries: 0,
    proofWorkerRuns: [],
    proofSourceLabel: null,
    loading: true,
    error: null,
  })
  const sourceFilter = useSignal<TelemetrySource | ''>('')
  const keeperFilter = useSignal('')
  const sessionFilter = useSignal(params.session_id ?? '')
  const operationFilter = useSignal(params.operation_id ?? '')
  const workerRunFilter = useSignal(params.worker_run_id ?? '')
  const limit = useSignal(100)

  useEffect(() => {
    sessionFilter.value = route.value.params.session_id ?? ''
    operationFilter.value = route.value.params.operation_id ?? ''
    workerRunFilter.value = route.value.params.worker_run_id ?? ''
  }, [
    route.value.params.session_id,
    route.value.params.operation_id,
    route.value.params.worker_run_id,
  ])

  async function load() {
    state.value = { ...state.value, loading: true, error: null }
    try {
      const telemetryPromise = fetchTelemetry({
        source: sourceFilter.value || undefined,
        keeper: keeperFilter.value || undefined,
        session_id: sessionFilter.value || undefined,
        operation_id: operationFilter.value || undefined,
        worker_run_id: workerRunFilter.value || undefined,
        n: limit.value,
      })
      const summaryPromise = fetchTelemetrySummary()
      const proofPromise =
        sessionFilter.value || operationFilter.value
          ? fetchDashboardProof(sessionFilter.value || null, operationFilter.value || null)
          : Promise.resolve(null)
      const [telemetry, summary, proof] = await Promise.all([
        telemetryPromise,
        summaryPromise,
        proofPromise,
      ])
      const proofWorkerRuns = filterWorkerRuns(
        Array.isArray(proof?.worker_run_evidence) ? proof?.worker_run_evidence ?? [] : [],
        sessionFilter.value,
        operationFilter.value,
        workerRunFilter.value,
      )
      state.value = {
        entries: telemetry.entries,
        summary: summary.sources,
        totalEntries: summary.total_entries,
        proofWorkerRuns,
        proofSourceLabel:
          proof
            ? `OAS proof bridge · ${(proof.session_id ?? sessionFilter.value) || '-'}${proof.operation_id ? ` · ${proof.operation_id}` : ''}`
            : null,
        loading: false,
        error: null,
      }
    } catch (e) {
      state.value = {
        ...state.value,
        loading: false,
        error: e instanceof Error ? e.message : String(e),
      }
    }
  }

  useEffect(() => { void load() }, [
    sourceFilter.value,
    keeperFilter.value,
    sessionFilter.value,
    operationFilter.value,
    workerRunFilter.value,
    limit.value,
  ])

  const { entries, summary, totalEntries, proofWorkerRuns, proofSourceLabel, loading, error } = state.value
  const validationCount = proofWorkerRuns.filter(item => (item.validation_failures?.length ?? 0) > 0).length
  const traceReadyCount = proofWorkerRuns.filter(item => item.trace_evidence_status === 'available').length
  const proofReadyCount = proofWorkerRuns.filter(item => item.proof_evidence_status === 'available').length
  const toolSurfaceMissingCount = proofWorkerRuns.filter(item => item.tool_surface_status === 'missing').length
  const routingFallbackCount = proofWorkerRuns.filter(item => (item.routing_reason ?? '').toLowerCase().includes('fallback')).length
  const resolutionMismatchCount = mismatchCount(proofWorkerRuns)

  return html`
    <div class="flex flex-col gap-4">
      <div class="rounded-xl border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-4">
        <div class="text-[12px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">Runtime Diagnosis</div>
        <div class="mt-1 text-[14px] leading-relaxed text-[var(--text-body)]">
          MASC telemetry store와 OAS proof bridge를 분리해서 보여줍니다. 저장소를 섞지 않고, UI에서만 한 화면으로 합성합니다.
        </div>
        <div class="mt-3 flex flex-wrap gap-2">
          <span class="rounded-md bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-dim)]">MASC: keeper/tool/agent store</span>
          <span class="rounded-md bg-[rgba(245,158,11,0.12)] px-2 py-1 text-[11px] text-amber-300">OAS: proof/runtime evidence bridge</span>
          ${sessionFilter.value ? html`<span class="rounded-md bg-[var(--white-4)] px-2 py-1 text-[11px] font-mono text-[var(--text-dim)]">session ${sessionFilter.value}</span>` : null}
          ${operationFilter.value ? html`<span class="rounded-md bg-[var(--white-4)] px-2 py-1 text-[11px] font-mono text-[var(--text-dim)]">operation ${operationFilter.value}</span>` : null}
          ${workerRunFilter.value ? html`<span class="rounded-md bg-[var(--white-4)] px-2 py-1 text-[11px] font-mono text-[var(--text-dim)]">worker_run ${workerRunFilter.value}</span>` : null}
        </div>
      </div>

      <div class="flex flex-wrap gap-3">
        ${summary.map(src => html`<${SummaryCard} src=${src} />`)}
        <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3 min-w-[140px]">
          <div class="text-xs font-medium text-[var(--text-muted)] mb-1">Total</div>
          <div class="text-2xl font-bold text-[var(--text-strong)]">${totalEntries.toLocaleString()}</div>
        </div>
      </div>

      <div class="flex items-center gap-3 flex-wrap">
        <select
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${sourceFilter.value}
          onChange=${(e: Event) => { sourceFilter.value = (e.target as HTMLSelectElement).value as TelemetrySource | '' }}
        >
          <option value="">All sources</option>
          ${Object.entries(SOURCE_META).map(([key, m]) => html`<option value=${key}>${m.label}</option>`)}
        </select>
        <input
          type="text"
          placeholder="Keeper name..."
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-32"
          value=${keeperFilter.value}
          onInput=${(e: Event) => { keeperFilter.value = (e.target as HTMLInputElement).value }}
        />
        <input
          type="text"
          placeholder="session_id"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${sessionFilter.value}
          onInput=${(e: Event) => { sessionFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="text"
          placeholder="operation_id"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${operationFilter.value}
          onInput=${(e: Event) => { operationFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="text"
          placeholder="worker_run_id"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${workerRunFilter.value}
          onInput=${(e: Event) => { workerRunFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <select
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${String(limit.value)}
          onChange=${(e: Event) => { limit.value = Number((e.target as HTMLSelectElement).value) }}
        >
          <option value="50">50</option>
          <option value="100">100</option>
          <option value="200">200</option>
          <option value="500">500</option>
        </select>
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void load()}
        >
          Refresh
        </button>
        ${loading ? html`<span class="text-xs text-[var(--text-muted)]">loading...</span>` : null}
      </div>

      <div class="flex flex-wrap gap-3">
        <${DiagnosisCard}
          title="OAS Proof Bridge"
          value=${String(proofWorkerRuns.length)}
          detail=${proofSourceLabel ?? 'session_id 또는 operation_id를 고르면 OAS runtime/proof evidence를 별도 브리지로 읽습니다.'}
          tone=${proofWorkerRuns.length > 0 ? 'ok' : 'neutral'}
        />
        <${DiagnosisCard}
          title="Provider Resolve"
          value=${String(resolutionMismatchCount)}
          detail=${proofWorkerRuns.length > 0
            ? `requested/resolved 불일치 ${resolutionMismatchCount}건 · routing fallback ${routingFallbackCount}건`
            : '현재 scope에 연결된 worker run evidence 없음'}
          tone=${resolutionMismatchCount > 0 || routingFallbackCount > 0 ? 'warn' : 'neutral'}
        />
        <${DiagnosisCard}
          title="Validation Failure"
          value=${String(validationCount)}
          detail=${proofWorkerRuns.length > 0
            ? `trace evidence ${traceReadyCount}건 · proof evidence ${proofReadyCount}건`
            : '검증 대상 worker run evidence 없음'}
          tone=${validationCount > 0 ? 'warn' : 'ok'}
        />
        <${DiagnosisCard}
          title="Tool Surface"
          value=${String(toolSurfaceMissingCount)}
          detail=${proofWorkerRuns.length > 0
            ? `tool surface missing ${toolSurfaceMissingCount}건`
            : 'OAS worker scope가 없어서 tool surface를 아직 비교하지 않았습니다.'}
          tone=${toolSurfaceMissingCount > 0 ? 'warn' : 'ok'}
        />
      </div>

      ${proofWorkerRuns.length > 0 ? html`
        <div class="rounded-xl border border-amber-500/20 bg-amber-500/5 p-4">
          <div class="text-[12px] font-semibold uppercase tracking-wider text-amber-300">OAS Runtime Bridge</div>
          <div class="mt-2 grid gap-2">
            ${proofWorkerRuns.map(item => html`
              <div class="rounded-lg border border-white/10 bg-black/10 p-3">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-[12px] font-semibold text-[var(--text-strong)]">${item.worker_name ?? item.worker_run_id}</span>
                  <span class="rounded bg-white/5 px-1.5 py-0.5 text-[10px] font-mono text-[var(--text-dim)]">${item.worker_run_id}</span>
                  ${item.session_id ? html`<span class="rounded bg-white/5 px-1.5 py-0.5 text-[10px] font-mono text-[var(--text-dim)]">S ${item.session_id}</span>` : null}
                  ${item.operation_id ? html`<span class="rounded bg-white/5 px-1.5 py-0.5 text-[10px] font-mono text-[var(--text-dim)]">OP ${item.operation_id}</span>` : null}
                </div>
                <div class="mt-2 text-[12px] leading-relaxed text-[var(--text-body)]">
                  요청 runtime/model: ${item.requested_runtime ?? '-'} / ${item.requested_model ?? '-'}<br />
                  해석 runtime/model: ${item.resolved_runtime ?? '-'} / ${item.resolved_model ?? '-'}<br />
                  trace/proof: ${item.trace_evidence_status ?? '-'} / ${item.proof_evidence_status ?? '-'}<br />
                  validation: ${(item.validation_failures ?? []).length > 0 ? item.validation_failures?.join(' · ') : '없음'}
                </div>
              </div>
            `)}
          </div>
        </div>
      ` : null}

      ${error ? html`
        <div class="rounded border border-red-500/30 bg-red-500/10 px-3 py-2 text-xs text-red-400">
          ${error}
        </div>
      ` : null}

      <div class="rounded-xl border border-[var(--card-border)] overflow-hidden">
        <div class="px-3 py-2 border-b border-[var(--card-border)] bg-[var(--white-3)] text-xs text-[var(--text-muted)]">
          MASC telemetry store entries ${entries.length.toLocaleString()}건
        </div>
        <div class="max-h-[600px] overflow-y-auto">
          ${entries.length > 0
            ? entries.map(entry => html`<${EntryRow} entry=${entry} />`)
            : html`<div class="px-4 py-6 text-sm text-[var(--text-muted)]">선택한 scope에 해당하는 MASC telemetry entry가 없습니다.</div>`}
        </div>
      </div>
    </div>
  `
}
