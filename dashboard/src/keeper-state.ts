import { signal } from '@preact/signals'
import { formatKeeperVisibleReply } from './keeper-message'
import { isRecord, asString, asNumber, asBoolean, toIsoTimestamp } from './components/common/normalize'
import type {
  Keeper,
  KeeperConversationEntry,
  KeeperConversationRole,
  KeeperConversationStreamState,
  KeeperConversationDelivery,
  KeeperDiagnostic,
  KeeperProbeResult,
  KeeperRecoverResult,
  KeeperStatusDetail,
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
      return 'User'
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

// --- Diagnostic helpers ---

function classifyKeeperErrorKind(errorText: string): KeeperDiagnostic['quiet_reason'] {
  const lowered = errorText.toLowerCase()
  if (lowered.includes('graphql')) return 'graphql_error'
  if (
    lowered.includes('timeout')
    || lowered.includes('model')
    || lowered.includes('api key')
    || lowered.includes('api_key')
    || lowered.includes('provider')
  ) {
    return 'model_error'
  }
  return 'unknown'
}

function quietReasonSummary(healthState: KeeperDiagnostic['health_state'], quietReason: KeeperDiagnostic['quiet_reason']): string {
  if (healthState === 'offline' || healthState === 'degraded' || healthState === 'stale') {
    return 'Keeper is not in a healthy reply state. Probe or recover before relying on automation.'
  }
  if (quietReason === 'quiet_hours') {
    return 'Social quiet hours are active. Direct messages still work, but scheduled public-square reactions may look asleep.'
  }
  if (quietReason === 'min_gap') {
    return 'Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.'
  }
  if (quietReason === 'never_started') {
    return 'Keeper metadata exists but no reply turn has been recorded yet.'
  }
  return 'Keeper is reachable. Send a direct message for an immediate response.'
}

function diagnosticSummary(rawSummary: unknown, healthState: KeeperDiagnostic['health_state'], quietReason: KeeperDiagnostic['quiet_reason']): string {
  return asString(rawSummary) ?? quietReasonSummary(healthState, quietReason)
}

function diagnosticRecoverable(rawRecoverable: unknown, nextActionPath: KeeperDiagnostic['next_action_path']): boolean {
  if (typeof rawRecoverable === 'boolean') return rawRecoverable
  return nextActionPath === 'recover'
}

// --- Normalizers ---

export function normalizeKeeperDiagnostic(raw: unknown): KeeperDiagnostic | null {
  if (!isRecord(raw)) return null
  const healthState = asString(raw.health_state)
  const nextActionPath = asString(raw.next_action_path)
  const lastReplyStatus = asString(raw.last_reply_status)
  if (!healthState || !nextActionPath || !lastReplyStatus) return null
  return {
    health_state: healthState as KeeperDiagnostic['health_state'],
    quiet_reason: (asString(raw.quiet_reason) ?? null) as KeeperDiagnostic['quiet_reason'],
    next_action_path: nextActionPath as KeeperDiagnostic['next_action_path'],
    last_reply_status: lastReplyStatus as KeeperDiagnostic['last_reply_status'],
    last_reply_at: toIsoTimestamp(raw.last_reply_at) ?? null, // undefined->null: field is string|null
    last_reply_preview: asString(raw.last_reply_preview) ?? null,
    last_error: asString(raw.last_error) ?? null,
    next_eligible_at_s: asNumber(raw.next_eligible_at_s) ?? null,
    recoverable: diagnosticRecoverable(raw.recoverable, nextActionPath as KeeperDiagnostic['next_action_path']),
    summary: diagnosticSummary(raw.summary, healthState as KeeperDiagnostic['health_state'], (asString(raw.quiet_reason) ?? null) as KeeperDiagnostic['quiet_reason']),
    keepalive_running: typeof raw.keepalive_running === 'boolean' ? raw.keepalive_running : undefined,
    continuity_state:
      (asString(raw.continuity_state) ?? null) as KeeperDiagnostic['continuity_state'],
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

export function deriveKeeperDiagnostic(
  keeper: Partial<Keeper> | null | undefined,
): KeeperDiagnostic | null {
  if (!keeper?.name) return null

  const agentStatus = asString(keeper.agent?.status) ?? asString(keeper.status) ?? 'unknown'
  const agentError = asString(keeper.agent?.error) ?? null
  const keepaliveExpected = keeper.presence_keepalive ?? true
  const keepaliveRunning = keeper.keepalive_running ?? false
  const totalTurns = keeper.turn_count ?? 0
  const lastTurnAgo = keeper.last_turn_ago_s ?? null
  const proactiveEnabled = keeper.proactive_enabled ?? false
  const proactiveCooldownSec = keeper.proactive_cooldown_sec ?? 0
  const lastProactiveAgo = keeper.last_proactive_ago_s ?? null
  const nextEligibleAtS =
    proactiveEnabled && lastProactiveAgo != null
      ? Math.max(0, proactiveCooldownSec - lastProactiveAgo)
      : null

  const lastReplyStatus: KeeperDiagnostic['last_reply_status'] =
    totalTurns <= 0 || lastTurnAgo == null ? 'never' : lastTurnAgo > 900 ? 'stale' : 'fresh'

  const lastReplyAt = (() => {
    if (typeof keeper.last_heartbeat === 'string' && keeper.last_heartbeat.trim()) return keeper.last_heartbeat
    return null
  })()

  const lastError =
    agentError
    ?? (keepaliveExpected && !keepaliveRunning ? 'keeper keepalive is not running' : null)

  const healthState: KeeperDiagnostic['health_state'] =
    agentStatus === 'offline' || agentStatus === 'inactive'
      ? 'offline'
      : lastError
        ? 'degraded'
        : lastReplyStatus === 'stale'
          ? 'stale'
          : lastReplyStatus === 'never'
            ? 'idle'
            : 'healthy'

  const quietReason: KeeperDiagnostic['quiet_reason'] =
    lastError
      ? classifyKeeperErrorKind(lastError)
      : keepaliveExpected && !keepaliveRunning
        ? 'disabled'
        : totalTurns <= 0
          ? 'never_started'
          : nextEligibleAtS != null && nextEligibleAtS > 0
            ? 'min_gap'
            : lastReplyStatus === 'fresh' || lastReplyStatus === 'stale'
              ? 'no_recent_activity'
              : 'unknown'

  const nextActionPath: KeeperDiagnostic['next_action_path'] =
    healthState === 'offline' || healthState === 'degraded' || healthState === 'stale'
      ? 'recover'
      : quietReason === 'quiet_hours'
        ? 'manual_social_sweep'
        : quietReason === 'unknown'
          ? 'probe'
          : 'direct_message'

  return {
    health_state: healthState,
    quiet_reason: quietReason,
    next_action_path: nextActionPath,
    last_reply_status: lastReplyStatus,
    last_reply_at: lastReplyAt,
    last_reply_preview: null,
    last_error: lastError,
    next_eligible_at_s: nextEligibleAtS != null && nextEligibleAtS > 0 ? nextEligibleAtS : null,
    recoverable: diagnosticRecoverable(undefined, nextActionPath),
    summary: diagnosticSummary(undefined, healthState, quietReason),
    keepalive_running: keepaliveRunning,
  }
}

// --- Thread state management ---

function normalizeHistoryEntry(raw: unknown, index: number, keeperName?: string): KeeperConversationEntry | null {
  if (!isRecord(raw)) return null
  const role = normalizeRole(raw.role)
  const rawText = asString(raw.content) ?? asString(raw.preview)
  if (!rawText) return null
  const text = formatKeeperVisibleReply(rawText)
  if (!text) return null
  const timestamp = toIsoTimestamp(raw.ts_unix) ?? toIsoTimestamp(raw.timestamp)
  const label = role === 'assistant' && keeperName ? keeperName : roleLabel(role)
  return {
    id: `${role}-${timestamp ?? 'entry'}-${index}`,
    role,
    label,
    text,
    rawText,
    timestamp,
    delivery: 'history',
    streamState: null,
    details: null,
  }
}

function normalizeStatusDetail(name: string, text: string, rawStatus: unknown): KeeperStatusDetail {
  const parsed = isRecord(rawStatus) ? rawStatus : null
  const history = Array.isArray(parsed?.history_tail)
    ? parsed.history_tail
      .map((entry, index) => normalizeHistoryEntry(entry, index, name))
      .filter((entry): entry is KeeperConversationEntry => entry !== null)
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
    [name]: [...existing, entry].slice(-50),
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

function sameConversationEntry(
  left: KeeperConversationEntry,
  right: KeeperConversationEntry,
): boolean {
  if (left.role !== right.role || left.text !== right.text) return false
  if (left.timestamp && right.timestamp) return left.timestamp === right.timestamp
  return true
}

function replaceThread(name: string, entries: KeeperConversationEntry[]): void {
  const existing = keeperThreads.value[name] ?? []
  const localEntries = existing.filter(
    entry =>
      entry.delivery !== 'history'
      && !entries.some(historyEntry => sameConversationEntry(entry, historyEntry)),
  )
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: [...entries, ...localEntries].slice(-50),
  }
}

export function setStatusDetail(name: string, detail: KeeperStatusDetail): void {
  keeperStatusDetails.value = {
    ...keeperStatusDetails.value,
    [name]: detail,
  }
  replaceThread(name, detail.history)
}

export function updateDiagnostic(name: string, patch: Partial<KeeperDiagnostic>): void {
  const existing = keeperStatusDetails.value[name]
  if (!existing) return
  const current = existing.diagnostic ?? {
    health_state: 'idle',
    next_action_path: 'direct_message',
    last_reply_status: 'unknown',
  }
  setStatusDetail(name, {
    ...existing,
    diagnostic: {
      ...current,
      ...patch,
    },
  })
}

export { normalizeStatusDetail }

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
