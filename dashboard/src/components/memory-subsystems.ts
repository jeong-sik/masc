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

const shortAgentLabel = (name: string) => {
  const trimmed = name.replace(/^keeper-/, '').replace(/-agent$/, '')
  return trimmed.length > 12 ? trimmed.slice(0, 11) + '…' : trimmed
}

// --- Hebbian visualization constants (SSOT) ---------------------------------
// Arbitrary values — see #7094 for rationale and tuning guidance.

// Weight ramp: single definition drives color, Tailwind bar class, and legend.
// Sorted descending so the first match wins. Add/remove tiers here and the
// entire file follows.
const WEIGHT_RAMP: ReadonlyArray<{
  floor: number
  svg: string
  tw: string
  label: string
}> = [
  { floor: 0.7, svg: '#10b981', tw: 'bg-emerald-500', label: '70%+' },
  { floor: 0.4, svg: '#f59e0b', tw: 'bg-amber-500', label: '40%+' },
  { floor: 0,   svg: '#f87171', tw: 'bg-red-400',    label: '<40%' },
]

const LEGEND_STOPS = [1.0, 0.75, 0.5, 0.25, 0.05] as const

// Responsive matrix cell sizes. Arbitrary breakpoints to prevent label
// collisions at common agent counts.
const CELL_SIZE_BREAKPOINTS: ReadonlyArray<{ maxAgents: number; cell: number }> = [
  { maxAgents: 8, cell: 32 },
  { maxAgents: 12, cell: 26 },
  { maxAgents: Infinity, cell: 22 },
]

const TOP_LINK_COUNT = 5

const SPARKLINE = { width: 80, height: 16, strokeWidth: 1.25 } as const

// Must be well under the typical strengthen/weaken step (~0.1) so one learning
// event produces a decisive color while sub-threshold drift stays neutral.
const TREND_DEAD_ZONE = 0.02

// --- Derived helpers --------------------------------------------------------

// Last entry is the catch-all (floor: 0).
const WEIGHT_RAMP_FALLBACK = WEIGHT_RAMP[WEIGHT_RAMP.length - 1]!

const weightTier = (w: number): typeof WEIGHT_RAMP_FALLBACK =>
  WEIGHT_RAMP.find(t => w >= t.floor) ?? WEIGHT_RAMP_FALLBACK

const weightColor = (w: number) => weightTier(w).svg
const weightBarClass = (w: number) => weightTier(w).tw

// √ compresses the high end so differences near 0 remain visible.
// Floor 0.25 keeps low-weight cells distinguishable from empty (undefined)
// cells drawn at #1e293b. Floor and range are arbitrary — picked by eye,
// not derived from a perceptual model. Tune if empty/low contrast is wrong.
const weightOpacity = (w: number) => 0.25 + 0.75 * Math.sqrt(Math.max(0, Math.min(1, w)))

function HebbianMatrix({ synapses }: { synapses: MemorySubsystemsSynapse[] }) {
  if (synapses.length === 0) return null

  // Sort by activity total (success + failure on either side) — hubs appear top-left.
  // Sorting the matrix by some feature is common in Hebbian literature
  // (e.g. Sadeh & Clopath, PNAS 2024 sorts by stimulus tuning peak); activity
  // total is a usage-frequency proxy chosen here because MASC has no stimulus.
  const activity = new Map<string, number>()
  synapses.forEach(s => {
    const n = s.success_count + s.failure_count
    activity.set(s.from_agent, (activity.get(s.from_agent) ?? 0) + n)
    activity.set(s.to_agent, (activity.get(s.to_agent) ?? 0) + n)
  })
  const agents = Array.from(activity.keys()).sort(
    (a, b) => (activity.get(b) ?? 0) - (activity.get(a) ?? 0),
  )

  const cellMap = new Map<string, MemorySubsystemsSynapse>()
  synapses.forEach(s => cellMap.set(`${s.from_agent}|${s.to_agent}`, s))

  const n = agents.length
  const cell = (CELL_SIZE_BREAKPOINTS.find(b => n <= b.maxAgents) ?? CELL_SIZE_BREAKPOINTS[CELL_SIZE_BREAKPOINTS.length - 1]!).cell
  const leftPad = 120
  const topPad = 96
  const legendW = 70
  const width = leftPad + n * cell + legendW
  const height = topPad + n * cell + 30

  return html`
    <div class="bg-zinc-900 rounded-lg p-3 overflow-x-auto">
      <svg viewBox="0 0 ${width} ${height}" class="w-full h-auto" style="max-height:560px">
        ${agents.map(
          (name, i) => html`
            <g transform="translate(${leftPad + i * cell + cell / 2}, ${topPad - 6}) rotate(-45)">
              <text
                text-anchor="start"
                font-size="10"
                fill="#cbd5e1"
                font-family="monospace"
                class="cursor-pointer hover:fill-sky-400"
                onClick=${() => openAgentDetail(name)}
              >${shortAgentLabel(name)}</text>
            </g>
          `,
        )}

        ${agents.map(
          (name, i) => html`
            <text
              x=${leftPad - 6}
              y=${topPad + i * cell + cell / 2 + 4}
              text-anchor="end"
              font-size="10"
              fill="#cbd5e1"
              font-family="monospace"
              class="cursor-pointer hover:fill-sky-400"
              onClick=${() => openAgentDetail(name)}
            >${shortAgentLabel(name)}</text>
          `,
        )}

        ${agents.flatMap((from, r) =>
          agents.map((to, c) => {
            const s = cellMap.get(`${from}|${to}`)
            const x = leftPad + c * cell
            const y = topPad + r * cell
            if (!s) {
              return html`<rect
                x=${x}
                y=${y}
                width=${cell - 1}
                height=${cell - 1}
                fill="#1e293b"
                stroke="#0f172a"
                stroke-width="0.5"
              />`
            }
            const pct = Math.round(s.weight * 100)
            const isDiag = from === to
            return html`
              <g>
                <title>${`${from} → ${to}\nweight ${pct}% · 성공 ${s.success_count} · 실패 ${s.failure_count}`}</title>
                <rect
                  x=${x}
                  y=${y}
                  width=${cell - 1}
                  height=${cell - 1}
                  fill=${weightColor(s.weight)}
                  opacity=${weightOpacity(s.weight)}
                  stroke=${isDiag ? '#64748b' : '#0f172a'}
                  stroke-dasharray=${isDiag ? '2 2' : ''}
                  stroke-width="0.5"
                  class="cursor-pointer hover:stroke-zinc-300"
                  role="button"
                  aria-label=${`${from} to ${to}: ${pct}%`}
                  onClick=${() => openAgentDetail(to)}
                />
              </g>
            `
          }),
        )}

        <g transform="translate(${leftPad + n * cell + 16}, ${topPad})">
          <text x="0" y="-8" font-size="9" fill="#94a3b8">weight</text>
          ${LEGEND_STOPS.map(
            (v, i) => html`
              <g>
                <rect
                  x="0"
                  y=${i * 16}
                  width="14"
                  height="13"
                  fill=${weightColor(v)}
                  opacity=${weightOpacity(v)}
                />
                <text
                  x="20"
                  y=${i * 16 + 10}
                  font-size="9"
                  fill="#94a3b8"
                  font-family="monospace"
                >${Math.round(v * 100)}%</text>
              </g>
            `,
          )}
        </g>
      </svg>
      <div class="mt-2 text-xs text-zinc-500 text-center">
        행 = from · 열 = to · 셀 = 시냅스 가중치 · 정렬 = 활동량 내림차순
      </div>
    </div>
  `
}

// Render a tiny polyline of weight history. Input is newest-first from
// the backend; reverse for chronological left-to-right rendering.
function WeightSparkline({ history }: { history?: Array<[number, number]> }) {
  if (!history || history.length < 2) {
    return html`<span class="text-zinc-700 text-[10px] w-20 text-center">—</span>`
  }
  const chronological = [...history].reverse()
  const { width: sw, height: sh, strokeWidth } = SPARKLINE
  const n = chronological.length
  const points = chronological
    .map(([, weight], i) => {
      const x = (i / (n - 1)) * (sw - 2) + 1
      const y = sh - 1 - Math.max(0, Math.min(1, weight)) * (sh - 2)
      return `${x.toFixed(1)},${y.toFixed(1)}`
    })
    .join(' ')
  const first = chronological[0]?.[1] ?? 0
  const last = chronological[n - 1]?.[1] ?? 0
  const trendColor =
    last > first + TREND_DEAD_ZONE ? '#10b981' :
    last < first - TREND_DEAD_ZONE ? '#f87171' : '#94a3b8'
  return html`
    <svg
      viewBox="0 0 ${sw} ${sh}"
      width=${sw}
      height=${sh}
      class="shrink-0"
      aria-label=${`weight trend: ${n} points`}
    >
      <polyline fill="none" stroke=${trendColor} stroke-width=${strokeWidth} points=${points} />
    </svg>
  `
}

function HebbianTopLinks({ synapses }: { synapses: MemorySubsystemsSynapse[] }) {
  if (synapses.length === 0) return null
  const top = [...synapses].sort((a, b) => b.weight - a.weight).slice(0, TOP_LINK_COUNT)
  return html`
    <div class="bg-zinc-900 rounded-lg p-3 mt-3">
      <div class="text-xs text-zinc-500 mb-2">강한 연결 Top ${TOP_LINK_COUNT} · sparkline = 학습 궤적</div>
      <div class="space-y-1.5">
        ${top.map(s => {
          const pct = Math.round(s.weight * 100)
          return html`
            <div class="flex items-center gap-2 text-xs font-mono">
              <button
                class="text-zinc-300 hover:text-sky-400 truncate w-32 text-right"
                onClick=${() => openAgentDetail(s.from_agent)}
              >${shortAgentLabel(s.from_agent)}</button>
              <span class="text-zinc-600">→</span>
              <button
                class="text-zinc-300 hover:text-sky-400 truncate w-32 text-left"
                onClick=${() => openAgentDetail(s.to_agent)}
              >${shortAgentLabel(s.to_agent)}</button>
              <div class="flex-1 bg-zinc-800 rounded h-1.5 min-w-[60px]">
                <div class="${weightBarClass(s.weight)} rounded h-1.5" style="width:${pct}%"></div>
              </div>
              <span class="text-zinc-300 w-10 text-right">${pct}%</span>
              <${WeightSparkline} history=${s.weight_history} />
              <span class="text-emerald-400 w-8 text-right">${s.success_count}</span>
              <span class="text-red-400 w-8 text-right">${s.failure_count}</span>
            </div>
          `
        })}
      </div>
    </div>
  `
}

function SynapseRow({ s }: { s: MemorySubsystemsSynapse }) {
  const pct = Math.round(s.weight * 100)
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
            <div class="${weightBarClass(s.weight)} rounded h-1.5" style="width:${pct}%"></div>
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
            ? html`<div class="mb-3">
                <${HebbianMatrix} synapses=${synapses} />
                <${HebbianTopLinks} synapses=${synapses} />
              </div>`
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
