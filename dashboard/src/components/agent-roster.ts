// MASC Dashboard — Runtime Roster
// Workspace agents, keeper runtime fibers, configured keepers, and task owners
// are separate surfaces internally. Fleet joins them only through typed
// keeper_id / keeper_name / agent_name relation fields; display-name parsing
// is not an identity contract. The roster therefore needs no disclaimer copy.

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
  shellRuntimeResolution,
} from '../store'
import { EmptyState } from './common/feedback-state'
import { ringFocusClasses } from './common/ring'
import { RouteLink } from './common/route-link'
import { TimeAgo } from './common/time-ago'
import { AgentAvatar } from './overview/agent-avatar'
import { AgentPresence } from './common/agent-presence'
import { AgentCapability } from './common/agent-capability'
import { openAgentProfile } from './agent-detail-state'
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
import { keeperExclusionLabel } from './keeper-exclusion-label'
import {
  expectedKeeperDetailRows,
  expectedRuntimeDetailRows,
  formatKeeperCountBreakdown,
  formatRuntimeRosterCount,
  keeperRowLooksRunning,
  resolveRuntimeCounts,
  runtimeDetailRows,
  shouldShowExecutionFallbackState,
} from '../runtime-counts'
import {
  keeperActivityDisplay,
  keeperDisplayRuntime,
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
import { FL_TONE_LABEL, type FleetTone } from '../lib/fleet-tone'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import { compositeSnapshotForKeeper } from '../lib/keeper-composite-lookup'
import { buildCompositeByKeeperKey, fleetCompositeSnapshot } from '../composite-signals'
import { showSpawnPanel } from './keeper-spawn/keeper-spawn-state'
import { operatorSnapshot } from '../operator-store'

type RosterStateNote = { label: string; text: string; kind?: string }
type RosterPresenceDisplay = { status: string | null; detail: string | null }

function rosterBandActionHint(band: RuntimeBand, isKeeper: boolean): string {
  switch (band) {
    case 'active': return '감시 중'
    case 'attention': return '확인 필요'
    case 'paused': return '재개 대기'
    case 'offline': return isKeeper ? '기동 필요' : '연결 없음'
    case 'transient': return '전이'
  }
}

// PipelineStage SSOT: branches aligned to `types/core.ts#PipelineStage`.
// Tone for the scannable per-row rail (keeper-v2 Fleet design: a left edge
// keyed to runtime band so keeper state reads down a single column instead of
// every row looking identical). Maps masc's RuntimeBand onto the v2 tone
// vocabulary (ok/warn/bad/busy/idle); the CSS in v2-monitoring.css paints the
// edge. RFC-0295: `transient` resolves to `busy`, activating the previously
// dead `[data-tone="busy"]` selectors in fleet.css.
const ROSTER_BAND_TONE: Record<RuntimeBand, 'ok' | 'warn' | 'bad' | 'busy' | 'idle'> = {
  active: 'ok',
  attention: 'bad',
  paused: 'warn',
  offline: 'idle',
  transient: 'busy',
}

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
    const reason = gate.disposition_reason?.trim()
    const text = [
      tool ? `작업 ${tool}` : 'Gate Human 판단 필요',
      reason ? `사유 ${reason}` : null,
    ].filter((part): part is string => part !== null).join(' · ')
    return { label: 'HITL 대기', text }
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

  // #16 (38-bug campaign PR-5): prefer the backend's typed `run_state` —
  // it distinguishes actively executing (and *why* it woke) from idle
  // waiting for the proactive cadence, which the old `is_live` boolean
  // could not. Falls back to `is_live` only when `run_state` is absent
  // (a pinned backend that predates this field), never when it is present
  // but `waiting`/`suspended` — those are honest "not busy" answers, not
  // missing data.
  if (state.kind === 'running') {
    const runState = composite?.run_state
    if (runState?.kind === 'in_turn') {
      const wakeLabel = runState.wake_kind === 'woken'
        ? '반응형'
        : runState.wake_kind === 'proactive_tick'
          ? '자율'
          : runState.wake_kind != null
            ? `기원 ${runState.wake_kind}`
            : '기원 확인 필요'
      return { status: 'busy', detail: `${state.turnPhase} live · ${wakeLabel}` }
    }
    if (runState?.kind === 'waiting') {
      const depth = runState.queue_depth
      const detail = depth == null
        ? '대기 중 · 큐 확인 필요'
        : depth > 0
          ? `대기 중 · 큐 ${depth}`
          : '대기 중'
      return { status: 'idle', detail }
    }
    if (runState?.kind === 'suspended') {
      const phase = runState.phase?.trim()
      return {
        status: agent.status ?? keeper.status ?? null,
        detail: phase ? `중단 · ${phase}` : '중단 · 단계 확인 필요',
      }
    }
    if (runState != null) {
      return {
        status: agent.status ?? keeper.status ?? null,
        detail: `런타임 상태 ${runState.kind}`,
      }
    }
    if (runState == null) {
      if (composite?.is_live === true) {
        return { status: 'busy', detail: `${state.turnPhase} live` }
      }
      if (composite?.is_live === false) {
        return { status: 'idle', detail: '대기 중' }
      }
    }
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

// keeper-v2 Fleet skin (fleet.css .fl-*) helpers. The prototype keys every
// chip / rail / aside-state on a 5-value tone vocabulary
// (ok/warn/bad/busy/idle). RFC-0295 brings masc's RuntimeBand to the same 5
// values via ROSTER_BAND_TONE (transient → busy); the Korean tone label
// is the SSOT `FL_TONE_LABEL` from `lib/fleet-tone.ts` (shared with
// `keeper-workspace-shared.ts`), used for the aside "selected runtime"
// state line. Do not redeclare here — see fleet-tone.ts.

// CTX pressure threshold the prototype paints `hot` at (>=85%). Mirrors the
// existing live threshold used in the aside CTX meter so both surfaces agree.
const FLEET_CTX_HOT_PCT = 85

type FleetVital = { k: string; v: string }

type FleetRuntimeEvidence =
  | { source: 'assigned'; value: string }
  | { source: 'unknown'; value: null }

export function fleetRuntimeEvidence(keeper: Keeper | null): FleetRuntimeEvidence {
  const runtime = keeperDisplayRuntime(keeper)
  return runtime
    ? { source: 'assigned', value: runtime.value }
    : { source: 'unknown', value: null }
}

// Build the aside `런타임` vitals grid from shared keeper runtime display only.
// Fields with no live source (e.g. tps) are omitted rather than fabricated —
// the audit (P1-6) flags `tps` as having no roster-model source.
function fleetRuntimeVitals(
  keeper: Keeper | null,
  contextDetail: string | null,
): FleetVital[] {
  if (!keeper) return []
  const vitals: FleetVital[] = []

  const runtime = fleetRuntimeEvidence(keeper)
  vitals.push({
    k: runtime.source === 'assigned' ? 'runtime · 할당' : 'runtime · 미확인',
    v: runtime.value ?? '미확인',
  })

  if (typeof keeper.keeper_age_s === 'number' && Number.isFinite(keeper.keeper_age_s)) {
    vitals.push({ k: 'uptime', v: formatDuration(keeper.keeper_age_s) })
  }

  const turns = keeper.total_turns ?? keeper.turn_count ?? null
  if (typeof turns === 'number' && Number.isFinite(turns)) {
    vitals.push({ k: 'turns', v: String(turns) })
  }

  const openTasks = keeper.goal_progress?.open_task_count
  const doneTasks = keeper.goal_progress?.done_task_count
  if (typeof openTasks === 'number' || typeof doneTasks === 'number') {
    const open = typeof openTasks === 'number' ? openTasks : 0
    const done = typeof doneTasks === 'number' ? doneTasks : 0
    vitals.push({ k: 'tasks', v: `${open} / ${done}` })
  }

  if (contextDetail) vitals.push({ k: 'context', v: contextDetail })

  return vitals
}

type FleetAttentionItem = { sev: 'warn' | 'bad'; text: string }

// Collapse the operator-severity wire string (operator_digest_types emits
// "critical" | "bad" | "warn") to the two-level dot the aside attention list
// paints. Unknown/critical fold to the nearest defined tone rather than
// inventing a third dot color.
function fleetAttentionSev(severity: string): 'warn' | 'bad' {
  return severity === 'bad' || severity === 'critical' ? 'bad' : 'warn'
}

// Selected-keeper attention reasons, read from the same live composite that
// drives the row's attention band. Each keeper-targeted `recommended_actions`
// entry (backend-gated on `runtime_attention.needs_attention`) contributes one
// reason — no fixture text, so an item exists only when the backend actually
// recommends an action for this keeper.
function fleetAttentionItems(
  composite: KeeperCompositeSnapshot | null,
): FleetAttentionItem[] {
  if (!composite) return []
  return composite.recommended_actions
    .filter(action => action.target_type === 'keeper')
    .map(action => ({ sev: fleetAttentionSev(action.severity), text: action.reason }))
}

function relationValue(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function relationKey(
  kind: 'keeper-id' | 'keeper-name' | 'agent-name',
  value: string | null | undefined,
): string | null {
  const relation = relationValue(value)
  return relation ? `${kind}:${relation}` : null
}

/** Fleet identity joins use backend-projected relation fields only.
 *
 * The key namespace is part of the relation: equal text in a keeper id, keeper
 * name, and agent name does not make those identifiers interchangeable. In
 * particular, this code never parses `keeper-*-agent` or generated nicknames. */
function keeperRelationKeys(source: Keeper): string[] {
  const keys = [
    relationKey('keeper-id', source.keeper_id),
    relationKey('keeper-name', source.name),
    relationKey('agent-name', source.agent_name),
    relationKey('agent-name', source.agent?.name),
  ]
  return Array.from(new Set(keys.filter((key): key is string => key != null)))
}

function agentRelationKeys(agent: Pick<Agent, 'name' | 'keeper_id' | 'keeper_name'>): string[] {
  const keys = [
    relationKey('keeper-id', agent.keeper_id),
    relationKey('keeper-name', agent.keeper_name),
    relationKey('agent-name', agent.name),
  ]
  return Array.from(new Set(keys.filter((key): key is string => key != null)))
}

function fleetKeeperKey(source: Pick<Keeper, 'keeper_id' | 'name'>): string {
  const keeperId = relationValue(source.keeper_id)
  if (keeperId) return `keeper-id:${keeperId}`
  return `keeper-name:${source.name.trim()}`
}

function registerKeeperLookup(lookup: Map<string, Keeper>, source: Keeper) {
  for (const key of keeperRelationKeys(source)) {
    if (!lookup.has(key)) lookup.set(key, source)
  }
}

function buildKeeperRuntimeLookup(keeperList: Keeper[]): Map<string, Keeper> {
  const lookup = new Map<string, Keeper>()
  for (const keeper of keeperList) registerKeeperLookup(lookup, keeper)
  return lookup
}

function findKeeperRuntimeForAgent(
  agent: Pick<Agent, 'name' | 'keeper_id' | 'keeper_name'>,
  lookup: Map<string, Keeper>,
): Keeper | null {
  for (const key of agentRelationKeys(agent)) {
    const keeper = lookup.get(key)
    if (keeper) return keeper
  }
  return null
}

function fleetRosterKey(
  agent: Pick<Agent, 'name' | 'keeper_id' | 'keeper_name'>,
  lookup: Map<string, Keeper>,
): string {
  const keeper = findKeeperRuntimeForAgent(agent, lookup)
  return keeper
    ? fleetKeeperKey(keeper)
    : `agent-name:${agent.name.trim()}`
}

function fleetKeeperIdEvidence(keeper: Keeper | null): string | null {
  const keeperId = relationValue(keeper?.keeper_id)
  const keeperName = relationValue(keeper?.name)
  return keeperId && keeperId !== keeperName ? keeperId : null
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
  return keeperRelationKeys(keeper).some(key => liveAgentKeys.has(key))
}

function liveAgentIdentityKeys(agentList: readonly Agent[]): Set<string> {
  const keys = new Set<string>()
  for (const agent of agentList) {
    if (!agentCanBackKeeperRuntime(agent)) continue
    for (const key of agentRelationKeys(agent)) keys.add(key)
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

function keeperRuntimeAgentProjection(source: Keeper): RosterAgent | null {
  const displayName = relationValue(source.name)
  if (!displayName) return null

  const linkedAgent = source.agent
  const liveCurrentTask =
    source.recent_output_preview
    ?? source.recent_input_preview
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
    const key = keeper
      ? fleetKeeperKey(keeper)
      : `agent-name:${agent.name.trim()}`
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
    const key = fleetKeeperKey(source)
    roster.set(key, mergeRosterAgent(roster.get(key), keeperRuntimeAgent))
  }

  return Array.from(roster.values())
}

function countAgentsByStatus(
  agentList: Agent[],
  keeperList: Keeper[],
  compositeByKeeperKey: ReadonlyMap<string, KeeperCompositeSnapshot> | null = null,
): Record<RuntimeBand, number> {
  const keeperLookup = buildKeeperRuntimeLookup(keeperList)
  const counts: Record<RuntimeBand, number> = {
    active: 0,
    attention: 0,
    paused: 0,
    offline: 0,
    // RFC-0295: keep parity with the 5-band facet so transient keepers
    // appear under their own filter rather than being silently absorbed by
    // `active`.
    transient: 0,
  }

  for (const agent of agentList) {
    const keeperRuntime = findKeeperRuntimeForAgent(agent, keeperLookup)
    // RFC-0135 PR-12: pass composite to band derivation so stale
    // blockers are demoted via SSOT instead of inflating attention.
    const composite = compositeSnapshotForKeeper(keeperRuntime, compositeByKeeperKey)
    const band = runtimeBandMetaForAgent(agent, keeperRuntime, composite).key
    counts[band] += 1
  }

  return counts
}

export function countRuntimeKinds(
  agentList: Agent[],
  keeperList: Keeper[],
  // RFC-0295: pass the fleet-wide composite snapshot map so the breakdown
  // agrees with the per-row band computation (`liveRuntimeCounts`,
  // `bandByAgent`). Without this, countRuntimeKinds and the chip/footer math
  // would disagree on transient/attention whenever composite gates shift
  // the band — a silent operator-visible count inconsistency.
  compositeByKeeperKey?: ReadonlyMap<string, KeeperCompositeSnapshot> | null,
): {
  agents: number
  keepers: number
  pausedKeepers: number
  // RFC-0295: transient band rows (Compacting / HandingOff / Restarting)
  // are now part of the breakdown. Exposed so consumers can reconcile
  // `keepers + pausedKeepers + transientKeepers + offlineKeepers` against
  // `keeperRows` without guessing where the missing rows went.
  // RFC-0295 §5.3 (pixel-perfect Fleet tone rail, iter-6): Draining is
  // counted under `pausedKeepers` here, NOT under `transientKeepers`.
  // The Draining phase routes to the `paused` band in `keeperBand()`
  // (`monitoring-runtime.ts`), and the rail paint, filter chip, and
  // count chip are all derived from the same `band` SSOT — so the
  // count must follow the band, not the raw `isKeeperPaused` predicate.
  // `isKeeperPaused` is the *action*-layer predicate (it does not
  // include operator-initiated Draining), while `band === 'paused'` is
  // the *presentation*-layer predicate (it does, by design). The two
  // remain deliberately orthogonal; this count is a presentation
  // surface, so it follows the band.
  transientKeepers: number
  offlineKeepers: number
  keeperRows: number
  totalRuntimes: number
} {
  const runtimeKeepers = rosterDetailKeepers(keeperList, agentList)
  const rosterAgents = buildAgentRoster(agentList, runtimeKeepers)
  const keeperLookup = buildKeeperRuntimeLookup(runtimeKeepers)
  const allKeepers = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeepers, 'keeper-only', keeperLookup)
  // Drive the count from the same `band` SSOT that drives the rail paint
  // (`runtimeBandMetaForAgent`) and the filter chip (`countAgentsByStatus`).
  // Before iter-6 the `pausedKeepers` count used `isKeeperPaused(keeper)`
  // while the rail/filter used `band === 'paused'`; the two diverged on
  // Draining-phase keepers (rail+chip=2, count=1). Routing through `band`
  // closes the gap so the chip count and the rail paint always agree.
  let pausedKeepers = 0
  let runningKeepers = 0
  let transientKeepers = 0
  for (const row of allKeepers) {
    const keeper = findKeeperRuntimeForAgent(row, keeperLookup)
    const composite = compositeSnapshotForKeeper(keeper, compositeByKeeperKey ?? null)
    const band = keeper ? runtimeBandMetaForAgent(row, keeper, composite).key : null
    if (band === 'transient') {
      transientKeepers += 1
    } else if (band === 'paused') {
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
    transientKeepers,
    offlineKeepers: Math.max(0, keeperRows - runningKeepers - pausedKeepers - transientKeepers),
    keeperRows,
    totalRuntimes: rosterAgents.length,
  }
}

export function AgentRoster({ keeperFilter = 'all' }: { keeperFilter?: KeeperFilterMode } = {}) {
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
  const compositeByKeeperKey = useMemo(() => buildCompositeByKeeperKey(fleetSnapshot), [fleetSnapshot])

  // Derive runtime kind counts from memoized roster (avoids duplicate buildAgentRoster call)
  const liveRuntimeCounts = useMemo(() => {
    const allKeepers = scopeAgentsByKeeperFilter(rosterAgents, runtimeKeeperList, 'keeper-only', keeperRuntimeLookup)
    // Count via the same `band` SSOT that the rail paint and health pills
    // use. RFC-0295 §5.3 + iter-6 reconciliation: `Draining` phase
    // contributes to `pausedCount` because `keeperBand()` routes it to
    // the `paused` band. The duplicated count block in `countRuntimeKinds`
    // carries the same logic; keep them structurally aligned.
    let pausedCount = 0
    let runningCount = 0
    let transientCount = 0
    for (const row of allKeepers) {
      const keeper = findKeeperRuntimeForAgent(row, keeperRuntimeLookup)
      const band = keeper
        ? runtimeBandMetaForAgent(row, keeper, compositeSnapshotForKeeper(keeper, compositeByKeeperKey)).key
        : null
      if (band === 'transient') {
        transientCount += 1
      } else if (band === 'paused') {
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
      transientKeepers: transientCount,
      offlineKeepers: Math.max(0, keeperRows - runningCount - pausedCount - transientCount),
      keeperRows,
      totalRuntimes: rosterAgents.length,
    }
  }, [rosterAgents, runtimeKeeperList, keeperRuntimeLookup, compositeByKeeperKey])

  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: liveRuntimeCounts.agents,
    keepersCount: liveRuntimeCounts.keepers,
    pausedKeepersCount: liveRuntimeCounts.pausedKeepers,
    transientKeepersCount: liveRuntimeCounts.transientKeepers,
    offlineKeepersCount: liveRuntimeCounts.offlineKeepers,
    keeperRowsCount: liveRuntimeCounts.keeperRows,
    namespaceTruthCounts: namespaceTruth.value?.root.counts,
    namespaceTruthConfiguredKeepers: namespaceTruth.value?.root.configured_keepers,
    shellCounts: shellCounts.value,
    shellConfiguredKeepers: shellCounts.value?.configured_keepers,
    runtimeFleetSafety: shellRuntimeResolution.value?.fleet_safety ?? null,
    runtimeHealthGeneratedAt: shellRuntimeResolution.value?.generated_at ?? null,
  })
  const expectedScopedCount = expectedCountForKeeperFilter(keeperFilter, runtimeCounts)
  const namespaceStatus = namespaceTruth.value?.root.status ?? serverStatus.value
  const namespaceName = namespaceStatus?.project ?? 'default'
  const inferenceInflight = operatorSnapshot.value?.inference_inflight ?? null

  const scopedAgents = useMemo(
    () => scopeAgentsByKeeperFilter(rosterAgents, runtimeKeeperList, keeperFilter, keeperRuntimeLookup),
    [rosterAgents, runtimeKeeperList, keeperFilter, keeperRuntimeLookup],
  )
  const bandByAgent = useMemo(
    () => new Map(
      scopedAgents.map(agent => {
        const keeperRuntime = findKeeperRuntimeForAgent(agent, keeperRuntimeLookup)
        // RFC-0135 PR-12: thread composite snapshot through band
        // derivation so stale-blocker demotion in the typed SSOT
        // applies to the badge color too.
        const composite = compositeSnapshotForKeeper(keeperRuntime, compositeByKeeperKey)
        return [
          fleetRosterKey(agent, keeperRuntimeLookup),
          runtimeBandMetaForAgent(agent, keeperRuntime, composite),
        ] as const
      }),
    ),
    [scopedAgents, keeperRuntimeLookup, compositeByKeeperKey],
  )
  const filtered = useMemo(() => scopedAgents.slice()
    .sort((a: Agent, b: Agent) => {
      // RFC-0295: transient sits between active and paused on the sort
      // axis — the prototype groups "what is currently moving" above the
      // healthy steady-state rows so the operator's first scan reads as
      // "attention → transient → active → paused → offline" instead of
      // burying a mid-compaction keeper under the active rows.
      const order: Record<RuntimeBand, number> = {
        attention: 0,
        transient: 1,
        active: 2,
        paused: 3,
        offline: 4,
      }
      const aOrder = order[
        bandByAgent.get(fleetRosterKey(a, keeperRuntimeLookup))?.key ?? 'attention'
      ]
      const bOrder = order[
        bandByAgent.get(fleetRosterKey(b, keeperRuntimeLookup))?.key ?? 'attention'
      ]
      if (aOrder !== bOrder) return aOrder - bOrder
      return a.name.localeCompare(b.name)
    }),
    [scopedAgents, bandByAgent, keeperRuntimeLookup],
  )

  const counts = countAgentsByStatus(scopedAgents, runtimeKeeperList, compositeByKeeperKey)
  const showExecutionFallbackState = shouldShowExecutionFallbackState({
    executionLoaded: executionLoaded.value,
    executionLoading: executionLoading.value,
    executionError: executionError.value,
    loadedCount: scopedAgents.length,
    expectedCount: expectedScopedCount,
  })
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
        transientKeepers: liveRuntimeCounts.transientKeepers,
        offlineKeepers: liveOfflineKeepers,
        configuredKeepers,
      })
    : keeperFilter === 'agent-only'
      ? `workspace agents ${runtimeCounts.live.agents}`
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
      ? '상태 불러오기 실패'
      : executionLoaded.value
        ? '일부만 불러옴'
        : '불러오는 중'
  const fallbackStateMessage =
    executionError.value
      ? `${scopeLabel}. 상태 정보를 아직 불러오지 못했습니다.`
      : executionLoaded.value
        ? `${scopeLabel}. 일부만 불러왔습니다.${configuredIdleHint ? ` ${configuredIdleHint}.` : ''}`
        : `${scopeLabel}.${configuredIdleHint ? ` ${configuredIdleHint}.` : ''} 상태 정보가 올라오면 목록이 채워집니다.`

  const rosterRows = useMemo(() => filtered.map((agent: Agent) => {
    const keeperRuntime = findKeeperRuntimeForAgent(agent, keeperRuntimeLookup)
    const rowKey = fleetRosterKey(agent, keeperRuntimeLookup)
    const band = bandByAgent.get(rowKey) ?? runtimeBandMeta('attention')
    const compositeForMonitoring: KeeperCompositeSnapshot | null =
      compositeSnapshotForKeeper(keeperRuntime, compositeByKeeperKey)
    const keeperMonitoring = keeperRuntime ? summarizeKeeperMonitoring(keeperRuntime, compositeForMonitoring) : null
    const monitoringEvidence = keeperMonitoring ? summarizeMonitoringEvidence(keeperMonitoring) : null
    const attentionItems = fleetAttentionItems(compositeForMonitoring)
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
    const compositeForKeeper: KeeperCompositeSnapshot | null =
      compositeSnapshotForKeeper(keeperRuntime, compositeByKeeperKey)
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
    const displayName = relationValue(keeperRuntime?.name) ?? agent.name
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
      openAgentProfile(agent.name)
    }

    return {
      key: rowKey,
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
      attentionItems,
      detailLabel,
      openDetail,
    }
  }),
    [filtered, keeperRuntimeLookup, runtimeKeeperList, bandByAgent, compositeByKeeperKey],
  )
  const selectedRow = rosterRows.find(row => row.key === selectedKey) ?? rosterRows[0] ?? null
  const selectedBlockerDisplay = selectedRow
    ? rosterBlockerDisplay(selectedRow.stateNote, selectedRow.keeperRuntime)
    : null

  // keeper-v2 Fleet skin: partition the (already sorted) rows into attention,
  // transient, and steady groups so transitional keepers do not appear under
  // the normal-state divider.
  const attentionRows = rosterRows.filter(row => row.band.key === 'attention')
  const transientRows = rosterRows.filter(row => row.band.key === 'transient')
  const steadyRows = rosterRows.filter(row => row.band.key !== 'attention' && row.band.key !== 'transient')

  // Health pills (fl-hpill) read from the same band counts as the rows. No title
  // here — the shell's SurfaceLead owns the "Keeper Fleet" header for this
  // surface (dashboard-shell SURFACE_OWN_LEAD).
  const healthRun = counts.active
  const healthTransient = counts.transient
  const healthPaused = counts.paused
  const healthOffline = counts.offline
  const healthAttention = counts.attention

  const selectedTone: FleetTone = selectedRow ? ROSTER_BAND_TONE[selectedRow.band.key] : 'idle'
  const selectedCtxPct = selectedRow?.contextMeta?.pct ?? null
  const selectedCtxHot = selectedCtxPct != null && selectedCtxPct >= FLEET_CTX_HOT_PCT
  const selectedVitals = selectedRow
    ? fleetRuntimeVitals(selectedRow.keeperRuntime, selectedRow.contextMeta?.detail ?? null)
    : []
  const selectedKoreanName = selectedRow?.keeperRuntime?.koreanName?.trim()
    || selectedRow?.agent.koreanName?.trim()
    || null
  const selectedKeeperId = fleetKeeperIdEvidence(selectedRow?.keeperRuntime ?? null)

  // Render one fleet roster row (.fl-row), layered with the live classes /
  // test-ids the tests + CSS rely on (v2-monitoring-roster-row, data-tone,
  // data-testid). The grid track comes from .fl-row (var(--fl-cols)).
  const renderFleetRow = (row: (typeof rosterRows)[number]) => {
    const selected = selectedRow?.key === row.key
    const tone = ROSTER_BAND_TONE[row.band.key]
    const blockerDisplay = rosterBlockerDisplay(row.stateNote, row.keeperRuntime)
    const stageLabel =
      row.fsmStageText
      ?? row.monitoringEvidence?.phase?.label
      ?? row.monitoringEvidence?.stage?.label
      ?? null
    // chip text: band label (운영판정) so the operational verdict reads first,
    // matching the legacy column the tests + operators rely on. gloss line:
    // blocker reason when present, else the stage/phase label. The band action
    // hint (재개 대기 / 기동 필요 / 감시 중 / 연결 없음) renders as a second
    // muted line. All fall back to honest copy, never faked.
    const chipLabel = row.band.label
    // autoboot exclusion (declarative_autoboot_disabled / autoboot_disabled):
    // why this keeper is not booting. null when bootable; paused has its own
    // 일시정지 UI so it is filtered out in keeperExclusionLabel. Surfaced on
    // execution keepers via enrich_keeper_with_diagnostic.
    const exclusionLabel = keeperExclusionLabel(row.keeperRuntime?.exclusion_reason)
    // #16 (38-bug campaign PR-5): never claim a bare "실행 중" (running)
    // as a silent default — that hid actively-executing / idle-waiting /
    // reactively-woken behind one label. Prefer the FSM stage label, then
    // the typed presence detail (itself derived from `run_state`; see
    // `rosterPresenceDisplay`), and only fall back to an explicit
    // "unknown" when neither is available.
    const glossText = row.stateNote
      ? blockerDisplay.cell
      : (stageLabel ?? row.presenceDisplay.detail ?? '상태 확인 필요')
    const glossTitle = row.stateNote ? blockerDisplay.title : (stageLabel ?? '')
    const latestTool = row.recentTools[0] ?? (row.toolCallCount != null && row.toolCallCount > 0 ? `${row.toolCallCount} calls` : '—')
    const ctxPct = row.contextMeta?.pct ?? null
    const ctxHot = ctxPct != null && ctxPct >= FLEET_CTX_HOT_PCT
    const runtime = fleetRuntimeEvidence(row.keeperRuntime)
    const keeperId = fleetKeeperIdEvidence(row.keeperRuntime)

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
        data-roster-key=${row.key}
        data-tone=${tone}
        aria-label=${row.isKeeper
          ? `${row.displayName} keeper 선택`
          : `${row.displayName} agent 선택`}
        aria-pressed=${selected}
        onClick=${() => setSelectedKey(row.key)}
        onKeyDown=${handleRowKey}
        class="fl-row v2-monitoring-roster-row ${selected ? 'sel' : ''} ${ringFocusClasses({ tone: 'accent-fg', width: 2 })}"
      >
        <div class="fl-id" aria-label=${`Keeper ${row.displayName}`}>
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
          <div class="fl-id-txt">
            <div class="fl-name">
              <b>${row.displayName}</b>
              ${row.band.key === 'attention' ? html`<span class="fl-att">▲</span>` : null}
            </div>
            <div class="mt-0.5 flex flex-wrap items-center gap-1.5 text-2xs text-[var(--color-fg-secondary)]">
              <${AgentPresence} status=${row.presenceDisplay.status} detail=${row.presenceDisplay.detail} size="sm" />
            </div>
            ${row.keeperRuntime?.sandbox_profile === 'local'
              ? html`<div class="fl-ns"><span class="fl-sandbox" title="git worktree 격리 · localhost-trust (OS sandbox 없음)">⬡</span> worktree 격리</div>`
              : keeperId ? html`<div class="fl-ns">keeper-id · ${keeperId}</div>` : null}
          </div>
        </div>

        <div class="fl-state" aria-label=${`운영판정 · 차단 · 단계 ${chipLabel} ${glossText} ${row.bandActionHint}`}>
          <span class="fl-chip" data-tone=${tone} title=${row.band.description}>
            <span class="inline-block h-1.5 w-1.5 rounded-full" style="background:currentColor" aria-hidden="true"></span>
            ${chipLabel}
          </span>
          <span class="fl-gloss" title=${glossTitle}>${glossText}</span>
          <span class="fl-gloss">${row.bandActionHint}</span>
          ${exclusionLabel
            ? html`<span class="fl-gloss" data-exclusion title="자동 부팅에서 제외됨 — 서버 시작 시 기동하지 않습니다. 기동 버튼으로 직접 켜세요.">${exclusionLabel}</span>`
            : null}
        </div>

        <div class="fl-ctx" aria-label=${`컨텍스트 ${ctxPct != null ? `${ctxPct}%` : '없음'}`}>
          ${ctxPct != null
            ? html`
                <div class="fl-ctx-bar"><span class=${ctxHot ? 'hot' : ''} style="width:${ctxPct}%"></span></div>
                <span class="fl-ctx-val ${ctxHot ? 'hot' : ctxPct === 0 ? 'zero' : ''}">${ctxPct}%</span>
              `
            : html`<span class="fl-ctx-val zero" data-stub="no context_ratio">—</span>`}
        </div>

        <div
          class="fl-runtime ${runtime.source === 'unknown' ? 'unknown' : ''}"
          data-runtime-source=${runtime.source}
          title=${runtime.source === 'assigned'
            ? `할당 runtime · ${runtime.value}`
            : 'runtime source · 미확인'}
          aria-label=${runtime.source === 'assigned'
            ? `할당 런타임 ${runtime.value}`
            : '런타임 출처 미확인'}
        >
          <span class="fl-runtime-source">${runtime.source === 'assigned' ? '할당' : '미확인'}</span>
          ${runtime.value ? html`<span class="fl-runtime-value">${runtime.value}</span>` : null}
        </div>

        <div
          class="fl-tool ${row.recentTools.length || (row.toolCallCount ?? 0) > 0 ? '' : 'none'}"
          title=${latestTool}
          aria-label=${`최근 도구 ${latestTool}`}
        >${latestTool}</div>

        <div class="fl-actcell" aria-label="액션" onClick=${(e: Event) => e.stopPropagation()}>
          ${row.keeperRuntime
            ? html`<${KeeperActionButtons}
                keeper=${row.keeperRuntime}
                size="sm"
                compact
                stopPropagation
              />`
            : html`<span class="text-2xs text-[var(--color-fg-muted)]">—</span>`}
        </div>
      </div>
    `
  }

  return html`
    <div class="v2-monitoring-surface fl-shell agent-page">
      <header class="fl-top" aria-label="Keeper Fleet summary">
        <div class="fl-brand">
          <span class="ov-eyebrow">Observatory</span>
          <h1 class="fl-title">Keeper Fleet</h1>
        </div>
        <div class="fl-health">
          <span class="fl-hpill ok">런타임 가능 <b>${healthRun}</b></span>
          ${healthTransient > 0 ? html`<span class="fl-hpill busy">전이 <b>${healthTransient}</b></span>` : null}
          <span class="fl-hpill warn">일시정지 <b>${healthPaused}</b></span>
          <span class="fl-hpill">오프라인 <b>${healthOffline}</b></span>
          ${healthAttention > 0 ? html`<span class="fl-hpill bad">주의 <b>${healthAttention}</b></span>` : null}
        </div>
        <span class="fl-spacer"></span>
        <button
          type="button"
          class="fl-create"
          data-testid="keeper-spawn-panel"
          onClick=${() => { showSpawnPanel.value = true }}
        >＋ 새 Keeper</button>
        <div class="fl-meta"><span class="live">● live</span><span>${namespaceName}</span></div>
        <span class="sr-only">실행 rows ${healthRun} · 전이 rows ${healthTransient} · 일시정지 rows ${healthPaused} · 오프라인 rows ${healthOffline}</span>
      </header>

      ${showExecutionFallbackState
        ? html`
            <div class="fl-fallback ${executionError.value ? 'error' : ''}">
              <strong>${fallbackStateTitle}</strong>
              <span>${fallbackStateMessage}</span>
              ${configuredIdleHint ? html`<span class="mono">${configuredIdleHint}</span>` : null}
            </div>
          `
        : null}

      ${inferenceInflight ? html`
        <section class="fl-capacity" aria-label="Runtime inference observation" data-testid="fleet-inference-inflight">
          <div class="fl-capacity-lead">
            <span class="ov-eyebrow">Inference</span>
            <strong>관측값</strong>
          </div>
          <div class="fl-capacity-cell">
            <span>활성 추론</span>
            <strong>${inferenceInflight.active}</strong>
          </div>
          <div class="fl-capacity-cell owner">
            <span>경계 소유자</span>
            <strong>${inferenceInflight.boundary_owner}</strong>
          </div>
        </section>
      ` : null}

      <div class="fl-body">
        <section class="fl-main v2-monitoring-panel" aria-label="Keeper operations list">
          <!--
            keeper-v2 Fleet skin (fleet.css .fl-*): roster header + tone-rail
            rows + attention/steady group dividers. The shell's SurfaceLead
            owns the "Keeper Fleet" title for this surface, so this body
            renders NO top-level page header (avoids the prior duplicate-header
            regression). Live wiring (selection, actions, presence) is
            unchanged — only the markup/class tree is reskinned.

            Column header labels keep 운영판정 / 차단 · 단계 / 액션 so existing
            tests + operators read the same axis names; the cells below fold
            them into the fl-state chip + fl-gloss as the prototype does.
          -->
          <div class="fl-rhead">
            <span>Keeper</span>
            <span>운영판정 · 차단 · 단계</span>
            <span>컨텍스트</span>
            <span>런타임 · 출처</span>
            <span>최근 도구</span>
            <span class="r">액션</span>
          </div>

          <div class="fl-roster">
            ${attentionRows.length > 0 ? html`<div class="fl-group attn">주의 필요 · ${attentionRows.length}</div>` : null}
            ${attentionRows.map(renderFleetRow)}
            ${transientRows.length > 0 ? html`<div class="fl-group">전이 중 · ${transientRows.length}</div>` : null}
            ${transientRows.map(renderFleetRow)}
            ${steadyRows.length > 0 ? html`<div class="fl-group">정상 · ${steadyRows.length}</div>` : null}
            ${steadyRows.map(renderFleetRow)}

            ${rosterRows.length === 0 ? html`
              <div class="px-6 py-10">
                <${EmptyState}
                  message=${showExecutionFallbackState && expectedScopedCount > 0
                      ? `${fallbackStateTitle}: ${scopeLabel}가 있지만, 현재 조건에 맞는 항목은 아직 없습니다.`
                      : '조건에 맞는 runtime row가 없습니다.'}
                  compact
                />
              </div>
            ` : null}
          </div>
        </section>

        <aside class="fl-aside v2-monitoring-panel" aria-label="Selected keeper detail">
          ${selectedRow ? html`
            <div class="fl-as-head">
              <span class="fl-as-ey">${selectedRow.isKeeper ? 'selected keeper runtime' : 'selected workspace agent'}</span>
              <span class="fl-as-state">
                <span class="inline-block h-1.5 w-1.5 rounded-full" style="background:currentColor" aria-hidden="true"></span>
                ${FL_TONE_LABEL[selectedTone]}
              </span>
            </div>

            <div class="fl-as-id">
              <span class="shrink-0">
                <${AgentAvatar}
                  name=${selectedRow.agent.name}
                  status=${selectedRow.presenceDisplay.status}
                  traits=${selectedRow.agent.traits}
                  size="lg"
                  currentWork=${selectedRow.currentWork}
                  activityAge=${selectedRow.lastActivityAge}
                />
              </span>
              <div class="min-w-0">
                <h3 class="fl-as-name m-0 truncate">${selectedRow.displayName}</h3>
                ${selectedKoreanName || selectedKeeperId ? html`
                  <div class="fl-as-kr">
                    ${selectedKoreanName ?? ''}
                    ${selectedKoreanName && selectedKeeperId ? ' · ' : ''}
                    ${selectedKeeperId ? html`<span class="font-mono">keeper-id · ${selectedKeeperId}</span>` : null}
                  </div>
                ` : null}
                <div class="mt-1.5 flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-secondary)]">
                  <${AgentPresence} status=${selectedRow.presenceDisplay.status} detail=${selectedRow.presenceDisplay.detail} size="sm" />
                  <span class="inline-flex items-center gap-1 text-[var(--color-fg-muted)]">
                    ${selectedRow.lastActivityLabel}
                    <span class="text-[var(--color-fg-primary)]">
                      ${selectedRow.lastActivityAt
                        ? html`<${TimeAgo} timestamp=${selectedRow.lastActivityAt} />`
                        : selectedRow.lastActivityAge != null
                          ? `${formatDuration(selectedRow.lastActivityAge)} 전`
                          : '기록 없음'}
                    </span>
                  </span>
                </div>
              </div>
            </div>

            <div class="fl-as-cta">
              <button
                type="button"
                class="fl-open-chat v2-monitoring-action"
                aria-label=${selectedRow.detailLabel}
                data-detail-kind=${selectedRow.isKeeper ? 'keeper' : 'agent-profile'}
                data-detail-target=${selectedRow.isKeeper
                  ? selectedRow.keeperRuntime?.name ?? selectedRow.displayName
                  : selectedRow.agent.name}
                onClick=${selectedRow.openDetail}
              >
                <span>상세 열기</span><span class="arr">▸</span>
              </button>
            </div>

            <div class="fl-as-sec">
              <div class="fl-as-phase">
                ${selectedRow.isKeeper && selectedRow.fsmPhaseKey
                  ? html`<${KeeperPhaseBadge} phase=${selectedRow.fsmPhaseKey} compact />`
                  : html`<span class="fl-chip" data-tone=${selectedTone}>${selectedRow.band.label}</span>`}
                ${selectedRow.fsmStageKey && selectedRow.fsmStageText ? html`
                  <span class="inline-flex items-center rounded-[var(--r-0)] border px-2 py-0.5 text-2xs font-medium ${stageBadgeClass(selectedRow.fsmStageKey)}" title=${selectedRow.monitoringEvidence?.stage?.description ?? '활동 단계 정보가 없습니다.'}>
                    ${selectedRow.fsmStageText}
                  </span>
                ` : null}
              </div>
              <div class="fl-as-gloss">${selectedRow.summaryText}</div>
            </div>

            ${selectedRow.stateNote ? html`
              <div class="fl-as-sec">
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
              </div>
            ` : null}

            ${selectedRow.attentionItems.length > 0 ? html`
              <div class="fl-as-sec">
                <h4>주의 · ${selectedRow.attentionItems.length}</h4>
                <div class="fl-attn-list">
                  ${selectedRow.attentionItems.map(item => html`
                    <div class="fl-attn-item" data-sev=${item.sev}><span class="fl-attn-dot"></span>${item.text}</div>
                  `)}
                </div>
              </div>
            ` : null}

            ${selectedCtxPct != null ? html`
              <div class="fl-as-sec">
                <h4>컨텍스트 압박</h4>
                <div class="fl-ctxbig">
                  <div class="fl-ctxbig-top">
                    <span class="v ${selectedCtxHot ? 'hot' : ''}">${selectedCtxPct}%</span>
                    <span class="l">${selectedCtxHot ? 'compact 임계 근접' : 'window 사용량'}</span>
                  </div>
                  <div class="bar"><span class=${selectedCtxHot ? 'hot' : ''} style="width:${selectedCtxPct}%"></span></div>
                  ${selectedRow.contextMeta?.detail ? html`<div class="mt-1.5 font-mono text-2xs text-[var(--color-fg-muted)]">${selectedRow.contextMeta.detail}</div>` : null}
                </div>
              </div>
            ` : null}

            ${selectedVitals.length > 0 ? html`
              <div class="fl-as-sec">
                <h4>런타임</h4>
                <div class="fl-vitals">
                  ${selectedVitals.map(vital => html`
                    <div class="fl-vital"><div class="k">${vital.k}</div><div class="v">${vital.v}</div></div>
                  `)}
                </div>
              </div>
            ` : null}

            ${(selectedRow.recentTools.length > 0 || selectedRow.toolCallCount != null || selectedRow.toolAuditAt) ? html`
              <div class="fl-as-sec">
                <h4>최근 도구</h4>
                <div class="flex flex-wrap items-center gap-1.5 text-2xs text-[var(--color-fg-muted)]">
                  <${AgentCapability} tools=${selectedRow.recentTools} maxVisible=${5} />
                  ${selectedRow.toolCallCount != null && selectedRow.toolCallCount > 0 ? html`
                    <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs">${selectedRow.toolCallCount}회 관찰됨</span>
                  ` : null}
                  ${selectedRow.toolAuditAt ? html`
                    <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs">감사 <${TimeAgo} timestamp=${selectedRow.toolAuditAt} /></span>
                  ` : null}
                </div>
              </div>
            ` : null}

            ${selectedRow.keeperRuntime ? html`
              <div class="fl-as-sec">
                <h4>상세 렌즈</h4>
                <div class="flex flex-wrap gap-2">
                  <${RouteLink}
                    tab="monitoring"
                    params=${{ section: 'cognition', view: 'keeper', keeper: selectedRow.keeperRuntime.name, focus: 'tool-access' }}
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
          ` : html`
            <div class="fl-as-sec">
              <${EmptyState} message="선택할 keeper 또는 agent가 없습니다." compact />
            </div>
          `}
        </aside>
      </div>

      <div class="fl-foot">
        <span class="fl-tick"><span class="k">runtime rows</span><span class="v">active ${healthRun}/${rosterRows.length}</span></span>
        <span class="fl-tick"><span class="k">transient rows</span><span class="v">${healthTransient}</span></span>
        <span class="fl-tick"><span class="k">paused rows</span><span class="v">${healthPaused}</span></span>
        <span class="fl-tick"><span class="k">offline rows</span><span class="v">${healthOffline}</span></span>
        <span class="fl-tick"><span class="k">attention</span><span class="v ${healthAttention ? 'warn' : 'ok'}">${healthAttention}</span></span>
      </div>
    </div>
  `
}
