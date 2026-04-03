// MASC Dashboard — Unified Agent Roster
// All entities are agents. Keeper = agent with persistent runtime.
// Keeper state (CTX gauge, generation, autonomy) shown inline on the card.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { Agent, Keeper } from '../types'
import type {
  DashboardMissionAgentBrief,
  DashboardMissionKeeperBrief,
} from '../types/dashboard-mission'
import {
  agents,
  keepers,
  serverStatus,
  executionLoaded,
  executionLoading,
  executionError,
  shellCounts,
} from '../store'
import { missionKeeperBriefs, missionAgentBriefs } from '../mission-signals'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { EmptyState } from './common/empty-state'
import { AgentAvatar } from './overview/agent-avatar'
import { openAgentDetail } from './agent-detail'
import { formatDuration, trimText } from './mission-utils'
import { namespaceTruth } from '../namespace-truth-store'
import {
  resolveRuntimeCounts,
  runtimeCountSourceLabel,
  shouldShowExecutionFallbackState,
} from '../runtime-counts'

type StatusFilter = 'all' | 'active' | 'idle' | 'offline'

function statusCategory(status: string | undefined): StatusFilter {
  if (!status) return 'idle'
  const s = status.toLowerCase()
  if (s === 'active' || s === 'busy' || s === 'listening' || s === 'working') return 'active'
  if (s === 'offline' || s === 'inactive') return 'offline'
  return 'idle'
}

function statusLabel(status: string | undefined): string {
  if (!status) return '상태 미수집'
  const labels: Record<string, string> = {
    active: '온라인', busy: '처리 중', listening: '응답 대기', working: '작업 실행 중',
    idle: '대기', offline: '오프라인', inactive: '종료됨',
  }
  return labels[status.toLowerCase()] ?? status
}

function statusDescription(status: string | undefined): string {
  if (!status) return '런타임 상태를 아직 받지 못했습니다.'
  const descriptions: Record<string, string> = {
    active: '연결되어 있고 요청을 받을 수 있는 상태입니다.',
    busy: '지금 응답이나 작업을 처리하고 있습니다.',
    listening: '연결된 상태에서 입력이나 다음 지시를 기다리고 있습니다.',
    working: '현재 작업을 수행 중입니다.',
    idle: '연결은 유지되지만 지금 표시할 작업은 없습니다.',
    offline: '하트비트가 없어 현재 접근할 수 없습니다. 수동으로 내렸거나 연결이 끊겼을 수 있습니다.',
    inactive: '등록은 남아 있지만 명시적으로 내려간 상태입니다.',
  }
  return descriptions[status.toLowerCase()] ?? '정의되지 않은 상태값입니다.'
}

function statusBadgeClass(status: string | undefined): string {
  const cat = statusCategory(status)
  if (cat === 'active') return 'roster-badge--active'
  if (cat === 'offline') return 'roster-badge--offline'
  return 'roster-badge--idle'
}

interface KeeperInfo {
  generation?: number | null
  context_ratio?: number | null
  model?: string | null
  current_work?: string | null
  last_turn_ago_s?: number | null
}

function findKeeper(agentName: string, keeperList: Keeper[], keeperBriefs: DashboardMissionKeeperBrief[]): KeeperInfo | null {
  // Try keeper briefs first (richer data from mission snapshot)
  for (const kb of keeperBriefs) {
    if (kb.name === agentName || kb.agent_name === agentName
        || agentName.includes(kb.name) || kb.name?.includes(agentName)) {
      return kb
    }
  }
  // Fallback to keeper signal store
  for (const k of keeperList) {
    if (k.name === agentName || k.agent_name === agentName
        || agentName.includes(k.name) || k.name?.includes(agentName)) {
      return k
    }
  }
  return null
}

type KeeperFilterMode = 'all' | 'agent-only' | 'keeper-only'

function expectedCountForKeeperFilter(
  keeperFilter: KeeperFilterMode,
  counts: ReturnType<typeof resolveRuntimeCounts>,
): number {
  if (keeperFilter === 'keeper-only') return counts.keepers
  if (keeperFilter === 'agent-only') return counts.agents
  return counts.totalRuntimes
}

const FILTER_META: Record<StatusFilter, { label: string; description: string }> = {
  all: {
    label: '전체 보기',
    description: '등록된 런타임 전체를 보여줍니다.',
  },
  active: {
    label: '온라인',
    description: 'active, busy, listening, working 상태를 묶어 보여줍니다.',
  },
  idle: {
    label: '작업 없음',
    description: '연결은 살아 있지만 현재 잡힌 작업이 없는 상태입니다.',
  },
  offline: {
    label: '연결 끊김',
    description: 'offline, inactive 상태를 묶어 보여줍니다.',
  },
}

function matchesKeeperFilter(
  agentName: string,
  keeperList: Keeper[],
  keeperBriefs: DashboardMissionKeeperBrief[],
  keeperFilter: KeeperFilterMode,
): boolean {
  if (keeperFilter === 'all') return true
  const isKeeper = findKeeper(agentName, keeperList, keeperBriefs) != null
  return keeperFilter === 'keeper-only' ? isKeeper : !isKeeper
}

export function scopeAgentsByKeeperFilter(
  agentList: Agent[],
  keeperList: Keeper[],
  keeperBriefs: DashboardMissionKeeperBrief[],
  keeperFilter: KeeperFilterMode,
): Agent[] {
  return agentList.filter((agent: Agent) =>
    matchesKeeperFilter(agent.name, keeperList, keeperBriefs, keeperFilter))
}

function keeperRuntimeName(source: Pick<Keeper, 'name' | 'agent_name'> | DashboardMissionKeeperBrief): string {
  const runtimeName = source.agent_name?.trim()
  return runtimeName && runtimeName.length > 0 ? runtimeName : source.name
}

function synthesizeAgentFromKeeper(source: Keeper | DashboardMissionKeeperBrief): Agent | null {
  const runtimeName = keeperRuntimeName(source)
  if (!runtimeName) return null

  const typed = source as Keeper & DashboardMissionKeeperBrief
  const linkedAgent = typed.agent

  return {
    name: runtimeName,
    agent_type: linkedAgent?.agent_type,
    status: (linkedAgent?.status as Agent['status'] | undefined) ?? (typed.status as Agent['status'] | undefined),
    current_task: linkedAgent?.current_task ?? typed.current_work ?? null,
    context_ratio: typed.context_ratio ?? undefined,
    joined_at: linkedAgent?.joined_at,
    last_seen: linkedAgent?.last_seen,
    capabilities: linkedAgent?.capabilities,
    emoji: typed.emoji,
    koreanName: typed.koreanName,
    model: typed.model,
    traits: typed.traits,
    activityLevel: typed.activityLevel,
    primaryValue: typed.primaryValue,
    synthetic: true,
  }
}

function mergeRosterAgent(existing: Agent | undefined, next: Agent): Agent {
  if (!existing) return next
  return {
    ...existing,
    agent_type: existing.agent_type ?? next.agent_type,
    status: existing.status ?? next.status,
    current_task: existing.current_task ?? next.current_task,
    context_ratio: existing.context_ratio ?? next.context_ratio,
    joined_at: existing.joined_at ?? next.joined_at,
    last_seen: existing.last_seen ?? next.last_seen,
    capabilities: existing.capabilities?.length ? existing.capabilities : next.capabilities,
    emoji: existing.emoji ?? next.emoji,
    koreanName: existing.koreanName ?? next.koreanName,
    model: existing.model ?? next.model,
    traits: existing.traits?.length ? existing.traits : next.traits,
    activityLevel: existing.activityLevel ?? next.activityLevel,
    primaryValue: existing.primaryValue ?? next.primaryValue,
  }
}

export function buildAgentRoster(
  agentList: Agent[],
  keeperList: Keeper[],
  keeperBriefs: DashboardMissionKeeperBrief[],
): Agent[] {
  const roster = new Map<string, Agent>()

  for (const agent of agentList) {
    roster.set(agent.name, agent)
  }

  for (const source of [...keeperList, ...keeperBriefs]) {
    const synthetic = synthesizeAgentFromKeeper(source)
    if (!synthetic) continue
    roster.set(synthetic.name, mergeRosterAgent(roster.get(synthetic.name), synthetic))
  }

  return Array.from(roster.values())
}

export function countAgentsByStatus(agentList: Agent[]): Record<StatusFilter, number> {
  return {
    all: agentList.length,
    active: agentList.filter((agent: Agent) => statusCategory(agent.status) === 'active').length,
    idle: agentList.filter((agent: Agent) => statusCategory(agent.status) === 'idle').length,
    offline: agentList.filter((agent: Agent) => statusCategory(agent.status) === 'offline').length,
  }
}

export function countRuntimeKinds(
  agentList: Agent[],
  keeperList: Keeper[],
  keeperBriefs: DashboardMissionKeeperBrief[],
): { agents: number; keepers: number; totalRuntimes: number } {
  const rosterAgents = buildAgentRoster(agentList, keeperList, keeperBriefs)
  const keeperCount = scopeAgentsByKeeperFilter(rosterAgents, keeperList, keeperBriefs, 'keeper-only').length
  const agentCount = scopeAgentsByKeeperFilter(rosterAgents, keeperList, keeperBriefs, 'agent-only').length

  return {
    agents: agentCount,
    keepers: keeperCount,
    totalRuntimes: rosterAgents.length,
  }
}

export function AgentRoster({ keeperFilter = 'all' }: { keeperFilter?: KeeperFilterMode } = {}) {
  const [filter, setFilter] = useState<StatusFilter>('all')
  const [search, setSearch] = useState('')

  const agentList = agents.value
  const keeperList = keepers.value
  const briefs = missionAgentBriefs.value
  const keeperBriefs = missionKeeperBriefs.value
  const liveRuntimeCounts = countRuntimeKinds(agentList, keeperList, keeperBriefs)
  const rosterAgents = buildAgentRoster(agentList, keeperList, keeperBriefs)
  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: liveRuntimeCounts.agents,
    keepersCount: liveRuntimeCounts.keepers,
    namespaceTruthCounts: namespaceTruth.value?.namespace.counts,
    shellCounts: shellCounts.value,
  })
  const expectedScopedCount = expectedCountForKeeperFilter(keeperFilter, runtimeCounts)
  const countSourceLabel = runtimeCountSourceLabel(runtimeCounts.source)
  const roomStatus = namespaceTruth.value?.namespace.status ?? serverStatus.value
  const roomName = roomStatus?.namespace ?? 'default'
  const roomBasePath = roomStatus?.namespace_base_path ?? null

  const briefMap = new Map<string, DashboardMissionAgentBrief>(
    briefs.map(brief => [brief.agent_name, brief] as const),
  )
  const hasKeeperRuntime =
    keeperFilter !== 'agent-only'
    && (keeperList.length > 0 || keeperBriefs.length > 0 || runtimeCounts.keepers > 0)
  const scopedAgents = scopeAgentsByKeeperFilter(rosterAgents, keeperList, keeperBriefs, keeperFilter)
  const pageTitle = keeperFilter === 'keeper-only'
    ? '키퍼 런타임'
    : keeperFilter === 'agent-only'
      ? '일반 에이전트'
      : '에이전트 목록'
  const pageDescription = keeperFilter === 'keeper-only'
    ? '장기 컨텍스트를 유지하는 상주 런타임만 보여줍니다.'
    : keeperFilter === 'agent-only'
      ? '키퍼가 연결되지 않은 일반 에이전트만 보여줍니다.'
      : '등록된 모든 런타임을 보여줍니다. 키퍼는 장기 컨텍스트를 유지하는 상주 런타임입니다.'

  const filtered = scopedAgents
    .filter((a: Agent) => {
      if (filter !== 'all' && statusCategory(a.status) !== filter) return false
      if (search && !a.name.toLowerCase().includes(search.toLowerCase())) return false
      return true
    })
    .sort((a: Agent, b: Agent) => {
      const order: Record<StatusFilter, number> = {
        all: 0,
        active: 0,
        idle: 1,
        offline: 2,
      }
      const aOrder = order[statusCategory(a.status)]
      const bOrder = order[statusCategory(b.status)]
      if (aOrder !== bOrder) return aOrder - bOrder
      return a.name.localeCompare(b.name)
    })

  const counts = countAgentsByStatus(scopedAgents)
  const showExecutionFallbackState = shouldShowExecutionFallbackState({
    executionLoaded: executionLoaded.value,
    executionLoading: executionLoading.value,
    executionError: executionError.value,
    loadedCount: scopedAgents.length,
    expectedCount: expectedScopedCount,
  })
  const resultCountLabel =
    expectedScopedCount > scopedAgents.length
      ? (
          filtered.length === scopedAgents.length
            ? `${filtered.length}개 로드됨 · 예상 ${expectedScopedCount}개`
            : `${filtered.length} / ${scopedAgents.length}개 표시 · 예상 ${expectedScopedCount}개`
        )
      : (
          filtered.length === scopedAgents.length
            ? `${filtered.length}개 표시 중`
            : `${filtered.length} / ${scopedAgents.length}개 표시 중`
        )
  const statusChips = (['all', 'active', 'idle', 'offline'] as StatusFilter[]).map(key => ({
    key,
    label: FILTER_META[key].label,
    count: executionLoaded.value || scopedAgents.length > 0 ? counts[key] : null,
    title: FILTER_META[key].description,
  }))
  const scopeLabel = keeperFilter === 'keeper-only'
    ? `키퍼 ${expectedScopedCount}개`
    : keeperFilter === 'agent-only'
      ? `일반 에이전트 ${expectedScopedCount}개`
      : `런타임 ${expectedScopedCount}개`
  const fallbackStateTitle =
    executionError.value
      ? 'execution 상세 불러오기 실패'
      : executionLoaded.value
        ? '상세 runtime 부분 동기화'
        : '상세 runtime 동기화 중'
  const fallbackStateMessage =
    executionError.value
      ? `${countSourceLabel} 기준 ${scopeLabel}가 등록되어 있지만 execution 상세 projection을 아직 가져오지 못했습니다.`
      : executionLoaded.value
        ? `${countSourceLabel} 기준 ${scopeLabel}가 등록되어 있고 일부만 상세 목록에 반영됐습니다.`
        : `${countSourceLabel} 기준 ${scopeLabel}가 등록되어 있습니다. execution 상세 projection이 올라오면 상태별 분류와 카드가 채워집니다.`
  const legendCards = [
    {
      title: '온라인',
      body: '응답을 받을 수 있는 연결 상태입니다. active, busy, listening, working 값을 한데 묶습니다.',
    },
    {
      title: '작업 없음',
      body: '연결은 살아 있지만 지금 카드에 보여줄 현재 작업이 없는 상태입니다.',
    },
    {
      title: '연결 끊김',
      body: '하트비트가 없거나 런타임이 내려간 상태입니다.',
    },
    ...(hasKeeperRuntime
      ? [{
          title: '세대 / 컨텍스트 사용량',
          body: '세대는 키퍼 핸드오프가 일어날 때 올라가는 런타임 번호입니다. 컨텍스트 사용량은 현재 창을 얼마나 쓰고 있는지 보여줍니다.',
        }]
      : []),
  ]

  return html`
    <div class="agent-page flex w-full flex-col gap-5 px-0 py-1">
      <section class="monitor-surface-card monitor-surface-card-strong p-5">
        <div class="flex flex-col gap-5">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div class="flex min-w-0 flex-col gap-3">
              <div class="flex flex-wrap items-center gap-3">
                <h2 class="m-0 text-[20px] font-semibold tracking-[-0.02em] text-[var(--text-strong)]">${pageTitle}</h2>
                <span class="inline-flex items-center rounded-full border border-[var(--border-slate-22)] bg-[var(--accent-soft)] px-2.5 py-1 text-[11px] font-medium text-[var(--text-strong)]">${resultCountLabel}</span>
              </div>
              <p class="m-0 max-w-[720px] text-[13px] leading-[1.6] text-[var(--text-body)]">${pageDescription}</p>
            </div>

            <label class="flex w-full max-w-[320px] flex-col gap-2 text-[11px] font-semibold tracking-[0.08em] text-[var(--text-muted)] uppercase">
              <span>에이전트 이름으로 찾기</span>
              <${TextInput}
                class="rounded-2xl bg-[var(--white-3)] px-4 py-3 text-[14px] text-[var(--text-body)] shadow-[inset_0_1px_0_var(--white-3)] focus:border-[var(--accent)] focus:shadow-[0_0_0_2px_var(--accent-soft)]"
                name="agent_search"
                ariaLabel="에이전트 이름 검색"
                autoComplete="off"
                placeholder="에이전트 이름으로 찾기"
                value=${search}
                onInput=${(e: Event) => setSearch((e.target as HTMLInputElement).value)}
              />
            </label>
          </div>

          <div class="monitor-muted-panel p-3.5 md:p-4">
            <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
              <div class="flex flex-col gap-1">
                <div class="text-[11px] font-semibold tracking-[0.08em] text-[var(--text-strong)] uppercase">연결 상태</div>
                <p class="m-0 text-[12px] leading-[1.5] text-[var(--text-muted)]">상태별로 카드를 좁혀 보면서 현재 응답 가능 런타임과 유휴 런타임을 구분합니다.</p>
              </div>
              <${FilterChips}
                chips=${statusChips}
                value=${filter}
                onChange=${(key: StatusFilter) => setFilter(key)}
                size="md"
                tone="accent"
              />
            </div>
          </div>

          ${showExecutionFallbackState
            ? html`
                <div class="rounded-2xl border ${executionError.value ? 'border-[rgba(251,191,36,0.28)] bg-[rgba(251,191,36,0.08)]' : 'border-[rgba(71,184,255,0.18)] bg-[rgba(71,184,255,0.08)]'} px-4 py-3 shadow-[0_10px_28px_rgba(0,0,0,0.12)]">
                  <div class="flex flex-col gap-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <strong class="text-[12px] font-semibold text-[var(--text-strong)]">${fallbackStateTitle}</strong>
                      <span class="inline-flex items-center rounded-full border border-[var(--white-10)] bg-[var(--white-6)] px-2 py-0.5 text-[10px] font-medium text-[var(--text-muted)]">${countSourceLabel}</span>
                    </div>
                    <p class="m-0 text-[12px] leading-[1.55] text-[var(--text-body)]">${fallbackStateMessage}</p>
                    <div class="flex flex-wrap items-center gap-2 text-[11px] text-[var(--text-muted)]">
                      <span class="rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">room ${roomName}</span>
                      ${roomBasePath ? html`<code class="rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5 text-[10px]">${roomBasePath}</code>` : null}
                    </div>
                  </div>
                </div>
              `
            : null}

          <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            ${legendCards.map(card => html`
              <div class="monitor-muted-panel px-4 py-4 shadow-[0_8px_24px_rgba(0,0,0,0.12)]">
                <div class="text-[11px] font-semibold text-[var(--text-strong)]">${card.title}</div>
                <p class="m-0 mt-2 text-[12px] leading-[1.55] text-[var(--text-muted)]">${card.body}</p>
              </div>
            `)}
          </div>
        </div>
      </section>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
        ${filtered.map((agent: Agent) => {
          const brief = briefMap.get(agent.name)
          const keeper = findKeeper(agent.name, keeperList, keeperBriefs)
          const isKeeper = keeper != null
          const currentWork = keeper?.current_work ?? brief?.current_work ?? agent.current_task ?? null
          const lastActivity = keeper?.last_turn_ago_s ?? brief?.last_activity_age_sec ?? null
          const ctxPct = keeper?.context_ratio != null ? Math.round(keeper.context_ratio * 100) : null
          const workPreview = trimText(currentWork, 140) ?? '표시할 작업 정보가 없습니다.'
          const lastActivityLabel = lastActivity != null ? `${formatDuration(lastActivity)} 전` : '활동 기록 없음'

          return html`
            <button type="button"
              class="monitor-surface-card monitor-surface-card-medium group flex min-h-[308px] w-full flex-col gap-4 rounded-[22px] p-5 text-left transition-all duration-200 cursor-pointer hover:border-[var(--border-slate-22)] hover:bg-[var(--bg-1)] hover:-translate-y-0.5"
              key=${agent.name}
              aria-label=${`${agent.name} 상세 보기`}
              onClick=${() => openAgentDetail(agent.name)}
            >
              <div class="flex items-start gap-4">
                <div class="shrink-0 relative">
                  <${AgentAvatar}
                    name=${agent.name}
                    status=${agent.status}
                    traits=${agent.traits}
                    size="xl"
                    currentWork=${currentWork}
                    activityAge=${lastActivity}
                  />
                </div>
                
                <div class="flex flex-col min-w-0 flex-1 justify-center py-1">
                  <strong class="mb-2 min-w-0 overflow-hidden text-[17px] text-[var(--text-strong)] font-semibold leading-[1.3] group-hover:text-[var(--accent)] transition-colors [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2] [overflow-wrap:anywhere]">${agent.name}</strong>
                  
                  <div class="flex items-center gap-1.5 flex-wrap mt-1">
                    <span class="roster-badge ${statusBadgeClass(agent.status)}" title=${statusDescription(agent.status)}>${statusLabel(agent.status)}</span>
                    <span class="text-[11px] text-[var(--text-muted)] bg-[var(--white-4)] border border-[var(--card-border)] px-2 py-0.5 rounded-full">${isKeeper ? '키퍼 런타임' : '일반 에이전트'}</span>
                    ${agent.synthetic ? html`<span class="text-[10px] text-[var(--text-muted)] bg-[var(--white-6)] border border-dashed border-[var(--card-border)] px-1.5 py-px rounded italic" title="키퍼 데이터에서 파생된 합성 엔트리입니다.">파생</span>` : null}
                    ${keeper?.model ? html`<span class="font-mono text-[10px] text-[var(--text-muted)] bg-[var(--white-4)] border border-[var(--card-border)] px-1.5 py-px rounded">${keeper.model}</span>` : null}
                    ${keeper?.generation != null ? html`<span class="text-[11px] text-[var(--accent)] font-medium bg-[var(--accent-10)] px-1.5 py-px rounded border border-[rgba(71,184,255,0.15)]" title="키퍼 핸드오프가 일어날 때 올라가는 런타임 세대입니다.">세대 ${keeper.generation}</span>` : null}
                  </div>
                </div>
              </div>

              <div class="flex flex-1 flex-col gap-3 border-t border-[var(--border-slate-12)] pt-3">
                <div class="rounded-2xl border border-[var(--white-6)] bg-[var(--white-2)] px-3 py-3">
                  <div class="text-[10px] font-semibold tracking-[0.08em] uppercase text-[var(--text-muted)]">현재 하는 일</div>
                  <p class="mt-1 text-[13px] leading-[1.5] text-[var(--text-strong)] break-words" title=${currentWork ?? ''}>${workPreview}</p>
                </div>

                <div class="flex flex-wrap gap-2">
                  <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2.5 py-1 text-[11px] text-[var(--text-muted)]">
                    최근 활동 ${lastActivityLabel}
                  </span>
                  ${isKeeper ? html`
                    <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2.5 py-1 text-[11px] text-[var(--text-muted)]">
                      컨텍스트 ${ctxPct != null ? `${ctxPct}% 사용` : '대기 중'}
                    </span>
                  ` : null}
                </div>

                ${isKeeper ? html`
                  ${ctxPct != null ? html`
                    <div class="rounded-2xl border border-[var(--white-6)] bg-[var(--white-2)] px-3 py-3">
                      <div class="mb-2 flex items-center justify-between gap-3 text-[11px]">
                        <span class="text-[var(--text-muted)]">컨텍스트 사용량</span>
                        <strong class="text-[var(--text-strong)]">${ctxPct}%</strong>
                      </div>
                      <div class="h-2 overflow-hidden rounded-full bg-[var(--white-6)]">
                        <div
                          class="h-full rounded-full bg-linear-to-r from-[var(--accent)] to-[var(--ok)]"
                          style=${{ width: `${ctxPct}%` }}
                        ></div>
                      </div>
                      <p class="mt-2 text-[11px] leading-[1.45] text-[var(--text-muted)]">키퍼가 현재 컨텍스트 창을 얼마나 쓰고 있는지 보여줍니다.</p>
                    </div>
                  ` : html`
                    <div class="rounded-2xl border border-dashed border-[var(--white-8)] bg-[var(--white-2)] px-3 py-3">
                      <div class="flex items-center justify-between gap-3 text-[11px]">
                        <span class="text-[var(--text-muted)]">컨텍스트 사용량</span>
                        <strong class="text-[var(--text-strong)]">대기 중</strong>
                      </div>
                      <p class="mt-2 text-[11px] leading-[1.45] text-[var(--text-muted)]">아직 메트릭이 보고되지 않았습니다. 키퍼가 첫 턴을 시작하면 자동으로 갱신됩니다.</p>
                    </div>
                  `}
                ` : null}
              </div>
            </button>
          `
        })}
        ${filtered.length === 0 ? html`
          <div class="col-span-full rounded-[24px] border border-dashed border-[var(--ff-border-subtle)] bg-[var(--white-2)] px-6 py-10">
            <${EmptyState}
              message=${showExecutionFallbackState && expectedScopedCount > 0
                ? `${fallbackStateTitle}: ${countSourceLabel} 기준 ${scopeLabel}가 보이지만, 현재 조건에 맞는 상세 카드는 아직 없습니다.`
                : '조건에 맞는 에이전트가 없습니다.'}
              compact
            />
          </div>
        ` : null}
      </div>
    </div>
  `
}
