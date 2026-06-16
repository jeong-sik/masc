import { signal } from '@preact/signals'
import { formatKeeperVisibleReply } from './keeper-message'
import { isRecord, asString, asNumber, asBoolean, toIsoTimestamp } from './components/common/normalize'
import type {
  KeeperConversationEntry,
  KeeperConversationRole,
  KeeperConversationSource,
  KeeperConversationStreamState,
  KeeperConversationDelivery,
  KeeperDiagnostic,
  KeeperProbeResult,
  KeeperRecoverResult,
  KeeperStatusDetail,
  SurfaceRef,
} from './types'

// --- Signals ---

export const activeKeeperName = signal('')
export const keeperStatusDetails = signal<Record<string, KeeperStatusDetail>>({})
export const keeperThreads = signal<Record<string, KeeperConversationEntry[]>>({})
export const keeperHydrating = signal<Record<string, boolean>>({})
export const keeperSending = signal<Record<string, boolean>>({})
export const keeperProbing = signal<Record<string, boolean>>({})
export const keeperRecovering = signal<Record<string, boolean>>({})
export const keeperActionErrors = signal<Record<string, string | null>>({})
export const keeperStreamStartedAt = signal<Record<string, number | null>>({})
// Wall-clock ms of the most recent SSE event observed for an in-flight
// stream. Drives the stall indicator (streaming but no events for N s).
export const keeperStreamLastEventAt = signal<Record<string, number | null>>({})

// Thread entries kept per keeper. History beyond this window stays
// available server-side (keeper_chat/<name>.jsonl, GET /chat/history).
export const THREAD_ENTRY_CAP = 200

// --- Private stream tracking ---

const keeperStreamControllers = new Map<string, AbortController>()
const keeperStreamEntryIds = new Map<string, string>()

// --- Helpers ---

export function setRecordValue<T>(state: typeof keeperThreads | typeof keeperHydrating | typeof keeperSending | typeof keeperProbing | typeof keeperRecovering | typeof keeperActionErrors | typeof keeperStreamStartedAt, key: string, value: T): void {
  state.value = {
    ...state.value,
    [key]: value,
  } as typeof state.value
}

function normalizeRole(value: unknown): KeeperConversationRole {
  const role = asString(value)?.toLowerCase()
  if (role === 'user' || role === 'assistant' || role === 'system' || role === 'tool') return role
  return 'other'
}

function roleLabel(role: KeeperConversationRole): string {
  switch (role) {
    case 'user':
      return '사용자'
    case 'assistant':
      return 'Keeper'
    case 'system':
      return 'System'
    case 'tool':
      return 'Tool'
    default:
      return 'Event'
  }
}

function looksLikeWorldStatePrompt(text: string): boolean {
  const trimmed = text.trim()
  return trimmed.startsWith('## Current World State')
    || (trimmed.includes('### Workspace State') && trimmed.includes('### Context'))
}

function normalizeConversationSource(
  value: unknown,
  role: KeeperConversationRole,
  rawText: string,
  previousSource: KeeperConversationSource | null,
): KeeperConversationSource {
  const source = asString(value)?.trim()
  if (
    source === 'direct_user'
    || source === 'direct_assistant'
    || source === 'world_state_prompt'
    || source === 'internal_assistant'
    || source === 'tool_result'
    || source === 'system'
    || source === 'unknown'
  ) {
    return source
  }

  if (role === 'tool') return 'tool_result'
  if (role === 'system') return 'system'
  if (role === 'user') {
    return looksLikeWorldStatePrompt(rawText) ? 'world_state_prompt' : 'direct_user'
  }
  if (role === 'assistant') {
    return previousSource === 'world_state_prompt' ? 'internal_assistant' : 'direct_assistant'
  }
  return 'unknown'
}

export function isVisibleDirectConversationEntry(entry: KeeperConversationEntry): boolean {
  if (entry.role !== 'user' && entry.role !== 'assistant') return false
  return entry.source !== 'world_state_prompt'
    && entry.source !== 'internal_assistant'
    && entry.source !== 'tool_result'
    && entry.source !== 'system'
}

// --- Normalizers ---

// Closed runtime mirrors of the 5 narrow string unions inside
// KeeperDiagnostic. The previous 5 `as KeeperDiagnostic['<field>']` casts
// trusted whatever backend string arrived; these sets enforce the
// boundary so an unrecognized value returns null (caller decides
// fallback). Same shape as toKeeperPhase / toKeeperLifecycleState /
// toPipelineStage (PRs #16745, #16788, #16791).
//
// Each set is typed as `KeeperDiagnostic['<field>']` (indexed access)
// so drift between the set and the underlying private union in
// types/core.ts surfaces as a tsc error here — no separate type
// export needed.
const KEEPER_HEALTH_STATES: ReadonlySet<NonNullable<KeeperDiagnostic['health_state']>> =
  new Set<NonNullable<KeeperDiagnostic['health_state']>>([
    'healthy', 'idle', 'stale', 'degraded', 'offline',
  ])

const KEEPER_QUIET_REASONS: ReadonlySet<NonNullable<KeeperDiagnostic['quiet_reason']>> =
  new Set<NonNullable<KeeperDiagnostic['quiet_reason']>>([
    'quiet_hours', 'min_gap', 'no_recent_activity', 'disabled',
    'startup', 'model_error', 'graphql_error', 'never_started', 'unknown',
  ])

const KEEPER_NEXT_ACTION_PATHS: ReadonlySet<NonNullable<KeeperDiagnostic['next_action_path']>> =
  new Set<NonNullable<KeeperDiagnostic['next_action_path']>>([
    'direct_message', 'manual_social_sweep', 'probe', 'recover',
  ])

const KEEPER_REPLY_STATUSES: ReadonlySet<NonNullable<KeeperDiagnostic['last_reply_status']>> =
  new Set<NonNullable<KeeperDiagnostic['last_reply_status']>>([
    'never', 'awaiting_reply', 'delivered', 'fresh', 'stale', 'error', 'unknown',
  ])

const KEEPER_CONTINUITY_STATES: ReadonlySet<NonNullable<KeeperDiagnostic['continuity_state']>> =
  new Set<NonNullable<KeeperDiagnostic['continuity_state']>>([
    'not_running', 'recovering', 'healthy', 'disabled', 'offline',
  ])

// Generic typed-parse helper. Returns the input value typed as `T` if
// `set` accepts it, else `null`. Callers compose with `?? <default>`
// for the fallback. This pattern is repeated 3 times in other dashboard
// modules (toKeeperPhase / toKeeperLifecycleState / toPipelineStage) —
// a future refactor could extract it to a shared module if it appears
// at a 4th boundary.
function membershipParse<T extends string>(
  set: ReadonlySet<T>,
  raw: string | null | undefined,
): T | null {
  if (!raw) return null
  const trimmed = raw.trim()
  if (!trimmed) return null
  return set.has(trimmed as T) ? (trimmed as T) : null
}

export function normalizeKeeperDiagnostic(raw: unknown): KeeperDiagnostic | null {
  if (!isRecord(raw)) return null
  const healthState = membershipParse(KEEPER_HEALTH_STATES, asString(raw.health_state))
  const nextActionPath = membershipParse(KEEPER_NEXT_ACTION_PATHS, asString(raw.next_action_path))
  const lastReplyStatus = membershipParse(KEEPER_REPLY_STATUSES, asString(raw.last_reply_status))
  // Reject the diagnostic entirely if any required field is invalid;
  // the previous behaviour rejected when these were empty strings, so
  // we preserve "reject on bad input" semantics while strengthening
  // from "non-empty string" to "valid union member".
  if (!healthState || !nextActionPath || !lastReplyStatus) return null
  return {
    health_state: healthState,
    quiet_reason: membershipParse(KEEPER_QUIET_REASONS, asString(raw.quiet_reason)),
    next_action_path: nextActionPath,
    last_reply_status: lastReplyStatus,
    last_reply_at: toIsoTimestamp(raw.last_reply_at) ?? null, // undefined->null: field is string|null
    last_reply_preview: asString(raw.last_reply_preview) ?? null,
    last_error: asString(raw.last_error) ?? null,
    next_eligible_at_s: asNumber(raw.next_eligible_at_s) ?? null,
    recoverable: typeof raw.recoverable === 'boolean' ? raw.recoverable : undefined,
    summary: asString(raw.summary),
    keepalive_running: typeof raw.keepalive_running === 'boolean' ? raw.keepalive_running : undefined,
    continuity_state: membershipParse(KEEPER_CONTINUITY_STATES, asString(raw.continuity_state)),
    continuity_summary: asString(raw.continuity_summary) ?? null,
  }
}

export function normalizeKeeperProbeResult(raw: unknown): KeeperProbeResult | null {
  if (!isRecord(raw)) return null
  return {
    status: raw.status,
    diagnostic: normalizeKeeperDiagnostic(raw.diagnostic),
  }
}

export function normalizeKeeperRecoverResult(raw: unknown): KeeperRecoverResult | null {
  if (!isRecord(raw)) return null
  return {
    recovered: asBoolean(raw.recovered) ?? false,
    skipped_reason: asString(raw.skipped_reason) ?? null,
    before: normalizeKeeperDiagnostic(raw.before),
    after: normalizeKeeperDiagnostic(raw.after),
    down: raw.down,
    up: raw.up,
  }
}

// --- Thread state management ---

// Stable fallback id for a message whose backend predates R3 and so
// carries no producer-assigned id. Derived from the content (not the merge
// index) so it does not shift when history pages are merged.
function fallbackHistoryEntryId(
  role: string,
  timestamp: string | null | undefined,
  text: string,
): string {
  let hash = 5381
  for (let i = 0; i < text.length; i += 1) {
    hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0
  }
  return `${role}-${timestamp ?? 'entry'}-${(hash >>> 0).toString(36)}`
}

function normalizeHistoryEntry(
  raw: unknown,
  keeperName?: string,
  previousSource: KeeperConversationSource | null = null,
): KeeperConversationEntry | null {
  if (!isRecord(raw)) return null
  const role = normalizeRole(raw.role)
  const rawText = asString(raw.content) ?? asString(raw.preview)
  if (!rawText) return null
  const source = normalizeConversationSource(raw.source, role, rawText, previousSource)
  const text = formatKeeperVisibleReply(rawText)
  if (!text) return null
  const timestamp = toIsoTimestamp(raw.ts_unix) ?? toIsoTimestamp(raw.timestamp)
  const label = role === 'assistant' && keeperName ? keeperName : roleLabel(role)
  const surface = isRecord(raw.surface) ? (raw.surface as unknown as SurfaceRef) : null
  return {
    // R3: key off the producer-assigned server id when present so the
    // render key is stable across history-page merges (the former
    // `${role}-${ts}-${index}` shifted with the merge index and remounted
    // bubbles). Pre-R3 rows fall back to a stable content-derived id.
    id: asString(raw.id) ?? fallbackHistoryEntryId(role, timestamp, rawText),
    role,
    source,
    label,
    text,
    rawText,
    timestamp,
    delivery: 'history',
    streamState: null,
    details: null,
    surface,
  }
}

export function normalizeStatusDetail(name: string, text: string, rawStatus: unknown): KeeperStatusDetail {
  const parsed = isRecord(rawStatus) ? rawStatus : null
  const history = Array.isArray(parsed?.history_tail)
    ? (() => {
        let previousSource: KeeperConversationSource | null = null
        return parsed.history_tail
          .map((entry) => {
            const normalized = normalizeHistoryEntry(entry, name, previousSource)
            previousSource = normalized?.source ?? previousSource
            return normalized
          })
          .filter((entry): entry is KeeperConversationEntry => entry !== null)
      })()
    : []
  return {
    name,
    diagnostic: normalizeKeeperDiagnostic(parsed?.diagnostic),
    history,
    rawText: text,
    rawStatus,
    loadedAt: new Date().toISOString(),
  }
}

export function appendThreadEntry(name: string, entry: KeeperConversationEntry): void {
  const existing = keeperThreads.value[name] ?? []
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: [...existing, entry].slice(-THREAD_ENTRY_CAP),
  }
}

export function removeThreadEntries(name: string, entryIds: readonly string[]): void {
  if (entryIds.length === 0) return
  const removeIds = new Set(entryIds)
  const existing = keeperThreads.value[name] ?? []
  const next = existing.filter(entry => !removeIds.has(entry.id))
  if (next.length === existing.length) return
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: next,
  }
}

/** Insert [entry] immediately before the entry with id [beforeId].
 *  Falls back to append when [beforeId] is absent. Used to keep live
 *  tool-call entries above the streaming assistant bubble so the final
 *  reply renders last in the transcript. */
export function insertThreadEntryBefore(
  name: string,
  beforeId: string,
  entry: KeeperConversationEntry,
): void {
  const existing = keeperThreads.value[name] ?? []
  const index = existing.findIndex(e => e.id === beforeId)
  const next =
    index === -1
      ? [...existing, entry]
      : [...existing.slice(0, index), entry, ...existing.slice(index)]
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: next.slice(-THREAD_ENTRY_CAP),
  }
}

export function updateThreadEntry(
  name: string,
  entryId: string,
  updater: (entry: KeeperConversationEntry) => KeeperConversationEntry,
): void {
  const existing = keeperThreads.value[name] ?? []
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: existing.map(entry => (entry.id === entryId ? updater(entry) : entry)),
  }
}

export function setAssistantStreamState(
  name: string,
  entryId: string,
  streamState: KeeperConversationStreamState,
  delivery: KeeperConversationDelivery,
): void {
  updateThreadEntry(name, entryId, entry => ({
    ...entry,
    streamState,
    delivery,
  }))
}

export function appendAssistantDelta(name: string, entryId: string, delta: string): void {
  updateThreadEntry(name, entryId, entry => ({
    ...entry,
    rawText: `${entry.rawText ?? entry.text}${delta}`,
    text: formatKeeperVisibleReply(`${entry.rawText ?? entry.text}${delta}`),
    streamState: 'streaming',
    delivery: 'streaming',
  }))
}

export function finalizeAssistantEntry(
  name: string,
  entryId: string,
  patch: Partial<KeeperConversationEntry>,
): void {
  updateThreadEntry(name, entryId, entry => ({
    ...entry,
    ...patch,
  }))
}

// Dedup key for merging server history with locally-appended entries.
// Compares role + text only: the server stamps a message pair with its
// completion time while the local entry carries the send time, so
// timestamp equality never holds for the same logical message and
// produced duplicate bubbles on every history merge. Source is also
// excluded — REST history has no source field, so the derived source
// can differ from the local one for the same message.
//
// R3 made every history entry carry the producer-assigned server id, so
// render keys are now stable; this optimistic-vs-server dedup still keys
// on role+text because a locally-appended entry is created before the
// server mints its id and so cannot match by id yet. Replacing it with id
// equality needs a send-response id handshake (the POST returning the
// minted id for the optimistic entry to adopt) — tracked as the R3
// follow-up, deliberately out of this change's scope.
function sameConversationEntry(
  left: KeeperConversationEntry,
  right: KeeperConversationEntry,
): boolean {
  return left.role === right.role && left.text === right.text
}

function replaceThread(name: string, entries: KeeperConversationEntry[]): void {
  // An empty history payload means the caller did not request history
  // (e.g. hydrateKeeperStatus fast path with tail_messages: 0), not
  // that the conversation is empty. Wiping previously-hydrated history
  // entries here is what made the transcript vanish after a status
  // refresh / probe / recover.
  if (entries.length === 0) return
  const existing = keeperThreads.value[name] ?? []
  const localEntries = existing.filter(
    entry =>
      entry.delivery !== 'history'
      && !entries.some(historyEntry => sameConversationEntry(entry, historyEntry)),
  )
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: [...entries, ...localEntries].slice(-THREAD_ENTRY_CAP),
  }
}

/** Merge server-fetched chat history (REST `GET /chat/history`) into the
 *  thread. History entries become the canonical prefix; locally-appended
 *  live entries that are not already covered by the server copy are kept
 *  after it. */
export function mergeServerHistoryEntries(
  name: string,
  entries: KeeperConversationEntry[],
): void {
  replaceThread(name, entries)
}

interface RestChatHistoryMessage {
  id?: string
  role: string
  content: string
  ts: number
  tool_call_id?: string
  tool_call_name?: string
  source?: string
  surface?: SurfaceRef
}

/** Convert a persisted tool-call row into the same entry shape the live
 *  TOOL_CALL_* stream path produces (keeper-stream.ts): id `tool-<id>`,
 *  role 'tool', label = tool name, text = accumulated argument JSON.
 *  Matching the live convention means a reload re-renders the tool card
 *  and replaceThread dedups it against a still-mounted live entry. The
 *  raw content is used as-is — formatKeeperVisibleReply is for keeper
 *  reply text and would mangle argument JSON. */
function toolHistoryEntry(message: RestChatHistoryMessage): KeeperConversationEntry | null {
  if (!message.tool_call_id || !message.tool_call_name) return null
  return {
    id: `tool-${message.tool_call_id}`,
    role: 'tool',
    source: 'tool_result',
    label: message.tool_call_name,
    text: message.content,
    rawText: message.content,
    timestamp: toIsoTimestamp(message.ts),
    delivery: 'history',
    streamState: null,
    details: null,
    surface: message.surface ?? null,
  }
}

/** Convert REST chat-history messages ({role, content, ts-seconds}) into
 *  conversation entries, chaining source inference the same way
 *  status-detail history does. */
export function chatHistoryEntriesFromRest(
  keeperName: string,
  messages: RestChatHistoryMessage[],
): KeeperConversationEntry[] {
  let previousSource: KeeperConversationSource | null = null
  const entries: KeeperConversationEntry[] = []
  messages.forEach((message) => {
    if (message.role === 'tool') {
      // Tool rows do not participate in user/assistant source chaining.
      const toolEntry = toolHistoryEntry(message)
      if (toolEntry) entries.push(toolEntry)
      return
    }
    const normalized = normalizeHistoryEntry(
      { id: message.id, role: message.role, content: message.content, ts_unix: message.ts },
      keeperName,
      previousSource,
    )
    if (normalized) {
      previousSource = normalized.source
      entries.push(normalized)
    }
  })
  return entries
}

export function setStatusDetail(name: string, detail: KeeperStatusDetail): void {
  keeperStatusDetails.value = {
    ...keeperStatusDetails.value,
    [name]: detail,
  }
  replaceThread(name, detail.history)
}

// --- Stream controller management ---

export function setActiveStream(name: string, entryId: string, controller: AbortController): void {
  keeperStreamEntryIds.set(name, entryId)
  keeperStreamControllers.set(name, controller)
}

export function clearActiveStream(name: string): void {
  keeperStreamEntryIds.delete(name)
  keeperStreamControllers.delete(name)
}

export function activeStreamEntryId(name: string): string | null {
  return keeperStreamEntryIds.get(name) ?? null
}

export function getStreamController(name: string): AbortController | undefined {
  return keeperStreamControllers.get(name)
}
