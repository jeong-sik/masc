// MASC Dashboard — Unified Agent Roster
// All entities are agents. Keeper = agent with persistent runtime.
// Keeper state (CTX gauge, autonomy) shown inline on the card.

import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import type { Agent, Keeper } from '../types'
import {
  agents,
  keepers,
  serverStatus,
  executionLoaded,
  executionLoading,
  executionError,
  shellCounts,
} from '../store'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { EmptyState } from './common/empty-state'
import { TimeAgo } from './common/time-ago'
import {
  keeperIdentityKeys,
  keeperIdentitySearchTerms,
  keeperPrincipalKey,
  keeperPrimaryName,
} from './common/keeper-identity'
import { AgentAvatar } from './overview/agent-avatar'
import { AgentPresence } from './common/agent-presence'
import { AgentCapability } from './common/agent-capability'
import { openAgentDetail } from './agent-detail-state'
import { openKeeperDetail } from './keeper-detail'
import { formatDuration, trimText } from './mission-utils'
import { formatTokens } from '../lib/format-number'
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
import {
  keeperActivityDisplay,
  keeperDisplayModel,
} from '../lib/keeper-runtime-display'

type StatusFilter = 'all' | RuntimeBand

function stageBadgeClass(stageKey: string): string {
  if (stageKey === 'tool_use') return 'border-[var(--info-border)] bg-[var(--accent-12)] text-[var(--color-accent-fg)]'
  if (stageKey === 'scheduled_autonomous' || stageKey === 'thinking') return 'border-[var(--ok-border)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]'
  if (stageKey === 'handoff' || stageKey === 'compacting') return 'border-[var(--purple-24)] bg-[var(--purple-12)] text-[var(--stalled-fg)]'
  if (stageKey === 'failing' || stageKey === 'crashed') return 'border-[var(--err-border)] bg-[var(--bad-soft)] text-[var(--color-status-err)]'
  if (stageKey === 'paused') return 'border-[var(--purple-24)] bg-[var(--purple-12)] text-[var(--purple)]'
  return 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]'
}

function compactModelLabel(model: string | null | undefined): string | null {
  const value = model?.trim()
  if (!value) return null
  const separator = value.indexOf(':')
  if (separator >= 0 && separator < value.length - 1) {
    const provider = value.slice(0, separator).trim()
    const suffix = value.slice(separator + 1).trim()
    if (!suffix) return value
    if (suffix === 'auto') return provider.replace(/(?:[_-](?:cli|code))$/i, '')
    return suffix
  }
  return value
}

function rosterModelMeta(
  source: {
    last_model_used_label?: string | null
    last_model_used?: string | null
    active_model_label?: string | null
    active_model?: string | null
    model?: string | null
    primary_model?: string | null
    metrics_series?: Array<{ model_used?: string | null } | null> | null
  } | null | undefined,
): { label: string; value: string } | null {
  return keeperDisplayModel(source)
}

function rosterContextMeta(
  source: {
    context_ratio?: number | null
    context_tokens?: number | null
    context_max?: number | null
  } | null | undefined,
): { pct: number; detail: string | null } | null {
  const ratio = source?.context_ratio
  if (ratio == null || !Number.isFinite(ratio)) return null

  const pct = Math.round(ratio * 100)
  const tokens = source?.context_tokens
  const max = source?.context_max
  const detail =
    tokens != null && max != null
      ? `${formatTokens(tokens)} / ${formatTokens(max)}`
      : tokens != null
        ? formatTokens(tokens)
        : null

  return { pct, detail }
}

function rosterStateNote(
  keeper: {
    runtime_blocker_summary?: string | null
    diagnostic?: { last_error?: string | null } | null
  } | null | undefined,
  monitoringHint?: string | null,
): { label: string; text: string } | null {
  const runtimeBlocker = keeper?.runtime_blocker_summary?.trim()
  if (runtimeBlocker) return { label: '현재 차단', text: runtimeBlocker }

  const diagnosticError = keeper?.diagnostic?.last_error?.trim()
  if (diagnosticError) return { label: '최근 오류', text: diagnosticError }

  const hint = monitoringHint?.trim()
  if (hint) return { label: '상태 메모', text: hint }
  return null
}

function registerKeeperLookup<T extends Pick<Keeper, 'keeper_id' | 'name' | 'agent_name'>>(
  lookup: Map<string, T>,
  source: T,
) {
  const candidates = keeperIdentityKeys(source.keeper_id ?? null, source.name, source.agent_name)
  for (const candidate of candidates) {
    const key = candidate?.trim()
    if (!key || lookup.has(key)) continue
    lookup.set(key, source)
  }
}

function buildKeeperRuntimeLookup(keeperList: Keeper[]): Map<string, Keeper> {
  const lookup = new Map<string, Keeper>()
  for (const keeper of keeperList) registerKeeperLookup(lookup, keeper)
  return lookup
}

function findKeeperRuntime(agentName: string, keeperList: Keeper[]): Keeper | null {
  const target = agentName.trim()
  if (!target) return null
  const lookup = buildKeeperRuntimeLookup(keeperList)
  return lookup.get(target) ?? lookup.get(target.toLowerCase()) ?? null
}

function findKeeperRuntimeForAgent(
  agent: Pick<Agent, 'name' | 'keeper_id' | 'keeper_name'>,
  lookup: Map<string, Keeper>,
): Keeper | null {
  const candidates = keeperIdentityKeys(
    agent.keeper_id ?? null,
    agent.keeper_name ?? null,
    agent.name,
  )
  for (const candidate of candidates) {
    const keeper = lookup.get(candidate)
    if (keeper) return keeper
  }
  return null
}

type KeeperFilterMode = 'all' | 'agent-only' | 'keeper-only'

function isRuntimeBackedKeeper(keeper: Pick<Keeper, 'paused' | 'registered' | 'keepalive_running'>): boolean {
  if (keeper.registered === false && keeper.keepalive_running === false) return false
  if (keeper.paused === true && keeper.registered !== true && keeper.keepalive_running !== true) return false
  return true
}

function runtimeBackedKeepers(keeperList: Keeper[]): Keeper[] {
  return keeperList.filter(isRuntimeBackedKeeper)
}

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
    description: '응답 지연, 오류, 복구, 승계 등으로 상태 확인이 필요한 항목입니다.',
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

/**
 * Pure filter for agent roster rows.
 *
 * Case-insensitive substring match on `row.name`, `row.model`,
 * `row.current_task`, and `row.koreanName` so operators can locate an
 * agent/keeper by display name, by the model it runs, by its current
 * task text, or by the Korean alias shown on the card.
 *
 * Empty/whitespace query returns the input reference unchanged (no new
 * array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated; `Agent` is treated as readonly.
 */
function filterAgentRoster(
  rows: readonly Agent[],
  query: string,
): readonly Agent[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter(row => {
    if (row.name.toLowerCase().includes(needle)) return true
    if (row.model && row.model.toLowerCase().includes(needle)) return true
    if (row.current_task && row.current_task.toLowerCase().includes(needle)) return true
    if (row.koreanName && row.koreanName.toLowerCase().includes(needle)) return true
    return false
  })
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
  agent: Pick<Agent, 'name' | 'keeper_id' | 'keeper_name'>,
  keeperLookup: Map<string, Keeper>,
  keeperFilter: KeeperFilterMode,
): boolean {
  if (keeperFilter === 'all') return true
  const isKeeper = findKeeperRuntimeForAgent(agent, keeperLookup) != null
  return keeperFilter === 'keeper-only' ? isKeeper : !isKeeper
}

function scopeAgentsByKeeperFilter(
  agentList: Agent[],
  keeperList: Keeper[],
  keeperFilter: KeeperFilterMode,
  keeperLookup: Map<string, Keeper> = buildKeeperRuntimeLookup(keeperList),
): Agent[] {
  return agentList.filter((agent: Agent) =>
    matchesKeeperFilter(agent, keeperLookup, keeperFilter))
}

function keeperRuntimeName(source: Pick<Keeper, 'name' | 'agent_name'>): string {
  const runtimeName = source.agent_name?.trim()
  return runtimeName && runtimeName.length > 0 ? runtimeName : source.name
}

function synthesizeAgentFromKeeper(source: Keeper): Agent | null {
  const displayName = keeperPrimaryName(source.name, source.agent_name) ?? keeperRuntimeName(source)
  if (!displayName) return null

  const linkedAgent = source.agent
  const liveCurrentTask =
    source.recent_output_preview
    ?? source.recent_input_preview
    ?? source.short_goal
    ?? source.goal
    ?? null

  return {
    name: displayName,
    keeper_name: source.name,
    keeper_id: source.keeper_id ?? null,
    agent_type: linkedAgent?.agent_type,
    status: (linkedAgent?.status as Agent['status'] | undefined) ?? (source.status as Agent['status'] | undefined),
    current_task: linkedAgent?.current_task ?? liveCurrentTask,
    context_ratio: source.context_ratio ?? undefined,
    joined_at: linkedAgent?.joined_at,
    last_seen: linkedAgent?.last_seen,
    capabilities: linkedAgent?.capabilities,
    emoji: source.emoji,
    koreanName: source.koreanName,
    model: source.model,
    traits: source.traits,
    activityLevel: source.activityLevel,
    primaryValue: source.primaryValue,
    synthetic: true,
  }
}

function mergeRosterAgent(existing: Agent | undefined, next: Agent): Agent {
  if (!existing) return next
  return {
    ...existing,
    name: next.synthetic && !existing.synthetic ? next.name : existing.name,
    keeper_name: existing.keeper_name ?? next.keeper_name ?? null,
    keeper_id: existing.keeper_id ?? next.keeper_id ?? null,
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

function buildAgentRoster(
  agentList: Agent[],
  keeperList: Keeper[],
): Agent[] {
  const keeperLookup = buildKeeperRuntimeLookup(keeperList)
  const roster = new Map<string, Agent>()

  for (const agent of agentList) {
    const keeper = findKeeperRuntimeForAgent(agent, keeperLookup)
    const key =
      keeperPrincipalKey(
        keeper?.keeper_id ?? agent.keeper_id ?? null,
        keeper?.name ?? agent.keeper_name ?? null,
        keeper?.agent_name ?? agent.name,
      )
      ?? agent.name
    const normalizedAgent =
      keeper != null
        ? {
            ...agent,
            keeper_name: agent.keeper_name ?? keeper.name,
            keeper_id: agent.keeper_id ?? keeper.keeper_id ?? null,
          }
        : agent
    roster.set(key, mergeRosterAgent(roster.get(key), normalizedAgent))
  }

  for (const source of keeperList) {
    const synthetic = synthesizeAgentFromKeeper(source)
    if (!synthetic) continue
    const key = keeperPrincipalKey(source.keeper_id ?? null, source.name, source.agent_name) ?? synthetic.name
    roster.set(key, mergeRosterAgent(roster.get(key), synthetic))
  }

  return Array.from(roster.values())
}

function countAgentsByStatus(
  agentList: Agent[],
  keeperList: Keeper[],
): Record<StatusFilter, number> {
  const keeperLookup = buildKeeperRuntimeLookup(keeperList)
  const counts: Record<StatusFilter, number> = {
    all: agentList.length,
    active: 0,
    attention: 0,
    paused: 0,
    offline: 0,
  }

  for (const agent of agentList) {
    const keeperRuntime = findKeeperRuntimeForAgent(agent, keeperLookup)
    const band = runtimeBandMetaForAgent(agent, keeperRuntime).key
    counts[band] += 1
  }

  return counts
}

export function countRuntimeKinds(
  agentList: Agent[],
  keeperList: Keeper[],
): { agents: number; keepers: number; totalRuntimes: number } {
  const runtimeKeepers = runtimeBackedKeepers(keeperList)
  const rosterAgents = buildAgentRoster(agentList, runtimeKeepers)
  const keeperLookup = buildKeeperRuntimeLookup(runtimeKeepers)
  const keeperCount = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeepers, 'keeper-only', keeperLookup).length
  const agentCount = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeepers, 'agent-only', keeperLookup).length

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
  const runtimeKeeperList = useMemo(
    () => runtimeBackedKeepers(keeperList),
    [keeperList],
  )

  // Memoize roster and lookup Maps — these iterate full keeper/agent arrays.
  // Directory cards are live-only: cached mission briefs are intentionally
  // excluded so one card never mixes multiple freshness levels.
  const rosterAgents = useMemo(
    () => buildAgentRoster(agentList, runtimeKeeperList),
    [agentList, runtimeKeeperList],
  )
  const keeperRuntimeLookup = useMemo(
    () => buildKeeperRuntimeLookup(runtimeKeeperList),
    [runtimeKeeperList],
  )

  // Derive runtime kind counts from memoized roster (avoids duplicate buildAgentRoster call)
  const liveRuntimeCounts = useMemo(() => {
    const keeperCount = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeeperList, 'keeper-only', keeperRuntimeLookup).length
    const agentCount = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeeperList, 'agent-only', keeperRuntimeLookup).length
    return { agents: agentCount, keepers: keeperCount, totalRuntimes: rosterAgents.length }
  }, [rosterAgents, runtimeKeeperList, keeperRuntimeLookup])

  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: liveRuntimeCounts.agents,
    keepersCount: liveRuntimeCounts.keepers,
    namespaceTruthCounts: namespaceTruth.value?.root.counts,
    namespaceTruthConfiguredKeepers: namespaceTruth.value?.root.configured_keepers,
    shellCounts: shellCounts.value,
    shellConfiguredKeepers: shellCounts.value?.configured_keepers,
  })
  const expectedScopedCount = expectedCountForKeeperFilter(keeperFilter, runtimeCounts)
  const countSourceLabel = runtimeCountSourceLabel(runtimeCounts.source)
  const namespaceStatus = namespaceTruth.value?.root.status ?? serverStatus.value
  const namespaceName = namespaceStatus?.project ?? 'default'

  const scopedAgents = useMemo(
    () => scopeAgentsByKeeperFilter(rosterAgents, runtimeKeeperList, keeperFilter, keeperRuntimeLookup),
    [rosterAgents, runtimeKeeperList, keeperFilter, keeperRuntimeLookup],
  )
  const bandByAgent = useMemo(
    () => new Map(
      scopedAgents.map(agent => [
        agent.name,
        runtimeBandMetaForAgent(
          agent,
          keeperRuntimeLookup.get(agent.name)
            ?? findKeeperRuntimeForAgent(agent, keeperRuntimeLookup)
            ?? findKeeperRuntime(agent.name, runtimeKeeperList),
        ),
      ] as const),
    ),
    [scopedAgents, keeperRuntimeLookup, runtimeKeeperList],
  )
  const normalizedSearch = search.trim().toLowerCase()
  const searchTermsByAgent = useMemo(
    () => new Map(
      scopedAgents.map(agent => {
        const keeper =
          keeperRuntimeLookup.get(agent.name)
          ?? findKeeperRuntimeForAgent(agent, keeperRuntimeLookup)
          ?? findKeeperRuntime(agent.name, runtimeKeeperList)
        return [
          agent.name,
          keeperIdentitySearchTerms(
            keeper?.name ?? null,
            keeper?.agent_name ?? agent.name,
          ).map(term => term.toLowerCase()),
        ] as const
      }),
    ),
    [scopedAgents, keeperRuntimeLookup, runtimeKeeperList],
  )
  const pageDescription = keeperFilter === 'keeper-only'
    ? 'live runtime 기준으로 주 이름과 현재 상태를 먼저 훑습니다.'
    : keeperFilter === 'agent-only'
      ? 'live execution 기준으로 키퍼가 연결되지 않은 일반 에이전트만 따로 봅니다.'
      : 'live execution/runtime 기준으로 현재 상태를 보고, cached 조율 정보는 이 화면에 섞지 않습니다.'

  const filtered = scopedAgents
    .filter((a: Agent) => {
      if (filter !== 'all' && bandByAgent.get(a.name)?.key !== filter) return false
      if (normalizedSearch) {
        const terms = searchTermsByAgent.get(a.name) ?? [a.name.toLowerCase()]
        const identityMatch = terms.some(term => term.includes(normalizedSearch))
        if (!identityMatch) {
          // Fall back to the pure roster filter (model / current_task / koreanName).
          const fieldMatch = filterAgentRoster([a], search).length === 1
          if (!fieldMatch) return false
        }
      }
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

  const counts = countAgentsByStatus(scopedAgents, runtimeKeeperList)
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
      : `에이전트/키퍼 ${expectedScopedCount}개`
  const configuredKeeperHint =
    keeperFilter === 'agent-only' || runtimeCounts.configuredKeepers <= 0
      ? null
      : runtimeCounts.configuredKeepers > runtimeCounts.keepers
        ? `설정된 keeper ${runtimeCounts.configuredKeepers}개 · runtime ${runtimeCounts.keepers}개 · 일시정지/미기동 ${runtimeCounts.configuredKeepers - runtimeCounts.keepers}개`
        : `설정된 keeper ${runtimeCounts.configuredKeepers}개`
  const fallbackStateTitle =
    executionError.value
      ? '상세 상태 불러오기 실패'
      : executionLoaded.value
        ? '상세 상태 부분 동기화'
        : '상세 상태 동기화 중'
  const fallbackStateMessage =
    executionError.value
      ? `${countSourceLabel} 기준 ${scopeLabel}가 등록되어 있지만 상세 상태 정보를 아직 가져오지 못했습니다.`
      : executionLoaded.value
        ? `${countSourceLabel} 기준 ${scopeLabel}가 등록되어 있고 일부만 상세 목록에 반영됐습니다.${configuredKeeperHint ? ` ${configuredKeeperHint}.` : ''}`
        : `${countSourceLabel} 기준 ${scopeLabel}가 등록되어 있습니다.${configuredKeeperHint ? ` ${configuredKeeperHint}.` : ''} 상세 상태 정보가 올라오면 상태별 분류와 카드가 채워집니다.`

  return html`
    <div class="agent-page flex w-full flex-col gap-5 px-0 py-1">
      <section class="monitor-surface-card monitor-surface-card-strong p-5" aria-label="에이전트 디렉터리">
        <div class="flex flex-col gap-5">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_320px] xl:items-end">
            <div class="flex min-w-0 flex-col gap-2">
              <div class="flex flex-wrap items-center gap-3">
                <span class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">디렉터리 필터</span>
                <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-accent-soft)] px-2.5 py-1 text-2xs font-medium text-[var(--color-fg-secondary)]">${resultCountLabel}</span>
              </div>
              <p class="m-0 max-w-180 text-sm leading-loose text-[var(--color-fg-primary)]">${pageDescription}</p>
            </div>

            <label class="flex w-full flex-col gap-2 text-2xs font-semibold tracking-[var(--track-caps)] text-[var(--color-fg-muted)] uppercase">
              <span>이름 / model / 작업</span>
              <${TextInput}
                class="rounded-[var(--r-1)] bg-[var(--color-bg-surface)] px-4 py-3 text-base text-[var(--color-fg-primary)] shadow-[inset_0_1px_0_var(--color-border-default)] focus:border-[var(--color-accent-fg)] focus:shadow-[0_0_0_2px_var(--color-accent-soft)]"
                name="agent_search"
                ariaLabel="에이전트 이름 · 모델 · 작업 검색"
                autoComplete="off"
                placeholder="이름 · runtime alias · model · 작업으로 찾기"
                value=${search}
                onInput=${(e: Event) => setSearch((e.target as HTMLInputElement).value)}
              />
            </label>
          </div>

          <div class="monitor-muted-panel p-3.5 md:p-4">
            <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
              <div class="flex flex-col gap-1">
                <div class="text-2xs font-semibold tracking-[var(--track-caps)] text-[var(--color-fg-secondary)] uppercase">운영 상태</div>
                <p class="m-0 text-xs leading-normal text-[var(--color-fg-muted)]">live runtime 신호로 먼저 걸러 보고, 필요할 때만 세부 상태와 최근 근거를 확인합니다.</p>
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
                <div class="rounded-[var(--r-1)] border ${executionError.value ? 'border-[var(--warn-border)] bg-[var(--warn-10)]' : 'border-[var(--accent-20)] bg-[var(--accent-10)]'} px-4 py-3 shadow-[var(--shadow-panel)]">
                  <div class="flex flex-col gap-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <strong class="text-xs font-semibold text-[var(--color-fg-secondary)]">${fallbackStateTitle}</strong>
                      <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-2 py-0.5 text-3xs font-medium text-[var(--color-fg-muted)]">${countSourceLabel}</span>
                    </div>
                    <p class="m-0 text-xs leading-paragraph text-[var(--color-fg-primary)]">${fallbackStateMessage}</p>
                    <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
                      <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5">scope ${namespaceName}</span>
                      ${configuredKeeperHint ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5">${configuredKeeperHint}</span>` : null}
                    </div>
                  </div>
                </div>
              `
            : null}
        </div>
      </section>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
        ${filtered.map((agent: Agent) => {
          const keeperRuntime =
            keeperRuntimeLookup.get(agent.name)
            ?? findKeeperRuntimeForAgent(agent, keeperRuntimeLookup)
            ?? findKeeperRuntime(agent.name, runtimeKeeperList)
          const band = bandByAgent.get(agent.name) ?? runtimeBandMeta('attention')
          const keeperMonitoring = keeperRuntime ? summarizeKeeperMonitoring(keeperRuntime) : null
          const monitoringEvidence = keeperMonitoring ? summarizeMonitoringEvidence(keeperMonitoring) : null
          const fsmPhase = keeperRuntime ? keeperPhaseForDisplay(keeperRuntime) : null
          const isKeeper = keeperRuntime != null
          const goalSummary = keeperRuntime?.short_goal ?? keeperRuntime?.goal ?? agent.current_task ?? null
          const currentWork =
            keeperRuntime?.recent_output_preview
            ?? keeperRuntime?.recent_input_preview
            ?? goalSummary
            ?? null
          const activityDisplay = keeperRuntime
            ? keeperActivityDisplay(keeperRuntime, agent.last_seen)
            : null
          const lastActivityAge = activityDisplay?.ageSeconds ?? null
          const lastActivityAt = activityDisplay?.timestamp ?? agent.last_seen ?? null
          const lastActivityLabel = activityDisplay?.label ?? '최근 활동'
          const contextMeta =
            rosterContextMeta(keeperRuntime ?? null)
          const workPreview =
            trimText(keeperRuntime?.recent_output_preview, 140)
            ?? trimText(keeperRuntime?.recent_input_preview, 140)
            ?? trimText(goalSummary, 140)
            ?? '최근 활동 요약 없음'
          const summaryText = workPreview
          const stateNote =
            keeperRuntime
              ? rosterStateNote(keeperRuntime, band.key === 'active' ? null : keeperMonitoring?.hint ?? null)
              : null
          const recentTools = uniqueToolNames(
            keeperRuntime?.recent_tool_names,
            keeperRuntime?.latest_tool_names,
          )
          const toolCallCount =
            keeperRuntime?.latest_tool_call_count
            ?? null
          const toolAuditAt = keeperRuntime?.tool_audit_at ?? null
          const displayName =
            keeperPrimaryName(
              keeperRuntime?.name ?? null,
              keeperRuntime?.agent_name ?? agent.name,
            )
            ?? agent.name
          const modelMeta = rosterModelMeta(keeperRuntime ?? agent)
          const modelDisplay = isKeeper
            ? modelMeta?.value ?? null
            : compactModelLabel(modelMeta?.value)
          const fsmPhaseKey =
            keeperMonitoring?.phase.key && keeperMonitoring.phase.key !== 'unknown'
              ? keeperMonitoring.phase.key
              : fsmPhase
          const fsmStageKey = monitoringEvidence?.stage?.key ?? null
          const fsmStageLabel = monitoringEvidence?.stage?.label ?? null
          const fsmStageText = fsmStageLabel ? `활동 ${fsmStageLabel}` : null
          const detailLabel = keeperRuntime ? `${displayName} keeper 상세 보기` : `${displayName} 상세 보기`
          const openDetail = () => {
            if (keeperRuntime) {
              openKeeperDetail(keeperRuntime)
              return
            }
            openAgentDetail(agent.name)
          }

          return html`
            <button type="button"
              class="monitor-surface-card monitor-surface-card-medium group flex w-full flex-col gap-3.5 rounded-card p-4 text-left transition-[background-color,border-color,transform] duration-[var(--t-med)] cursor-pointer hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-surface)] hover:-translate-y-0.5 contain-content"
              key=${agent.name}
              aria-label=${detailLabel}
              onClick=${openDetail}
            >
              <div class="flex items-start justify-between gap-4">
                <div class="flex min-w-0 flex-1 items-start gap-4">
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

                  <div class="min-w-0 flex-1 py-0.5">
                    <div class="flex flex-wrap items-center gap-2">
                      <strong class="min-w-0 overflow-hidden text-lg font-semibold leading-[1.3] text-[var(--color-fg-secondary)] transition-colors group-hover:text-[var(--color-accent-fg)] [display:-webkit-box] [-webkit-box-orient:vertical] [-webkit-line-clamp:2] [overflow-wrap:anywhere]">${displayName}</strong>
                      ${agent.synthetic ? html`
                        <span class="inline-flex items-center rounded-[var(--r-0)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-2 py-0.5 text-3xs italic text-[var(--color-fg-muted)]" title="키퍼 데이터에서 파생된 합성 엔트리입니다.">
                          파생
                        </span>
                      ` : null}
                    </div>
                  </div>
                </div>

                <div class="flex shrink-0 items-start">
                  <${AgentPresence} status=${agent.status} size="sm" />
                </div>
              </div>

              <p class="m-0 text-sm leading-paragraph text-[var(--color-fg-primary)] break-words line-clamp-2" title=${summaryText}>${summaryText}</p>

              ${stateNote ? html`
                <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
                  <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-2 py-0.5 text-3xs font-semibold text-[var(--color-status-warn)]">
                    ${stateNote.label}
                  </span>
                  ${lastActivityAt
                    ? html`<span class="text-3xs text-[var(--color-fg-muted)]">최근 신호 · ${lastActivityLabel} <${TimeAgo} timestamp=${lastActivityAt} /></span>`
                    : lastActivityAge != null
                      ? html`<span class="text-3xs text-[var(--color-fg-muted)]">최근 신호 · ${lastActivityLabel} ${formatDuration(lastActivityAge)} 전</span>`
                    : null}
                  <span class="min-w-0 flex-1 text-xs leading-relaxed text-[var(--color-fg-primary)] break-words line-clamp-2" title=${stateNote.text}>
                    ${stateNote.text}
                  </span>
                </div>
              ` : null}

              ${isKeeper && (monitoringEvidence?.phase || monitoringEvidence?.stage) ? html`
                <div class="rounded-[var(--r-5)] border border-[var(--color-border-divider)] bg-[linear-gradient(180deg,var(--color-bg-surface),var(--color-bg-page))] px-3 py-2.5">
                  <div class="flex flex-wrap items-center gap-2">
                    ${monitoringEvidence?.phase && fsmPhaseKey
                      ? html`<${KeeperPhaseBadge} phase=${fsmPhaseKey} compact />`
                      : null}
                    ${fsmStageKey && fsmStageText ? html`
                      <span class="inline-flex items-center rounded-[var(--r-0)] border px-2 py-0.5 text-3xs font-medium ${stageBadgeClass(fsmStageKey)}" title=${monitoringEvidence?.stage?.description ?? '활동 단계 정보가 없습니다.'}>
                        ${fsmStageText}
                      </span>
                    ` : null}
                  </div>
                </div>
              ` : null}

              <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
                <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1">
                  ${lastActivityLabel}
                  <span class="ml-1 text-[var(--color-fg-primary)]">
                    ${lastActivityAt
                      ? html`<${TimeAgo} timestamp=${lastActivityAt} />`
                      : lastActivityAge != null
                        ? `${formatDuration(lastActivityAge)} 전`
                        : '기록 없음'}
                  </span>
                </span>
                ${isKeeper && contextMeta ? html`
                  <span class="inline-flex items-center gap-1.5 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1">
                    <span>CTX</span>
                    <span class="font-mono font-medium ${contextMeta.pct > 85 ? 'text-[var(--color-status-err)]' : contextMeta.pct > 60 ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-secondary)]'}">${contextMeta.pct}%</span>
                    ${contextMeta.detail ? html`
                      <span class="font-mono text-3xs text-[var(--color-fg-muted)]">${contextMeta.detail}</span>
                    ` : null}
                    <span class="inline-block h-1.5 w-12 overflow-hidden rounded-[var(--r-0)] bg-[var(--color-bg-hover)]">
                      <span class="block h-full rounded-[var(--r-0)] ${contextMeta.pct > 85 ? 'bg-[var(--color-status-err)]' : contextMeta.pct > 60 ? 'bg-[var(--color-status-warn)]' : 'bg-[var(--color-status-ok)]'}" style="width:${contextMeta.pct}%"></span>
                    </span>
                  </span>
                ` : null}
                ${modelMeta && modelDisplay ? html`
                  <span class="inline-flex items-center gap-1.5 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1">
                    <span>${modelMeta.label}</span>
                    <span class="max-w-[18rem] overflow-hidden text-ellipsis whitespace-nowrap font-mono text-3xs text-[var(--color-fg-primary)]" translate="no" title=${modelMeta.value}>${modelDisplay}</span>
                  </span>
                ` : null}
              </div>

              ${(recentTools.length > 0 || toolCallCount != null || toolAuditAt) ? html`
                <div class="flex flex-wrap items-center gap-1.5 text-2xs text-[var(--color-fg-muted)]">
                  <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5">최근 도구</span>
                  <${AgentCapability} tools=${recentTools} maxVisible=${3} />
                  ${toolCallCount != null && toolCallCount > 0 ? html`
                    <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs">
                      ${toolCallCount}회 관찰됨
                    </span>
                  ` : null}
                  ${toolAuditAt ? html`
                    <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs">
                      감사 <${TimeAgo} timestamp=${toolAuditAt} />
                    </span>
                  ` : null}
                </div>
              ` : null}
            </button>
          `
        })}
        ${filtered.length === 0 ? html`
          <div class="col-span-full rounded-[var(--radius-xl)] border border-dashed border-[var(--ff-border-subtle)] bg-[var(--color-bg-surface)] px-6 py-10">
            <${EmptyState}
              message=${normalizedSearch && scopedAgents.length > 0
                ? `필터 결과 없음 (${scopedAgents.length} items)`
                : showExecutionFallbackState && expectedScopedCount > 0
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
