// MASC Dashboard — Prometheus Metrics Surface
// Fetches /metrics (Prometheus text format) and renders as categorized tables.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { TextInput } from './common/input'
import { fetchWithTimeout, authHeaders } from '../api/core'
import { navigate } from '../router'
import { TimeAgo } from './common/time-ago'

// --- Prometheus text format parser ---

interface ParsedMetric {
  name: string
  help: string
  type: string
  samples: MetricSample[]
}

interface MetricSample {
  name: string
  labels: Record<string, string>
  value: number
}

export function parsePrometheusText(text: string): ParsedMetric[] {
  const metrics: ParsedMetric[] = []
  const lines = text.split('\n')
  let current: ParsedMetric | null = null

  for (const line of lines) {
    const trimmed = line.trim()
    if (!trimmed) continue

    if (trimmed.startsWith('# HELP ')) {
      const rest = trimmed.slice(7)
      const spaceIdx = rest.indexOf(' ')
      const name = spaceIdx > 0 ? rest.slice(0, spaceIdx) : rest
      const help = spaceIdx > 0 ? rest.slice(spaceIdx + 1) : ''
      current = { name, help, type: 'untyped', samples: [] }
      metrics.push(current)
      continue
    }

    if (trimmed.startsWith('# TYPE ')) {
      const rest = trimmed.slice(7)
      const spaceIdx = rest.indexOf(' ')
      if (current && spaceIdx > 0) {
        current.type = rest.slice(spaceIdx + 1)
      }
      continue
    }

    if (trimmed.startsWith('#')) continue

    // Sample line: metric_name{label="value"} 123.45
    const sample = parseSampleLine(trimmed)
    if (sample && current) {
      current.samples.push(sample)
    }
  }

  return metrics
}

function parseSampleLine(line: string): MetricSample | null {
  let name: string
  let labels: Record<string, string> = {}
  let valueStr: string

  const braceStart = line.indexOf('{')
  if (braceStart >= 0) {
    name = line.slice(0, braceStart)
    const braceEnd = line.indexOf('}', braceStart)
    if (braceEnd < 0) return null
    labels = parseLabels(line.slice(braceStart + 1, braceEnd))
    valueStr = line.slice(braceEnd + 1).trim()
  } else {
    const parts = line.split(/\s+/)
    if (parts.length < 2 || !parts[0] || !parts[1]) return null
    name = parts[0]
    valueStr = parts[1]
  }

  const value = Number(valueStr)
  if (Number.isNaN(value)) return null
  return { name, labels, value }
}

function parseLabels(raw: string): Record<string, string> {
  const labels: Record<string, string> = {}
  const re = /(\w+)="([^"]*)"/g
  let m: RegExpExecArray | null
  while ((m = re.exec(raw)) !== null) {
    if (m[1] && m[2] !== undefined) labels[m[1]] = m[2]
  }
  return labels
}

// --- Categorization ---

type MetricCategory = 'server' | 'agent' | 'keeper' | 'transport' | 'inference' | 'tool' | 'delta' | 'provider' | 'other'

export function categorize(name: string): MetricCategory {
  if (name.startsWith('masc_keeper_')) return 'keeper'
  if (name.startsWith('masc_agent_')) return 'agent'
  if (name.startsWith('masc_sse_') || name.startsWith('masc_grpc_') || name.startsWith('masc_ws_')) return 'transport'
  if (name.startsWith('masc_inference_') || name.startsWith('masc_llm_')) return 'inference'
  if (name.startsWith('masc_tool_')) return 'tool'
  if (name.startsWith('masc_delta_') || name.startsWith('masc_full_checkpoint')) return 'delta'
  if (name.startsWith('masc_provider_')) return 'provider'
  if (name.startsWith('masc_mcp_') || name.startsWith('masc_uptime') || name.startsWith('masc_tasks') || name.startsWith('masc_errors') || name.startsWith('masc_active') || name.startsWith('masc_pending')) return 'server'
  return 'other'
}

const CATEGORY_META: Record<MetricCategory, { label: string; description: string }> = {
  server: { label: 'Server', description: 'requests, tasks, errors, uptime' },
  agent: { label: 'Agent', description: 'agent heartbeat age, stale detection' },
  keeper: { label: 'Keeper', description: 'compaction, heartbeat (per-keeper labels)' },
  transport: { label: 'Transport', description: 'SSE, gRPC, WebSocket connections/sessions' },
  inference: { label: 'Inference', description: 'LLM duration, admission queue' },
  tool: { label: 'Tool', description: 'tool call duration' },
  delta: { label: 'Delta Checkpoint', description: 'checkpoint size, shadow match' },
  provider: { label: 'Provider', description: 'prefix cache tokens, HTTP status' },
  other: { label: 'Other', description: 'uncategorized (report as bug)' },
}

// --- Formatting ---

function fmtValue(value: number, type: string, name: string): string {
  if (name.includes('seconds') || name.includes('duration')) {
    if (value === 0) return '0s'
    if (value < 0.001) return `${(value * 1_000_000).toFixed(0)}us`
    if (value < 1) return `${(value * 1000).toFixed(1)}ms`
    if (value < 60) return `${value.toFixed(2)}s`
    return `${(value / 60).toFixed(1)}m`
  }
  if (name.includes('bytes')) {
    if (value === 0) return '0B'
    if (value < 1024) return `${value.toFixed(0)}B`
    if (value < 1048576) return `${(value / 1024).toFixed(1)}KB`
    return `${(value / 1048576).toFixed(1)}MB`
  }
  if (type === 'gauge' && !Number.isInteger(value)) return value.toFixed(4)
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`
  return String(value)
}

function typeBadge(type: string): ReturnType<typeof html> {
  const colors: Record<string, string> = {
    counter: 'bg-[var(--accent-10)] text-[var(--accent)]',
    gauge: 'bg-[var(--ok-10)] text-[var(--ok)]',
    summary: 'bg-[var(--warn-10)] text-[var(--warn)]',
  }
  return html`<span class="inline-block rounded px-1.5 py-0.5 text-3xs font-mono ${colors[type] ?? 'bg-[var(--white-5)] text-[var(--text-muted)]'}">${type}</span>`
}

function labelPills(labels: Record<string, string>): ReturnType<typeof html> | null {
  const entries = Object.entries(labels)
  if (entries.length === 0) return null
  return html`<span class="ml-2 inline-flex gap-1 flex-wrap">${entries.map(([k, v]) => {
    if (k === 'keeper') {
      return html`<button type="button"
        class="rounded bg-[var(--accent-10)] px-1 py-0.5 text-3xs text-[var(--accent)] font-mono hover:bg-[var(--accent-10)] hover:text-[var(--accent)] transition-colors cursor-pointer"
        title="View keeper detail"
        onClick=${(e: Event) => {
          e.stopPropagation()
          navigate('monitoring', { section: 'agents', keeper: v })
        }}
      >${k}=${v}</button>`
    }
    if (k === 'tool_name' || k === 'tool') {
      return html`<button type="button"
        class="rounded bg-[var(--warn-10)] px-1 py-0.5 text-3xs text-[var(--warn)] font-mono hover:bg-[var(--warn-10)] hover:text-[var(--warn)] transition-colors cursor-pointer"
        title="View tool quality"
        onClick=${(e: Event) => {
          e.stopPropagation()
          navigate('monitoring', { section: 'fleet-health', view: 'tool-quality', tool: v })
        }}
      >${k}=${v}</button>`
    }
    return html`<span class="rounded bg-[var(--white-5)] px-1 py-0.5 text-3xs text-[var(--text-muted)] font-mono">${k}=${v}</span>`
  })}</span>`
}

// --- Fetch ---

async function fetchPrometheusText(signal?: AbortSignal): Promise<string> {
  const res = await fetchWithTimeout(
    '/metrics',
    { headers: authHeaders(), signal },
    10_000,
  )
  if (!res.ok) throw new Error(`/metrics returned ${res.status}`)
  return res.text()
}

// --- Search helpers ---

export function metricMatchesSearch(m: ParsedMetric, q: string): boolean {
  const lower = q.toLowerCase()
  if (m.name.toLowerCase().includes(lower)) return true
  if (m.help.toLowerCase().includes(lower)) return true
  return m.samples.some(s =>
    s.name.toLowerCase().includes(lower) ||
    Object.values(s.labels).some(v => v.toLowerCase().includes(lower)),
  )
}

// --- Component ---

export function PrometheusMetrics() {
  const loading = useSignal(true)
  const error = useSignal<string | null>(null)
  const metrics = useSignal<ParsedMetric[]>([])
  const lastUpdated = useSignal<number | null>(null)
  const searchQuery = useSignal('')
  const expandedCategories = useSignal<Set<MetricCategory>>(new Set(['server', 'agent', 'keeper', 'inference']))

  async function refresh() {
    loading.value = true
    error.value = null
    try {
      const text = await fetchPrometheusText()
      metrics.value = parsePrometheusText(text)
      lastUpdated.value = Date.now()
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  useEffect(() => { void refresh() }, [])

  if (loading.value && metrics.value.length === 0) {
    return html`<${LoadingState} label="Prometheus /metrics" />`
  }

  if (error.value && metrics.value.length === 0) {
    return html`<${ErrorState} message=${error.value} onRetry=${refresh} />`
  }

  if (metrics.value.length === 0) {
    return html`<${EmptyState} message="No metrics available" />`
  }

  // Group by category (filtered if search active)
  const query = searchQuery.value.trim().toLowerCase()
  const filteredMetrics = query
    ? metrics.value.filter(m => metricMatchesSearch(m, query))
    : metrics.value

  const grouped = new Map<MetricCategory, ParsedMetric[]>()
  for (const m of filteredMetrics) {
    const cat = categorize(m.name)
    const list = grouped.get(cat) ?? []
    list.push(m)
    grouped.set(cat, list)
  }

  // Auto-expand categories when searching
  if (query) {
    const expanded = new Set<MetricCategory>()
    for (const cat of grouped.keys()) expanded.add(cat)
    if (expandedCategories.value !== expanded) expandedCategories.value = expanded
  }

  // Summary stats
  const totalMetrics = filteredMetrics.length
  const totalSamples = filteredMetrics.reduce((sum, m) => sum + m.samples.length, 0)
  const nonZeroSamples = filteredMetrics.reduce(
    (sum, m) => sum + m.samples.filter(s => s.value !== 0).length,
    0,
  )

  function toggleCategory(cat: MetricCategory) {
    const next = new Set(expandedCategories.value)
    if (next.has(cat)) next.delete(cat)
    else next.add(cat)
    expandedCategories.value = next
  }

  const categoryOrder: MetricCategory[] = ['server', 'agent', 'keeper', 'transport', 'inference', 'tool', 'delta', 'provider', 'other']

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-lg font-semibold text-[var(--text-heading)]">Prometheus Metrics</h2>
          <p class="text-xs text-[var(--text-muted)]">
            /metrics endpoint (${totalMetrics} metrics, ${totalSamples} samples, ${nonZeroSamples} active)
          </p>
        </div>
        <div class="flex items-center gap-3">
          ${lastUpdated.value && html`<span class="text-xs text-[var(--text-muted)]"><${TimeAgo} timestamp=${lastUpdated.value} /></span>`}
          <button type="button"
            class="rounded border border-[var(--card-border)] bg-[var(--bg-1)] px-3 py-1.5 text-xs text-[var(--text-body)] hover:bg-[var(--bg-2)] transition-colors"
            aria-label="Prometheus 메트릭 새로고침"
            onClick=${refresh}
            disabled=${loading.value}
          >
            ${loading.value ? 'Loading...' : 'Refresh'}
          </button>
        </div>
      </div>

      ${error.value && html`
        <div class="rounded bg-[var(--bad-10)] border border-[var(--bad-20)] px-3 py-2 text-xs text-[var(--bad-light)]" role="alert">
          ${error.value}
        </div>
      `}

      <${TextInput}
        class="max-w-75"
        placeholder="검색 (메트릭 이름, 라벨...)"
        ariaLabel="메트릭 검색"
        value=${searchQuery.value}
        onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
      />

      ${query && html`
        <span class="text-xs text-[var(--text-muted)]" role="status">
          ${totalMetrics} / ${metrics.value.length} 메트릭 일치
        </span>
      `}

      ${totalMetrics === 0 && query ? html`
        <${EmptyState} message="조건에 맞는 메트릭이 없습니다." />
      ` : null}

      ${categoryOrder.filter(cat => grouped.has(cat)).map(cat => {
        const catMetrics = grouped.get(cat)!
        const meta = CATEGORY_META[cat]
        const expanded = expandedCategories.value.has(cat)
        const activeSamples = catMetrics.reduce(
          (sum, m) => sum + m.samples.filter(s => s.value !== 0).length,
          0,
        )

        return html`
          <${Card}>
            <button type="button"
              class="flex w-full items-center justify-between text-left"
              aria-expanded=${expanded}
              onClick=${() => toggleCategory(cat)}
            >
              <div class="flex items-center gap-2">
                <span class="text-xs font-mono ${expanded ? 'text-[var(--text-body)]' : 'text-[var(--text-muted)]'}" aria-hidden="true">${expanded ? '▼' : '▶'}</span>
                <span class="font-medium text-[var(--text-heading)]">${meta.label}</span>
                <span class="text-xs text-[var(--text-muted)]">${meta.description}</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="rounded-sm bg-[var(--bg-2)] px-2 py-0.5 text-3xs text-[var(--text-muted)]">
                  ${catMetrics.length} metrics
                </span>
                ${activeSamples > 0 && html`
                  <span class="rounded-sm bg-[var(--ok-10)] px-2 py-0.5 text-3xs text-[var(--ok)]">
                    ${activeSamples} active
                  </span>
                `}
              </div>
            </button>

            ${expanded && html`
              <div class="mt-3 overflow-x-auto">
                <table class="w-full text-xs" aria-label="Prometheus 메트릭 시계열">
                  <thead>
                    <tr class="border-b border-[var(--card-border)] text-[var(--text-muted)]">
                      <th scope="col" class="pb-2 text-left font-normal">Metric</th>
                      <th scope="col" class="pb-2 text-left font-normal w-16">Type</th>
                      <th scope="col" class="pb-2 text-right font-normal w-24">Value</th>
                    </tr>
                  </thead>
                  <tbody>
                    ${catMetrics.flatMap(m =>
                      m.samples.length === 0
                        ? [html`
                            <tr key="${m.name}" class="border-b border-[var(--card-border)]/30 hover:bg-[var(--bg-1)]">
                              <td class="py-1.5 font-mono text-[var(--text-body)]">
                                ${m.name}
                                <div class="text-3xs text-[var(--text-muted)] font-sans">${m.help}</div>
                              </td>
                              <td class="py-1.5">${typeBadge(m.type)}</td>
                              <td class="py-1.5 text-right text-[var(--text-muted)]">--</td>
                            </tr>
                          `]
                        : m.samples.map((s, i) => html`
                            <tr key="${s.name}-${i}" class="border-b border-[var(--card-border)]/30 hover:bg-[var(--bg-1)]">
                              <td class="py-1.5 font-mono ${s.value !== 0 ? 'text-[var(--text-body)]' : 'text-[var(--text-muted)]'}">
                                ${s.name}${labelPills(s.labels)}
                                ${i === 0 && html`<div class="text-3xs text-[var(--text-muted)] font-sans">${m.help}</div>`}
                              </td>
                              <td class="py-1.5">${i === 0 ? typeBadge(m.type) : null}</td>
                              <td class="py-1.5 text-right font-mono tabular-nums ${s.value !== 0 ? 'text-[var(--ok)]' : 'text-[var(--text-muted)]'}">
                                ${fmtValue(s.value, m.type, s.name)}
                              </td>
                            </tr>
                          `)
                    )}
                  </tbody>
                </table>
              </div>
            `}
          <//>
        `
      })}
    </div>
  `
}
