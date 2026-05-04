import { html } from 'htm/preact'
import { signal, useSignal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import { LoadingState } from './common/feedback-state'
import { TextInput } from './common/input'
import { MermaidGraph } from './common/mermaid-graph'
import { Select } from './common/select'
import {
  fetchMemorySubsystems,
  fetchKeeperDecisions,
  type MemorySubsystemsResponse,
  type MemorySubsystemsSynapse,
  type MemorySubsystemsEpisode,
  type KeeperDecision,
} from '../api/dashboard'
import { formatTimeAgo } from '../lib/format-time'
import { isAbortError } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { openAgentDetail } from './agent-detail-state'
import { ringFocusClasses } from './common/ring'

const REFRESH_MS = 30_000

export const ARCHITECTURE_FLOW = `graph LR
    subgraph Keeper["키퍼 턴"]
      K1[LLM 응답 생성] --> K2["[STATE] 파싱"]
      K2 --> K3{STATE 있음?}
    end

    K3 -->|Yes| M1[store_episode_from_snapshot]
    M1 --> M2[Memory.t in-memory]
    M2 --> M3[flush_incremental]
    M3 --> F1[(institution_episodes.jsonl)]
    F1 -->|cap 500| F1

    subgraph Task["태스크 완료"]
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

    classDef store fill:#1e293b,stroke:#334155,color:#e2e8f0
    classDef action fill:#0f766e,stroke:#14b8a6,color:#e2e8f0
    classDef ui fill:#7c2d12,stroke:#f97316,color:#e2e8f0
    class F1,G1 store
    class M1,M3,H1,H2,T2 action
    class UI ui`

const shortAgentLabel = (name: string) => {
  const trimmed = name.replace(/^keeper-/, '').replace(/-agent$/, '')
  return trimmed.length > 12 ? trimmed.slice(0, 11) + '…' : trimmed
}

// Synapse pair filter — when set, only episodes whose participants include
// both agents are shown in the episode list below the matrix.
// Module-scope so HebbianMatrix cells, HebbianTopLinks rows, and the main
// MemorySubsystems component can all read/write it.
type SynapsePairFilter = { from: string; to: string } | null
const synapsePairFilter = signal<SynapsePairFilter>(null)
const setSynapsePairFilter = (pair: SynapsePairFilter) => {
  synapsePairFilter.value = pair
}
const toggleSynapsePairFilter = (from: string, to: string) => {
  const current = synapsePairFilter.value
  if (current && current.from === from && current.to === to) {
    synapsePairFilter.value = null
  } else {
    synapsePairFilter.value = { from, to }
  }
}
const isActivePair = (from: string, to: string) => {
  const f = synapsePairFilter.value
  return f !== null && f.from === from && f.to === to
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
  { floor: 0.7, svg: 'var(--color-emerald)', tw: 'bg-[var(--ok-10)]', label: '70%+' },
  { floor: 0.4, svg: 'var(--amber-bright)', tw: 'bg-[var(--warn-10)]', label: '40%+' },
  { floor: 0,   svg: 'var(--bad-light)', tw: 'bg-[var(--bad-10)]',    label: '<40%' },
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
// cells drawn at var(--color-bg-panel-alt). Floor and range are arbitrary — picked by eye,
// not derived from a perceptual model. Tune if empty/low contrast is wrong.
const weightOpacity = (w: number) => 0.25 + 0.75 * Math.sqrt(Math.max(0, Math.min(1, w)))

/**
 * Pure filter for the Hebbian synapses table rows.
 *
 * Case-insensitive substring match against `from_agent` then `to_agent`;
 * first field match wins. Synapse pairs grow N² with fleet size so on a
 * 10+ agent fleet the table has 100+ rows — operators need a quick way
 * to isolate "every link involving keeper-foo".
 *
 * Empty/whitespace query returns the input reference unchanged (preserves
 * referential equality for `useMemo`-memoised consumers).
 *
 * The input array is never mutated; callers may pass a readonly array.
 */
export function filterSynapses(
  synapses: readonly MemorySubsystemsSynapse[],
  query: string,
): readonly MemorySubsystemsSynapse[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return synapses
  return synapses.filter(s => {
    if (s.from_agent.toLowerCase().includes(needle)) return true
    if (s.to_agent.toLowerCase().includes(needle)) return true
    return false
  })
}

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
    <div class="bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] p-3 overflow-x-auto">
      <svg viewBox="0 0 ${width} ${height}" class="w-full h-auto" role="img" aria-label="에이전트 간 메모리 서브시스템 연결 행렬" style="max-height:560px">
        ${agents.map(
          (name, i) => html`
            <g transform="translate(${leftPad + i * cell + cell / 2}, ${topPad - 6}) rotate(-45)">
              <text
                text-anchor="start"
                font-size="10"
                fill="var(--color-fg-muted)"
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
              fill="var(--color-fg-muted)"
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
                fill="var(--color-bg-panel-alt)"
                stroke="var(--panel-dark)"
                stroke-width="0.5"
              />`
            }
            const pct = Math.round(s.weight * 100)
            const isDiag = from === to
            const active = isActivePair(from, to)
            return html`
              <g>
                <title>${`${from} → ${to}\nweight ${pct}% · 성공 ${s.success_count} · 실패 ${s.failure_count}\n(클릭: 이 쌍의 에피소드만 필터)`}</title>
                <rect
                  x=${x}
                  y=${y}
                  width=${cell - 1}
                  height=${cell - 1}
                  fill=${weightColor(s.weight)}
                  opacity=${weightOpacity(s.weight)}
                  stroke=${active ? 'var(--frost-100)' : isDiag ? 'var(--color-fg-muted)' : 'var(--panel-dark)'}
                  stroke-dasharray=${isDiag ? '2 2' : ''}
                  stroke-width=${active ? '1.5' : '0.5'}
                  class="cursor-pointer hover:stroke-[var(--color-fg-muted)]"
                  role="button"
                  aria-label=${`${from} to ${to}: ${pct}% — filter episodes for this pair`}
                  aria-pressed=${active ? 'true' : 'false'}
                  onClick=${() => toggleSynapsePairFilter(from, to)}
                />
              </g>
            `
          }),
        )}

        <g transform="translate(${leftPad + n * cell + 16}, ${topPad})">
          <text x="0" y="-8" font-size="9" fill="var(--color-fg-muted)">weight</text>
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
                  fill="var(--color-fg-muted)"
                  font-family="monospace"
                >${Math.round(v * 100)}%</text>
              </g>
            `,
          )}
        </g>
      </svg>
      <div class="mt-2 text-xs text-[var(--color-fg-muted)] text-center">
        행 = from · 열 = to · 셀 = 시냅스 가중치 · 정렬 = 활동량 내림차순
      </div>
    </div>
  `
}

// Render a tiny polyline of weight history. Input is newest-first from
// the backend; reverse for chronological left-to-right rendering.
function WeightSparkline({ history }: { history?: Array<[number, number]> }) {
  if (!history || history.length < 2) {
    return html`<span class="text-[var(--color-fg-muted)] text-3xs w-20 text-center">—</span>`
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
    last > first + TREND_DEAD_ZONE ? 'var(--color-emerald)' :
    last < first - TREND_DEAD_ZONE ? 'var(--bad-light)' : 'var(--color-fg-muted)'
  return html`
    <svg
      viewBox="0 0 ${sw} ${sh}"
      width=${sw}
      height=${sh}
      class="shrink-0"
      aria-label=${`가중치 트렌드: ${n} 포인트`}
    >
      <polyline fill="none" stroke=${trendColor} stroke-width=${strokeWidth} points=${points} />
    </svg>
  `
}

function HebbianTopLinks({ synapses }: { synapses: MemorySubsystemsSynapse[] }) {
  if (synapses.length === 0) return null
  const top = [...synapses].sort((a, b) => b.weight - a.weight).slice(0, TOP_LINK_COUNT)
  return html`
    <div class="bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] p-3 mt-3">
      <div class="text-xs text-[var(--color-fg-muted)] mb-2">강한 연결 Top ${TOP_LINK_COUNT} · sparkline = 학습 궤적</div>
      <div class="space-y-1.5">
        ${top.map(s => {
          const pct = Math.round(s.weight * 100)
          const active = isActivePair(s.from_agent, s.to_agent)
          return html`
            <div class="flex items-center gap-2 text-xs font-mono px-1 py-0.5 rounded-[var(--r-1)] ${active ? 'ring-1 ring-[var(--color-border-default)] bg-[var(--color-bg-elevated)]' : 'hover:bg-[var(--color-bg-elevated)]'}">
              <button
                type="button"
                class=${`text-[var(--color-fg-muted)] hover:text-[var(--color-accent-fg)] truncate w-32 text-right ${ringFocusClasses()}`}
                onClick=${() => openAgentDetail(s.from_agent)}
              >${shortAgentLabel(s.from_agent)}</button>
              <button
                type="button"
                aria-pressed=${active ? 'true' : 'false'}
                title="이 쌍의 에피소드만 필터"
                class=${`text-[var(--color-fg-muted)] hover:text-[var(--color-accent-fg)] ${ringFocusClasses()} ${active ? 'text-[var(--color-accent-fg)]' : ''}`}
                onClick=${() => toggleSynapsePairFilter(s.from_agent, s.to_agent)}
              >→</button>
              <button
                type="button"
                class=${`text-[var(--color-fg-muted)] hover:text-[var(--color-accent-fg)] truncate w-32 text-left ${ringFocusClasses()}`}
                onClick=${() => openAgentDetail(s.to_agent)}
              >${shortAgentLabel(s.to_agent)}</button>
              <div class="flex-1 bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] h-1.5 min-w-15">
                <div class="${weightBarClass(s.weight)} rounded-[var(--r-1)] h-1.5" style="width:${pct}%"></div>
              </div>
              <span class="text-[var(--color-fg-muted)] w-10 text-right">${pct}%</span>
              <${WeightSparkline} history=${s.weight_history} />
              <span class="text-[var(--color-status-ok)] w-8 text-right">${s.success_count}</span>
              <span class="text-[var(--bad-light)] w-8 text-right">${s.failure_count}</span>
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
    <tr class="border-b border-[var(--color-border-default)]">
      <td class="py-1.5 px-2 text-sm font-mono">
        <button
          class="hover:text-[var(--color-accent-fg)] hover:underline focus:outline-none focus:text-[var(--color-accent-fg)]"
          onClick=${() => openAgentDetail(s.from_agent)}
        >${s.from_agent}</button>
      </td>
      <td class="py-1.5 px-2 text-sm text-[var(--color-fg-muted)] text-center">→</td>
      <td class="py-1.5 px-2 text-sm font-mono">
        <button
          class="hover:text-[var(--color-accent-fg)] hover:underline focus:outline-none focus:text-[var(--color-accent-fg)]"
          onClick=${() => openAgentDetail(s.to_agent)}
        >${s.to_agent}</button>
      </td>
      <td class="py-1.5 px-2 text-sm text-right">
        <div class="flex items-center gap-2 justify-end">
          <div class="w-16 bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] h-1.5">
            <div class="${weightBarClass(s.weight)} rounded-[var(--r-1)] h-1.5" style="width:${pct}%"></div>
          </div>
          <span class="text-[var(--color-fg-muted)] w-10 text-right">${pct}%</span>
        </div>
      </td>
      <td class="py-1.5 px-2 text-sm text-[var(--color-status-ok)] text-center">${s.success_count}</td>
      <td class="py-1.5 px-2 text-sm text-[var(--bad-light)] text-center">${s.failure_count}</td>
      <td class="py-1.5 px-2 text-xs text-[var(--color-fg-muted)]">${formatTimeAgo(s.last_updated * 1000)}</td>
    </tr>
  `
}

function EpisodeCard({ ep }: { ep: MemorySubsystemsEpisode }) {
  const outcomeColor =
    ep.outcome === 'success'
      ? 'text-[var(--color-status-ok)]'
      : ep.outcome === 'partial'
        ? 'text-[var(--color-status-warn)]'
        : 'text-[var(--bad-light)]'
  const outcomeIcon =
    ep.outcome === 'success' ? '●' : ep.outcome === 'partial' ? '◐' : '○'
  return html`
    <div class="border border-[var(--color-border-default)] rounded-[var(--r-1)] p-3 mb-2 hover:border-[var(--color-border-default)] transition-colors">
      <div class="flex items-start justify-between gap-2 mb-1">
        <div class="flex items-center gap-2 min-w-0">
          <span class="${outcomeColor} text-xs">${outcomeIcon}</span>
          <span class="text-sm font-medium text-[var(--color-fg-muted)] truncate">${ep.summary}</span>
        </div>
        <span class="text-xs text-[var(--color-fg-muted)] shrink-0">${formatTimeAgo(ep.timestamp * 1000)}</span>
      </div>
      <div class="flex items-center gap-2 text-xs text-[var(--color-fg-muted)] mb-1 flex-wrap">
        <span class="bg-[var(--color-bg-elevated)] px-1.5 py-0.5 rounded-[var(--r-1)]">${ep.event_type}</span>
        ${ep.participants.map(
          (p: string) => html`<span class="font-mono">${p}</span>`,
        )}
        <span class="text-[var(--color-fg-muted)] font-mono text-3xs">${ep.id}</span>
      </div>
      ${
        ep.learnings.length > 0
          ? html`
              <div class="mt-1.5 space-y-0.5">
                ${ep.learnings.map(
                  (l: string) =>
                    html`<div class="text-xs text-[var(--color-fg-muted)] pl-3 border-l border-[var(--color-border-default)]">${l}</div>`,
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
                    html`<span class="text-xs bg-[var(--color-bg-elevated)] px-1.5 py-0.5 rounded-[var(--r-1)] text-[var(--color-fg-muted)]"
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
  const resource = useManagedAsyncResource<MemorySubsystemsResponse>(null)

  const keeperFilter = useSignal<string>('')
  const outcomeFilter = useSignal<string>('')
  const searchQuery = useSignal<string>('')
  // Client-side substring filter for the Hebbian synapses table. Independent
  // from the episodes filter bar above — the synapses table is N² in fleet
  // size and needs its own needle.
  const synapseQuery = useSignal<string>('')

  useEffect(() => {
    const run = () => {
      void resource.load(async (signal) =>
        fetchMemorySubsystems({
          limit: 100,
          keeper: keeperFilter.value || undefined,
          outcome: outcomeFilter.value || undefined,
          q: searchQuery.value || undefined,
          signal,
        }),
      )
    }
    run()
    const cleanup = setupVisibleAutoRefresh(run, REFRESH_MS)
    return () => {
      resource.cancel()
      cleanup()
    }
  }, [keeperFilter.value, outcomeFilter.value, searchQuery.value, resource])

  const { loading, error, data } = resource.state.value
  if (loading && !data) return html`<${LoadingState} label="기억 서브시스템 로드 중..." />`
  if (error && !data)
    return html`<div class="p-4 text-[var(--bad-light)]">오류: ${error}</div>`

  const synapses = data?.hebbian?.synapses ?? []
  const lastConsolidation = data?.hebbian?.last_consolidation ?? 0
  const synapseQueryValue = synapseQuery.value
  const visibleSynapses = useMemo(
    () => filterSynapses(synapses, synapseQueryValue),
    [synapses, synapseQueryValue],
  )
  const isSynapseFiltering = synapseQueryValue.trim() !== ''
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
    synapsePairFilter.value = null
  }

  const pairFilter = synapsePairFilter.value
  const hasFilter = Boolean(
    keeperFilter.value || outcomeFilter.value || searchQuery.value || pairFilter,
  )

  // Pair filter is applied client-side after the server returns episodes —
  // episodes aren't indexed by synapse pair on the backend. For typical
  // keeper workloads episode lists are <100 items, so per-render filter
  // cost is negligible.
  const visibleEpisodes = pairFilter
    ? episodes.filter(ep =>
        ep.participants.includes(pairFilter.from) &&
        ep.participants.includes(pairFilter.to),
      )
    : episodes

  const showArch = useSignal(false)

  return html`
    <div class="space-y-6">
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2 text-xs text-[var(--color-fg-muted)]">
        이 화면은 <span class="text-[var(--color-fg-muted)] font-medium">global memory surface</span>만 보여줍니다.
        institution episodes와 Hebbian graph는 여기서 보고,
        keeper checkpoint/history/memory bank는 Keeper Detail에서 확인합니다.
      </div>

      <!-- Architecture Flow (collapsible) -->
      <section aria-label="아키텍처 데이터 흐름도">
        <button
          onClick=${() => (showArch.value = !showArch.value)}
          class="w-full flex items-center justify-between p-2 bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] hover:bg-[var(--color-bg-elevated)] transition-colors"
        >
          <span class="text-sm font-semibold text-[var(--color-fg-muted)] flex items-center gap-2">
            <span class="text-xs">${showArch.value ? '▼' : '▶'}</span>
            아키텍처 — 데이터 흐름도
          </span>
          <span class="text-xs text-[var(--color-fg-muted)]">
            Keeper turn → episodes / task_done → Hebbian. Keeper memory bank와 checkpoint는 다른 패널에서 본다.
          </span>
        </button>
        ${
          showArch.value
            ? html`
                <div class="mt-2 bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] p-3">
                  <${MermaidGraph}
                    source=${ARCHITECTURE_FLOW}
                    prefix="memory-arch"
                    minHeightClass="min-h-80"
                  />
                </div>
              `
            : null
        }
      </section>

      <!-- Hebbian Synapses -->
      <section aria-label="Hebbian 시냅스 그래프">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-base font-semibold text-[var(--color-fg-muted)]">Hebbian 시냅스 그래프</h3>
          <div class="flex items-center gap-3 text-xs text-[var(--color-fg-muted)]">
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
            ? html`<div class="text-sm text-[var(--color-fg-muted)] bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] p-4 text-center">
                시냅스 데이터 없음. keeper task 완료 시 자동 생성됩니다.
              </div>`
            : html`
                <div class="flex items-center gap-2 mb-2 flex-wrap">
                  <${TextInput}
                    type="search"
                    class="flex-1 min-w-50 !px-2 !py-1 !text-sm"
                    value=${synapseQueryValue}
                    placeholder="시냅스 검색 (from/to 에이전트 이름)"
                    ariaLabel="시냅스 필터"
                    onInput=${(e: Event) => {
                      synapseQuery.value = (e.target as HTMLInputElement).value
                    }}
                  />
                  ${
                    isSynapseFiltering
                      ? html`<span class="text-xs text-[var(--color-fg-muted)]">${visibleSynapses.length}/${synapses.length}</span>`
                      : null
                  }
                </div>
                ${
                  isSynapseFiltering && visibleSynapses.length === 0
                    ? html`<div class="text-sm text-[var(--color-fg-muted)] bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] p-4 text-center">
                        필터 결과 없음 (${synapses.length} items)
                      </div>`
                    : html`<div class="overflow-x-auto">
                        <table class="w-full text-left" aria-label="Hebbian 시냅스 상세 테이블">
                          <thead>
                            <tr class="border-b border-[var(--color-border-default)] text-xs text-[var(--color-fg-muted)]">
                              <th scope="col" class="py-1.5 px-2">출처</th>
                              <th scope="col" class="py-1.5 px-2"><span class="sr-only">방향</span></th>
                              <th scope="col" class="py-1.5 px-2">대상</th>
                              <th scope="col" class="py-1.5 px-2 text-right">가중치</th>
                              <th scope="col" class="py-1.5 px-2 text-center">성공</th>
                              <th scope="col" class="py-1.5 px-2 text-center">실패</th>
                              <th scope="col" class="py-1.5 px-2">마지막</th>
                            </tr>
                          </thead>
                          <tbody>
                            ${visibleSynapses.map(
                              (s: MemorySubsystemsSynapse) => html`<${SynapseRow} s=${s} />`,
                            )}
                          </tbody>
                        </table>
                      </div>`
                }
              `
        }
      </section>

      <!-- Episodes -->
      <section aria-label="에피소드 기록">
        <div class="flex items-center justify-between mb-3 flex-wrap gap-2">
          <h3 class="text-base font-semibold text-[var(--color-fg-muted)]">에피소드 기록</h3>
          <span class="text-xs text-[var(--color-fg-muted)]">
            총 ${totalEpisodes}개 · 필터 ${filteredTotal}개 · 표시 ${visibleEpisodes.length}개
          </span>
        </div>

        ${
          pairFilter
            ? html`<div class="flex items-center gap-2 mb-2 px-2 py-1 bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] rounded-[var(--r-1)] text-xs">
                <span class="text-[var(--color-fg-muted)]">시냅스 쌍 필터</span>
                <span class="text-[var(--color-fg-muted)] font-mono">${shortAgentLabel(pairFilter.from)} → ${shortAgentLabel(pairFilter.to)}</span>
                <button
                  class="ml-auto text-[var(--color-fg-muted)] hover:text-[var(--color-fg-muted)]"
                  onClick=${() => setSynapsePairFilter(null)}
                  aria-label="시냅스 쌍 필터 해제"
                >✕</button>
              </div>`
            : null
        }

        <!-- Filter Bar -->
        <div class="flex items-center gap-2 mb-3 flex-wrap">
          <${TextInput}
            type="text"
            class="flex-1 min-w-50 !px-2 !py-1 !text-sm"
            placeholder="검색 (summary, learnings, event_type...)"
            ariaLabel="에피소드 검색"
            value=${searchQuery.value}
            onInput=${onSearchInput}
          />
          <${Select}
            class="px-2 py-1 text-sm"
            ariaLabel="키퍼 필터"
            value=${keeperFilter.value}
            options=${[
              { value: '', label: '모든 키퍼' },
              ...knownKeepers.map((k: string) => ({ value: k, label: k })),
            ]}
            onInput=${(v: string) => { keeperFilter.value = v }}
          />
          <${Select}
            class="px-2 py-1 text-sm"
            ariaLabel="결과 필터"
            value=${outcomeFilter.value}
            options=${[
              { value: '', label: '모든 결과' },
              ...knownOutcomes.map((o: string) => ({ value: o, label: o })),
            ]}
            onInput=${(v: string) => { outcomeFilter.value = v }}
          />
          ${
            hasFilter
              ? html`<button
                  onClick=${clearFilters}
                  class="text-xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-muted)] px-2 py-1 border border-[var(--color-border-default)] rounded-[var(--r-1)] hover:border-[var(--color-border-default)]0"
                >
                  필터 해제
                </button>`
              : null
          }
        </div>

        ${
          visibleEpisodes.length === 0
            ? html`<div class="text-sm text-[var(--color-fg-muted)] bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] p-4 text-center">
                ${hasFilter
                  ? '필터 조건에 맞는 에피소드가 없습니다.'
                  : '에피소드 없음. keeper [STATE] 출력 시 자동 기록됩니다.'}
              </div>`
            : html`
                <div class="space-y-1">
                  ${visibleEpisodes
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

      <${DecisionsStream} />

      ${
        error
          ? html`<div class="text-xs text-[var(--color-status-warn)] mt-2">refresh error: ${error}</div>`
          : null
      }
    </div>
  `
}

const DECISION_REFRESH_MS = 30_000

function DecisionsStream() {
  const state = useSignal<{
    loading: boolean
    error: string | null
    data: KeeperDecision[] | null
  }>({ loading: true, error: null, data: null })

  const keeperFilter = useSignal<string>('')
  const eventFilter = useSignal<string>('')
  const outcomeFilter = useSignal<string>('')
  const limit = useSignal<number>(50)

  async function refresh(sig?: AbortSignal) {
    try {
      const resp = await fetchKeeperDecisions(limit.value, { signal: sig })
      state.value = { loading: false, error: null, data: resp.events }
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
    const cleanup = setupVisibleAutoRefresh(() => refresh(), DECISION_REFRESH_MS)
    return () => {
      ac.abort()
      cleanup()
    }
  }, [limit.value])

  const { loading, error, data } = state.value
  const events = data ?? []

  const knownKeepers = Array.from(new Set(events.map(e => e.keeper_name))).sort()
  const knownEvents = Array.from(new Set(events.map(e => e.event_type))).sort()
  const knownOutcomes = Array.from(new Set(events.map(e => e.outcome).filter((o): o is string => o != null))).sort()

  const visible = events.filter(ev => {
    if (keeperFilter.value && ev.keeper_name !== keeperFilter.value) return false
    if (eventFilter.value && ev.event_type !== eventFilter.value) return false
    if (outcomeFilter.value && ev.outcome !== outcomeFilter.value) return false
    return true
  })

  const hasFilter = Boolean(keeperFilter.value || eventFilter.value || outcomeFilter.value)

  return html`
    <section class="flex flex-col gap-3" aria-label="Keeper decisions stream">
      <div class="flex flex-wrap items-center gap-2">
        <h3 class="text-sm font-semibold text-text-strong">Decisions Stream</h3>
        <span class="text-2xs text-text-muted">${visible.length} / ${events.length} events</span>
        <div class="ml-auto flex items-center gap-2">
          <${Select}
            class="px-2 py-1 text-2xs"
            ariaLabel="Keeper"
            value=${keeperFilter.value}
            options=${[
              { value: '', label: 'all keepers' },
              ...knownKeepers.map(k => ({ value: k, label: k })),
            ]}
            onInput=${(v: string) => { keeperFilter.value = v }}
          />
          <${Select}
            class="px-2 py-1 text-2xs"
            ariaLabel="Event"
            value=${eventFilter.value}
            options=${[
              { value: '', label: 'all events' },
              ...knownEvents.map(e => ({ value: e, label: e })),
            ]}
            onInput=${(v: string) => { eventFilter.value = v }}
          />
          <${Select}
            class="px-2 py-1 text-2xs"
            ariaLabel="Outcome"
            value=${outcomeFilter.value}
            options=${[
              { value: '', label: 'all outcomes' },
              ...knownOutcomes.map(o => ({ value: o, label: o })),
            ]}
            onInput=${(v: string) => { outcomeFilter.value = v }}
          />
          ${hasFilter
            ? html`<button
                class="text-2xs text-text-muted hover:text-text-strong px-2 py-1 border border-card-border/40 rounded-[var(--r-1)]"
                onClick=${() => {
                  keeperFilter.value = ''
                  eventFilter.value = ''
                  outcomeFilter.value = ''
                }}
              >clear</button>`
            : null}
        </div>
      </div>

      ${loading && !data
        ? html`<${LoadingState} label="decisions 로드 중..." />`
        : error && !data
          ? html`<div class="text-sm text-[var(--color-status-err)]">decisions 오류: ${error}</div>`
          : html`
              <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
                <table class="w-full text-2xs" aria-label="decision events">
                  <thead>
                    <tr class="border-b border-[var(--color-border-default)] text-text-muted uppercase tracking-1">
                      <th class="px-2 py-1.5 text-left">time</th>
                      <th class="px-2 py-1.5 text-left">keeper</th>
                      <th class="px-2 py-1.5 text-left">event</th>
                      <th class="px-2 py-1.5 text-left">outcome</th>
                      <th class="px-2 py-1.5 text-left">model</th>
                      <th class="px-2 py-1.5 text-right">latency</th>
                      <th class="px-2 py-1.5 text-right">cost</th>
                      <th class="px-2 py-1.5 text-right">tokens</th>
                      <th class="px-2 py-1.5 text-left">stop / error</th>
                    </tr>
                  </thead>
                  <tbody>
                    ${visible.map((ev: KeeperDecision) => {
                      const ts = ev.ts_unix ? formatTimeAgo(ev.ts_unix * 1000) : '—'
                      const latency = ev.latency_ms != null ? `${Math.round(ev.latency_ms)}ms` : '—'
                      const cost = ev.cost_usd != null ? `$${ev.cost_usd.toFixed(4)}` : '—'
                      const tokens = ev.input_tokens != null || ev.output_tokens != null
                        ? `${ev.input_tokens ?? 0} / ${ev.output_tokens ?? 0}`
                        : '—'
                      const stopErr = ev.error_category ?? ev.stop_reason ?? '—'
                      const rowTone = ev.outcome === 'failure' || ev.error_category
                        ? 'text-[var(--color-status-err)]'
                        : ev.outcome === 'partial'
                          ? 'text-[var(--color-status-warn)]'
                          : ''
                      return html`
                        <tr key=${`${ev.keeper_name}-${ev.ts_unix ?? 0}-${ev.event_type}`}
                          class="border-b border-[var(--color-border-default)]/40 align-baseline ${rowTone}">
                          <td class="px-2 py-1.5 font-mono whitespace-nowrap">${ts}</td>
                          <td class="px-2 py-1.5 font-mono text-[var(--color-accent-fg)]">${ev.keeper_name}</td>
                          <td class="px-2 py-1.5">
                            <span class="rounded-[var(--r-1)] px-1 py-0.5 bg-[var(--color-bg-hover)] text-text-muted">${ev.event_type}</span>
                          </td>
                          <td class="px-2 py-1.5">${ev.outcome ?? '—'}</td>
                          <td class="px-2 py-1.5 font-mono text-text-muted">${ev.model_used ?? '—'}</td>
                          <td class="px-2 py-1.5 text-right font-mono">${latency}</td>
                          <td class="px-2 py-1.5 text-right font-mono">${cost}</td>
                          <td class="px-2 py-1.5 text-right font-mono">${tokens}</td>
                          <td class="px-2 py-1.5 font-mono text-text-muted">${stopErr}</td>
                        </tr>
                      `
                    })}
                  </tbody>
                </table>
                ${visible.length === 0
                  ? html`<div class="p-4 text-center text-text-muted">필터에 맞는 결정이 없습니다.</div>`
                  : null}
              </div>
            `}
    </section>
  `
}
