import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import { LoadingState } from './common/feedback-state'
import { Card } from './common/card'
import {
  fetchMemorySubsystems,
  type MemorySubsystemsResponse,
  type MemorySubsystemsSynapse,
  type MemorySubsystemsEpisode,
} from '../api/dashboard'
import { formatTimeAgo } from '../lib/format-time'
import { isAbortError } from '../lib/async-state'
import { highlightMatch } from '../lib/highlight-match'

interface Props {
  agentName: string
}

export function normalizeKeeperName(name: string): string {
  return name.replace(/^keeper-/, '').replace(/-agent$/, '')
}

export function matchesKeeper(synapseAgent: string, keeperName: string): boolean {
  const a = normalizeKeeperName(synapseAgent)
  const b = normalizeKeeperName(keeperName)
  return a === b
}

/**
 * Pure filter for recent episodes.
 *
 * Case-insensitive substring match on `summary`, `event_type`, and any
 * element of `learnings`. Operators typically recall an episode by what
 * the keeper was doing (event_type), a keyword from the one-line summary,
 * or a phrase from a learning — so these three text fields are covered.
 *
 * Empty/whitespace query returns the input reference unchanged (no new
 * array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated.
 */
export function filterEpisodes(
  episodes: readonly MemorySubsystemsEpisode[],
  query: string,
): readonly MemorySubsystemsEpisode[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return episodes
  return episodes.filter(ep => {
    if (ep.summary.toLowerCase().includes(needle)) return true
    if (ep.event_type.toLowerCase().includes(needle)) return true
    for (const learning of ep.learnings) {
      if (learning.toLowerCase().includes(needle)) return true
    }
    return false
  })
}

export function AgentDetailMemory({ agentName }: Props) {
  const state = useSignal<{
    loading: boolean
    error: string | null
    data: MemorySubsystemsResponse | null
  }>({ loading: true, error: null, data: null })
  const episodeQuery = useSignal('')

  useEffect(() => {
    const ac = new AbortController()
    ;(async () => {
      try {
        const data = await fetchMemorySubsystems({
          keeper: normalizeKeeperName(agentName),
          limit: 10,
          signal: ac.signal,
        })
        state.value = { loading: false, error: null, data }
      } catch (err) {
        if (isAbortError(err)) return
        state.value = {
          loading: false,
          error: err instanceof Error ? err.message : String(err),
          data: null,
        }
      }
    })()
    return () => ac.abort()
  }, [agentName])

  const { loading, error, data } = state.value
  if (loading) return html`<${LoadingState} label="메모리 컨텍스트 로드 중..." />`
  if (error)
    return html`<div class="text-sm text-amber-500">메모리 로드 실패: ${error}</div>`
  if (!data) return null

  // Filter hebbian synapses where this keeper is either endpoint
  const allSynapses = data.hebbian?.synapses ?? []
  const myEdges = allSynapses.filter(
    (s: MemorySubsystemsSynapse) =>
      matchesKeeper(s.from_agent, agentName) ||
      matchesKeeper(s.to_agent, agentName),
  )
  const outgoing = myEdges.filter((s: MemorySubsystemsSynapse) =>
    matchesKeeper(s.from_agent, agentName),
  )
  const incoming = myEdges.filter(
    (s: MemorySubsystemsSynapse) => matchesKeeper(s.to_agent, agentName),
  )

  const episodes = data.episodes?.items ?? []
  const visibleEpisodes = useMemo(
    () => filterEpisodes(episodes, episodeQuery.value),
    [episodes, episodeQuery.value],
  )
  const isFilteringEpisodes = episodeQuery.value.trim() !== ''

  return html`
    <${Card} title="협업 & 기억">
      <div class="space-y-4">
        <!-- Hebbian collaboration -->
        <div>
          <div class="text-xs text-[var(--text-dim)] uppercase tracking-wide mb-2">
            협업 시냅스 (나에게 연결된 ${myEdges.length}개)
          </div>
          ${
            myEdges.length === 0
              ? html`<div class="text-sm text-[var(--text-dim)]">
                  아직 협업 데이터가 없습니다. task 완료 시 자동 학습됩니다.
                </div>`
              : html`
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    ${outgoing.length > 0
                      ? html`
                          <div>
                            <div class="text-[11px] text-[var(--text-muted)] mb-1">
                              내가 강화한 파트너 (out, ${outgoing.length})
                            </div>
                            <div class="space-y-1">
                              ${outgoing.map(
                                (s: MemorySubsystemsSynapse) => html`
                                  <div class="flex items-center gap-2 text-xs">
                                    <span class="font-mono flex-1 truncate">${normalizeKeeperName(s.to_agent)}</span>
                                    <div class="w-16 bg-zinc-800 rounded h-1.5">
                                      <div
                                        class="${s.weight >= 0.7 ? 'bg-emerald-500' : s.weight >= 0.4 ? 'bg-amber-500' : 'bg-red-400'} rounded h-1.5"
                                        style="width:${Math.round(s.weight * 100)}%"
                                      ></div>
                                    </div>
                                    <span class="text-zinc-400 w-10 text-right">${Math.round(s.weight * 100)}%</span>
                                  </div>
                                `,
                              )}
                            </div>
                          </div>
                        `
                      : null}
                    ${incoming.length > 0
                      ? html`
                          <div>
                            <div class="text-[11px] text-[var(--text-muted)] mb-1">
                              나를 강화한 파트너 (in, ${incoming.length})
                            </div>
                            <div class="space-y-1">
                              ${incoming.map(
                                (s: MemorySubsystemsSynapse) => html`
                                  <div class="flex items-center gap-2 text-xs">
                                    <span class="font-mono flex-1 truncate">${normalizeKeeperName(s.from_agent)}</span>
                                    <div class="w-16 bg-zinc-800 rounded h-1.5">
                                      <div
                                        class="${s.weight >= 0.7 ? 'bg-emerald-500' : s.weight >= 0.4 ? 'bg-amber-500' : 'bg-red-400'} rounded h-1.5"
                                        style="width:${Math.round(s.weight * 100)}%"
                                      ></div>
                                    </div>
                                    <span class="text-zinc-400 w-10 text-right">${Math.round(s.weight * 100)}%</span>
                                  </div>
                                `,
                              )}
                            </div>
                          </div>
                        `
                      : null}
                  </div>
                `
          }
        </div>

        <!-- Recent episodes for this keeper -->
        <div>
          <div class="mb-2 flex items-center justify-between gap-2">
            <div class="text-xs text-[var(--text-dim)] uppercase tracking-wide">
              최근 에피소드 (${
                isFilteringEpisodes
                  ? `${visibleEpisodes.length}/${episodes.length}`
                  : `${data.episodes?.filtered ?? 0}`
              }개)
            </div>
            ${episodes.length > 0
              ? html`<input
                  type="search"
                  value=${episodeQuery.value}
                  placeholder="summary / event / learning 필터"
                  aria-label="에피소드 필터"
                  onInput=${(e: Event) => {
                    episodeQuery.value = (e.target as HTMLInputElement).value
                  }}
                  class="min-w-[160px] max-w-[240px] flex-1 rounded-md border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
                />`
              : null}
          </div>
          ${
            episodes.length === 0
              ? html`<div class="text-sm text-[var(--text-dim)]">
                  이 키퍼의 에피소드 기록이 없습니다.
                </div>`
              : visibleEpisodes.length === 0
                ? html`<div class="py-4 text-center text-[11px] text-[var(--text-dim)]">
                    필터 결과 없음 (${episodes.length}개 중 0)
                  </div>`
                : html`
                  <div class="space-y-1.5 max-h-[240px] overflow-y-auto pr-1 custom-scrollbar">
                    ${visibleEpisodes
                      .slice()
                      .reverse()
                      .map((ep: MemorySubsystemsEpisode) => {
                        const outcomeIcon =
                          ep.outcome === 'success'
                            ? '●'
                            : ep.outcome === 'partial'
                              ? '◐'
                              : '○'
                        const outcomeColor =
                          ep.outcome === 'success'
                            ? 'text-[var(--ok)]'
                            : ep.outcome === 'partial'
                              ? 'text-[var(--warn)]'
                              : 'text-[var(--bad-light)]'
                        return html`
                          <div class="border border-zinc-800 rounded px-2 py-1.5 text-xs">
                            <div class="flex items-center justify-between gap-2">
                              <div class="flex items-center gap-2 min-w-0">
                                <span class="${outcomeColor}">${outcomeIcon}</span>
                                <span class="truncate text-zinc-300">${highlightMatch(ep.summary, episodeQuery.value)}</span>
                              </div>
                              <span class="text-[10px] text-zinc-500 shrink-0">${formatTimeAgo(ep.timestamp * 1000)}</span>
                            </div>
                            ${ep.learnings.length > 0
                              ? html`<div class="mt-1 text-[11px] text-zinc-400 pl-3 border-l border-zinc-700">${highlightMatch(ep.learnings[0]!, episodeQuery.value)}</div>`
                              : null}
                          </div>
                        `
                      })}
                  </div>
                `
          }
        </div>
      </div>
    <//>
  `
}
