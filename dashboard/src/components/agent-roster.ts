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
import { EmptyState } from './common/feedback-state'
import { ringFocusClasses } from './common/ring'
import { RouteLink } from './common/route-link'
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
import { formatDuration } from '../lib/format-time'
import { trimText } from '../lib/truncate'
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
import { KeeperActionButtons } from './keeper-action-panel'
import {
  expectedKeeperDetailRows,
  expectedRuntimeDetailRows,
  formatKeeperCountBreakdown,
  formatRuntimeRosterCount,
  keeperRowLooksRunning,
  resolveRuntimeCounts,
  runtimeDetailRows,
  runtimeCountSourceLabel,
  shouldShowExecutionFallbackState,
} from '../runtime-counts'
import {
  keeperActivityDisplay,
  keeperRuntimeBlockerHint,
  keeperRuntimeBlockerLabel,
  keeperWorkPreview,
} from '../lib/keeper-runtime-display'
// RFC-0135 PR-4: roster card derives its blocker note through the typed
// KeeperOperationalState SSOT so the headline (`현재 차단` vs `이전 차단`
// vs `실행중`) matches the detail panel for the same keeper. Previously
// `rosterStateNote` read `keeper.runtime_blocker_*` flat and never saw
// `composite.runtime_attention.execution_current`, producing the
// 2026-05-19 lifecycle-worker symptom (`현재 차단 · synthetic_stall` in
// the list while detail showed `턴 진행 중 · executing live`).
import { deriveKeeperOperationalState } from '../lib/keeper-operational-state'
import { isKeeperPaused } from '../lib/keeper-predicates'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import { fleetCompositeSnapshot } from '../composite-signals'

type StatusFilter = 'all' | RuntimeBand

type RosterStateNote = { label: string; text: string; kind?: string }
type RosterPresenceDisplay = { status: string | null; detail: string | null }

function rosterBandActionHint(band: RuntimeBand, isKeeper: boolean): string {
  switch (band) {
    case 'active': return '감시 중'
    case 'attention': return '확인 필요'
    case 'paused': return '재개 대기'
    case 'offline': return isKeeper ? '기동 필요' : '연결 없음'
  }
}

// PipelineStage SSOT: branches aligned to `types/core.ts#PipelineStage`.
// Legacy `tool_use` / `scheduled_autonomous` / `thinking` removed — the
// backend never emits them as pipeline_stage.
function stageBadgeClass(stageKey: string): string {
  if (stageKey === 'handoff' || stageKey === 'compacting') return 'border-[var(--purple-24)] bg-[var(--purple-12)] text-[var(--stalled-fg)]'
  if (stageKey === 'failing' || stageKey === 'crashed') return 'border-[var(--err-border)] bg-[var(--bad-soft)] text-[var(--color-status-err)]'
  if (stageKey === 'paused') return 'border-[var(--purple-24)] bg-[var(--purple-12)] text-[var(--purple)]'
  return 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]'
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

/**
 * RFC-0135 §1.1 root fix. Decide the roster card state note from the
 * typed `KeeperOperationalState` SSOT — the same function the detail
 * panel calls — so the two surfaces cannot diverge.
 *
 * Display rules per typed state:
 *  - stuck             → `현재 차단`  (text: backend summary or typed reason)
 *  - running + staleBlocker → `이전 차단` (informational; not a headline)
 *  - running + synthetic_stall → `상태 추정` (diagnostic; not a blocker)
 *  - running           → fallback to diagnostic error / monitoring hint
 *  - paused           → pause cause when available, because it explains the
 *                       resume gate.
 *  - offline          → interrupted work / diagnostics / monitoring hint when
 *                       available; otherwise the row action axis carries the
 *                       "start required" state.
 */
export function rosterStateNote(
  keeper: Keeper | null | undefined,
  composite: KeeperCompositeSnapshot | null,
  monitoringHint?: string | null,
): RosterStateNote | null {
  if (!keeper) return null

  const gate = keeper.current_gate
  if (gate?.kind === 'approval_required') {
    const tool = gate.tool?.trim()
    const risk = gate.risk?.trim()
    const reason = gate.disposition_reason?.trim()
    const text = [
      tool ? `도구 ${tool}` : '도구 승인 필요',
      risk ? `위험도 ${risk}` : null,
      reason ? `사유 ${reason}` : null,
    ].filter((part): part is string => part !== null).join(' · ')
    return { label: '승인 대기', text }
  }

  const state = deriveKeeperOperationalState({ keeper, composite })

  if (state.kind === 'paused') {
    const blockerClass = keeper.runtime_blocker_class ?? undefined
    const runtimeHint = keeperRuntimeBlockerHint(keeper)
    if (runtimeHint) {
      return { label: '일시정지 원인', text: runtimeHint, kind: blockerClass }
    }

    const summary = keeper.runtime_blocker_summary?.trim()
    if (summary) {
      return { label: '일시정지 원인', text: summary, kind: blockerClass }
    }

    const hint = monitoringHint?.trim()
    if (hint) return { label: '일시정지', text: hint, kind: blockerClass }
    return null
  }

  if (state.kind === 'stuck') {
    const summary = keeper.runtime_blocker_summary?.trim()
    if (summary) {
      return { label: '현재 차단', text: summary, kind: state.reason }
    }
    return {
      label: '현재 차단',
      text: `차단 종류: ${state.reason} (요약 메시지 없음)`,
      kind: state.reason,
    }
  }

  if (state.kind === 'running' && state.staleBlocker !== null) {
    return {
      label: '이전 차단',
      text: `이전 턴 차단 (${state.staleBlocker}) — 현재는 실행 중`,
      kind: state.staleBlocker,
    }
  }

  if (state.kind === 'running' && keeper.runtime_blocker_class === 'synthetic_stall') {
    const summary = keeper.runtime_blocker_summary?.trim()
    return {
      label: '상태 추정',
      text: summary || '실제 STATE 없이 합성된 진행 기록만 남아 최근 턴 산출물 재확인이 필요합니다.',
      kind: 'synthetic_stall',
    }
  }

  if (state.kind === 'offline' && keeper.agent?.current_task) {
    return { label: '작업 중단', text: `할당된 작업이 있으나 keeper가 ${state.cause} 상태입니다` }
  }

  const diagnosticError = keeper.diagnostic?.last_error?.trim()
  if (diagnosticError) {
    return { label: state.kind === 'running' ? '이전 오류' : '최근 오류', text: diagnosticError }
  }

  const hint = monitoringHint?.trim()
  if (hint) return { label: '참고', text: hint }
  return null
}

function noteLooksLikeRawKind(note: RosterStateNote): boolean {
  if (!note.kind) return false
  return note.text === note.kind || note.text === `차단 종류: ${note.kind} (요약 메시지 없음)`
}

function rosterPresenceDisplay(
  agent: Agent,
  keeper: Keeper | null,
  composite: KeeperCompositeSnapshot | null,
): RosterPresenceDisplay {
  if (!keeper) return { status: agent.status ?? null, detail: null }

  const state = deriveKeeperOperationalState({ keeper, composite })
  if (state.kind === 'paused') {
    const staleTask = agent.current_task?.trim()
    return {
      status: 'paused',
      detail: staleTask ? `오래된 작업 신호 ${staleTask}` : null,
    }
  }

  if (state.kind === 'offline' && agent.current_task) {
    return { status: 'offline', detail: `중단된 작업 ${agent.current_task}` }
  }

  if (state.kind === 'running' && composite?.is_live === true) {
    return { status: 'busy', detail: `${state.turnPhase} live` }
  }

  if (state.kind === 'running' && composite?.is_live === false) {
    return { status: 'idle', detail: '대기 중' }
  }

  return { status: agent.status ?? keeper.status ?? null, detail: null }
}

export function rosterBlockerDisplay(
  note: RosterStateNote | null,
  keeper: Keeper | null | undefined,
): {
  cell: string
  detail: string
  title: string
  kindLabel: string | null
  rawKind: string | null
} {
  if (!note) {
    return {
      cell: '-',
      detail: '현재 차단 근거 없음',
      title: '현재 차단 근거 없음',
      kindLabel: null,
      rawKind: null,
    }
  }

  const kindLabel =
    note.kind && keeper?.runtime_blocker_class === note.kind
      ? keeperRuntimeBlockerLabel(keeper.runtime_blocker_class)
      : null
  const displayKind = kindLabel ?? note.kind ?? null
  const cell = displayKind ? `${note.label}: ${displayKind}` : note.label
  const runtimeHint = noteLooksLikeRawKind(note) ? keeperRuntimeBlockerHint(keeper) : null
  const detail = runtimeHint ?? note.text
  const rawKind = note.kind ?? null
  const title = rawKind && kindLabel
    ? `${cell} (${rawKind}) · ${detail}`
    : `${cell} · ${detail}`

  return { cell, detail, title, kindLabel, rawKind }
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
type RosterAgent = Agent & { rosterSource?: 'agent_registry' | 'keeper_runtime' }

function keeperHasRuntimeDetailRow(keeper: Keeper): boolean {
  // Paused keepers are not live capacity, but execution still sends them as
  // operator-visible detail rows. Keep them in the roster so "설정 N" does not
  // degrade into count-only inventory with missing paused rows.
  if (isKeeperPaused(keeper)) return true
  if (keeper.registered === false && keeper.keepalive_running === false) return false
  return true
}

function agentCanBackKeeperRuntime(agent: Agent): boolean {
  const normalized = agent.status?.trim().toLowerCase()
  return normalized !== 'inactive' && normalized !== 'offline'
}

function keeperHasLiveAgentPresence(
  keeper: Keeper,
  liveAgentKeys: ReadonlySet<string>,
): boolean {
  const candidates = keeperIdentityKeys(keeper.keeper_id ?? null, keeper.name, keeper.agent_name)
  return candidates.some(candidate => liveAgentKeys.has(candidate))
}

function liveAgentIdentityKeys(agentList: readonly Agent[]): Set<string> {
  const keys = new Set<string>()
  for (const agent of agentList) {
    if (!agentCanBackKeeperRuntime(agent)) continue
    for (const candidate of keeperIdentityKeys(
      agent.keeper_id ?? null,
      agent.keeper_name ?? null,
      agent.name,
    )) {
      keys.add(candidate)
    }
  }
  return keys
}

function rosterDetailKeepers(
  keeperList: Keeper[],
  agentList: readonly Agent[] = [],
): Keeper[] {
  const liveAgentKeys = liveAgentIdentityKeys(agentList)
  return keeperList.filter(keeper =>
    keeperHasRuntimeDetailRow(keeper) || keeperHasLiveAgentPresence(keeper, liveAgentKeys))
}

function expectedCountForKeeperFilter(
  keeperFilter: KeeperFilterMode,
  counts: ReturnType<typeof resolveRuntimeCounts>,
): number {
  // Roster fallback messages compare against detail rows, not running runtime
  // fibers. A paused keeper is not live capacity, but it is still a row the
  // operator expects to see in the directory.
  const useDetailRows = runtimeDetailRows(counts) > 0
  if (keeperFilter === 'keeper-only') return useDetailRows ? expectedKeeperDetailRows(counts) : counts.configured.keepers
  if (keeperFilter === 'agent-only') return counts.live.agents
  return useDetailRows ? expectedRuntimeDetailRows(counts) : counts.configured.totalRuntimes
}

const FILTER_META: Record<StatusFilter, { label: string; description: string }> = {
  all: {
    label: '전체 상세',
    description: 'execution 상세 행 전체를 보여줍니다. 런타임 가동 총계와는 별도 기준입니다.',
  },
  active: { label: runtimeBandMeta('active').label, description: runtimeBandMeta('active').description },
  attention: { label: runtimeBandMeta('attention').label, description: runtimeBandMeta('attention').description },
  paused: { label: runtimeBandMeta('paused').label, description: runtimeBandMeta('paused').description },
  offline: { label: runtimeBandMeta('offline').label, description: runtimeBandMeta('offline').description },
}

/**
 * Pure filter for agent roster rows.
 *
 * Case-insensitive substring match on `row.name`, `row.current_task`, and
 * `row.koreanName` so operators can locate an agent/keeper by display name,
 * current task text, or the Korean alias shown on the card.
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

function keeperRuntimeAgentProjection(source: Keeper): RosterAgent | null {
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
    rosterSource: 'keeper_runtime',
  }
}

function mergeRosterAgent(existing: RosterAgent | undefined, next: RosterAgent): RosterAgent {
  if (!existing) return next
  const nextIsKeeperProjection = next.rosterSource === 'keeper_runtime'
  const existingIsKeeperProjection = existing.rosterSource === 'keeper_runtime'
  return {
    ...existing,
    name: nextIsKeeperProjection && !existingIsKeeperProjection ? next.name : existing.name,
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
): RosterAgent[] {
  const keeperLookup = buildKeeperRuntimeLookup(keeperList)
  const roster = new Map<string, RosterAgent>()

  for (const agent of agentList) {
    const keeper = findKeeperRuntimeForAgent(agent, keeperLookup)
    const key =
      keeperPrincipalKey(
        keeper?.keeper_id ?? agent.keeper_id ?? null,
        keeper?.name ?? agent.keeper_name ?? null,
        keeper?.agent_name ?? agent.name,
      )
      ?? agent.name
    const normalizedAgent: RosterAgent =
      keeper != null
        ? {
            ...agent,
            keeper_name: agent.keeper_name ?? keeper.name,
            keeper_id: agent.keeper_id ?? keeper.keeper_id ?? null,
            rosterSource: 'agent_registry',
          }
        : { ...agent, rosterSource: 'agent_registry' }
    roster.set(key, mergeRosterAgent(roster.get(key), normalizedAgent))
  }

  for (const source of keeperList) {
    const keeperRuntimeAgent = keeperRuntimeAgentProjection(source)
    if (!keeperRuntimeAgent) continue
    const key = keeperPrincipalKey(source.keeper_id ?? null, source.name, source.agent_name) ?? keeperRuntimeAgent.name
    roster.set(key, mergeRosterAgent(roster.get(key), keeperRuntimeAgent))
  }

  return Array.from(roster.values())
}

function countAgentsByStatus(
  agentList: Agent[],
  keeperList: Keeper[],
  compositeByKeeperKey: ReadonlyMap<string, KeeperCompositeSnapshot> | null = null,
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
    // RFC-0135 PR-12: pass composite to band derivation so stale
    // blockers are demoted via SSOT instead of inflating attention.
    const composite =
      keeperRuntime && compositeByKeeperKey
        ? compositeByKeeperKey.get(keeperRuntime.name)
          ?? (typeof keeperRuntime.keeper_id === 'string'
            ? compositeByKeeperKey.get(keeperRuntime.keeper_id) ?? null
            : null)
        : null
    const band = runtimeBandMetaForAgent(agent, keeperRuntime, composite).key
    counts[band] += 1
  }

  return counts
}

export function countRuntimeKinds(
  agentList: Agent[],
  keeperList: Keeper[],
): {
  agents: number
  keepers: number
  pausedKeepers: number
  offlineKeepers: number
  keeperRows: number
  totalRuntimes: number
} {
  const runtimeKeepers = rosterDetailKeepers(keeperList, agentList)
  const rosterAgents = buildAgentRoster(agentList, runtimeKeepers)
  const keeperLookup = buildKeeperRuntimeLookup(runtimeKeepers)
  const allKeepers = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeepers, 'keeper-only', keeperLookup)
  // Hydrate the Keeper from the lookup before asking whether it is paused.
  // Agent rows only carry `keeper_id`/`keeper_name`, not the full Keeper, so
  // `a.keeper` was undefined here and `isKeeperPaused(undefined)` silently
  // returned false, leaving the paused count stuck at 0.
  let pausedKeepers = 0
  let runningKeepers = 0
  for (const row of allKeepers) {
    const keeper = findKeeperRuntimeForAgent(row, keeperLookup)
    if (keeper && isKeeperPaused(keeper)) {
      pausedKeepers += 1
    } else if (keeperRowLooksRunning(keeper)) {
      runningKeepers += 1
    }
  }
  const agentCount = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeepers, 'agent-only', keeperLookup).length
  const keeperRows = allKeepers.length

  return {
    agents: agentCount,
    keepers: runningKeepers,
    pausedKeepers,
    offlineKeepers: Math.max(0, keeperRows - runningKeepers - pausedKeepers),
    keeperRows,
    totalRuntimes: rosterAgents.length,
  }
}

export function AgentRoster({ keeperFilter = 'all' }: { keeperFilter?: KeeperFilterMode } = {}) {
  const [filter, setFilter] = useState<StatusFilter>('all')
  const [search, setSearch] = useState('')
  const [selectedKey, setSelectedKey] = useState<string | null>(null)

  const agentList = agents.value
  const keeperList = keepers.value
  const runtimeKeeperList = useMemo(
    () => rosterDetailKeepers(keeperList, agentList),
    [keeperList, agentList],
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

  // RFC-0135 PR-4: index the fleet-wide composite snapshot stream by
  // keeper identity so each roster row can read the same conditioning
  // signals (`runtime_attention.execution_current` etc.) the detail
  // panel already uses. `.value` access here auto-subscribes the
  // component to SSE-driven updates from `hydrateFleetCompositeSnapshot`.
  const fleetSnapshot = fleetCompositeSnapshot.value
  const compositeByKeeperKey = useMemo(() => {
    const map = new Map<string, KeeperCompositeSnapshot>()
    if (!fleetSnapshot) return map
    for (const snap of fleetSnapshot.snapshots) {
      const identityKeys = [snap.keeper, snap.correlation_id]
      for (const candidate of identityKeys) {
        if (typeof candidate === 'string' && candidate !== '' && !map.has(candidate)) {
          map.set(candidate, snap)
        }
      }
    }
    return map
  }, [fleetSnapshot])

  // Derive runtime kind counts from memoized roster (avoids duplicate buildAgentRoster call)
  const liveRuntimeCounts = useMemo(() => {
    const allKeepers = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeeperList, 'keeper-only', keeperRuntimeLookup)
    // See countRuntimeKinds(): Agent rows expose only keeper identifiers, so
    // `a.keeper` is undefined and isKeeperPaused needs the hydrated Keeper.
    let pausedCount = 0
    let runningCount = 0
    for (const row of allKeepers) {
      const keeper = findKeeperRuntimeForAgent(row, keeperRuntimeLookup)
      if (keeper && isKeeperPaused(keeper)) {
        pausedCount += 1
      } else if (keeperRowLooksRunning(keeper)) {
        runningCount += 1
      }
    }
    const agentCount = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeeperList, 'agent-only', keeperRuntimeLookup).length
    const keeperRows = allKeepers.length
    return {
      agents: agentCount,
      keepers: runningCount,
      pausedKeepers: pausedCount,
      offlineKeepers: Math.max(0, keeperRows - runningCount - pausedCount),
      keeperRows,
      totalRuntimes: rosterAgents.length,
    }
  }, [rosterAgents, runtimeKeeperList, keeperRuntimeLookup])

  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: liveRuntimeCounts.agents,
    keepersCount: liveRuntimeCounts.keepers,
    pausedKeepersCount: liveRuntimeCounts.pausedKeepers,
    offlineKeepersCount: liveRuntimeCounts.offlineKeepers,
    keeperRowsCount: liveRuntimeCounts.keeperRows,
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
      scopedAgents.map(agent => {
        const keeperRuntime =
          keeperRuntimeLookup.get(agent.name)
            ?? findKeeperRuntimeForAgent(agent, keeperRuntimeLookup)
            ?? findKeeperRuntime(agent.name, runtimeKeeperList)
        // RFC-0135 PR-12: thread composite snapshot through band
        // derivation so stale-blocker demotion in the typed SSOT
        // applies to the badge color too.
        const composite =
          keeperRuntime
            ? compositeByKeeperKey.get(keeperRuntime.name)
              ?? (typeof keeperRuntime.keeper_id === 'string'
                ? compositeByKeeperKey.get(keeperRuntime.keeper_id) ?? null
                : null)
            : null
        return [agent.name, runtimeBandMetaForAgent(agent, keeperRuntime, composite)] as const
      }),
    ),
    [scopedAgents, keeperRuntimeLookup, runtimeKeeperList, compositeByKeeperKey],
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
  const filtered = scopedAgents
    .filter((a: Agent) => {
      if (filter !== 'all' && bandByAgent.get(a.name)?.key !== filter) return false
      if (normalizedSearch) {
        const terms = searchTermsByAgent.get(a.name) ?? [a.name.toLowerCase()]
        const identityMatch = terms.some(term => term.includes(normalizedSearch))
        if (!identityMatch) {
          // Fall back to the pure roster filter (current_task / koreanName).
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

  const counts = countAgentsByStatus(scopedAgents, runtimeKeeperList, compositeByKeeperKey)
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
            ? `상세 행 ${filtered.length}개 로드됨 · 예상 ${expectedScopedCount}개`
            : `상세 행 ${filtered.length} / ${scopedAgents.length}개 표시 · 예상 ${expectedScopedCount}개`
        )
      : (
          filtered.length === scopedAgents.length
            ? `상세 행 ${filtered.length}개 표시 중`
            : `상세 행 ${filtered.length} / ${scopedAgents.length}개 표시 중`
        )
  const statusChips = (['all', 'attention', 'active', 'paused', 'offline'] as StatusFilter[]).map(key => ({
    key,
    label: FILTER_META[key].label,
    count: executionLoaded.value || scopedAgents.length > 0 ? counts[key] : null,
    title: FILTER_META[key].description,
  }))
  const liveKeepers = runtimeCounts.live.keepers
  const livePausedKeepers = runtimeCounts.live.pausedKeepers
  const liveOfflineKeepers = runtimeCounts.live.offlineKeepers
  const configuredKeepers = runtimeCounts.configured.keepers
  const configuredKeeperDelta = Math.max(0, configuredKeepers - runtimeCounts.live.keeperRows)
  const rawPausedKeepers = keeperList.filter(isKeeperPaused).length
  const pausedOutsideDetail = Math.max(0, rawPausedKeepers - livePausedKeepers)
  const notStartedKeepers = Math.max(0, configuredKeeperDelta - pausedOutsideDetail)
  const scopeLabel = keeperFilter === 'keeper-only'
    ? formatKeeperCountBreakdown({
        liveKeepers,
        pausedKeepers: livePausedKeepers,
        offlineKeepers: liveOfflineKeepers,
        configuredKeepers,
      })
    : keeperFilter === 'agent-only'
      ? `일반 에이전트 런타임 가동 ${runtimeCounts.live.agents}`
      : formatRuntimeRosterCount(runtimeCounts)
  const keeperStateHints = (
    keeperFilter === 'keeper-only'
      ? [
          pausedOutsideDetail > 0 ? `목록 밖 일시정지 ${pausedOutsideDetail}개` : null,
          notStartedKeepers > 0 ? `미기동 ${notStartedKeepers}개` : null,
        ]
      : [
          livePausedKeepers > 0 ? `일시정지 ${livePausedKeepers}개` : null,
          liveOfflineKeepers > 0 ? `오프라인 ${liveOfflineKeepers}개` : null,
          pausedOutsideDetail > 0 ? `목록 밖 일시정지 ${pausedOutsideDetail}개` : null,
          notStartedKeepers > 0 ? `미기동 ${notStartedKeepers}개` : null,
        ]
  ).filter((item): item is string => item != null)
  const configuredIdleHint =
    keeperFilter === 'agent-only' || keeperStateHints.length === 0
      ? null
      : `키퍼 ${keeperStateHints.join(' · ')}`
  const fallbackStateTitle =
    executionError.value
      ? '상세 상태 불러오기 실패'
      : executionLoaded.value
        ? '상세 상태 부분 동기화'
        : '상세 상태 동기화 중'
  const fallbackStateMessage =
    executionError.value
      ? `${countSourceLabel} 기준 ${scopeLabel}입니다. 상세 상태 정보를 아직 가져오지 못했습니다.`
      : executionLoaded.value
        ? `${countSourceLabel} 기준 ${scopeLabel}입니다. 일부만 상세 목록에 반영됐습니다.${configuredIdleHint ? ` ${configuredIdleHint}.` : ''}`
        : `${countSourceLabel} 기준 ${scopeLabel}입니다.${configuredIdleHint ? ` ${configuredIdleHint}.` : ''} 상세 상태 정보가 올라오면 상태별 분류와 카드가 채워집니다.`

  const rosterRows = filtered.map((agent: Agent) => {
    const keeperRuntime =
      keeperRuntimeLookup.get(agent.name)
      ?? findKeeperRuntimeForAgent(agent, keeperRuntimeLookup)
      ?? findKeeperRuntime(agent.name, runtimeKeeperList)
    const band = bandByAgent.get(agent.name) ?? runtimeBandMeta('attention')
    const compositeForMonitoring: KeeperCompositeSnapshot | null =
      keeperRuntime
        ? compositeByKeeperKey.get(keeperRuntime.name)
          ?? (typeof keeperRuntime.keeper_id === 'string'
            ? compositeByKeeperKey.get(keeperRuntime.keeper_id) ?? null
            : null)
        : null
    const keeperMonitoring = keeperRuntime ? summarizeKeeperMonitoring(keeperRuntime, compositeForMonitoring) : null
    const monitoringEvidence = keeperMonitoring ? summarizeMonitoringEvidence(keeperMonitoring) : null
    const fsmPhase = keeperRuntime ? keeperPhaseForDisplay(keeperRuntime, compositeForMonitoring) : null
    const isKeeper = keeperRuntime != null
    // Shared precedence (incl. last_proactive_preview); fall back to the agent
    // context's current_task for agents without a keeper runtime.
    const currentWork = keeperWorkPreview(keeperRuntime) ?? agent.current_task ?? null
    const activityDisplay = keeperRuntime
      ? keeperActivityDisplay(keeperRuntime, agent.last_seen)
      : null
    const lastActivityAge = activityDisplay?.ageSeconds ?? null
    const lastActivityAt = activityDisplay?.timestamp ?? agent.last_seen ?? null
    const lastActivityLabel = activityDisplay?.label ?? '최근 활동'
    const contextMeta = rosterContextMeta(keeperRuntime ?? null)
    const workPreview = trimText(currentWork, 140) ?? '최근 활동 요약 없음'
    const summaryText = workPreview
    const compositeForKeeper: KeeperCompositeSnapshot | null = keeperRuntime
      ? compositeByKeeperKey.get(keeperRuntime.name)
        ?? (keeperRuntime.keeper_id != null
          ? compositeByKeeperKey.get(keeperRuntime.keeper_id)
          : undefined)
        ?? null
      : null
    const stateNote =
      keeperRuntime
        ? rosterStateNote(
            keeperRuntime,
            compositeForKeeper,
            band.key === 'active' ? null : keeperMonitoring?.hint ?? null,
          )
        : null
    const presenceDisplay = rosterPresenceDisplay(agent, keeperRuntime, compositeForKeeper)
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

    return {
      key: agent.name,
      agent,
      keeperRuntime,
      band,
      isKeeper,
      bandActionHint: rosterBandActionHint(band.key, isKeeper),
      displayName,
      currentWork,
      summaryText,
      stateNote,
      presenceDisplay,
      recentTools,
      toolCallCount,
      toolAuditAt,
      lastActivityAge,
      lastActivityAt,
      lastActivityLabel,
      contextMeta,
      fsmPhaseKey,
      fsmStageKey,
      fsmStageText,
      monitoringEvidence,
      detailLabel,
      openDetail,
    }
  })
  const selectedRow = rosterRows.find(row => row.key === selectedKey) ?? rosterRows[0] ?? null
  const selectedBlockerDisplay = selectedRow
    ? rosterBlockerDisplay(selectedRow.stateNote, selectedRow.keeperRuntime)
    : null

  return html`
    <div class="ss-surface bg-surface-page styleseed-scope v2-monitoring-surface agent-page flex w-full flex-col gap-5 px-0 py-1">
      <section class="ss-card bg-card rounded-2xl shadow-card monitor-surface-card monitor-surface-card-strong v2-monitoring-card p-5" aria-label="에이전트 디렉터리">
        <div class="flex flex-col gap-5">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_320px] xl:items-end">
            <div class="flex min-w-0 flex-col gap-2">
              <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-accent-soft)] px-2.5 py-1 text-2xs font-medium text-[var(--color-fg-secondary)]">${resultCountLabel}</span>
            </div>

            <label class="flex w-full flex-col gap-2 text-2xs font-semibold tracking-[var(--track-caps)] text-[var(--color-fg-muted)] uppercase">
              <span>이름 / 작업</span>
              <${TextInput}
                class="rounded-[var(--r-1)] bg-[var(--color-bg-surface)] px-4 py-3 text-base text-[var(--color-fg-primary)] shadow-[inset_0_1px_0_var(--color-border-default)] focus:border-[var(--color-accent-fg)] focus:shadow-[0_0_0_2px_var(--color-accent-soft)]"
                name="agent_search"
                ariaLabel="에이전트 이름 · 작업 검색"
                autoComplete="off"
                placeholder="이름 · 작업으로 찾기"
                value=${search}
                onInput=${(e: Event) => setSearch((e.target as HTMLInputElement).value)}
              />
            </label>
          </div>

          <div class="monitor-muted-panel v2-monitoring-panel p-3.5 md:p-4">
            <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
              <div class="text-2xs font-semibold tracking-[var(--track-caps)] text-[var(--color-fg-secondary)] uppercase">상세 상태</div>
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
                      <strong class="text-xs font-semibold text-[var(--color-fg-primary)]">${fallbackStateTitle}</strong>
                      <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-2 py-0.5 text-2xs font-medium text-[var(--color-fg-muted)]">${countSourceLabel}</span>
                    </div>
                    <p class="m-0 text-xs leading-paragraph text-[var(--color-fg-primary)]">${fallbackStateMessage}</p>
                    <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
                      <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5">scope ${namespaceName}</span>
                      ${configuredIdleHint ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5">${configuredIdleHint}</span>` : null}
                    </div>
                  </div>
                </div>
              `
            : null}

        </div>
      </section>

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_360px]">
        <section class="ss-card bg-card rounded-2xl shadow-card monitor-surface-card monitor-surface-card-medium v2-monitoring-panel overflow-hidden" aria-label="Keeper operations list">
          <!--
            2026-05-27 KEEPER OPERATIONS row redesign:
            - 현재 단계 column was almost always "-" for stuck keepers (the
              dominant case the surface exists for) and duplicated the
              SELECTED RUNTIME phase badge. Removed; the blocker/stage cell
              now switches: blocker text when blocked, stage/phase label
              when running.
            - Row is now div role=button so inline action buttons
              (재개 / 일시정지 / 깨우기 / 기동 / 종료) can be nested without
              violating no-button-in-button HTML. Enter/Space keep
              keyboard selection working.
            - 차단 근거 셀이 truncate(1줄) 였던 것을 line-clamp-2 로 풀어 잘림을 완화.
          -->
          <div class="grid grid-cols-[minmax(180px,1.35fr)_minmax(80px,0.5fr)_minmax(170px,1.1fr)_minmax(110px,0.65fr)_minmax(160px,0.9fr)] gap-3 border-b border-[var(--color-border-divider)] px-4 py-2.5 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)] max-lg:hidden">
            <span>Keeper</span>
            <span>운영판정</span>
            <span>차단 · 단계</span>
            <span>최근 도구</span>
            <span>액션</span>
          </div>

          <div class="divide-y divide-[var(--color-border-divider)]">
            ${rosterRows.map(row => {
              const selected = selectedRow?.key === row.key
              const blockerDisplay = rosterBlockerDisplay(row.stateNote, row.keeperRuntime)
              const stageLabel =
                row.fsmStageText
                ?? row.monitoringEvidence?.phase?.label
                ?? row.monitoringEvidence?.stage?.label
                ?? null
              // 차단이 있으면 차단 근거가 더 의미 있고, 차단이 없으면 현재 단계 라벨로 fallback.
              // 둘 다 없으면 '-'.
              const blockerOrStage = row.stateNote
                ? blockerDisplay.cell
                : (stageLabel ?? '-')
              const blockerOrStageTitle = row.stateNote
                ? blockerDisplay.title
                : (stageLabel ?? '')
              const latestTool = row.recentTools[0] ?? (row.toolCallCount != null && row.toolCallCount > 0 ? `${row.toolCallCount} calls` : '-')

              const handleRowKey = (e: KeyboardEvent) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault()
                  setSelectedKey(row.key)
                }
              }

              return html`
                <div
                  role="button"
                  tabIndex=${0}
                  key=${row.key}
                  data-testid="keeper-operations-row"
                  aria-label=${`${row.displayName} 선택`}
                  aria-pressed=${selected}
                  onClick=${() => setSelectedKey(row.key)}
                  onKeyDown=${handleRowKey}
                  class="v2-monitoring-roster-row grid w-full cursor-pointer grid-cols-1 gap-2 px-4 py-3 text-left transition-colors hover:bg-[var(--color-bg-elevated)] ${ringFocusClasses({ tone: 'accent-fg', width: 2 })} lg:grid-cols-[minmax(180px,1.35fr)_minmax(80px,0.5fr)_minmax(170px,1.1fr)_minmax(110px,0.65fr)_minmax(160px,0.9fr)] lg:items-center lg:gap-3 ${selected ? 'bg-[var(--color-bg-hover)]' : 'bg-transparent'}"
                >
                  <span class="flex min-w-0 items-center gap-3">
                    <span class="shrink-0">
                      <${AgentAvatar}
                        name=${row.agent.name}
                        status=${row.presenceDisplay.status}
                        traits=${row.agent.traits}
                        size="md"
                        currentWork=${row.currentWork}
                        activityAge=${row.lastActivityAge}
                      />
                    </span>
                    <span class="min-w-0">
                      <span class="block truncate text-sm font-semibold text-[var(--color-fg-primary)]">${row.displayName}</span>
                      <span class="mt-0.5 flex flex-wrap items-center gap-1.5 text-2xs text-[var(--color-fg-secondary)]">
                        <${AgentPresence} status=${row.presenceDisplay.status} detail=${row.presenceDisplay.detail} size="sm" />
                      </span>
                    </span>
                  </span>

                  <span
                    class="inline-flex w-fit min-w-[4.5rem] flex-col items-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-2xs font-medium leading-tight text-[var(--color-fg-primary)] lg:w-auto"
                    title=${row.band.description}
                  >
                    <span>${row.band.label}</span>
                    <span class="mt-0.5 text-2xs font-normal text-[var(--color-fg-secondary)]">${row.bandActionHint}</span>
                  </span>

                  <span class="min-w-0 text-xs leading-snug text-[var(--color-fg-primary)]">
                    <span class="block truncate lg:hidden text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">차단 · 단계</span>
                    <span class="line-clamp-2 break-words" title=${blockerOrStageTitle}>${blockerOrStage}</span>
                  </span>

                  <span class="min-w-0 text-xs leading-snug text-[var(--color-fg-primary)]">
                    <span class="block truncate lg:hidden text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">최근 도구</span>
                    <span class="block truncate" title=${latestTool}>${latestTool}</span>
                  </span>

                  <span class="min-w-0">
                    <span class="block lg:hidden text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">액션</span>
                    ${row.keeperRuntime
                      ? html`<${KeeperActionButtons}
                          keeper=${row.keeperRuntime}
                          size="sm"
                          compact
                          stopPropagation
                        />`
                      : html`<span class="text-2xs text-[var(--color-fg-muted)]">—</span>`}
                  </span>
                </div>
              `
            })}

            ${rosterRows.length === 0 ? html`
              <div class="px-6 py-10">
                <${EmptyState}
                  message=${normalizedSearch && scopedAgents.length > 0
                    ? `필터 결과 없음 (${scopedAgents.length} items)`
                    : showExecutionFallbackState && expectedScopedCount > 0
                      ? `${fallbackStateTitle}: ${countSourceLabel} 기준 ${scopeLabel}가 보이지만, 현재 조건에 맞는 상세 row는 아직 없습니다.`
                      : '조건에 맞는 에이전트가 없습니다.'}
                  compact
                />
              </div>
            ` : null}
          </div>
        </section>

        <aside class="ss-card bg-card rounded-2xl shadow-card monitor-surface-card monitor-surface-card-medium v2-monitoring-panel p-4" aria-label="Selected keeper detail">
          ${selectedRow ? html`
            <div class="flex h-full flex-col gap-4">
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <span class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">selected runtime</span>
                  <h3 class="m-0 mt-1 truncate text-xl font-semibold text-[var(--color-fg-primary)]">${selectedRow.displayName}</h3>
                </div>
                <${AgentPresence} status=${selectedRow.presenceDisplay.status} detail=${selectedRow.presenceDisplay.detail} size="sm" />
              </div>

              <p class="m-0 text-sm leading-paragraph text-[var(--color-fg-primary)]" title=${selectedRow.summaryText}>${selectedRow.summaryText}</p>

              <div class="flex flex-wrap items-center gap-2">
                ${selectedRow.isKeeper && selectedRow.fsmPhaseKey
                  ? html`<${KeeperPhaseBadge} phase=${selectedRow.fsmPhaseKey} compact />`
                  : null}
                ${selectedRow.fsmStageKey && selectedRow.fsmStageText ? html`
                  <span class="inline-flex items-center rounded-[var(--r-0)] border px-2 py-0.5 text-2xs font-medium ${stageBadgeClass(selectedRow.fsmStageKey)}" title=${selectedRow.monitoringEvidence?.stage?.description ?? '활동 단계 정보가 없습니다.'}>
                    ${selectedRow.fsmStageText}
                  </span>
                ` : null}
                <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs text-[var(--color-fg-muted)]" title=${selectedRow.band.description}>
                  상태 액션
                  <span class="ml-1 text-[var(--color-fg-primary)]">${selectedRow.bandActionHint}</span>
                </span>
                <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs text-[var(--color-fg-muted)]">
                  ${selectedRow.lastActivityLabel}
                  <span class="ml-1 text-[var(--color-fg-primary)]">
                    ${selectedRow.lastActivityAt
                      ? html`<${TimeAgo} timestamp=${selectedRow.lastActivityAt} />`
                      : selectedRow.lastActivityAge != null
                        ? `${formatDuration(selectedRow.lastActivityAge)} 전`
                        : '기록 없음'}
                  </span>
                </span>
              </div>

              ${selectedRow.stateNote ? html`
                <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-status-warn)]">${selectedRow.stateNote.label}</span>
                    ${selectedBlockerDisplay?.kindLabel
                      ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-divider)] bg-[var(--color-bg-page)] px-2 py-0.5 text-2xs text-[var(--color-fg-primary)]">${selectedBlockerDisplay.kindLabel}</span>`
                      : null}
                    ${selectedBlockerDisplay?.rawKind
                      ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-divider)] bg-[var(--color-bg-page)] px-2 py-0.5 text-2xs font-mono text-[var(--color-fg-muted)]">${selectedBlockerDisplay.rawKind}</span>`
                      : null}
                  </div>
                  <p class="m-0 mt-1 text-xs leading-relaxed text-[var(--color-fg-primary)]">${selectedBlockerDisplay?.detail}</p>
                </div>
              ` : null}

              ${selectedRow.contextMeta ? html`
                <div class="flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-xs text-[var(--color-fg-muted)]">
                  <span class="font-semibold uppercase tracking-[var(--track-caps)]">CTX</span>
                  <span class="font-mono text-[var(--color-fg-secondary)]">${selectedRow.contextMeta.pct}%</span>
                  ${selectedRow.contextMeta.detail ? html`<span class="font-mono text-2xs">${selectedRow.contextMeta.detail}</span>` : null}
                  <span class="ml-auto inline-block h-1.5 w-20 overflow-hidden rounded-[var(--r-0)] bg-[var(--color-bg-hover)]">
                    <span class="block h-full rounded-[var(--r-0)] ${selectedRow.contextMeta.pct > 85 ? 'bg-[var(--color-status-err)]' : selectedRow.contextMeta.pct > 60 ? 'bg-[var(--color-status-warn)]' : 'bg-[var(--color-status-ok)]'}" style="width:${selectedRow.contextMeta.pct}%"></span>
                  </span>
                </div>
              ` : null}

              ${(selectedRow.recentTools.length > 0 || selectedRow.toolCallCount != null || selectedRow.toolAuditAt) ? html`
                <div class="flex flex-wrap items-center gap-1.5 text-2xs text-[var(--color-fg-muted)]">
                  <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5">최근 도구</span>
                  <${AgentCapability} tools=${selectedRow.recentTools} maxVisible=${5} />
                  ${selectedRow.toolCallCount != null && selectedRow.toolCallCount > 0 ? html`
                    <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs">${selectedRow.toolCallCount}회 관찰됨</span>
                  ` : null}
                  ${selectedRow.toolAuditAt ? html`
                    <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs">감사 <${TimeAgo} timestamp=${selectedRow.toolAuditAt} /></span>
                  ` : null}
                </div>
              ` : null}

              ${selectedRow.keeperRuntime ? html`
                <div class="grid gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
                  <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">detail lenses</div>
                  <div class="flex flex-wrap gap-2">
                    <${RouteLink}
                      tab="monitoring"
                      params=${{ section: 'cognition', view: 'keeper', keeper: selectedRow.keeperRuntime.name, focus: 'bdi' }}
                      class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-hover)]"
                    >
                      Cognition
                    <//>
                    <${RouteLink}
                      tab="monitoring"
                      params=${{ section: 'cognition', view: 'keeper', keeper: selectedRow.keeperRuntime.name, focus: 'tool-access' }}
                      class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-hover)]"
                    >
                      Tool Access
                    <//>
                    <${RouteLink}
                      tab="monitoring"
                      params=${{ section: 'runtime', view: 'inspector', keeper: selectedRow.keeperRuntime.name }}
                      class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2.5 py-1.5 text-xs font-medium text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-hover)]"
                    >
                      Runtime Trace
                    <//>
                  </div>
                </div>
              ` : null}

              <div class="mt-auto flex flex-wrap gap-2">
                <button
                  type="button"
                  class="v2-monitoring-action inline-flex items-center justify-center rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-3 py-2 text-xs font-medium text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--accent-20)]"
                  aria-label=${selectedRow.detailLabel}
                  onClick=${selectedRow.openDetail}
                >
                  상세 열기
                </button>
              </div>
            </div>
          ` : html`
            <${EmptyState} message="선택할 keeper 또는 agent가 없습니다." compact />
          `}
        </aside>
      </div>
    </div>
  `
}
