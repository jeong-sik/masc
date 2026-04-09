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
import { TimeAgo } from './common/time-ago'
import { AgentAvatar } from './overview/agent-avatar'
import { openAgentDetail } from './agent-detail'
import { openKeeperDetail } from './keeper-detail'
import { formatDuration, trimText } from './mission-utils'
import { namespaceTruth } from '../namespace-truth-store'
import {
  keeperPhaseForDisplay,
  runtimeBandMeta,
  runtimeBandMetaForAgent,
  summarizeMonitoringEvidence,
  summarizeKeeperMonitoring,
  type RuntimeBand,
} from '../lib/monitoring-runtime'
import { KeeperPhaseBadge } from './keeper-phase-indicator'
import {
  resolveRuntimeCounts,
  runtimeCountSourceLabel,
  shouldShowExecutionFallbackState,
} from '../runtime-counts'

type StatusFilter = 'all' | RuntimeBand

function runtimeBadgeClass(band: RuntimeBand): string {
  if (band === 'active') return 'border-[rgba(52,211,153,0.2)] bg-[rgba(52,211,153,0.12)] text-[var(--ok)]'
  if (band === 'attention') return 'border-[rgba(251,191,36,0.2)] bg-[rgba(251,191,36,0.12)] text-[var(--warn)]'
  if (band === 'paused') return 'border-[rgba(167,139,250,0.2)] bg-[rgba(167,139,250,0.12)] text-[#a78bfa]'
  return 'border-[var(--white-8)] bg-[var(--white-4)] text-[var(--text-dim)]'
}

interface KeeperInfo {
  generation?: number | null
  context_ratio?: number | null
  model?: string | null
  current_work?: string | null
  last_turn_ago_s?: number | null
  last_autonomous_action_at?: string | null
  recent_tool_names?: string[]
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_at?: string | null
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

function findKeeperRuntime(agentName: string, keeperList: Keeper[]): Keeper | null {
  for (const keeper of keeperList) {
    if (
      keeper.name === agentName
      || keeper.agent_name === agentName
      || agentName.includes(keeper.name)
      || keeper.name.includes(agentName)
    ) {
      return keeper
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
    label: '가동중',
    description: '운영자 개입 없이 흐름을 지켜봐도 되는 상태를 묶어 보여줍니다.',
  },
  attention: {
    label: '주의 필요',
    description: '오류, 복구, 승계, stale heartbeat, blocker 등 운영 확인이 필요한 상태입니다.',
  },
  paused: {
    label: '일시정지',
    description: '운영자가 멈춰 둔 상태를 따로 모아 봅니다.',
  },
  offline: {
    label: '오프라인',
    description: '프로세스가 내려갔거나 아직 기동되지 않은 상태입니다.',
  },
}

function uniqueToolNames(...groups: Array<string[] | null | undefined>): string[] {
  const seen = new Set<string>()
  const names: string[] = []
  for (const group of groups) {
    for (const entry of group ?? []) {
      const name = entry.trim()
      if (!name || seen.has(name)) continue
      seen.add(name)
      names.push(name)
    }
  }
  return names
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

export function countAgentsByStatus(
  agentList: Agent[],
  keeperList: Keeper[],
): Record<StatusFilter, number> {
  const counts: Record<StatusFilter, number> = {
    all: agentList.length,
    active: 0,
    attention: 0,
    paused: 0,
    offline: 0,
  }

  for (const agent of agentList) {
    const keeperRuntime = findKeeperRuntime(agent.name, keeperList)
    const band = runtimeBandMetaForAgent(agent, keeperRuntime).key
    counts[band] += 1
  }

  return counts
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
  const namespaceStatus = namespaceTruth.value?.namespace.status ?? serverStatus.value
  const namespaceName = namespaceStatus?.namespace ?? 'default'
  const namespaceBasePath = namespaceStatus?.namespace_base_path ?? null

  const briefMap = new Map<string, DashboardMissionAgentBrief>(
    briefs.map(brief => [brief.agent_name, brief] as const),
  )
  const scopedAgents = scopeAgentsByKeeperFilter(rosterAgents, keeperList, keeperBriefs, keeperFilter)
  const bandByAgent = new Map(
    scopedAgents.map(agent => [agent.name, runtimeBandMetaForAgent(agent, findKeeperRuntime(agent.name, keeperList))] as const),
  )
  const pageTitle = keeperFilter === 'keeper-only'
    ? '키퍼 런타임'
    : keeperFilter === 'agent-only'
      ? '일반 에이전트'
      : '통합 런타임 목록'
  const pageDescription = keeperFilter === 'keeper-only'
    ? '키퍼 런타임만 따로 봅니다.'
    : keeperFilter === 'agent-only'
      ? '키퍼가 연결되지 않은 일반 에이전트만 봅니다.'
      : '에이전트와 키퍼를 한 목록에서 봅니다.'

  const filtered = scopedAgents
    .filter((a: Agent) => {
      if (filter !== 'all' && bandByAgent.get(a.name)?.key !== filter) return false
      if (search && !a.name.toLowerCase().includes(search.toLowerCase())) return false
      return true
    })
    .sort((a: Agent, b: Agent) => {
      const order: Record<StatusFilter, number> = {
        all: 0,
        attention: 0,
        active: 1,
        paused: 2,
        offline: 3,
      }
      const aOrder = order[bandByAgent.get(a.name)?.key ?? 'attention']
      const bOrder = order[bandByAgent.get(b.name)?.key ?? 'attention']
      if (aOrder !== bOrder) return aOrder - bOrder
      return a.name.localeCompare(b.name)
    })

  const counts = countAgentsByStatus(scopedAgents, keeperList)
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
  const statusChips = (['all', 'attention', 'active', 'paused', 'offline'] as StatusFilter[]).map(key => ({
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
                <div class="text-[11px] font-semibold tracking-[0.08em] text-[var(--text-strong)] uppercase">운영 상태</div>
                <p class="m-0 text-[12px] leading-[1.5] text-[var(--text-muted)]">먼저 운영 상태로 걸러 보고, 필요할 때만 phase와 현재 활동 근거를 확인합니다.</p>
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
                <div class="rounded-2xl border ${executionError.value ? 'border-[rgba(251,191,36,0.28)] bg-[var(--warn-10)]' : 'border-[var(--accent-20)] bg-[var(--accent-10)]'} px-4 py-3 shadow-[0_10px_28px_rgba(0,0,0,0.12)]">
                  <div class="flex flex-col gap-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <strong class="text-[12px] font-semibold text-[var(--text-strong)]">${fallbackStateTitle}</strong>
                      <span class="inline-flex items-center rounded-full border border-[var(--white-10)] bg-[var(--white-6)] px-2 py-0.5 text-[10px] font-medium text-[var(--text-muted)]">${countSourceLabel}</span>
                    </div>
                    <p class="m-0 text-[12px] leading-[1.55] text-[var(--text-body)]">${fallbackStateMessage}</p>
                    <div class="flex flex-wrap items-center gap-2 text-[11px] text-[var(--text-muted)]">
                      <span class="rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5">scope ${namespaceName}</span>
                      ${namespaceBasePath ? html`<code class="rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5 text-[10px]">${namespaceBasePath}</code>` : null}
                    </div>
                  </div>
                </div>
              `
            : null}
        </div>
      </section>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
        ${filtered.map((agent: Agent) => {
          const brief = briefMap.get(agent.name)
          const keeper = findKeeper(agent.name, keeperList, keeperBriefs)
          const keeperRuntime = findKeeperRuntime(agent.name, keeperList)
          const band = bandByAgent.get(agent.name) ?? runtimeBandMeta('attention')
          const keeperMonitoring = keeperRuntime ? summarizeKeeperMonitoring(keeperRuntime) : null
          const monitoringEvidence = keeperMonitoring ? summarizeMonitoringEvidence(keeperMonitoring) : null
          const isKeeper = keeper != null
          const currentWork = keeper?.current_work ?? brief?.current_work ?? agent.current_task ?? null
          const lastActivityAge = keeperRuntime?.last_activity_ago_s ?? keeper?.last_turn_ago_s ?? brief?.last_activity_age_sec ?? null
          const lastActivityAt =
            brief?.last_activity_at
            ?? keeper?.last_autonomous_action_at
            ?? keeperRuntime?.last_autonomous_action_at
            ?? keeperRuntime?.last_heartbeat
            ?? agent.last_seen
            ?? null
          const ctxPct = (keeperRuntime?.context_ratio ?? keeper?.context_ratio) != null
            ? Math.round((keeperRuntime?.context_ratio ?? keeper?.context_ratio ?? 0) * 100)
            : null
          const workPreview =
            trimText(currentWork, 140)
            ?? trimText(brief?.recent_output_preview, 140)
            ?? trimText(keeperRuntime?.recent_output_preview, 140)
            ?? trimText(brief?.recent_input_preview, 140)
            ?? trimText(keeperRuntime?.recent_input_preview, 140)
            ?? '최근 활동 요약 없음'
          const summaryText =
            band.key === 'active'
              ? workPreview
              : keeperMonitoring?.hint ?? workPreview
          const recentTools = uniqueToolNames(
            brief?.recent_tool_names,
            brief?.latest_tool_names,
            keeperRuntime?.recent_tool_names,
            keeperRuntime?.latest_tool_names,
            keeper?.recent_tool_names,
            keeper?.latest_tool_names,
          )
          const visibleTools = recentTools.slice(0, 2)
          const hiddenToolCount = Math.max(0, recentTools.length - visibleTools.length)
          const toolCallCount =
            brief?.latest_tool_call_count
            ?? keeper?.latest_tool_call_count
            ?? keeperRuntime?.latest_tool_call_count
            ?? null
          const toolAuditAt =
            brief?.tool_audit_at
            ?? keeper?.tool_audit_at
            ?? keeperRuntime?.tool_audit_at
            ?? null
          const model = keeperRuntime?.model ?? keeper?.model
          const generation = keeperRuntime?.generation ?? keeper?.generation ?? null
          const detailLabel = keeperRuntime ? `${agent.name} keeper 상세 보기` : `${agent.name} 상세 보기`
          const openDetail = () => {
            if (keeperRuntime) {
              openKeeperDetail(keeperRuntime)
              return
            }
            openAgentDetail(agent.name)
          }

          return html`
            <button type="button"
              class="monitor-surface-card monitor-surface-card-medium group flex w-full flex-col gap-4 rounded-[var(--radius-xl)] p-5 text-left transition-all duration-200 cursor-pointer hover:border-[var(--border-slate-22)] hover:bg-[var(--bg-1)] hover:-translate-y-0.5"
              key=${agent.name}
              aria-label=${detailLabel}
              onClick=${openDetail}
            >
              <div class="flex items-start gap-4">
                <div class="shrink-0 relative">
                  <${AgentAvatar}
                    name=${agent.name}
                    status=${agent.status}
                    traits=${agent.traits}
                    size="xl"
                    currentWork=${currentWork}
                    activityAge=${lastActivityAge}
                  />
                </div>
                
                <div class="flex flex-col min-w-0 flex-1 justify-center py-1">
                  <strong class="mb-2 min-w-0 overflow-hidden text-[17px] text-[var(--text-strong)] font-semibold leading-[1.3] group-hover:text-[var(--accent)] transition-colors [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2] [overflow-wrap:anywhere]">${agent.name}</strong>
                  
                  <div class="flex items-center gap-1.5 flex-wrap mt-1">
                    <span class="inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-semibold ${runtimeBadgeClass(band.key)}" title=${band.description}>${band.label}</span>
                    <span class="text-[11px] text-[var(--text-muted)] bg-[var(--white-4)] border border-[var(--card-border)] px-2 py-0.5 rounded-full">${isKeeper ? '키퍼 런타임' : '일반 에이전트'}</span>
                    ${agent.synthetic ? html`<span class="text-[10px] text-[var(--text-muted)] bg-[var(--white-6)] border border-dashed border-[var(--card-border)] px-1.5 py-px rounded italic" title="키퍼 데이터에서 파생된 합성 엔트리입니다.">파생</span>` : null}
                    ${monitoringEvidence?.phase && keeperRuntime ? html`<${KeeperPhaseBadge} phase=${keeperPhaseForDisplay(keeperRuntime)} compact />` : null}
                    ${monitoringEvidence?.stage ? html`<span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-4)] px-2 py-0.5 text-[10px] font-medium text-[var(--text-muted)]" title=${monitoringEvidence.stage.description}>활동 ${monitoringEvidence.stage.label}</span>` : null}
                    ${model ? html`<span class="font-mono text-[10px] text-[var(--text-muted)] bg-[var(--white-4)] border border-[var(--card-border)] px-1.5 py-px rounded">${model}</span>` : null}
                    ${generation != null ? html`<span class="text-[11px] text-[var(--accent)] font-medium bg-[var(--accent-10)] px-1.5 py-px rounded border border-[var(--accent-10)]" title="키퍼 핸드오프가 일어날 때 올라가는 런타임 세대입니다.">세대 ${generation}</span>` : null}
                  </div>
                </div>
              </div>

              <div class="flex flex-1 flex-col gap-3 border-t border-[var(--border-slate-12)] pt-3">
                <p class="m-0 text-[13px] leading-[1.5] text-[var(--text-body)] break-words line-clamp-3" title=${summaryText}>${summaryText}</p>

                <div class="flex flex-wrap items-center gap-2 text-[11px] text-[var(--text-muted)]">
                  <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2.5 py-1">
                    최근 활동 ${lastActivityAt
                      ? html`<${TimeAgo} timestamp=${lastActivityAt} />`
                      : lastActivityAge != null
                        ? `${formatDuration(lastActivityAge)} 전`
                        : '기록 없음'}
                  </span>
                  ${isKeeper && ctxPct != null ? html`
                    <span class="inline-flex items-center gap-1.5 rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2.5 py-1">
                      CTX
                      <span class="font-mono font-medium ${ctxPct > 85 ? 'text-[var(--bad)]' : ctxPct > 60 ? 'text-[var(--warn)]' : 'text-[var(--text-strong)]'}">${ctxPct}%</span>
                      <span class="inline-block w-12 h-1.5 rounded-full bg-[var(--white-6)] overflow-hidden">
                        <span class="block h-full rounded-full ${ctxPct > 85 ? 'bg-[var(--bad)]' : ctxPct > 60 ? 'bg-[var(--warn)]' : 'bg-[var(--ok)]'}" style="width:${ctxPct}%"></span>
                      </span>
                    </span>
                  ` : null}
                </div>

                ${(visibleTools.length > 0 || toolCallCount != null || toolAuditAt) ? html`
                  <div class="flex flex-wrap items-center gap-1.5 text-[11px] text-[var(--text-muted)]">
                    <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2 py-0.5">tool</span>
                    ${visibleTools.map(name => html`
                      <span class="inline-flex items-center rounded-full border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 font-mono text-[10px] text-[var(--text-body)]">
                        ${name}
                      </span>
                    `)}
                    ${hiddenToolCount > 0 ? html`
                      <span class="inline-flex items-center rounded-full border border-dashed border-[var(--white-8)] bg-[var(--white-2)] px-2 py-0.5 text-[10px]">
                        +${hiddenToolCount}
                      </span>
                    ` : null}
                    ${visibleTools.length === 0 && toolCallCount === 0 ? html`
                      <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2 py-0.5 text-[10px]">
                        최근 도구 없음
                      </span>
                    ` : null}
                    ${visibleTools.length === 0 && toolCallCount != null && toolCallCount > 0 ? html`
                      <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2 py-0.5 text-[10px]">
                        도구 ${toolCallCount}회
                      </span>
                    ` : null}
                    ${toolAuditAt ? html`
                      <span class="inline-flex items-center rounded-full border border-[var(--white-8)] bg-[var(--white-2)] px-2 py-0.5 text-[10px]">
                        감사 <${TimeAgo} timestamp=${toolAuditAt} />
                      </span>
                    ` : null}
                  </div>
                ` : null}
              </div>
            </button>
          `
        })}
        ${filtered.length === 0 ? html`
          <div class="col-span-full rounded-[var(--radius-xl)] border border-dashed border-[var(--ff-border-subtle)] bg-[var(--white-2)] px-6 py-10">
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
