import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { LoadingState } from './common/feedback-state'
import { MermaidGraph } from './common/mermaid-graph'
import {
  fetchMemorySubsystems,
  type MemorySubsystemsResponse,
  type MemorySubsystemsSynapse,
  type MemorySubsystemsEpisode,
} from '../api/dashboard'
import { formatTimeAgo } from '../lib/format-time'
import { isAbortError } from '../lib/async-state'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { openAgentDetail } from './agent-detail-state'

const REFRESH_MS = 30_000

const ARCHITECTURE_FLOW = `graph LR
    subgraph Keeper["Keeper Turn"]
      K1[LLM 응답 생성] --> K2["[STATE] 파싱"]
      K2 --> K3{STATE 있음?}
    end

    K3 -->|Yes| M1[store_episode_from_snapshot]
    M1 --> M2[Memory.t in-memory]
    M2 --> M3[flush_incremental]
    M3 --> F1[(institution_episodes.jsonl)]
    F1 -->|cap 500| F1

    subgraph Task["Task Completion"]
      T1[keeper_task_done] --> T2[transition_task_r]
      T2 --> T3[Done_action 분기]
    end

    T3 --> H1[hebbian_on_task_done_fn]
    H1 --> H2["List.iter: strengthen per peer"]
    H2 --> G1[(graph.json)]

    subgraph Dashboard["Dashboard"]
      D1[fetchMemorySubsystems]
    end

    F1 --> D1
    G1 --> D1
    D1 --> UI[기억 서브시스템 패널]

    classDef store fill:#1e293b,stroke:#334155,color:#f1f5f9
    classDef action fill:#0f766e,stroke:#14b8a6,color:#f0fdfa
    classDef ui fill:#7c2d12,stroke:#f97316,color:#ffedd5
    class F1,G1 store
    class M1,M3,H1,H2,T2 action
    class UI ui`

function HebbianNetwork({ synapses }: { synapses: MemorySubsystemsSynapse[] }) {
  if (synapses.length === 0) return null

  const nodes = new Map<string, number>()
  synapses.forEach(s => {
    nodes.set(s.from_agent, (nodes.get(s.from_agent) ?? 0) + 1)
    nodes.set(s.to_agent, (nodes.get(s.to_agent) ?? 0) + 1)
  })

  const nodeNames = Array.from(nodes.keys())
  const width = 600
  const height = 360
  const cx = width / 2
  const cy = height / 2
  const radius = Math.min(width, height) / 2 - 60

  const positions = new Map<string, { x: number; y: number }>()
  nodeNames.forEach((name, i) => {
    const angle = (i / nodeNames.length) * Math.PI * 2 - Math.PI / 2
    positions.set(name, {
      x: cx + radius * Math.cos(angle),
      y: cy + radius * Math.sin(angle),
    })
  })

  const shortLabel = (name: string) => {
    const trimmed = name.replace(/^keeper-/, '').replace(/-agent$/, '')
    return trimmed.length > 10 ? trimmed.slice(0, 9) + '…' : trimmed
  }

  return html`
    <div class="bg-zinc-900 rounded-lg p-2 overflow-x-auto">
      <svg viewBox="0 0 ${width} ${height}" class="w-full h-auto" style="max-height:400px">
        <defs>
          <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">
            <path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor" class="text-zinc-600" />
          </marker>
        </defs>
        ${synapses.map(s => {
          const from = positions.get(s.from_agent)
          const to = positions.get(s.to_agent)
          if (!from || !to) return null
          const pct = Math.round(s.weight * 100)
          const stroke =
            pct >= 70 ? '#10b981' : pct >= 40 ? '#f59e0b' : '#f87171'
          const sw = Math.max(1, s.weight * 4)
          const dx = to.x - from.x
          const dy = to.y - from.y
          const len = Math.sqrt(dx * dx + dy * dy)
          const ux = dx / len
          const uy = dy / len
          const sx = from.x + ux * 22
          const sy = from.y + uy * 22
          const ex = to.x - ux * 22
          const ey = to.y - uy * 22
          return html`<line
            x1=${sx}
            y1=${sy}
            x2=${ex}
            y2=${ey}
            stroke=${stroke}
            stroke-width=${sw}
            opacity="0.7"
            marker-end="url(#arrow)"
          />`
        })}
        ${nodeNames.map(name => {
          const pos = positions.get(name)!
          const label = shortLabel(name)
          const isKeeper = name.startsWith('keeper-')
          const fill = isKeeper ? '#1e293b' : '#0f172a'
          const stroke = isKeeper ? '#3b82f6' : '#64748b'
          const onNodeClick = () => openAgentDetail(name)
          const onKeyDown = (e: KeyboardEvent) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              openAgentDetail(name)
            }
          }
          return html`
            <g
              class="cursor-pointer hover:opacity-80 transition-opacity"
              role="button"
              tabindex="0"
              onClick=${onNodeClick}
              onKeyDown=${onKeyDown}
              aria-label=${'에이전트 상세 열기: ' + label}
            >
              <circle
                cx=${pos.x}
                cy=${pos.y}
                r="22"
                fill=${fill}
                stroke=${stroke}
                stroke-width="2"
              />
              <text
                x=${pos.x}
                y=${pos.y + 4}
                text-anchor="middle"
                font-size="11"
                fill="#f1f5f9"
                font-family="monospace"
                class="pointer-events-none select-none"
              >
                ${label}
              </text>
            </g>
          `
        })}
      </svg>
    </div>
  `
}

function SynapseRow({ s }: { s: MemorySubsystemsSynapse }) {
  const pct = Math.round(s.weight * 100)
  const barColor =
    pct >= 70 ? 'bg-emerald-500' : pct >= 40 ? 'bg-amber-500' : 'bg-red-400'
  return html`
    <tr class="border-b border-zinc-800">
      <td class="py-1.5 px-2 text-sm font-mono">
        <button
          class="hover:text-sky-400 hover:underline focus:outline-none focus:text-sky-400"
          onClick=${() => openAgentDetail(s.from_agent)}
        >${s.from_agent}</button>
      </td>
      <td class="py-1.5 px-2 text-sm text-zinc-400 text-center">→</td>
      <td class="py-1.5 px-2 text-sm font-mono">
        <button
          class="hover:text-sky-400 hover:underline focus:outline-none focus:text-sky-400"
          onClick=${() => openAgentDetail(s.to_agent)}
        >${s.to_agent}</button>
      </td>
      <td class="py-1.5 px-2 text-sm text-right">
        <div class="flex items-center gap-2 justify-end">
          <div class="w-16 bg-zinc-800 rounded h-1.5">
            <div class="${barColor} rounded h-1.5" style="width:${pct}%"></div>
          </div>
          <span class="text-zinc-300 w-10 text-right">${pct}%</span>
        </div>
      </td>
      <td class="py-1.5 px-2 text-sm text-emerald-400 text-center">${s.success_count}</td>
      <td class="py-1.5 px-2 text-sm text-red-400 text-center">${s.failure_count}</td>
      <td class="py-1.5 px-2 text-xs text-zinc-500">${formatTimeAgo(s.last_updated * 1000)}</td>
    </tr>
  `
}

function EpisodeCard({ ep }: { ep: MemorySubsystemsEpisode }) {
  const outcomeColor =
    ep.outcome === 'success'
      ? 'text-emerald-400'
      : ep.outcome === 'partial'
        ? 'text-amber-400'
        : 'text-red-400'
  const outcomeIcon =
    ep.outcome === 'success' ? '●' : ep.outcome === 'partial' ? '◐' : '○'
  return html`
    <div class="border border-zinc-800 rounded-lg p-3 mb-2 hover:border-zinc-700 transition-colors">
      <div class="flex items-start justify-between gap-2 mb-1">
        <div class="flex items-center gap-2 min-w-0">
          <span class="${outcomeColor} text-xs">${outcomeIcon}</span>
          <span class="text-sm font-medium text-zinc-200 truncate">${ep.summary}</span>
        </div>
        <span class="text-xs text-zinc-500 shrink-0">${formatTimeAgo(ep.timestamp * 1000)}</span>
      </div>
      <div class="flex items-center gap-2 text-xs text-zinc-500 mb-1 flex-wrap">
        <span class="bg-zinc-800 px-1.5 py-0.5 rounded">${ep.event_type}</span>
        ${ep.participants.map(
          (p: string) => html`<span class="font-mono">${p}</span>`,
        )}
        <span class="text-zinc-600 font-mono text-[10px]">${ep.id}</span>
      </div>
      ${
        ep.learnings.length > 0
          ? html`
              <div class="mt-1.5 space-y-0.5">
                ${ep.learnings.map(
                  (l: string) =>
                    html`<div class="text-xs text-zinc-400 pl-3 border-l border-zinc-700">${l}</div>`,
                )}
              </div>
            `
          : null
      }
      ${
        ep.context && Object.keys(ep.context).length > 0
          ? html`
              <div class="mt-1 flex gap-2 flex-wrap">
                ${Object.entries(ep.context).map(
                  ([k, v]) =>
                    html`<span class="text-xs bg-zinc-800/50 px-1.5 py-0.5 rounded text-zinc-500"
                      >${k}: ${v}</span
                    >`,
                )}
              </div>
            `
          : null
      }
    </div>
  `
}

export function MemorySubsystems() {
  const state = useSignal<{
    loading: boolean
    error: string | null
    data: MemorySubsystemsResponse | null
  }>({ loading: true, error: null, data: null })

  const keeperFilter = useSignal<string>('')
  const outcomeFilter = useSignal<string>('')
  const searchQuery = useSignal<string>('')

  async function refresh(signal?: AbortSignal) {
    try {
      const data = await fetchMemorySubsystems({
        limit: 100,
        keeper: keeperFilter.value || undefined,
        outcome: outcomeFilter.value || undefined,
        q: searchQuery.value || undefined,
        signal,
      })
      state.value = { loading: false, error: null, data }
    } catch (err) {
      if (isAbortError(err)) return
      state.value = {
        loading: false,
        error: err instanceof Error ? err.message : String(err),
        data: state.value.data,
      }
    }
  }

  useEffect(() => {
    const ac = new AbortController()
    refresh(ac.signal)
    const cleanup = setupVisibleAutoRefresh(() => refresh(), REFRESH_MS)
    return () => {
      ac.abort()
      cleanup()
    }
  }, [keeperFilter.value, outcomeFilter.value, searchQuery.value])

  const { loading, error, data } = state.value
  if (loading && !data) return html`<${LoadingState} label="기억 서브시스템 로드 중..." />`
  if (error && !data)
    return html`<div class="p-4 text-red-400">Error: ${error}</div>`

  const synapses = data?.hebbian?.synapses ?? []
  const lastConsolidation = data?.hebbian?.last_consolidation ?? 0
  const episodes = data?.episodes?.items ?? []
  const totalEpisodes = data?.episodes?.total ?? 0
  const filteredTotal = data?.episodes?.filtered ?? episodes.length
  const knownKeepers = data?.filters?.keepers ?? []
  const knownOutcomes = data?.filters?.outcomes ?? ['success', 'partial', 'failure']

  const onSearchInput = (e: Event) => {
    const v = (e.target as HTMLInputElement).value
    searchQuery.value = v
  }

  const clearFilters = () => {
    keeperFilter.value = ''
    outcomeFilter.value = ''
    searchQuery.value = ''
  }

  const hasFilter = Boolean(keeperFilter.value || outcomeFilter.value || searchQuery.value)

  const showArch = useSignal(false)

  return html`
    <div class="space-y-6">
      <!-- Architecture Flow (collapsible) -->
      <section>
        <button
          onClick=${() => (showArch.value = !showArch.value)}
          class="w-full flex items-center justify-between p-2 bg-zinc-900 rounded-lg hover:bg-zinc-800 transition-colors"
        >
          <span class="text-sm font-semibold text-zinc-200 flex items-center gap-2">
            <span class="text-xs">${showArch.value ? '▼' : '▶'}</span>
            아키텍처 — 데이터 흐름도
          </span>
          <span class="text-xs text-zinc-500">
            Keeper turn → Memory.t → JSONL / task_done → Hebbian → graph.json
          </span>
        </button>
        ${
          showArch.value
            ? html`
                <div class="mt-2 bg-zinc-900 rounded-lg p-3">
                  <${MermaidGraph}
                    source=${ARCHITECTURE_FLOW}
                    prefix="memory-arch"
                    minHeightClass="min-h-[320px]"
                  />
                </div>
              `
            : null
        }
      </section>

      <!-- Hebbian Synapses -->
      <section>
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-base font-semibold text-zinc-200">Hebbian 시냅스 그래프</h3>
          <div class="flex items-center gap-3 text-xs text-zinc-500">
            <span>${synapses.length}개 시냅스</span>
            ${
              lastConsolidation > 0
                ? html`<span>마지막 통합: ${formatTimeAgo(lastConsolidation * 1000)}</span>`
                : null
            }
          </div>
        </div>
        ${
          synapses.length > 0
            ? html`<div class="mb-3"><${HebbianNetwork} synapses=${synapses} /></div>`
            : null
        }
        ${
          synapses.length === 0
            ? html`<div class="text-sm text-zinc-500 bg-zinc-900 rounded-lg p-4 text-center">
                시냅스 데이터 없음. keeper task 완료 시 자동 생성됩니다.
              </div>`
            : html`
                <div class="overflow-x-auto">
                  <table class="w-full text-left">
                    <thead>
                      <tr class="border-b border-zinc-700 text-xs text-zinc-500">
                        <th class="py-1.5 px-2">From</th>
                        <th class="py-1.5 px-2"></th>
                        <th class="py-1.5 px-2">To</th>
                        <th class="py-1.5 px-2 text-right">Weight</th>
                        <th class="py-1.5 px-2 text-center">성공</th>
                        <th class="py-1.5 px-2 text-center">실패</th>
                        <th class="py-1.5 px-2">마지막</th>
                      </tr>
                    </thead>
                    <tbody>
                      ${synapses.map(
                        (s: MemorySubsystemsSynapse) => html`<${SynapseRow} s=${s} />`,
                      )}
                    </tbody>
                  </table>
                </div>
              `
        }
      </section>

      <!-- Episodes -->
      <section>
        <div class="flex items-center justify-between mb-3 flex-wrap gap-2">
          <h3 class="text-base font-semibold text-zinc-200">에피소드 기록</h3>
          <span class="text-xs text-zinc-500">
            총 ${totalEpisodes}개 · 필터 ${filteredTotal}개 · 표시 ${episodes.length}개
          </span>
        </div>

        <!-- Filter Bar -->
        <div class="flex items-center gap-2 mb-3 flex-wrap">
          <input
            type="text"
            placeholder="검색 (summary, learnings, event_type...)"
            value=${searchQuery.value}
            onInput=${onSearchInput}
            class="flex-1 min-w-[200px] bg-zinc-900 border border-zinc-700 rounded px-2 py-1 text-sm text-zinc-200 placeholder:text-zinc-600 focus:border-zinc-500 focus:outline-none"
          />
          <select
            value=${keeperFilter.value}
            onChange=${(e: Event) => (keeperFilter.value = (e.target as HTMLSelectElement).value)}
            class="bg-zinc-900 border border-zinc-700 rounded px-2 py-1 text-sm text-zinc-200 focus:border-zinc-500 focus:outline-none"
          >
            <option value="">모든 키퍼</option>
            ${knownKeepers.map(
              (k: string) => html`<option value=${k}>${k}</option>`,
            )}
          </select>
          <select
            value=${outcomeFilter.value}
            onChange=${(e: Event) => (outcomeFilter.value = (e.target as HTMLSelectElement).value)}
            class="bg-zinc-900 border border-zinc-700 rounded px-2 py-1 text-sm text-zinc-200 focus:border-zinc-500 focus:outline-none"
          >
            <option value="">모든 결과</option>
            ${knownOutcomes.map(
              (o: string) => html`<option value=${o}>${o}</option>`,
            )}
          </select>
          ${
            hasFilter
              ? html`<button
                  onClick=${clearFilters}
                  class="text-xs text-zinc-400 hover:text-zinc-200 px-2 py-1 border border-zinc-700 rounded hover:border-zinc-500"
                >
                  필터 해제
                </button>`
              : null
          }
        </div>

        ${
          episodes.length === 0
            ? html`<div class="text-sm text-zinc-500 bg-zinc-900 rounded-lg p-4 text-center">
                ${hasFilter
                  ? '필터 조건에 맞는 에피소드가 없습니다.'
                  : '에피소드 없음. keeper [STATE] 출력 시 자동 기록됩니다.'}
              </div>`
            : html`
                <div class="space-y-1">
                  ${episodes
                    .slice()
                    .reverse()
                    .map(
                      (ep: MemorySubsystemsEpisode) =>
                        html`<${EpisodeCard} ep=${ep} />`,
                    )}
                </div>
              `
        }
      </section>

      ${
        error
          ? html`<div class="text-xs text-amber-500 mt-2">refresh error: ${error}</div>`
          : null
      }
    </div>
  `
}
