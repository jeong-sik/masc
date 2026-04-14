import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { LoadingState } from './common/feedback-state'
import {
  fetchMemorySubsystems,
  type MemorySubsystemsResponse,
  type MemorySubsystemsSynapse,
  type MemorySubsystemsEpisode,
} from '../api/dashboard'
import { formatTimeAgo } from '../lib/format-time'
import { isAbortError } from '../lib/async-state'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'

const REFRESH_MS = 30_000

function SynapseRow({ s }: { s: MemorySubsystemsSynapse }) {
  const pct = Math.round(s.weight * 100)
  const barColor =
    pct >= 70 ? 'bg-emerald-500' : pct >= 40 ? 'bg-amber-500' : 'bg-red-400'
  return html`
    <tr class="border-b border-zinc-800">
      <td class="py-1.5 px-2 text-sm font-mono">${s.from_agent}</td>
      <td class="py-1.5 px-2 text-sm text-zinc-400 text-center">→</td>
      <td class="py-1.5 px-2 text-sm font-mono">${s.to_agent}</td>
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

  return html`
    <div class="space-y-6">
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
