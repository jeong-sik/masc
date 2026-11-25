/**
 * Keepers Workspace — Epoch-fenced, mode-aware API & AG-UI SSE transport layer.
 *
 * Uses ONLY Layer 3 `src/core/*` primitives (`apiGet`, `apiGetV2`, `apiMutate`,
 * `apiMutateV2`, `resourceCache`, `authSession`, `sessionEpoch`, `currentSessionEpoch`,
 * `isEpochCurrent`, `getSingleUserToken`, `getActiveCsrfToken`).
 *
 * Wire Envelopes strictly matched to #36:
 * - V2Envelope (`apiGetV2` / `apiMutateV2`): `/candle/ledger`, `/config/schema`, `/config/patch`, `/infra/sandboxes/:k`
 * - Flat JSON (`apiGet` / `apiMutate`): all `/keepers/*`, `/gate/keepers`, `/dashboard/agents/purge`, `/voice/transcribe`
 */

import { err, ok, type Result } from '../../lib/result'
import {
  authSession,
  currentSessionEpoch,
  getActiveCsrfToken,
  getSingleUserToken,
  isEpochCurrent,
  resolveWorkspaceUrl,
  sessionEpoch,
} from '../../core/auth'
import {
  apiGet,
  apiGetV2,
  apiMutate,
  type ApiError,
} from '../../core/transport'
import { acquireViewStream } from '../../core/view-stream-slot'
import {
  observedAbsent,
  observedValue,
  resourceCache,
  type FetchReason,
  type Observed,
} from '../../core/resource-cache'
import { isKeeperEquipment, type KeeperEquipment } from '../../lib/keeper-portrait'
import {
  decodeQueuedChatOperationPage,
  queuedChatOperationsPath,
  readQueuedChatOperations,
} from '../../lib/keeper-chat-queue'
import { randomUuid } from '../../lib/uuid'
import { decodeKeeperChatDeliveryProvenance } from '../../keeper-delivery-provenance'
import {
  dedupeHistoryToolRows,
  formatNativeCompletionSummary,
  formatNativeProgressLabel,
} from './chat-blocks'
import type {
  CandleBalanceRow,
  CandleLedgerEventRow,
  ChatAttachmentDraft,
  ChatEntryKind,
  ChatHistoryPage,
  ChatJournalCursor,
  ChatJournalEvent,
  ChatJournalPage,
  ChatJournalTextOwner,
  ChatToolBlock,
  ChatTranscriptEntry,
  CheckpointInventoryData,
  KeeperAttachedProvider,
  KeeperActiveTurn,
  KeeperActiveTurnPreview,
  KeeperCandleLedgerData,
  KeeperCatalogItem,
  KeeperItemsData,
  KeeperToolResultResponse,
  KeeperWaitingInventoryData,
  KeeperWaitingRow,
  KeeperLastPromptData,
  KeeperLaneFailure,
  KeeperLinkedTask,
  KeeperMemoryFactsData,
  KeeperMemoryJournalData,
  KeeperMemoryJournalEntry,
  KeeperMemoryOsInternalsData,
  KeeperOperatorNoteData,
  KeeperPathRest,
  KeeperRosterItem,
  KeeperSandboxData,
  KeeperToolCallEntry,
  KeeperToolCallsData,
  KeeperToolStatsData,
  KeeperTurnBreakdown,
  KeeperTurnRecordsData,
  KeeperWaitingSummary,
  MemoryActPayload,
  OrdinaryMemoryBranch,
  PortraitSlot,
  ProviderInputData,
  ProviderInputPartSummary,
  QueuedChatOperation,
  RawTraceTurnItem,
  RosterMode,
  SourceBoundMemoryBranch,
  TurnRecordItem,
  TurnRecordPromptBlock,
} from './types'

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asStr(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

function asNum(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function wrap<T>(p: Promise<Result<T, ApiError>>): Promise<Result<T | null, ApiError>> {
  return p.then((r) => (r.ok ? ok<T | null>(r.value) : r))
}

// ── Shared Formatters ────────────────────────────────────────────────────

export function formatCandleMilli(raw: string | number | null | undefined): Observed<string> {
  if (raw === null || raw === undefined) return observedAbsent()
  const text = typeof raw === 'number'
    ? (Number.isFinite(raw) ? String(Math.trunc(raw)) : '')
    : raw.trim()
  if (!/^-?\d+$/.test(text)) return observedAbsent('invalid_milli')
  const neg = text.startsWith('-')
  const digits = neg ? text.slice(1) : text
  const padded = digits.padStart(4, '0')
  const whole = padded.slice(0, padded.length - 3).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  const frac = padded.slice(padded.length - 3)
  return observedValue(`${neg ? '-' : ''}${whole}.${frac}`)
}

export function observeRosterContextPct(item: KeeperRosterItem): Observed<number> {
  if (typeof item.context_ratio === 'number' && Number.isFinite(item.context_ratio)) {
    return observedValue(Math.max(0, Math.min(100, Math.round(item.context_ratio * 100))))
  }
  if (
    item.context_provenance === 'estimated'
    && typeof item.estimated_context_ratio === 'number'
    && Number.isFinite(item.estimated_context_ratio)
  ) {
    return observedValue(Math.max(0, Math.min(100, Math.round(item.estimated_context_ratio * 100))))
  }
  if (item.context_unavailable_reason) {
    return observedAbsent(item.context_unavailable_reason)
  }
  return observedAbsent()
}

export function formatContextDetail(item: Pick<
  KeeperRosterItem,
  'context_ratio' | 'context_tokens' | 'context_max' | 'context_provenance' | 'estimated_context_ratio' | 'context_unavailable_reason'
>): { readonly label: string; readonly tooltip: string; readonly estimated: boolean } {
  if (typeof item.context_ratio === 'number' && Number.isFinite(item.context_ratio)) {
    const pct = Math.max(0, Math.min(100, Math.round(item.context_ratio * 100)))
    const tok = item.context_tokens != null && item.context_max != null
      ? `${item.context_tokens.toLocaleString('en-US')} / ${item.context_max.toLocaleString('en-US')} tok`
      : `측정됨 (${pct}%)`
    return { label: `${pct}%`, tooltip: tok, estimated: false }
  }
  if (
    item.context_provenance === 'estimated'
    && typeof item.estimated_context_ratio === 'number'
    && Number.isFinite(item.estimated_context_ratio)
  ) {
    const pct = Math.max(0, Math.min(100, Math.round(item.estimated_context_ratio * 100)))
    return {
      label: `~${pct}%`,
      tooltip: `추정 컨텍스트 비율 (~${pct}%)${item.context_unavailable_reason ? ` · ${item.context_unavailable_reason}` : ''}`,
      estimated: true,
    }
  }
  const reason = item.context_unavailable_reason
  return {
    label: '없음',
    tooltip: reason ? `컨텍스트 미측정 (${reason})` : '컨텍스트 미측정',
    estimated: false,
  }
}

export function isKeeperPathResting(
  k: Pick<KeeperRosterItem, 'runtime_path_rest' | 'paused' | 'keepalive_running' | 'health' | 'phase'>,
): boolean {
  if (k.runtime_path_rest?.status !== 'resting') return false
  if (k.paused || !k.keepalive_running) return false
  const h = k.health.toLowerCase()
  const p = k.phase.toLowerCase()
  return h !== 'offline' && p !== 'offline' && p !== 'stopped' && p !== 'paused'
}

/**
 * Builds the portrait preview URL matching live OCaml server contract:
 * - `preview`: single bare portrait item ID (`Keeper_portrait_item.of_id`, e.g. `?size=256&preview=crown`)
 * - `expected_equipment`: 5-key JSON object (`Keeper_portrait_equipment.of_json`)
 */
export function buildPortraitPreviewUrl(
  keeper: string,
  size = 256,
  previewItemId?: string | null,
  expectedEquipment?: KeeperEquipment | null,
): string {
  const params = new URLSearchParams({ size: String(size) })
  const trimmedPreview = typeof previewItemId === 'string' ? previewItemId.trim() : ''
  if (trimmedPreview.length > 0) {
    params.set('preview', trimmedPreview)
  }
  if (expectedEquipment) {
    params.set(
      'expected_equipment',
      JSON.stringify({
        face: expectedEquipment.face,
        neck: expectedEquipment.neck,
        head: expectedEquipment.head,
        hand: expectedEquipment.hand,
        base: expectedEquipment.base,
      }),
    )
  }
  return `/api/v1/keepers/${encodeURIComponent(keeper)}/portrait.png?${params.toString()}`
}

// ── Roster Loader & Pure Sorter ──────────────────────────────────────────

interface TurnListItem {
  readonly keeper_name: string
  readonly chat_control_token: string | null
  readonly active: KeeperRosterItem['active_turn']
  readonly waiting: KeeperWaitingSummary | null
}

function formatUnixOrIso(v: unknown): string | null {
  const s = asStr(v)
  if (s) return s
  const n = asNum(v)
  if (n === null) return null
  const ms = n < 1_000_000_000_000 ? n * 1000 : n
  const d = new Date(ms)
  return Number.isNaN(d.getTime()) ? null : d.toISOString()
}

function decodeWaitingSummary(raw: unknown): KeeperWaitingSummary | null {
  const rows = Array.isArray(raw)
    ? raw
    : isRecord(raw) && Array.isArray(raw.waiting_heads)
      ? raw.waiting_heads
      : isRecord(raw) && Array.isArray(raw.items)
        ? raw.items
        : isRecord(raw) && Array.isArray(raw.entries)
          ? raw.entries
          : null
  const topCount = isRecord(raw) ? (asNum(raw.waiting_count) ?? asNum(raw.count) ?? asNum(raw.total)) : null
  const topDueAt = isRecord(raw) ? formatUnixOrIso(raw.due_at) : null
  if (rows && rows.length > 0) {
    const first = isRecord(rows[0]) ? rows[0] : null
    const primaryReason = first
      ? (asStr(first.waiting_on) ?? asStr(first.what) ?? asStr(first.source) ?? asStr(first.reason))
      : null
    const dueAt = (first ? (formatUnixOrIso(first.due_at) ?? asStr(first.next_action)) : null) ?? topDueAt
    return { count: topCount !== null && topCount > 0 ? topCount : rows.length, primary_reason: primaryReason, due_at: dueAt }
  }
  if (isRecord(raw) && topCount !== null && topCount > 0) {
    return {
      count: topCount,
      primary_reason: asStr(raw.waiting_on) ?? asStr(raw.what) ?? asStr(raw.reason),
      due_at: topDueAt,
    }
  }
  return null
}

function decodePathRest(raw: unknown): KeeperPathRest | null {
  if (!isRecord(raw)) return null
  const st = asStr(raw.status)?.toLowerCase()
  if (st !== 'serving' && st !== 'resting') return null
  return {
    status: st,
    runtime_id: asStr(raw.runtime_id),
    release_at: formatUnixOrIso(raw.release_at) ?? formatUnixOrIso(raw.release_at_unix),
    release_basis: asStr(raw.release_basis),
  }
}

function decodeSingleLaneFailure(row: unknown): KeeperLaneFailure | null {
  if (!isRecord(row)) return null
  const summary = asStr(row.summary)
    ?? (isRecord(row.failure) && isRecord(row.failure.cause) ? asStr(row.failure.cause.detail) : null)
    ?? asStr(row.detail)
  if (!summary) return null
  const faultKind = isRecord(row.api_candidate_fault)
    ? asStr(row.api_candidate_fault.fact) ?? asStr(row.api_candidate_fault.kind)
    : isRecord(row.failure) && isRecord(row.failure.cause)
      ? asStr(row.failure.cause.kind)
      : null
  return {
    runtime_id: asStr(row.runtime_id),
    summary,
    fault_kind: faultKind,
  }
}

function decodeLaneFailures(raw: unknown): readonly KeeperLaneFailure[] {
  if (!isRecord(raw)) return []
  const evidence = isRecord(raw.evidence) ? raw.evidence : raw
  const failuresRaw = Array.isArray(evidence.failures) ? evidence.failures : []
  const out: KeeperLaneFailure[] = []
  for (const row of failuresRaw) {
    const parsed = decodeSingleLaneFailure(row)
    if (parsed) out.push(parsed)
  }
  if (isRecord(evidence.terminal) && asStr(evidence.terminal.kind) === 'candidate') {
    const term = decodeSingleLaneFailure(evidence.terminal)
    if (term && !out.some((f) => f.runtime_id === term.runtime_id && f.summary === term.summary)) {
      out.push(term)
    }
  }
  return out
}

function decodeTurnPreview(raw: unknown): KeeperActiveTurnPreview | null {
  if (!isRecord(raw)) return null
  if (typeof raw.status_text !== 'string') return null
  const activity = asStr(raw.activity)
  const updatedAt = asNum(raw.updated_at_unix)
  if (!activity || updatedAt === null) return null
  const statusText = raw.status_text
  const textTail = typeof raw.text_tail === 'string' ? raw.text_tail : ''
  const lastTool = asStr(raw.last_tool)
  const revision = asNum(raw.revision)
  return {
    status_text: statusText,
    activity,
    text_tail: textTail,
    last_tool: lastTool,
    updated_at_unix: updatedAt,
    revision: revision !== null && Number.isInteger(revision) && revision >= 1 ? revision : null,
  }
}

function decodeTurnsList(raw: unknown): Map<string, TurnListItem> {
  const map = new Map<string, TurnListItem>()
  const list = isRecord(raw) && Array.isArray(raw.keepers)
    ? raw.keepers
    : Array.isArray(raw)
      ? raw
      : []
  for (const row of list) {
    if (!isRecord(row)) continue
    const name = asStr(row.keeper_name) ?? asStr(row.name)
    if (!name) continue
    const activeRaw = isRecord(row.active_turn)
      ? row.active_turn
      : isRecord(row.turn)
        ? row.turn
        : null
    const decodedPreview = activeRaw ? decodeTurnPreview(activeRaw.preview) : null
    const active: KeeperActiveTurn | null = activeRaw
      ? {
          lane: asStr(activeRaw.lane) ?? 'chat',
          turn_ref: asStr(activeRaw.turn_ref),
          started_at_unix: asNum(activeRaw.started_at_unix) ?? asNum(activeRaw.started_at) ?? 0,
          phase: asStr(activeRaw.phase),
          tool_in_flight: asStr(activeRaw.tool_in_flight) ?? asStr(activeRaw.tool) ?? decodedPreview?.last_tool ?? null,
          elapsed_ms: asNum(activeRaw.elapsed_ms),
          preview: decodedPreview,
        }
      : null
    const waiting = decodeWaitingSummary(row.waiting ?? row.waiting_inventory)
    map.set(name, {
      keeper_name: name,
      chat_control_token: asStr(row.chat_control_token),
      active,
      waiting,
    })
  }
  return map
}

function deriveCompany(name: string): string {
  const dash = name.indexOf('-')
  return dash > 0 ? name.slice(0, dash) : 'General'
}

export function decodeKeeperRoster(gateRaw: unknown): KeeperRosterItem[] {
  const list = isRecord(gateRaw) && Array.isArray(gateRaw.keepers) ? gateRaw.keepers : []
  const items: KeeperRosterItem[] = []
  for (const raw of list) {
    if (!isRecord(raw)) continue
    const name = asStr(raw.name)
    if (!name) continue
    const meta = isRecord(raw.meta) ? raw.meta : null
    const issue = isRecord(raw.effective_meta_error) ? asStr(raw.effective_meta_error.message) : null
    const lf = isRecord(raw.last_failure) && asStr(raw.last_failure.cause)
      ? { cause: asStr(raw.last_failure.cause)!, at_unix: asNum(raw.last_failure.at_unix) }
      : null

    let turns24h: number | null = null
    let turnsBreakdown: KeeperTurnBreakdown | null = null
    if (isRecord(raw.recent_turns) && Array.isArray(raw.recent_turns.slots)) {
      let okCount = 0
      let restedCount = 0
      let failedCount = 0
      for (const s of raw.recent_turns.slots) {
        if (!isRecord(s)) continue
        okCount += asNum(s.ok) ?? 0
        restedCount += asNum(s.rested) ?? 0
        failedCount += asNum(s.failed) ?? 0
      }
      turns24h = okCount + restedCount + failedCount
      turnsBreakdown = { ok: okCount, rested: restedCount, failed: failedCount }
    }

    let portraitEquipment: KeeperEquipment | null = null
    if (isRecord(raw.portrait) && raw.portrait.state === 'ready' && isKeeperEquipment(raw.portrait.equipment)) {
      portraitEquipment = raw.portrait.equipment
    }

    const candleVal = typeof raw.candle_balance_milli === 'string' || typeof raw.candle_balance_milli === 'number'
      ? raw.candle_balance_milli
      : null
    const ctxProvRaw = asStr(raw.context_provenance)
    const contextProvenance = ctxProvRaw === 'measured' || ctxProvRaw === 'estimated' || ctxProvRaw === 'unavailable'
      ? ctxProvRaw
      : null
    const pathRest = decodePathRest(raw.runtime_path_rest)
    const laneFailures = decodeLaneFailures(raw.runtime_lane_observation)

    items.push({
      name,
      status: asStr(raw.status) ?? 'unknown',
      phase: asStr(raw.phase) ?? (issue ? 'error' : 'idle'),
      health: asStr(raw.health) ?? (issue ? 'failing' : 'unknown'),
      paused: raw.paused === true,
      keepalive_running: raw.keepalive_running === true,
      activation_mode: asStr(raw.activation_mode) ?? 'manual',
      runtime_id: asStr(raw.runtime_id) ?? 'unassigned',
      sandbox_profile: meta ? asStr(meta.sandbox_profile) : null,
      company: asStr(raw.group) ?? deriveCompany(name),
      context_ratio: asNum(raw.context_ratio),
      context_tokens: asNum(raw.context_tokens),
      context_max: asNum(raw.context_max),
      context_provenance: contextProvenance,
      estimated_context_ratio: asNum(raw.estimated_context_ratio),
      context_unavailable_reason: asStr(raw.context_metrics_unavailable_reason),
      runtime_blocker_summary: asStr(raw.runtime_blocker_summary),
      runtime_blocker_signature: asStr(raw.runtime_blocker_signature),
      runtime_path_rest: pathRest,
      operator_disposition: asStr(raw.operator_disposition),
      operator_disposition_reason: asStr(raw.operator_disposition_reason),
      failing_since: asNum(raw.failing_since),
      next_action: asStr(raw.next_action),
      runtime_lane_failures: laneFailures,
      last_failure: lf,
      directory_issue: issue,
      turns_24h: turns24h,
      turns_24h_breakdown: turnsBreakdown,
      candle_balance_milli: candleVal,
      portrait_equipment: portraitEquipment,
      chat_control_token: null,
      waiting_summary: null,
      active_turn: null,
    })
  }
  return items
}

export function needsRosterAttention(k: KeeperRosterItem): boolean {
  if (k.directory_issue || k.runtime_blocker_summary) return true
  const h = k.health.toLowerCase()
  return h === 'failing' || h === 'failed' || h === 'degraded' || h === 'error' || h === 'crashed'
}

export function filterAndSortRoster(
  items: readonly KeeperRosterItem[],
  mode: RosterMode,
  query: string,
): readonly KeeperRosterItem[] {
  const q = query.trim().toLowerCase()
  const filtered = q.length === 0
    ? [...items]
    : items.filter((k) =>
        k.name.toLowerCase().includes(q)
        || k.company.toLowerCase().includes(q)
        || k.runtime_id.toLowerCase().includes(q)
        || k.health.toLowerCase().includes(q)
        || (k.runtime_blocker_summary?.toLowerCase().includes(q) ?? false),
      )

  if (mode === 'attention') {
    return filtered.sort((a, b) => {
      const score = (k: KeeperRosterItem) =>
        needsRosterAttention(k) ? 0 : isKeeperPathResting(k) ? 1 : k.paused ? 2 : 3
      const aScore = score(a)
      const bScore = score(b)
      if (aScore !== bScore) return aScore - bScore
      const ctxVal = (k: KeeperRosterItem): number => {
        if (k.context_ratio !== null) return k.context_ratio
        if (k.context_provenance === 'estimated' && k.estimated_context_ratio != null) {
          return k.estimated_context_ratio
        }
        return -1
      }
      return ctxVal(b) - ctxVal(a) || a.name.localeCompare(b.name)
    })
  }
  if (mode === 'wall24h') {
    return filtered.sort((a, b) => {
      const diff = (b.turns_24h ?? -1) - (a.turns_24h ?? -1)
      return diff !== 0 ? diff : a.name.localeCompare(b.name)
    })
  }
  return filtered.sort((a, b) => {
    const c = a.company.localeCompare(b.company)
    return c !== 0 ? c : a.name.localeCompare(b.name)
  })
}

export const KEEPER_ROSTER_OBSERVER_TOPICS: readonly string[] = [
  'keeper',
  'keeper_roster_changed',
  'keeper_row_changed',
  'keeper_turn_changed',
  'keeper_turn_complete',
  'keeper_waiting_inventory_changed',
  'provider_standing',
  'keeper_turn',
  'keeper_lifecycle',
]

const KEEPER_ROSTER_KEY = 'keepers:roster'
const KEEPER_TURNS_KEY = 'keepers:turns'

function loadKeeperTurns(reason: FetchReason) {
  return resourceCache.fetch<ReadonlyMap<string, TurnListItem>>(
    KEEPER_TURNS_KEY,
    (signal) => apiGet('/api/v1/keepers/turns', { signal, decode: decodeTurnsList }),
    { ttlMs: 10_000, topics: ['keeper', 'keeper_turn', 'keeper_lifecycle', 'keeper_turn_changed'], reason },
  )
}

export function readKeeperRosterSources() {
  return {
    roster: resourceCache.observe<readonly KeeperRosterItem[]>(KEEPER_ROSTER_KEY).value,
    turns: resourceCache.observe<ReadonlyMap<string, TurnListItem>>(KEEPER_TURNS_KEY).value,
  }
}

export async function loadKeeperRoster(reason: FetchReason = 'mount'): Promise<void> {
  if (reason === 'sse') {
    resourceCache.invalidateKey(KEEPER_ROSTER_KEY)
    resourceCache.invalidateKey(KEEPER_TURNS_KEY)
  }
  await Promise.all([
    resourceCache.fetch<readonly KeeperRosterItem[]>(
      KEEPER_ROSTER_KEY,
      (signal) => apiGet('/api/v1/gate/keepers?detailed=true', { signal, decode: decodeKeeperRoster }),
      { ttlMs: 10_000, topics: ['keeper', 'keeper_turn', 'keeper_lifecycle', 'keeper_row_changed', 'keeper_roster_changed'], reason },
    ),
    loadKeeperTurns(reason),
  ])
}

export async function fetchKeeperControlToken(keeperName: string): Promise<string | null> {
  const turns = await loadKeeperTurns('manual')
  return turns.kind === 'value' ? turns.data.get(keeperName)?.chat_control_token ?? null : null
}

// ── Lifecycle Mutations ──────────────────────────────────────────────────

export function bootKeeperAction(name: string) {
  return apiMutate<Record<string, unknown>>('POST', `/api/v1/keepers/${encodeURIComponent(name)}/boot`, {})
}

export function pauseKeeperAction(name: string) {
  return apiMutate<Record<string, unknown>>('POST', `/api/v1/keepers/${encodeURIComponent(name)}/directive`, {
    action: 'pause',
  })
}

export function resumeKeeperAction(name: string) {
  return apiMutate<Record<string, unknown>>('POST', `/api/v1/keepers/${encodeURIComponent(name)}/directive`, {
    action: 'resume',
    operator_operation_id: `dashboard-resume-${randomUuid()}`,
  })
}

export function interruptKeeperTurnAction(name: string, operationId?: string) {
  return apiMutate<Record<string, unknown>>('POST', '/api/v1/keepers/turn/interrupt', {
    name,
    ...(operationId ? { request_id: operationId } : {}),
  })
}

export function deleteKeeperAction(name: string) {
  return apiMutate<Record<string, unknown>>('POST', '/api/v1/dashboard/agents/purge', {
    agent_name: name,
  })
}

export function clearKeeperHistoryAction(name: string, reason: string, preserveSystemPrompt = true) {
  return apiMutate<Record<string, unknown>>('POST', `/api/v1/keepers/${encodeURIComponent(name)}/clear`, {
    reason,
    preserve_system_prompt: preserveSystemPrompt,
  })
}

export function resetKeeperAction(name: string) {
  return apiMutate<Record<string, unknown>>('POST', `/api/v1/keepers/${encodeURIComponent(name)}/reset`, {})
}

// ── Chat History, Queued Ops, Cut-Reply Journal & Origin_bare AG-UI SSE ──

function stringifyPayloadField(val: unknown): string | undefined {
  if (val === undefined || val === null) return undefined
  if (typeof val === 'string') return val
  return JSON.stringify(val, null, 2)
}

function mapTraceToolStatus(raw: string | null): string | undefined {
  if (!raw) return undefined
  if (raw === 'ok') return 'completed'
  if (raw === 'err') return 'error'
  if (raw === 'pending') return 'running'
  return raw
}

function decodeHistoryBlocks(rawBlocks: unknown): {
  readonly thinking: readonly string[]
  readonly redactedThinking: boolean
  readonly toolCalls: readonly ChatToolBlock[]
} {
  if (!Array.isArray(rawBlocks)) {
    return { thinking: [], redactedThinking: false, toolCalls: [] }
  }
  const thinking: string[] = []
  let redactedThinking = false
  const toolCalls: ChatToolBlock[] = []

  for (const block of rawBlocks) {
    if (!isRecord(block)) continue
    const t = asStr(block.t)
    if (t === 'thinking') {
      if (block.redacted === true) {
        redactedThinking = true
      } else if (typeof block.content === 'string' && block.content.trim()) {
        thinking.push(block.content.trim())
      }
    } else if (t === 'trace' && Array.isArray(block.trace)) {
      for (const step of block.trace) {
        if (!isRecord(step)) continue
        const kind = asStr(step.kind)
        if (kind === 'think') {
          if (step.content_withheld === true) {
            redactedThinking = true
          } else if (typeof step.text === 'string' && step.text.trim()) {
            thinking.push(step.text.trim())
          }
        } else if (kind === 'reason') {
          const text = typeof step.text === 'string' ? step.text.trim() : ''
          const detail = typeof step.detail === 'string' ? step.detail.trim() : ''
          const combined = [text, detail].filter(Boolean).join('\n')
          if (combined) thinking.push(combined)
        } else if (kind === 'tool') {
          const name = asStr(step.name) ?? 'tool'
          toolCalls.push({
            id: asStr(step.tool_call_id) ?? undefined,
            executionId: asStr(step.execution_id) ?? undefined,
            name,
            args: stringifyPayloadField(step.args),
            result: stringifyPayloadField(step.result),
            status: mapTraceToolStatus(asStr(step.status)),
            duration: asStr(step.dur) ?? undefined,
          })
        }
      }
    }
  }
  return { thinking, redactedThinking, toolCalls }
}

function decodeToolBlocks(raw: Record<string, unknown>): readonly ChatToolBlock[] | undefined {
  const out: ChatToolBlock[] = []
  if (Array.isArray(raw.tool_calls)) {
    for (const tc of raw.tool_calls) {
      if (!isRecord(tc)) continue
      const name = asStr(tc.name) ?? asStr(tc.tool_name) ?? asStr(tc.tool) ?? 'tool'
      const argsVal = tc.args ?? tc.input ?? tc.arguments
      const resVal = tc.result ?? tc.output
      out.push({
        id: asStr(tc.id) ?? asStr(tc.tool_call_id) ?? undefined,
        executionId: asStr(tc.execution_id) ?? undefined,
        name,
        args: stringifyPayloadField(argsVal),
        result: stringifyPayloadField(resVal),
        status: mapTraceToolStatus(asStr(tc.status) ?? asStr(tc.outcome)),
        duration: asStr(tc.dur) ?? undefined,
      })
    }
  } else {
    const toolName = asStr(raw.tool_call_name) ?? asStr(raw.tool_name)
    if (toolName && (raw.tool_input !== undefined || raw.tool_output !== undefined || raw.tool_result !== undefined)) {
      const argsVal = raw.tool_input ?? raw.args
      const resVal = raw.tool_output ?? raw.tool_result ?? raw.output
      out.push({
        id: asStr(raw.tool_call_id) ?? undefined,
        executionId: asStr(raw.execution_id) ?? undefined,
        name: toolName,
        args: stringifyPayloadField(argsVal),
        result: stringifyPayloadField(resVal),
        status: mapTraceToolStatus(asStr(raw.status)),
      })
    }
  }
  return out.length > 0 ? out : undefined
}

export function decodeHistoryRow(raw: unknown): ChatTranscriptEntry | null {
  if (!isRecord(raw)) return null
  const id = asStr(raw.id)
  if (!id) return null
  const roleRaw = asStr(raw.role)
  const role: ChatTranscriptEntry['role'] =
    roleRaw === 'user' || roleRaw === 'assistant' || roleRaw === 'system' || roleRaw === 'tool' || roleRaw === 'request_failure'
      ? roleRaw
      : 'assistant'
  const speakerLabel = role === 'user'
    ? asStr(raw.speaker_name) ?? asStr(raw.speaker_id) ?? (raw.speaker_authority === 'owner' ? 'Operator' : undefined)
    : undefined
  const content = typeof raw.content === 'string' ? raw.content : ''
  const ts = asNum(raw.ts) ?? Date.now() / 1000
  const decodedBlocks = decodeHistoryBlocks(raw.blocks)
  const rawThinking = asStr(raw.thinking) ?? asStr(raw.reasoning) ?? asStr(raw.reasoning_content) ?? undefined
  const thinkingParts: string[] = []
  if (rawThinking) thinkingParts.push(rawThinking)
  for (const part of decodedBlocks.thinking) {
    if (!thinkingParts.includes(part)) thinkingParts.push(part)
  }
  const thinking = thinkingParts.length > 0
    ? thinkingParts.join('\n\n')
    : decodedBlocks.redactedThinking
      ? '[추론 내용 비공개 (redacted)]'
      : undefined
  const directToolCalls = decodeToolBlocks(raw) ?? []
  const mergedToolCalls: ChatToolBlock[] = [...directToolCalls]
  for (const bt of decodedBlocks.toolCalls) {
    const dup = mergedToolCalls.some(
      (existing) =>
        (bt.executionId && existing.executionId === bt.executionId)
        || (bt.id && existing.id === bt.id && existing.name === bt.name),
    )
    if (!dup) mergedToolCalls.push(bt)
  }
  const toolCalls = mergedToolCalls.length > 0 ? mergedToolCalls : undefined
  const autonomousTurn =
    raw.autonomous === true
    || isRecord(raw.autonomous_turn)
    || asStr(raw.source) === 'autonomous'
    || asStr(raw.turn_kind) === 'autonomous'
    || (isRecord(raw.metadata) && (raw.metadata.autonomous === true || asStr(raw.metadata.turn_kind) === 'autonomous'))
  const rawMemory = Array.isArray(raw.memory_recall)
    ? raw.memory_recall
    : Array.isArray(raw.recalled_facts)
      ? raw.recalled_facts
      : null
  const memoryItems = rawMemory
    ? rawMemory
        .map((item) => {
          if (typeof item === 'string') return item.trim()
          if (isRecord(item) && typeof item.claim === 'string') return item.claim.trim()
          return JSON.stringify(item)
        })
        .filter(Boolean)
    : undefined
  const kindRaw = asStr(raw.kind)
  const kind: ChatEntryKind | undefined =
    kindRaw === 'tool_call' || kindRaw === 'tool_result' || kindRaw === 'memory_recall' || kindRaw === 'autonomous' || kindRaw === 'system_internal' || kindRaw === 'chat'
      ? kindRaw
      : autonomousTurn
        ? 'autonomous'
        : memoryItems && memoryItems.length > 0 && !content.trim()
          ? 'memory_recall'
          : role === 'tool'
            ? 'tool_result'
            : undefined
  return {
    id,
    role,
    speakerLabel,
    content,
    thinking,
    ts,
    deliveryProvenance: decodeKeeperChatDeliveryProvenance(raw.delivery_key, raw.transcript_slot).value ?? undefined,
    turnRef: asStr(raw.turn_ref) ?? undefined,
    executionId: asStr(raw.execution_id) ?? undefined,
    toolName: asStr(raw.tool_call_name) ?? asStr(raw.tool_name) ?? undefined,
    kind,
    toolCalls,
    memoryItems: memoryItems && memoryItems.length > 0 ? memoryItems : undefined,
    autonomousTurn: autonomousTurn || undefined,
    deliveryState: 'Delivered',
  }
}

export function fetchKeeperWaitingInventoryApi(
  keeper: string,
  signal?: AbortSignal,
): Promise<Result<KeeperWaitingInventoryData | null, ApiError>> {
  return apiGet<KeeperWaitingInventoryData | null>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/waiting-inventory`,
    {
      signal,
      decode: (raw) => {
        const body = isRecord(raw) && isRecord(raw.data) ? raw.data : raw
        if (!isRecord(body)) return null
        const rowsRaw = Array.isArray(body.rows) ? body.rows : []
        const rows: KeeperWaitingRow[] = []
        for (const item of rowsRaw) {
          if (!isRecord(item)) continue
          const source = asStr(item.source)
          const waitingOn = asStr(item.waiting_on)
          if (!source || !waitingOn) continue
          rows.push({
            keeper_name: asStr(item.keeper_name),
            source,
            waiting_on: waitingOn,
            what: typeof item.what === 'string' ? item.what : '',
            wake_producer: asStr(item.wake_producer) ?? '',
            since: asNum(item.since),
            due_at: asNum(item.due_at),
            next_action: typeof item.next_action === 'string' ? item.next_action : '',
          })
        }
        return {
          schema: asStr(body.schema) ?? 'masc.keeper_waiting_inventory',
          keeper_count: asNum(body.keeper_count) ?? 0,
          waiting_keeper_count: asNum(body.waiting_keeper_count) ?? 0,
          row_count: asNum(body.row_count) ?? rows.length,
          total_row_count: asNum(body.total_row_count) ?? rows.length,
          oldest_age_seconds: asNum(body.oldest_age_seconds),
          rows,
        }
      },
    },
  )
}

export interface KeeperLiveToolPulse {
  readonly toolName: string
  readonly disposition: string | null
  readonly durationMs: number | null
  readonly executionMode: 'concurrent' | 'serial' | null
  readonly batchSize: number | null
  readonly updatedAt: number
}

export type KeeperObserverChatSignal =
  | {
      readonly kind: 'turn_preview'
      readonly ownerKey: string | null
      readonly preview: KeeperActiveTurnPreview
    }
  | { readonly kind: 'turn_ended' }
  | { readonly kind: 'tool_pulse'; readonly pulse: KeeperLiveToolPulse }
  | { readonly kind: 'chat_appended' }
  | { readonly kind: 'waiting_changed'; readonly queueChanged: boolean }

/**
 * Pure extractor for shared Observer SSE frames scoped to a single Keeper's
 * Chat view. Handles both flat event records and JSON-RPC `params` envelopes,
 * matching the live OCaml broadcast shapes (`server_turn_preview_broadcast.ml`).
 */
export function parseKeeperLiveObserverEvent(
  eventName: string,
  data: unknown,
  keeperName: string,
): KeeperObserverChatSignal | null {
  const payload = isRecord(data)
    ? (isRecord(data.params) ? data.params : data)
    : null
  const eventType =
    (payload ? (asStr(payload.type) ?? asStr(payload.event_type) ?? asStr(payload.event)) : null)
    ?? (eventName !== 'message' ? eventName : null)
  if (!eventType) return null

  const rowKeeper = payload
    ? (asStr(payload.keeper_name) ?? asStr(payload.keeper) ?? asStr(payload.name) ?? asStr(payload.agent_name))
    : null

  // A refresh can only be caused by an event addressed to this Keeper.
  if (rowKeeper !== keeperName) return null

  if (eventType === 'keeper_waiting_inventory_changed') {
    return { kind: 'waiting_changed', queueChanged: payload?.queue_kind === 'chat_operation' }
  }
  if (eventType === 'keeper_chat_appended') {
    return { kind: 'chat_appended' }
  }
  if (eventType === 'keeper_turn_complete') {
    return { kind: 'turn_ended' }
  }
  if (eventType === 'keeper_turn_changed' && payload) {
    const status = asStr(payload.status) ?? asStr(payload.phase)
    if (
      payload.active_turn === null
      || payload.turn === null
      || status === 'idle'
      || status === 'completed'
    ) {
      return { kind: 'turn_ended' }
    }
    // Start/in-progress previews arrive via `keeper_turn_preview_changed` and roster `active_turn`.
    return null
  }
  if (eventType === 'keeper_turn_preview_changed' && payload) {
    const obs = isRecord(payload.observation) ? payload.observation : null
    const previewRaw =
      (obs && isRecord(obs.preview) ? obs.preview : null)
      ?? (isRecord(payload.preview) ? payload.preview : null)
    const preview = decodeTurnPreview(previewRaw)
    if (preview) {
      const ownerKey = (obs ? asStr(obs.owner_key) : null) ?? asStr(payload.owner_key)
      return { kind: 'turn_preview', ownerKey, preview }
    }
    return null
  }
  if ((eventType === 'keeper_tool_call' || eventType === 'masc/keeper_tool_call') && payload) {
    const toolName = asStr(payload.tool_name) ?? asStr(payload.tool)
    if (!toolName) return null
    const execModeRaw = asStr(payload.execution_mode)
    return {
      kind: 'tool_pulse',
      pulse: {
        toolName,
        disposition: asStr(payload.disposition),
        durationMs: asNum(payload.duration_ms),
        executionMode: execModeRaw === 'concurrent' || execModeRaw === 'serial' ? execModeRaw : null,
        batchSize: asNum(payload.batch_size),
        updatedAt: Date.now(),
      },
    }
  }
  return null
}

export function fetchKeeperToolResultApi(
  keeper: string,
  executionId: string,
  maxBytes = 16_384,
  signal?: AbortSignal,
): Promise<Result<KeeperToolResultResponse, ApiError>> {
  const params = new URLSearchParams({
    execution_id: executionId,
    max_bytes: String(maxBytes),
  })
  return apiGet<KeeperToolResultResponse>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/tool-result?${params.toString()}`,
    {
      signal,
      decode: (raw) => {
        const body = isRecord(raw) && isRecord(raw.data) ? raw.data : raw
        if (!isRecord(body)) throw new Error('Invalid tool-result payload')
        const state = asStr(body.state)
        const execId = asStr(body.execution_id) ?? executionId
        if (state === 'pending') {
          return { state: 'pending', executionId: execId }
        }
        if (state === 'unavailable') {
          return {
            state: 'unavailable',
            executionId: execId,
            reason: asStr(body.reason) ?? 'unavailable',
          }
        }
        if (state === 'page' && isRecord(body.page)) {
          if (body.page.ok === false) {
            return {
              state: 'unavailable',
              executionId: execId,
              reason: asStr(body.page.error) ?? 'page_read_failed',
            }
          }
          const rawContent = typeof body.page.content === 'string' ? body.page.content : ''
          const encoding = asStr(body.page.encoding) ?? 'utf-8'
          const recordedBytes = asNum(body.recorded_bytes) ?? rawContent.length
          const content =
            encoding === 'base64'
              ? `[binary/base64 · ${recordedBytes.toLocaleString('en-US')}B]`
              : rawContent
          return {
            state: 'page',
            executionId: execId,
            content,
            isError: body.is_error === true,
            recordedBytes,
            totalBytes: asNum(body.page.total_bytes) ?? rawContent.length,
            eof: body.page.eof !== false,
          }
        }
        throw new Error(`Unknown tool-result state: ${String(state)}`)
      },
    },
  )
}

export function fetchKeeperChatHistoryPageApi(
  keeper: string,
  cursor?: string,
  limit = 40,
  signal?: AbortSignal,
): Promise<Result<ChatHistoryPage, ApiError>> {
  const params = new URLSearchParams({ limit: String(limit) })
  if (cursor) params.set('cursor', cursor)
  return apiGet<ChatHistoryPage>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/chat/history/page?${params.toString()}`,
    {
      signal,
      decode: (raw) => {
        if (!isRecord(raw) || !Array.isArray(raw.messages)) {
          throw new Error('Invalid chat history page')
        }
        const decoded = raw.messages
          .map(decodeHistoryRow)
          .filter((m): m is ChatTranscriptEntry => m !== null)
        const messages = dedupeHistoryToolRows(decoded)
        return {
          messages,
          hasMore: raw.has_more === true,
          nextCursor: typeof raw.next_cursor === 'string' && raw.next_cursor.trim() ? raw.next_cursor : null,
        }
      },
    },
  )
}

function decodeQueuedChatOperation(raw: unknown): QueuedChatOperation {
  if (!isRecord(raw) || raw.schema !== 'masc.keeper_chat_operation.v1' || raw.state !== 'Queued') {
    throw new Error('Expected a queued Keeper chat operation')
  }
  const operationId = asStr(raw.operation_id)
  const sequence = asStr(raw.sequence)
  const createdAt = asNum(raw.created_at)
  const input = raw.input
  if (
    !operationId || sequence === null || !/^\d+$/.test(sequence)
    || createdAt === null || createdAt < 0
    || !isRecord(input) || typeof input.message !== 'string'
  ) {
    throw new Error('Queued Keeper chat operation has an invalid contract')
  }
  return { operationId, sequence, createdAt, message: input.message, state: raw.state }
}

export function fetchQueuedChatOperations(
  keeper: string,
  signal?: AbortSignal,
): Promise<Result<readonly QueuedChatOperation[], ApiError>> {
  const startEpoch = currentSessionEpoch()
  return readQueuedChatOperations<QueuedChatOperation, ApiError>((cursor) => {
    if (!isEpochCurrent(startEpoch)) {
      return Promise.resolve(err({
        kind: 'epoch_stale', status: null, code: 'epoch_stale', message: 'Session epoch changed', retryable: false,
      }))
    }
    return apiGet(queuedChatOperationsPath(keeper, cursor), {
      signal,
      decode: (raw) => decodeQueuedChatOperationPage(raw, cursor, decodeQueuedChatOperation),
    })
  })
}

export function cancelQueuedChatOperation(keeper: string, operationId: string) {
  return apiMutate<unknown>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/chat/operations/${encodeURIComponent(operationId)}/cancel`,
    {},
  )
}

export function moveQueuedChatOperationToEndApi(keeper: string, operationId: string) {
  return apiMutate<unknown>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/chat/operations/${encodeURIComponent(operationId)}/move-to-end`,
    {},
  )
}

function decodeTextOwner(raw: Record<string, unknown>): ChatJournalTextOwner {
  const resp = isRecord(raw.response)
    ? raw.response
    : isRecord(raw.textResponse)
      ? raw.textResponse
      : null
  if (resp) {
    const cg = asNum(resp.content_generation)
    const ss = asNum(resp.stream_scope)
    if (cg !== null && ss !== null) {
      return { kind: 'observed_response', contentGeneration: cg, streamScope: ss }
    }
  }
  const bareScope = asNum(raw.stream_scope) ?? asNum(raw.textStreamScope)
  return { kind: 'unobserved_scope', streamScope: bareScope }
}

export function decodeChatJournalPage(raw: unknown, operationId: string): ChatJournalPage {
  if (!isRecord(raw) || !Array.isArray(raw.events)) {
    throw new Error('Invalid chat journal page')
  }
  const events: ChatJournalEvent[] = []
  for (const item of raw.events) {
    if (!isRecord(item)) continue
    const ev = isRecord(item.event) ? item.event : item
    const type = asStr(ev.type) ?? asStr(item.kind) ?? ''
    if (type === 'RUN_STARTED' || type === 'run_started') {
      events.push({ kind: 'run_started' })
    } else if (type === 'batch_bound') {
      const executionId = asStr(ev.execution_id)
      if (executionId && asStr(ev.operation_id) === operationId) {
        events.push({ kind: 'batch_bound', executionId })
      }
    } else if (
      type === 'agent_core_runtime_attempt_started'
      || (type === 'CUSTOM' && asStr(ev.name) === 'KEEPER_RUNTIME_ATTEMPT_STARTED')
    ) {
      events.push({ kind: 'runtime_attempt_started' })
    } else if (type === 'TEXT_MESSAGE_CONTENT' || type === 'text_delta') {
      const text = typeof ev.delta === 'string' ? ev.delta : typeof ev.text === 'string' ? ev.text : ''
      events.push({ kind: 'text_delta', text, owner: decodeTextOwner(ev) })
    } else if (type === 'RUN_FINISHED' || type === 'run_finished') {
      events.push({ kind: 'run_finished' })
    } else if (type === 'RUN_ERROR' || type === 'error' || type === 'event_error') {
      events.push({ kind: 'error', detail: asStr(ev.message) ?? asStr(ev.detail) ?? 'stream error' })
    } else {
      events.push({ kind: 'other' })
    }
  }
  const hasMore = raw.has_more === true
  const nextSeq = asNum(raw.next_since_seq)
  const nextOffset = asNum(raw.next_since_offset)
  const next: ChatJournalCursor | null =
    hasMore && nextSeq !== null && nextOffset !== null
      ? { lastSeq: nextSeq, nextOffset }
      : null
  return { operationId, events, next }
}

interface ResponseOwner {
  readonly contentGeneration: number
  readonly streamScope: number
}

interface CutReplyOwnership {
  readonly admitted: ResponseOwner | null
  readonly closed: ResponseOwner | null
  readonly unobservedScope: number | null
}

const FRESH_OWNERSHIP: CutReplyOwnership = {
  admitted: null,
  closed: null,
  unobservedScope: null,
}

function ownerOrder(a: ResponseOwner, b: ResponseOwner): number {
  if (a.contentGeneration !== b.contentGeneration) {
    return a.contentGeneration - b.contentGeneration
  }
  return a.streamScope - b.streamScope
}

function admitOwner(
  ownership: CutReplyOwnership,
  owner: ChatJournalTextOwner,
): { readonly accept: true; readonly ownership: CutReplyOwnership } | { readonly accept: false } {
  if (owner.kind === 'unobserved_scope') {
    if (owner.streamScope != null) {
      return { accept: true, ownership: { ...ownership, unobservedScope: owner.streamScope } }
    }
    return { accept: true, ownership }
  }
  const candidate: ResponseOwner = {
    contentGeneration: owner.contentGeneration ?? 0,
    streamScope: owner.streamScope ?? 0,
  }
  const closedOut = ownership.closed !== null && ownerOrder(candidate, ownership.closed) <= 0
  const precedesCurrent = ownership.admitted !== null && (
    ownerOrder(candidate, ownership.admitted) < 0
    || (
      candidate.contentGeneration === ownership.admitted.contentGeneration
      && ownership.unobservedScope !== null
      && candidate.streamScope < ownership.unobservedScope
    )
  )
  if (closedOut || precedesCurrent) {
    return { accept: false }
  }
  return {
    accept: true,
    ownership: { ...ownership, admitted: candidate, unobservedScope: null },
  }
}

function retireAttempt(ownership: CutReplyOwnership): CutReplyOwnership {
  let closed = ownership.closed
  if (ownership.admitted !== null) {
    if (closed === null || ownerOrder(closed, ownership.admitted) < 0) {
      closed = ownership.admitted
    }
  }
  return { admitted: null, closed, unobservedScope: null }
}

/**
 * Reconstructs the winning reply text from `/keepers/:k/chat/events` journal events.
 * Exact port of `lib/masc_tui/store/cut_reply.ml:7-102` monotonic response ownership:
 * - tracks `{ admitted, closed, unobservedScope }`
 * - retires attempts monotonically on `runtime_attempt_started`
 * - drops late/superseded `observed_response` frames without wiping newer text
 * - terminates cleanly on `run_finished` and `event_error`/`RUN_ERROR`.
 */
export function reconstructJournalReply(events: readonly ChatJournalEvent[]): {
  readonly text: string
  readonly finished: boolean
  readonly error: string | null
  readonly executionId: string | null
} {
  let pieces: string[] = []
  let ownership: CutReplyOwnership = FRESH_OWNERSHIP
  let executionId: string | null = null

  for (const ev of events) {
    switch (ev.kind) {
      case 'run_started':
        pieces = []
        ownership = FRESH_OWNERSHIP
        break
      case 'batch_bound':
        executionId = ev.executionId
        break
      case 'runtime_attempt_started':
        pieces = []
        ownership = retireAttempt(ownership)
        break
      case 'text_delta': {
        const res = admitOwner(ownership, ev.owner)
        if (res.accept) {
          pieces.push(ev.text)
          ownership = res.ownership
        }
        break
      }
      case 'run_finished':
        return { text: pieces.join(''), finished: true, error: null, executionId }
      case 'error':
        return { text: pieces.join(''), finished: false, error: ev.detail, executionId }
      case 'other':
        break
    }
  }
  return { text: pieces.join(''), finished: false, error: null, executionId }
}

export async function recoverCutReplyFromJournal(
  keeper: string,
  operationId: string,
): Promise<Result<ReturnType<typeof reconstructJournalReply>, ApiError>> {
  const allEvents: ChatJournalEvent[] = []
  let cursor: ChatJournalCursor | null = null
  let pages = 0

  while (pages < 8) {
    pages += 1
    const params = new URLSearchParams({
      operation_id: operationId,
      limit: '2000',
    })
    if (cursor) {
      params.set('since_seq', String(cursor.lastSeq))
      params.set('since_offset', String(cursor.nextOffset))
    }
    const res = await apiGet<ChatJournalPage>(
      `/api/v1/keepers/${encodeURIComponent(keeper)}/chat/events?${params.toString()}`,
      { decode: (raw) => decodeChatJournalPage(raw, operationId) },
    )
    if (!res.ok) return res
    allEvents.push(...res.value.events)
    if (!res.value.next) break
    cursor = res.value.next
  }

  return ok(reconstructJournalReply(allEvents))
}

export type ChatSubmitMode =
  | { readonly kind: 'queue' }
  | { readonly kind: 'steer'; readonly controlToken: string }
  | { readonly kind: 'btw' }

/**
 * Builds the `Origin_bare` POST payload for `/api/v1/keepers/chat/stream`.
 * Strictly omits `channel` (`Origin_bare`), attaches `admission_intent` for `⌘↵` Steer
 * carrying the caller's own `operationId`, and adds concise `/btw` turn instructions.
 */
export function buildChatStreamRequestBody(params: {
  readonly keeper: string
  readonly message: string
  readonly operationId: string
  readonly mode: ChatSubmitMode
  readonly attachments?: readonly ChatAttachmentDraft[]
}): Record<string, unknown> {
  const body: Record<string, unknown> = {
    request_id: params.operationId,
    name: params.keeper,
    message: params.message,
  }
  if (params.mode.kind === 'steer') {
    body.admission_intent = {
      kind: 'interactive',
      control_token: params.mode.controlToken,
      interrupt_token: null,
      operation_id: params.operationId,
    }
  } else if (params.mode.kind === 'btw') {
    body.turn_instructions = 'Answer concisely as an ephemeral /btw side-query.'
  }
  if (params.attachments && params.attachments.length > 0) {
    body.attachments = params.attachments.map((att) => ({
      id: att.id,
      type: att.type,
      name: att.name,
      size: att.size,
      mime_type: att.mimeType,
      data: att.data,
    }))
  }
  return body
}

export interface StreamKeeperChatCallbacks {
  readonly onBatchBound?: (operationId: string, executionId: string) => void
  readonly onAccepted?: (info: {
    readonly operationId: string
    readonly state: string
    readonly queuedCount: number
    readonly controlToken: string | null
  }) => void
  readonly onRunStarted?: () => void
  readonly onAttemptStarted?: () => void
  readonly onModelActivity?: (channel: 'thinking' | 'text') => void
  readonly onTextDelta?: (delta: string) => void
  readonly onThinkingDelta?: (delta: string, blockKey?: string) => void
  readonly onThinkingSnapshot?: (snapshot: string, blockKey?: string) => void
  readonly onToolStart?: (toolName: string, toolCallId?: string, streamKey?: string) => void
  readonly onToolAdmitted?: (toolName: string, toolCallId?: string, streamKey?: string) => void
  readonly onToolArgsDelta?: (toolCallId: string, delta: string, streamKey?: string) => void
  readonly onToolArgsSnapshot?: (toolCallId: string, snapshot: string, streamKey?: string) => void
  readonly onToolEnd?: (toolCallId?: string, streamKey?: string) => void
  readonly onToolResultReady?: (info: {
    readonly executionId: string
    readonly toolCallId?: string
    readonly streamKey?: string
  }) => void
  readonly onToolResult?: (toolCallId: string, content: string, streamKey?: string) => void
  readonly onNativeToolProgress?: (info: {
    readonly toolName?: string
    readonly toolCallId?: string
    readonly streamKey?: string
    readonly progressLabel: string
  }) => void
  readonly onNativeToolEnd?: (info: {
    readonly toolName?: string
    readonly toolCallId?: string
    readonly streamKey?: string
    readonly status: 'completed' | 'error'
    readonly summary?: string
  }) => void
  readonly onToolApprovalRequested?: (info: {
    readonly toolCallId: string
    readonly toolName: string
    readonly args?: string
    readonly question?: string
    readonly because?: string
  }) => void
  readonly onToolApprovalSettled?: (info: {
    readonly toolCallId: string
    readonly toolName?: string
    readonly outcome: string
  }) => void
  readonly onReplyDetails?: (reply: string, turnRef: string | null) => void
  readonly onFinished?: () => void
  readonly onError?: (message: string) => void
}

function extractToolOccurrenceKey(rec: Record<string, unknown>): string | undefined {
  const scope = asNum(rec.toolStreamScope)
  const blockIndex = asNum(rec.toolCallBlockIndex)
  if (scope !== null && blockIndex !== null && Number.isInteger(scope) && Number.isInteger(blockIndex)) {
    return `occ:${scope}:${blockIndex}`
  }
  return undefined
}

function extractThinkingBlockKey(val: Record<string, unknown>): string {
  const idx = asNum(val.index) ?? 0
  const resp = isRecord(val.response) ? val.response : null
  const cg = resp ? (asNum(resp.content_generation) ?? 0) : 0
  const ss = resp ? (asNum(resp.stream_scope) ?? 0) : 0
  return `${cg}:${ss}:${idx}`
}

/**
 * Mode-aware, epoch-fenced, 2+1 SSE slot-managed AG-UI chat client
 * (`POST /api/v1/keepers/chat/stream`). Acquires Layer 3 `acquireViewStream`
 * so at most one view/chat SSE stream is live at any time.
 */
export async function streamKeeperChat(params: {
  readonly keeper: string
  readonly message: string
  readonly operationId: string
  readonly mode: ChatSubmitMode
  readonly attachments?: readonly ChatAttachmentDraft[]
  readonly signal?: AbortSignal
  readonly fetchImpl?: typeof fetch
  readonly callbacks: StreamKeeperChatCallbacks
}): Promise<{ readonly terminal: boolean; readonly error: string | null }> {
  const fetchImpl = params.fetchImpl ?? globalThis.fetch
  const startEpoch = currentSessionEpoch()
  if (params.signal?.aborted) {
    return { terminal: false, error: 'aborted' }
  }

  const streamKey = `keeper-chat:${params.keeper}:${params.mode.kind}:${params.operationId}`

  const headers: Record<string, string> = {
    Accept: 'text/event-stream',
    'Content-Type': 'application/json',
  }
  const session = authSession.peek()
  if (session.kind === 'multi_account_signed_in') {
    const csrf = getActiveCsrfToken()
    if (csrf) headers['x-masc-csrf-token'] = csrf
  } else {
    const token = getSingleUserToken()
    if (token) headers.Authorization = `Bearer ${token}`
  }

  let runPromise: Promise<{ readonly terminal: boolean; readonly error: string | null }> | null = null

  const handle = acquireViewStream(streamKey, (slotSignal) => {
    // Guard against visibilitychange re-POSTing a mutation; if hidden aborted
    // the stream, caller recovers from /chat/events journal instead.
    if (runPromise !== null) return
    const controller = new AbortController()
    const abortMerged = () => controller.abort(slotSignal.aborted ? slotSignal.reason : params.signal?.reason)
    slotSignal.addEventListener('abort', abortMerged, { once: true })
    params.signal?.addEventListener('abort', abortMerged, { once: true })
    const unsubEpoch = sessionEpoch.subscribe((ep) => {
      if (ep !== startEpoch && !controller.signal.aborted) {
        controller.abort('session_epoch_changed')
      }
    })

    runPromise = (async () => {
      try {
        const res = await fetchImpl(resolveWorkspaceUrl('/api/v1/keepers/chat/stream'), {
          method: 'POST',
          credentials: 'same-origin',
          headers,
          body: JSON.stringify(buildChatStreamRequestBody(params)),
          signal: controller.signal,
        })

        if (!isEpochCurrent(startEpoch)) {
          return { terminal: false, error: 'session_epoch_changed' }
        }
        if (!res.ok) {
          const txt = await res.text().catch(() => `HTTP ${res.status}`)
          const msg = txt.trim() || `HTTP ${res.status}`
          params.callbacks.onError?.(msg)
          return { terminal: true, error: msg }
        }
        if (!res.body) {
          return { terminal: false, error: '스트림 본문 없음' }
        }

        const reader = res.body.getReader()
        const decoder = new TextDecoder()
        let buf = ''
        let terminal = false

        const handleFrame = (rawFrame: string) => {
          if (!isEpochCurrent(startEpoch) || controller.signal.aborted) return
          const dataLines = rawFrame
            .split(/\r?\n/)
            .filter((l) => l.startsWith('data:'))
            .map((l) => l.slice(5).trimStart())
          if (dataLines.length === 0) return
          let parsed: unknown
          try {
            parsed = JSON.parse(dataLines.join('\n'))
          } catch {
            return
          }
          if (!isRecord(parsed)) return
          const type = asStr(parsed.type)
          if (type === 'RUN_STARTED') {
            params.callbacks.onRunStarted?.()
          } else if (type === 'TEXT_MESSAGE_CONTENT' && typeof parsed.delta === 'string') {
            params.callbacks.onTextDelta?.(parsed.delta)
          } else if (type === 'TOOL_CALL_START') {
            params.callbacks.onToolStart?.(
              asStr(parsed.toolCallName) ?? 'tool',
              asStr(parsed.toolCallId) ?? undefined,
              extractToolOccurrenceKey(parsed),
            )
          } else if (type === 'TOOL_CALL_ARGS') {
            const tcId = asStr(parsed.toolCallId) ?? ''
            const occKey = extractToolOccurrenceKey(parsed)
            if (typeof parsed.snapshot === 'string') {
              params.callbacks.onToolArgsSnapshot?.(tcId, parsed.snapshot, occKey)
            } else if (typeof parsed.delta === 'string') {
              params.callbacks.onToolArgsDelta?.(tcId, parsed.delta, occKey)
            }
          } else if (type === 'TOOL_CALL_END') {
            params.callbacks.onToolEnd?.(
              asStr(parsed.toolCallId) ?? undefined,
              extractToolOccurrenceKey(parsed),
            )
          } else if (type === 'TOOL_CALL_RESULT') {
            const rawContent = typeof parsed.content === 'string'
              ? parsed.content
              : parsed.result !== undefined
                ? JSON.stringify(parsed.result, null, 2)
                : ''
            params.callbacks.onToolResult?.(
              asStr(parsed.toolCallId) ?? '',
              rawContent,
              extractToolOccurrenceKey(parsed),
            )
          } else if (type === 'RUN_FINISHED') {
            terminal = true
            params.callbacks.onFinished?.()
          } else if (type === 'RUN_ERROR') {
            terminal = true
            params.callbacks.onError?.(asStr(parsed.message) ?? 'Turn error')
          } else if (type === 'CUSTOM') {
            const name = asStr(parsed.name)
            const val = isRecord(parsed.value) ? parsed.value : null
            if (name === 'KEEPER_RUNTIME_ATTEMPT_STARTED') {
              params.callbacks.onAttemptStarted?.()
            } else if (name === 'KEEPER_MODEL_CONTENT_ACTIVITY' && val) {
              const ch = asStr(val.channel)
              if (ch === 'thinking' || ch === 'text') {
                params.callbacks.onModelActivity?.(ch)
              }
            } else if (name === 'KEEPER_THINKING_DELTA' && val && typeof val.delta === 'string') {
              params.callbacks.onThinkingDelta?.(val.delta, extractThinkingBlockKey(val))
            } else if (name === 'KEEPER_THINKING_SNAPSHOT' && val && typeof val.snapshot === 'string') {
              params.callbacks.onThinkingSnapshot?.(val.snapshot, extractThinkingBlockKey(val))
            } else if (name === 'KEEPER_TOOL_CALL_ADMITTED' && val) {
              const admittedName = asStr(val.toolCallName)
              if (admittedName) {
                params.callbacks.onToolAdmitted?.(
                  admittedName,
                  asStr(val.toolCallId) ?? undefined,
                  extractToolOccurrenceKey(val),
                )
              }
            } else if (name === 'KEEPER_TOOL_RESULT_READY' && val) {
              const executionId = asStr(val.executionId) ?? asStr(val.execution_id)
              if (executionId) {
                params.callbacks.onToolResultReady?.({
                  executionId,
                  toolCallId: asStr(val.toolCallId) ?? undefined,
                  streamKey: extractToolOccurrenceKey(val),
                })
              }
            } else if (name === 'KEEPER_NATIVE_TOOL_START' && val) {
              params.callbacks.onToolStart?.(
                asStr(val.toolCallName) ?? 'native_tool',
                asStr(val.toolCallId) ?? undefined,
                extractToolOccurrenceKey(val),
              )
            } else if (name === 'KEEPER_NATIVE_TOOL_PROGRESS' && val && isRecord(val.progress)) {
              const progressLabel = formatNativeProgressLabel(val.progress)
              if (progressLabel) {
                params.callbacks.onNativeToolProgress?.({
                  toolName: asStr(val.toolCallName) ?? undefined,
                  toolCallId: asStr(val.toolCallId) ?? undefined,
                  streamKey: extractToolOccurrenceKey(val),
                  progressLabel,
                })
              }
            } else if (name === 'KEEPER_NATIVE_TOOL_END' && val) {
              const completion = isRecord(val.completion) ? formatNativeCompletionSummary(val.completion) : { status: 'completed' as const }
              params.callbacks.onNativeToolEnd?.({
                toolName: asStr(val.toolCallName) ?? undefined,
                toolCallId: asStr(val.toolCallId) ?? undefined,
                streamKey: extractToolOccurrenceKey(val),
                status: completion.status,
                summary: completion.summary,
              })
            } else if (name === 'KEEPER_TOOL_APPROVAL_REQUESTED' && val) {
              const tcId = asStr(val.tool_call_id) ?? ''
              params.callbacks.onToolApprovalRequested?.({
                toolCallId: tcId,
                toolName: asStr(val.tool_call_name) ?? 'tool',
                args: typeof val.args === 'string' && val.args.trim() ? val.args : undefined,
                question: asStr(val.question) ?? undefined,
                because: asStr(val.because) ?? undefined,
              })
            } else if (name === 'KEEPER_TOOL_APPROVAL_SETTLED' && val) {
              const tcId = asStr(val.tool_call_id) ?? ''
              const outcome = asStr(val.outcome) ?? ''
              if (outcome) {
                params.callbacks.onToolApprovalSettled?.({
                  toolCallId: tcId,
                  toolName: asStr(val.tool_call_name) ?? undefined,
                  outcome,
                })
              }
            } else if (name === 'KEEPER_CHAT_BATCH_BOUND' && val) {
              const operationId = asStr(val.operation_id)
              const executionId = asStr(val.execution_id)
              if (operationId && executionId) params.callbacks.onBatchBound?.(operationId, executionId)
            } else if (name === 'KEEPER_CHAT_OPERATION_ACCEPTED' && val) {
              const state = asStr(val.state) ?? 'Queued'
              const inter = isRecord(val.interactive) ? val.interactive : null
              params.callbacks.onAccepted?.({
                operationId: asStr(val.operation_id) ?? params.operationId,
                state,
                queuedCount: asNum(val.queued_count) ?? 0,
                controlToken: inter ? asStr(inter.chat_control_token) : null,
              })
              if (state === 'Succeeded' || state === 'Failed' || state === 'Cancelled') {
                terminal = true
                params.callbacks.onFinished?.()
              }
            } else if (name === 'KEEPER_REPLY_DETAILS' && val && typeof val.reply === 'string') {
              params.callbacks.onReplyDetails?.(val.reply, asStr(val.turn_ref))
            }
          }
        }

        try {
          while (true) {
            const { done, value } = await reader.read()
            if (done) break
            if (!isEpochCurrent(startEpoch) || controller.signal.aborted) break
            buf += decoder.decode(value, { stream: true })
            const parts = buf.split(/\r?\n\r?\n/)
            buf = parts.pop() ?? ''
            for (const frame of parts) {
              handleFrame(frame)
              if (terminal) break
            }
            if (terminal) break
          }
          if (!terminal && buf.trim() && isEpochCurrent(startEpoch) && !controller.signal.aborted) {
            handleFrame(buf)
          }
        } finally {
          try {
            await reader.cancel()
          } catch { /* ignore */ }
          reader.releaseLock()
        }

        return { terminal, error: null }
      } catch (cause) {
        const msg = cause instanceof Error ? cause.message : String(cause)
        return { terminal: false, error: msg }
      } finally {
        unsubEpoch()
        slotSignal.removeEventListener('abort', abortMerged)
        params.signal?.removeEventListener('abort', abortMerged)
      }
    })()

    return () => {
      if (!controller.signal.aborted) controller.abort('view_stream_released')
    }
  })

  try {
    if (!runPromise) {
      return { terminal: false, error: 'tab_hidden' }
    }
    return await runPromise
  } finally {
    handle.release()
  }
}

/**
 * Sends raw binary audio bytes with `Content-Type: <mimeType>` to
 * `POST /api/v1/voice/transcribe` (matching `server_routes_http_routes_voice.ml:117-154`).
 */
export async function transcribeVoiceAudio(
  audioBytes: ArrayBuffer | Blob | Uint8Array,
  mimeType: string,
  opts: { readonly signal?: AbortSignal; readonly fetchImpl?: typeof fetch } = {},
): Promise<Result<string, ApiError>> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const startEpoch = currentSessionEpoch()
  const controller = new AbortController()
  const onAbort = () => controller.abort(opts.signal?.reason)
  if (opts.signal) {
    if (opts.signal.aborted) {
      return err({ kind: 'aborted', status: null, code: null, message: 'Aborted', retryable: false })
    }
    opts.signal.addEventListener('abort', onAbort, { once: true })
  }
  const unsubEpoch = sessionEpoch.subscribe((ep) => {
    if (ep !== startEpoch) controller.abort('epoch_stale')
  })

  const headers: Record<string, string> = {
    Accept: 'application/json',
    'Content-Type': mimeType && mimeType.trim() ? mimeType.trim() : 'audio/webm',
  }
  const session = authSession.peek()
  if (session.kind === 'multi_account_signed_in') {
    const csrf = getActiveCsrfToken()
    if (csrf) headers['x-masc-csrf-token'] = csrf
  } else {
    const token = getSingleUserToken()
    if (token) headers.Authorization = `Bearer ${token}`
  }

  try {
    const bodyInit: BodyInit = audioBytes instanceof Uint8Array
      ? new Uint8Array(audioBytes)
      : audioBytes
    const res = await fetchImpl(resolveWorkspaceUrl('/api/v1/voice/transcribe'), {
      method: 'POST',
      credentials: 'same-origin',
      headers,
      body: bodyInit,
      signal: controller.signal,
    })
    if (!isEpochCurrent(startEpoch)) {
      return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: 'Session epoch changed', retryable: false })
    }
    const raw: unknown = await res.json().catch(() => null)
    if (!res.ok) {
      const msg = isRecord(raw) && typeof raw.error === 'string' ? raw.error : `HTTP ${res.status}`
      return err({ kind: res.status >= 500 ? 'server' : 'validation', status: res.status, code: null, message: msg, retryable: res.status >= 500 })
    }
    const text = isRecord(raw) && typeof raw.text === 'string'
      ? raw.text
      : isRecord(raw) && typeof raw.transcript === 'string'
        ? raw.transcript
        : ''
    return ok(text)
  } catch (cause) {
    if (!isEpochCurrent(startEpoch)) {
      return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: 'Session epoch changed', retryable: false, cause })
    }
    return err({
      kind: controller.signal.aborted ? 'aborted' : 'network',
      status: null,
      code: null,
      message: cause instanceof Error ? cause.message : String(cause),
      retryable: !controller.signal.aborted,
      cause,
    })
  } finally {
    unsubEpoch()
    opts.signal?.removeEventListener('abort', onAbort)
  }
}

// ── Debug Companion: Turn Records, Tool Calls, Prompt, Provider Input, Raw Traces, Checkpoints ──

function decodePromptBlock(b: unknown): TurnRecordPromptBlock | null {
  if (!isRecord(b)) return null
  return {
    block: asStr(b.block) ?? asStr(b.id) ?? 'block',
    bytes: asNum(b.bytes) ?? 0,
    digest: asStr(b.digest) ?? '',
  }
}

function decodePromptBlocks(raw: unknown): TurnRecordPromptBlock[] {
  if (!Array.isArray(raw)) return []
  const out: TurnRecordPromptBlock[] = []
  for (const b of raw) {
    const decoded = decodePromptBlock(b)
    if (decoded) out.push(decoded)
  }
  return out
}

function decodeChangedPromptBlocks(raw: unknown): { readonly prev: TurnRecordPromptBlock; readonly next: TurnRecordPromptBlock }[] {
  if (!Array.isArray(raw)) return []
  const out: { readonly prev: TurnRecordPromptBlock; readonly next: TurnRecordPromptBlock }[] = []
  for (const item of raw) {
    if (!isRecord(item)) continue
    const prev = decodePromptBlock(item.prev)
    const next = decodePromptBlock(item.next)
    if (prev && next) out.push({ prev, next })
  }
  return out
}

export function fetchKeeperTurnRecordsApi(keeper: string, limit = 60): Promise<Result<KeeperTurnRecordsData, ApiError>> {
  return apiGet<KeeperTurnRecordsData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/turn-records?limit=${limit}`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const rawEntries = Array.isArray(rec.entries) ? rec.entries : []
        const entries: KeeperTurnRecordsData['entries'][number][] = []
        for (const e of rawEntries) {
          if (!isRecord(e) || !isRecord(e.record)) continue
          const r = e.record
          const refRaw = isRecord(r.raw_trace_run_ref) ? r.raw_trace_run_ref : null
          const item: TurnRecordItem = {
            trace_id: asStr(r.trace_id) ?? '',
            absolute_turn: asNum(r.absolute_turn) ?? 0,
            turn_ref: asStr(r.turn_ref) ?? '',
            turn_kind: r.turn_kind === 'direct' ? 'direct' : 'autonomous',
            runtime_profile: asStr(r.runtime_profile) ?? 'default',
            selected_model: asStr(r.selected_model) ?? undefined,
            finish_reason: asStr(r.finish_reason) ?? undefined,
            context_window: asNum(r.context_window) ?? undefined,
            provider_context_window: asNum(r.provider_context_window) ?? undefined,
            request_latency_ms: asNum(r.request_latency_ms) ?? undefined,
            ttfrc_ms: asNum(r.ttfrc_ms) ?? undefined,
            input_tokens: asNum(r.input_tokens) ?? undefined,
            cache_creation_input_tokens: asNum(r.cache_creation_input_tokens) ?? undefined,
            cache_read_input_tokens: asNum(r.cache_read_input_tokens) ?? undefined,
            output_tokens: asNum(r.output_tokens) ?? undefined,
            ts: asNum(r.ts) ?? 0,
            blocks: decodePromptBlocks(r.blocks),
            raw_trace_run_ref: refRaw && asStr(refRaw.path)
              ? {
                  worker_run_id: asStr(refRaw.worker_run_id) ?? '',
                  path: asStr(refRaw.path)!,
                  start_seq: asNum(refRaw.start_seq) ?? 0,
                  end_seq: asNum(refRaw.end_seq) ?? 0,
                }
              : null,
          }
          const diffRaw = isRecord(e.diff_vs_prev) ? e.diff_vs_prev : null
          entries.push({
            record: item,
            diff_vs_prev: diffRaw
              ? {
                  added: decodePromptBlocks(diffRaw.added),
                  removed: decodePromptBlocks(diffRaw.removed),
                  changed: decodeChangedPromptBlocks(diffRaw.changed),
                }
              : null,
          })
        }
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          count: asNum(rec.count) ?? entries.length,
          live_turn_in_progress: rec.live_turn_in_progress === true,
          health: asStr(rec.health) ?? 'unknown',
          entries,
        }
      },
    },
  )
}

export function fetchKeeperToolCallsApi(keeper: string, limit = 50): Promise<Result<KeeperToolCallsData, ApiError>> {
  return apiGet<KeeperToolCallsData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/tool-calls?limit=${limit}`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const list = Array.isArray(rec.entries) ? rec.entries : []
        const entries: KeeperToolCallEntry[] = []
        for (const item of list) {
          if (!isRecord(item)) continue
          const rk = item.record_kind
          entries.push({
            ts: asNum(item.ts) ?? 0,
            record_kind: rk === 'composition_run' || rk === 'lifecycle_event' ? rk : 'tool_call',
            keeper: asStr(item.keeper) ?? keeper,
            tool: asStr(item.tool) ?? 'unknown',
            duration_ms: asNum(item.duration_ms) ?? 0,
            wire_outcome: asStr(item.wire_outcome) ?? 'unknown',
            disposition:
              item.disposition === 'completed' || item.disposition === 'deferred' || item.disposition === 'failed'
                ? item.disposition
                : undefined,
            failure_class: asStr(item.failure_class) ?? undefined,
            execution_id: asStr(item.execution_id) ?? undefined,
            trace_id: asStr(item.trace_id) ?? undefined,
            turn: asNum(item.turn) ?? undefined,
            task_id: asStr(item.task_id) ?? undefined,
            model: asStr(item.model) ?? undefined,
            result_bytes: asNum(item.result_bytes) ?? undefined,
            input: item.input,
            output: item.output,
          })
        }
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          count: asNum(rec.count) ?? entries.length,
          health: asStr(rec.health) ?? 'unknown',
          entries,
        }
      },
    },
  )
}

export function fetchKeeperToolStatsApi(keeper: string, windowHours = 24): Promise<Result<KeeperToolStatsData, ApiError>> {
  return apiGet<KeeperToolStatsData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/tool-stats?window_hours=${windowHours}`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const toolsRaw = Array.isArray(rec.tools) ? rec.tools : []
        const tools = toolsRaw.filter(isRecord).map((t) => ({
          name: asStr(t.name) ?? 'unknown',
          call_count: asNum(t.call_count) ?? 0,
          success_count: asNum(t.success_count) ?? 0,
          failure_count: asNum(t.failure_count) ?? 0,
          avg_duration_ms: asNum(t.avg_duration_ms) ?? 0,
          p95_duration_ms: asNum(t.p95_duration_ms) ?? 0,
        }))
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          window_hours: asNum(rec.window_hours) ?? windowHours,
          total_entries: asNum(rec.total_entries) ?? 0,
          tools,
        }
      },
    },
  )
}

export function fetchKeeperLastPromptApi(keeper: string): Promise<Result<KeeperLastPromptData, ApiError>> {
  return apiGet<KeeperLastPromptData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/last-prompt`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const blocks = Array.isArray(rec.blocks)
          ? rec.blocks.filter(isRecord).map((b) => ({
              id: asStr(b.id) ?? 'block',
              bytes: asNum(b.bytes) ?? 0,
              text: typeof b.text === 'string' ? b.text : '',
            }))
          : []
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          captured_at: asNum(rec.captured_at) ?? 0,
          trace_id: asStr(rec.trace_id) ?? '',
          absolute_turn: asNum(rec.absolute_turn) ?? 0,
          assembled: typeof rec.assembled === 'string' ? rec.assembled : null,
          assembled_bytes: asNum(rec.assembled_bytes) ?? 0,
          system_prompt: typeof rec.system_prompt === 'string' ? rec.system_prompt : null,
          blocks,
        }
      },
    },
  )
}

export function fetchKeeperProviderInputApi(keeper: string, turnRef: string): Promise<Result<ProviderInputData, ApiError>> {
  return apiGet<ProviderInputData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/provider-input?turn_ref=${encodeURIComponent(turnRef)}`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const wire = isRecord(rec.wire) ? rec.wire : {}
        const parts: ProviderInputPartSummary[] = Array.isArray(rec.parts)
          ? rec.parts.filter(isRecord).map((p, idx) => ({
              index: asNum(p.index) ?? idx,
              kind:
                p.kind === 'system_prompt' || p.kind === 'tool_schema'
                  ? p.kind
                  : 'message',
              role: asStr(p.role) ?? undefined,
              name: asStr(p.name) ?? undefined,
              bytes: asNum(p.bytes) ?? 0,
              sha256: asStr(p.sha256) ?? '',
            }))
          : []
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          turn_ref: asStr(rec.turn_ref) ?? turnRef,
          runtime_profile: asStr(rec.runtime_profile) ?? '',
          wire: {
            provider: asStr(wire.provider) ?? 'unknown',
            model: asStr(wire.model) ?? 'unknown',
            http_codec: asStr(wire.http_codec) ?? '',
            body_bytes: asNum(wire.body_bytes) ?? 0,
          },
          parts,
        }
      },
    },
  )
}

export function fetchKeeperRawTracesApi(keeper: string, limit = 15): Promise<Result<readonly RawTraceTurnItem[], ApiError>> {
  return apiGet<readonly RawTraceTurnItem[]>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/raw-traces?limit=${limit}`,
    {
      decode: (raw) => {
        const list = isRecord(raw) && Array.isArray(raw.turns) ? raw.turns : []
        return list.filter(isRecord).map((t) => {
          const census = isRecord(t.census) ? t.census : null
          return {
            file: asStr(t.file) ?? '',
            trace_id: asStr(t.trace_id),
            bytes: asNum(t.bytes) ?? 0,
            records: census && census.state === 'whole_file' ? asNum(census.records) : null,
            modified_at: asNum(t.modified_at) ?? 0,
          }
        }).filter((t) => t.file.length > 0)
      },
    },
  )
}

export function fetchKeeperRawTracePageApi(keeper: string, file: string, limit = 30) {
  const qs = new URLSearchParams({ file, limit: String(limit) })
  return apiGet<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/raw-trace?${qs.toString()}`,
  )
}

export function fetchKeeperCheckpointsApi(keeper: string): Promise<Result<CheckpointInventoryData, ApiError>> {
  return apiGet<CheckpointInventoryData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/checkpoints`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const mapSnap = (s: unknown) => {
          if (!isRecord(s)) return null
          const sid = asStr(s.snapshot_id)
          if (!sid) return null
          return {
            snapshot_id: sid,
            message_count: asNum(s.message_count) ?? 0,
            created_at: asNum(s.created_at) ?? 0,
            latest_preview: asStr(s.latest_preview),
          }
        }
        const st = rec.current_status
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          trace_id: asStr(rec.trace_id) ?? '',
          current_status: st === 'available' || st === 'unavailable' ? st : 'missing',
          current: mapSnap(rec.current),
          history: Array.isArray(rec.history)
            ? rec.history.map(mapSnap).filter((x): x is NonNullable<typeof x> => x !== null)
            : [],
        }
      },
    },
  )
}

// ── Memory OS 3-Way Discriminated Parser (#36) & Recovery Actions ────────

export function parseOrdinaryMemoryBranch(raw: unknown): OrdinaryMemoryBranch {
  if (!isRecord(raw)) return { state: 'read_error', read_error: 'invalid_ordinary_memory_payload' }
  if (typeof raw.read_error === 'string' && raw.read_error.trim().length > 0) {
    return { state: 'read_error', read_error: raw.read_error }
  }
  if (raw.present === false) {
    return { state: 'absent' }
  }
  if (raw.present === true) {
    const facts = Array.isArray(raw.facts)
      ? raw.facts.filter(isRecord).map((f) => ({
          memory_id: asStr(f.memory_id) ?? '',
          claim: typeof f.claim === 'string' ? f.claim : '',
          category: asStr(f.category) ?? 'general',
          first_seen: asNum(f.first_seen) ?? 0,
          last_seen: asNum(f.last_seen) ?? 0,
        }))
      : []
    const supportInvalidations = Array.isArray(raw.support_invalidations)
      ? raw.support_invalidations.filter(isRecord).map((inv) => ({
          memory_id: asStr(inv.memory_id) ?? '',
          claim: typeof inv.claim === 'string' ? inv.claim : '',
          missing_premise_ids: Array.isArray(inv.missing_premise_ids)
            ? inv.missing_premise_ids.filter((x): x is string => typeof x === 'string')
            : [],
        }))
      : []
    return {
      state: 'present',
      revision: asNum(raw.revision) ?? 0,
      snapshot_sha256: asStr(raw.snapshot_sha256) ?? '',
      updated_at: asNum(raw.updated_at) ?? 0,
      facts,
      support_invalidations: supportInvalidations,
    }
  }
  return { state: 'read_error', read_error: 'unrecognized_ordinary_memory_discriminant' }
}

export function parseSourceBoundMemoryBranch(raw: unknown): SourceBoundMemoryBranch {
  if (!isRecord(raw)) return { state: 'read_error', read_error: 'invalid_source_bound_payload' }
  if (typeof raw.read_error === 'string' && raw.read_error.trim().length > 0) {
    return { state: 'read_error', read_error: raw.read_error }
  }
  if (raw.present === false) {
    return { state: 'absent' }
  }
  if (raw.present === true) {
    const facts = Array.isArray(raw.facts)
      ? raw.facts.filter(isRecord).map((f) => ({
          claim: typeof f.claim === 'string' ? f.claim : '',
          first_seen: asNum(f.first_seen) ?? 0,
          path: asStr(f.path) ?? '',
          sha256: asStr(f.sha256) ?? '',
        }))
      : []
    const invalidations = Array.isArray(raw.invalidations)
      ? raw.invalidations.filter(isRecord).map((inv) => ({
          source_path: asStr(inv.source_path) ?? '',
          invalidated_at: asNum(inv.invalidated_at) ?? 0,
          reason: asStr(inv.reason) ?? 'source_changed',
        }))
      : []
    return {
      state: 'present',
      revision: asNum(raw.revision) ?? 0,
      updated_at: asNum(raw.updated_at) ?? 0,
      facts,
      invalidations,
    }
  }
  return { state: 'read_error', read_error: 'unrecognized_source_bound_discriminant' }
}

export function decodeKeeperMemoryFacts(raw: unknown, keeper: string): KeeperMemoryFactsData {
  const rec = isRecord(raw) ? raw : {}
  return {
    keeper: asStr(rec.keeper) ?? keeper,
    ordinary: parseOrdinaryMemoryBranch(rec.ordinary),
    source_bound: parseSourceBoundMemoryBranch(rec.source_bound),
    events_unreadable_lines: asNum(rec.events_unreadable_lines) ?? 0,
    events_read_error: asStr(rec.events_read_error),
  }
}

export function fetchKeeperMemoryFactsApi(keeper: string): Promise<Result<KeeperMemoryFactsData, ApiError>> {
  return apiGet<KeeperMemoryFactsData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/memory-facts`,
    { decode: (raw) => decodeKeeperMemoryFacts(raw, keeper) },
  )
}

export function fetchKeeperMemoryOsInternalsApi(keeper: string): Promise<Result<KeeperMemoryOsInternalsData, ApiError>> {
  return apiGet<KeeperMemoryOsInternalsData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/memory-os-internals`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const comp = isRecord(rec.compaction) ? rec.compaction : {}
        const canon = isRecord(rec.canonical_turns) ? rec.canonical_turns : {}
        const dig = isRecord(rec.memory_digest) ? rec.memory_digest : {}
        const molt = isRecord(rec.librarian_molt) ? rec.librarian_molt : {}
        const availableActs = Array.isArray(molt.available_acts)
          ? molt.available_acts.map((a) => (typeof a === 'string' ? a : isRecord(a) ? (asStr(a.action) ?? JSON.stringify(a)) : String(a)))
          : []
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          compaction: {
            present: comp.present === true,
            epoch_count: asNum(comp.epoch_count) ?? 0,
            archived_turns_count: asNum(comp.archived_turns_count) ?? 0,
            anchor_bytes: asNum(comp.anchor_bytes) ?? 0,
            latest_epoch_id: asNum(comp.latest_epoch_id),
            verified_facts_count: asNum(comp.verified_facts_count) ?? 0,
            decisions_count: asNum(comp.decisions_count) ?? 0,
            open_threads_count: asNum(comp.open_threads_count) ?? 0,
            read_error: asStr(comp.read_error),
          },
          canonical_turns: {
            present: canon.present === true,
            turn_count: asNum(canon.turn_count) ?? 0,
            latest_turn_id: asStr(canon.latest_turn_id),
            compaction_watermark_seq: asNum(canon.compaction_watermark_seq),
            compaction_watermark_epoch: asNum(canon.compaction_watermark_epoch),
            history_resets_count: asNum(canon.history_resets_count) ?? 0,
            read_error: asStr(canon.read_error),
          },
          memory_digest: {
            present: dig.present === true,
            revision: asNum(dig.revision),
            digest_sha256: asStr(dig.digest_sha256),
            bytes: asNum(dig.bytes) ?? 0,
            fact_count: asNum(dig.fact_count) ?? 0,
            derived_count: asNum(dig.derived_count) ?? 0,
          },
          librarian_molt: {
            writer_kind: asStr(molt.writer_kind) ?? 'unknown',
            writer_state: molt.writer_state ?? null,
            pending_molt: molt.pending_molt ?? null,
            available_acts: availableActs,
          },
        }
      },
    },
  )
}

export function fetchKeeperMemoryJournalApi(keeper: string, limit = 50): Promise<Result<KeeperMemoryJournalData, ApiError>> {
  return apiGet<KeeperMemoryJournalData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/memory-journal?activity=1&limit=${limit}`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const entries: KeeperMemoryJournalEntry[] = Array.isArray(rec.entries)
          ? rec.entries.filter(isRecord).map((e) => {
              const source = isRecord(e.source) ? e.source : null
              const change = isRecord(e.change) ? e.change : null
              return {
                structural_id: asStr(e.structural_id) ?? '',
                ok: e.ok === true,
                error: asStr(e.error) ?? undefined,
                recorded_at: asNum(e.recorded_at) ?? undefined,
                revision: asNum(e.revision) ?? undefined,
                source_kind: source ? (asStr(source.kind) ?? undefined) : undefined,
                added: change ? (asNum(change.added) ?? 0) : undefined,
                removed: change ? (asNum(change.removed) ?? 0) : undefined,
                retained: change ? (asNum(change.retained) ?? 0) : undefined,
                invalidated: change ? (asNum(change.invalidated) ?? 0) : undefined,
              }
            })
          : []
        const actRaw = isRecord(rec.activity) ? rec.activity : null
        const activity = actRaw
          ? {
              events: Array.isArray(actRaw.events)
                ? actRaw.events.filter(isRecord).map((ev) => ({
                    identity: asStr(ev.identity) ?? '',
                    recorded_at: asNum(ev.recorded_at) ?? 0,
                    revision: asNum(ev.revision) ?? 0,
                    kind: asStr(ev.kind) ?? 'unknown',
                    reason: asStr(ev.reason),
                  }))
                : [],
              notes: Array.isArray(actRaw.notes)
                ? actRaw.notes.filter((n): n is string => typeof n === 'string')
                : [],
            }
          : null
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          returned: asNum(rec.returned) ?? entries.length,
          undecodable_lines: asNum(rec.undecodable_lines) ?? 0,
          entries,
          activity,
        }
      },
    },
  )
}

export function postKeeperMemoryAct(keeper: string, payload: MemoryActPayload) {
  return apiMutate<Record<string, unknown>>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/memory/act`,
    payload,
  )
}

export function postKeeperMemoryRetractions(
  keeper: string,
  retractions: readonly { readonly memory_id: string; readonly reason: string }[],
  planId = `dashboard-retract-${randomUuid()}`,
) {
  return apiMutate<Record<string, unknown>>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/memory/retractions`,
    {
      plan_id: planId,
      retractions,
    },
  )
}

// ── Portrait & Candle (V2Envelope + Flat /items + MCP purchase/equip) ────

export function fetchKeeperCandleLedgerApi(keeper: string, limit = 100): Promise<Result<KeeperCandleLedgerData, ApiError>> {
  return apiGetV2<KeeperCandleLedgerData>(
    `/api/v1/candle/ledger?keeper=${encodeURIComponent(keeper)}&limit=${limit}`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const policy = isRecord(rec.policy) ? rec.policy : {}
        const halfLife = isRecord(policy.half_life) ? policy.half_life : {}
        const supply = isRecord(rec.supply) ? rec.supply : {}
        const strMilli = (v: unknown) =>
          typeof v === 'string' && v.trim() ? v.trim() : typeof v === 'number' ? String(Math.trunc(v)) : '0'
        const balances = Array.isArray(rec.balances) ? rec.balances.filter(isRecord) : []
        const balRaw = balances.find((b) => asStr(b.keeper) === keeper) ?? balances[0] ?? null
        const eqRaw = balRaw && isRecord(balRaw.equipped) ? balRaw.equipped : {}
        const balance: CandleBalanceRow | null = balRaw
          ? {
              keeper: asStr(balRaw.keeper) ?? keeper,
              balance_milli: asNum(balRaw.balance_milli) ?? 0,
              decayed_milli: strMilli(balRaw.decayed_milli),
              last_event_unix: asNum(balRaw.last_event_unix),
              owned_items: Array.isArray(balRaw.owned_items)
                ? balRaw.owned_items.filter((x): x is string => typeof x === 'string')
                : [],
              equipped: {
                face: asStr(eqRaw.face),
                neck: asStr(eqRaw.neck),
                head: asStr(eqRaw.head),
                hand: asStr(eqRaw.hand),
                base: asStr(eqRaw.base),
              },
            }
          : null

        const recentEvents: CandleLedgerEventRow[] = Array.isArray(rec.recent_events)
          ? rec.recent_events.filter(isRecord).map((ev) => ({
              seq: asNum(ev.seq) ?? 0,
              at_unix: asNum(ev.at_unix) ?? 0,
              at_rfc3339: asStr(ev.at_rfc3339) ?? '',
              kind: asStr(ev.kind) ?? 'event',
              summary:
                asStr(ev.item)
                  ?? asStr(ev.goal_id)
                  ?? (typeof ev.amount_milli === 'string' || typeof ev.amount_milli === 'number'
                    ? `${strMilli(ev.amount_milli)} mC`
                    : asStr(ev.reason) ?? ''),
            }))
          : []

        const cfg = policy.configuration
        return {
          ledger_state: rec.ledger_state === 'present' ? 'present' : 'missing',
          total_events: asNum(rec.total_events) ?? 0,
          policy_configuration: cfg === 'enabled' ? 'enabled' : cfg === 'disabled' ? 'disabled' : 'off',
          disabled_reason: asStr(policy.disabled_reason),
          pricing_mode: asStr(policy.pricing_mode) ?? 'off',
          half_life_hours: asNum(halfLife.half_life_hours),
          supply: {
            issued_milli: strMilli(supply.issued_milli),
            burned_milli: strMilli(supply.burned_milli),
            circulating_milli: strMilli(supply.circulating_milli),
          },
          balance,
          recent_events: recentEvents,
        }
      },
    },
  )
}

export function fetchKeeperItemsApi(keeper: string): Promise<Result<KeeperItemsData, ApiError>> {
  return apiGet<KeeperItemsData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/items`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const status = rec.status === 'ready' ? 'ready' : rec.status === 'disabled' ? 'disabled' : 'off'
        const catalog: KeeperCatalogItem[] = Array.isArray(rec.catalog)
          ? rec.catalog.filter(isRecord).map((c) => {
              const slotRaw = asStr(c.slot)
              const slot: PortraitSlot =
                slotRaw === 'face' || slotRaw === 'neck' || slotRaw === 'head' || slotRaw === 'hand' || slotRaw === 'base'
                  ? slotRaw
                  : 'head'
              const priceStatus: KeeperCatalogItem['price_status'] =
                c.price_status === 'priced' ? 'priced' : 'unpriced'
              return {
                id: asStr(c.id) ?? '',
                slot,
                price_status: priceStatus,
                price_milli: typeof c.price_milli === 'string' ? c.price_milli : null,
              }
            }).filter((c) => c.id.length > 0)
          : []
        return {
          status,
          reason: asStr(rec.reason) ?? undefined,
          account_revision: asStr(rec.account_revision),
          balance_milli: typeof rec.balance_milli === 'string' ? rec.balance_milli : null,
          owned_items: Array.isArray(rec.owned_items)
            ? rec.owned_items.filter((x): x is string => typeof x === 'string')
            : [],
          catalog,
        }
      },
    },
  )
}

// Note: `keeper_candle_purchase` and `keeper_candle_equip` are Keeper-autonomous
// tools guarded by server wallet policy (`lib/mcp_server_eio_execute.ml:510-519`);
// operators cannot spoof a Keeper wallet over HTTP/MCP. Portrait try-on uses
// `GET /api/v1/keepers/:name/portrait.png?size=256&preview=<item_id>`.

// ── Work & Sandbox ───────────────────────────────────────────────────────

export function fetchKeeperLinkedTasksApi(keeper: string): Promise<Result<readonly KeeperLinkedTask[], ApiError>> {
  return apiGet<readonly KeeperLinkedTask[]>('/api/v1/dashboard/execution', {
    decode: (raw) => {
      const list = isRecord(raw) && Array.isArray(raw.tasks) ? raw.tasks : []
      return list
        .filter(isRecord)
        .filter((t) => asStr(t.assignee) === keeper)
        .map((t) => ({
          id: asStr(t.id) ?? '',
          title: asStr(t.title) ?? '',
          status: asStr(t.status) ?? 'Todo',
          priority: asNum(t.priority) ?? 0,
          goal_id: asStr(t.goal_id),
          updated_at: asStr(t.updated_at),
        }))
        .filter((t) => t.id.length > 0)
    },
  })
}

export function fetchKeeperOperatorNoteApi(keeper: string): Promise<Result<KeeperOperatorNoteData, ApiError>> {
  return apiGet<KeeperOperatorNoteData>(
    `/api/v1/keepers/${encodeURIComponent(keeper)}/operator-note`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const note = isRecord(rec.note) ? rec.note : {}
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          pending: rec.pending === true,
          text: typeof note.text === 'string' ? note.text : '',
          created_by: asStr(note.created_by) ?? '',
          created_at: asNum(note.created_at) ?? 0,
          consumed_turn: asNum(note.consumed_turn),
        }
      },
    },
  )
}

export function saveKeeperOperatorNoteApi(keeper: string, text: string): Promise<Result<KeeperOperatorNoteData, ApiError>> {
  return apiMutate<KeeperOperatorNoteData>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/operator-note`,
    { text },
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const note = isRecord(rec.note) ? rec.note : {}
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          pending: rec.pending === true,
          text: typeof note.text === 'string' ? note.text : text,
          created_by: asStr(note.created_by) ?? '',
          created_at: asNum(note.created_at) ?? 0,
          consumed_turn: asNum(note.consumed_turn),
        }
      },
    },
  )
}

export function fetchKeeperSandboxApi(keeper: string): Promise<Result<KeeperSandboxData, ApiError>> {
  return apiGetV2<KeeperSandboxData>(
    `/api/v1/infra/sandboxes/${encodeURIComponent(keeper)}`,
    {
      decode: (raw) => {
        const rec = isRecord(raw) ? raw : {}
        const probe = isRecord(rec.probe_state) ? rec.probe_state : {}
        const sb = isRecord(rec.sandbox) ? rec.sandbox : {}
        return {
          keeper: asStr(rec.keeper) ?? keeper,
          probe_kind: asStr(probe.kind) ?? 'unknown',
          backend: asStr(sb.backend) ?? asStr(sb.kind) ?? asStr(sb.sandbox_profile) ?? 'observed',
          summary: sb,
        }
      },
    },
  )
}

// ── Schema Config CAS & Secrets / OAuth Identity (#36) ───────────────────

export interface KeeperAttachedToolsSnapshot {
  readonly providers: readonly KeeperAttachedProvider[]
  readonly callbackUrl: string | null
}

function decodeKeeperAttachedProviders(raw: unknown): readonly KeeperAttachedProvider[] {
  const list = isRecord(raw) && Array.isArray(raw.providers) ? raw.providers : []
  return list.filter(isRecord).map((p) => ({
    provider: asStr(p.provider) ?? '',
    provider_label: asStr(p.provider_label) ?? asStr(p.provider) ?? '',
    attached: p.attached === true,
    enabled: typeof p.enabled === 'boolean' ? p.enabled : undefined,
    tools: Array.isArray(p.tools)
      ? p.tools.filter((x): x is string => typeof x === 'string')
      : undefined,
    problem: asStr(p.problem) ?? undefined,
    switch_problem: asStr(p.switch_problem) ?? undefined,
  })).filter((p) => p.provider.length > 0)
}

export function fetchKeeperOAuthAttachedToolsApi(
  keeper: string,
): Promise<Result<KeeperAttachedToolsSnapshot, ApiError>> {
  return apiGet<KeeperAttachedToolsSnapshot>(
    `/api/v1/keepers/oauth/attached-tools?keeper=${encodeURIComponent(keeper)}`,
    {
      decode: (raw) => {
        const callback = isRecord(raw) && isRecord(raw.callback) ? raw.callback : null
        return {
          providers: decodeKeeperAttachedProviders(raw),
          callbackUrl: callback ? asStr(callback.url) : null,
        }
      },
    },
  )
}

export function fetchKeeperAttachedProvidersApi(keeper: string): Promise<Result<readonly KeeperAttachedProvider[], ApiError>> {
  return apiGet<readonly KeeperAttachedProvider[]>(
    `/api/v1/keepers/oauth/attached-tools?keeper=${encodeURIComponent(keeper)}`,
    {
      decode: decodeKeeperAttachedProviders,
    },
  )
}

export function setKeeperIdentitySwitchApi(keeper: string, provider: string, enabled: boolean) {
  return apiMutate<unknown>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/identity-switch`,
    { provider, enabled },
  )
}

export function refreshKeeperIdentityToolsApi(keeper: string, provider: string) {
  return apiMutate<unknown>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/identity-refresh`,
    { provider },
  )
}

export function startKeeperOAuthLoginApi(keeper: string, provider: string) {
  return apiMutate<{ readonly authorize_url?: string }>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/oauth-login`,
    { provider },
  )
}

export function mutateKeeperSecretApi(
  keeper: string,
  payload:
    | { readonly action: 'set_env'; readonly scope: 'keeper' | 'shared'; readonly name: string; readonly value: string }
    | { readonly action: 'delete_env'; readonly scope: 'keeper' | 'shared'; readonly name: string },
) {
  return apiMutate<unknown>(
    'POST',
    `/api/v1/keepers/${encodeURIComponent(keeper)}/secrets`,
    payload,
  )
}

export { wrap }
