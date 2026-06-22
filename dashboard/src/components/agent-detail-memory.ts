import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import { LoadingState } from './common/feedback-state'
import { ProgressBar } from './common/progress-bar'
import { CollapsibleSection } from './common/collapsible'
import {
  fetchMemorySubsystems,
  type MemorySubsystemsResponse,
  type MemorySubsystemsSynapse,
  type MemorySubsystemsEpisode,
} from '../api/dashboard'
import { formatTimeAgo } from '../lib/format-time'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { highlightMatch } from '../lib/highlight-match'
import { TextInput } from './common/input'
import { MemoryLineageRail } from './memory/memory-lineage-rail'
import type { MemoryLineageRailProps } from './memory/memory-lineage-rail'
import type { MemoryNode } from './memory/memory-primitives'
import {
  MemoryInspector,
  DEFAULT_MEMORY_KEEPERS,
  type MemoryKeeper,
} from './memory-inspector'

interface Props {
  agentName: string
}

function normalizeKeeperName(name: string): string {
  return name.replace(/^keeper-/, '').replace(/-agent$/, '')
}

// Resolve the MemoryInspector keeper from the surfaced agent. When the agent
// matches the inspector's ported roster we reuse the fixture keeper (real ctx /
// status / task counts so the composition math renders); otherwise the keeper
// id alone is enough — the inspector falls back to empty memory for unknown ids
// (memory-inspector.ts getKeeperMemory). ctx 0 / status 'off' keeps an unknown
// keeper's composition bar in the documented "stopped — 활성 컨텍스트 없음" state
// rather than fabricating window usage.
function resolveInspectorKeeper(agentName: string): MemoryKeeper {
  const id = normalizeKeeperName(agentName)
  return (
    DEFAULT_MEMORY_KEEPERS.find(k => k.id === id) ?? {
      id,
      ctx: 0,
      status: 'off',
      tasks: 0,
      traces: 0,
    }
  )
}

function matchesKeeper(synapseAgent: string, keeperName: string): boolean {
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
function filterEpisodes(
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

function synapseWeightFillClass(weight: number): string {
  if (weight >= 0.7) return 'bg-[var(--ok-10)]'
  if (weight >= 0.4) return 'bg-[var(--warn-10)]'
  return 'bg-[var(--bad-10)]'
}

const LINEAGE_NODE_TYPES: MemoryLineageRailProps['nodeTypes'] = {
  memory: { kr: '기억', g: '◆', c: 'var(--volt)' },
}

function formatEpisodeTime(timestamp: number): string {
  const d = new Date(timestamp * 1000)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

function buildEpisodeLineage(
  episodes: readonly MemorySubsystemsEpisode[],
  fallbackKp: string,
): { steps: MemoryLineageRailProps['steps']; nodes: Record<string, MemoryNode> } {
  const sorted = [...episodes].sort((a, b) => a.timestamp - b.timestamp)
  const steps: MemoryLineageRailProps['steps'] = sorted.map((ep, i) => ({
    id: ep.id,
    t: formatEpisodeTime(ep.timestamp),
    rel: ep.event_type,
    anchor: i === sorted.length - 1,
  }))
  const nodes: Record<string, MemoryNode> = {}
  for (const ep of sorted) {
    nodes[ep.id] = {
      type: 'memory',
      title: ep.summary,
      kp: ep.participants[0] ?? fallbackKp,
      meta: ep.outcome,
      ns: ep.event_type,
    }
  }
  return { steps, nodes }
}

function SynapseWeightBar({ weight }: { weight: number }) {
  const pct = Math.round(weight * 100)
  return html`
    <${ProgressBar}
      pct=${pct}
      size="sm"
      trackClass="w-16 rounded-[var(--r-1)]"
      class=${synapseWeightFillClass(weight)}
      ariaLabel="시냅스 가중치 ${pct}%"
    />
  `
}

export function AgentDetailMemory({ agentName }: Props) {
  const resource = useManagedAsyncResource<MemorySubsystemsResponse>(null)
  const episodeQuery = useSignal('')
  const memOpen = useSignal(false)

  useEffect(() => {
    void resource.load(async (signal) =>
      fetchMemorySubsystems({
        keeper: normalizeKeeperName(agentName),
        limit: 10,
        signal,
      }),
    )
    return () => resource.cancel()
  }, [agentName, resource])

  const { loading, error, data } = resource.state.value
  if (loading) return html`<${LoadingState}>메모리 컨텍스트 로드 중...<//>`
  if (error)
    return html`<div class="text-sm text-[var(--color-status-warn)]" role="alert">메모리 로드 실패: ${error}</div>`
  if (!data) return html`<${LoadingState}>메모리 컨텍스트 로드 중...<//>`

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
    <${CollapsibleSection} class="v2-monitoring-detail" title="협업 & 기억" mountWhenOpen=${true}>
      <div class="space-y-4">
        <!-- Memory inspector trigger (rails.jsx:513-515 — ◈ 메모리 보기 · 핀 · 스토어 · 회상) -->
        <button
          type="button"
          class="cmp-open"
          onClick=${() => { memOpen.value = true }}
        >
          ${'◈'} 메모리 보기 <span class="cmp-open-sub">핀 · 스토어 · 회상</span>
        </button>

        <!-- Hebbian collaboration -->
        <div>
          <div class="text-xs text-[var(--color-fg-disabled)] uppercase tracking-wide mb-2">
            협업 시냅스 (나에게 연결된 ${myEdges.length}개)
          </div>
          ${
            myEdges.length === 0
              ? html`<div class="text-sm text-[var(--color-fg-disabled)]">
                  아직 협업 데이터가 없습니다. task 완료 시 자동 학습됩니다.
                </div>`
              : html`
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    ${outgoing.length > 0
                      ? html`
                          <div>
                            <div class="text-2xs text-[var(--color-fg-muted)] mb-1">
                              내가 강화한 파트너 (out, ${outgoing.length})
                            </div>
                            <div class="space-y-1">
                              ${outgoing.map(
                                (s: MemorySubsystemsSynapse) => html`
                                  <div class="v2-monitoring-row flex items-center gap-2 text-xs">
                                    <span class="font-mono flex-1 truncate">${normalizeKeeperName(s.to_agent)}</span>
                                    <${SynapseWeightBar} weight=${s.weight} />
                                    <span class="text-[var(--color-fg-muted)] w-10 text-right">${Math.round(s.weight * 100)}%</span>
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
                            <div class="text-2xs text-[var(--color-fg-muted)] mb-1">
                              나를 강화한 파트너 (in, ${incoming.length})
                            </div>
                            <div class="space-y-1">
                              ${incoming.map(
                                (s: MemorySubsystemsSynapse) => html`
                                  <div class="v2-monitoring-row flex items-center gap-2 text-xs">
                                    <span class="font-mono flex-1 truncate">${normalizeKeeperName(s.from_agent)}</span>
                                    <${SynapseWeightBar} weight=${s.weight} />
                                    <span class="text-[var(--color-fg-muted)] w-10 text-right">${Math.round(s.weight * 100)}%</span>
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
            <div class="text-xs text-[var(--color-fg-disabled)] uppercase tracking-wide">
              최근 에피소드 (${
                isFilteringEpisodes
                  ? `${visibleEpisodes.length}/${episodes.length}`
                  : `${data.episodes?.filtered ?? 0}`
              }개)
            </div>
            ${episodes.length > 0
              ? html`<${TextInput}
                  type="search"
                  value=${episodeQuery.value}
                  placeholder="summary / event / learning 필터"
                  ariaLabel="에피소드 필터"
                  onInput=${(e: Event) => {
                    episodeQuery.value = (e.target as HTMLInputElement).value
                  }}
                  class="min-w-40 max-w-60 flex-1 !px-2 !py-1 !text-2xs"
                />`
              : null}
          </div>
          ${
            episodes.length === 0
              ? html`<div class="text-sm text-[var(--color-fg-disabled)]">
                  이 키퍼의 에피소드 기록이 없습니다.
                </div>`
              : visibleEpisodes.length === 0
                ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">
                    필터 결과 없음 (${episodes.length}개 중 0)
                  </div>`
                : html`
                  <div role="log" aria-label="에피소드 목록" class="space-y-1.5 max-h-60 overflow-y-auto pr-1 custom-scrollbar">
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
                            ? 'text-[var(--color-status-ok)]'
                            : ep.outcome === 'partial'
                              ? 'text-[var(--color-status-warn)]'
                              : 'text-[var(--bad-light)]'
                        return html`
                          <div class="v2-monitoring-row border border-[var(--color-border-default)] rounded-[var(--r-1)] px-2.5 py-2 text-xs bg-[var(--color-bg-elevated)] hover:bg-[var(--color-bg-hover)] transition-colors">
                            <div class="flex items-center justify-between gap-2">
                              <div class="flex items-center gap-2 min-w-0">
                                <span class="${outcomeColor}">${outcomeIcon}</span>
                                <span class="truncate text-[var(--color-fg-primary)]">${highlightMatch(ep.summary, episodeQuery.value)}</span>
                              </div>
                              <span class="text-2xs text-[var(--color-fg-secondary)] shrink-0">${formatTimeAgo(ep.timestamp * 1000)}</span>
                            </div>
                            ${ep.learnings.length > 0
                              ? html`<div class="mt-1 text-2xs text-[var(--color-fg-secondary)] pl-3 border-l border-[var(--color-border-default)]">${highlightMatch(ep.learnings[0]!, episodeQuery.value)}</div>`
                              : null}
                          </div>
                        `
                      })}
                  </div>
                `
          }
        </div>

        <!-- Episode lineage rail -->
        ${episodes.length > 0
          ? html`
              <div>
                <div class="text-xs text-[var(--color-fg-disabled)] uppercase tracking-wide mb-2">
                  에피소드 인과 레일
                </div>
                ${(() => {
                  const { steps, nodes } = buildEpisodeLineage(visibleEpisodes, agentName)
                  return html`
                    <${MemoryLineageRail}
                      steps=${steps}
                      nodes=${nodes}
                      nodeTypes=${LINEAGE_NODE_TYPES}
                      ariaLabel="에피소드 인과 추적"
                    />
                  `
                })()}
              </div>
            `
          : null}
      </div>
      ${memOpen.value
        ? html`<${MemoryInspector}
            keeper=${resolveInspectorKeeper(agentName)}
            onClose=${() => { memOpen.value = false }}
          />`
        : null}
    <//>
  `
}
