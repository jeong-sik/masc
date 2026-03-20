import { signal } from '@preact/signals'
import {
  callMcpTool,
  runOperatorAction,
  sendKeeperMessageDetailed,
  streamKeeperMessage,
  type KeeperChatStreamEvent,
} from './api'
import { formatKeeperVisibleReply, normalizeKeeperConversationDetails } from './keeper-message'
import type {
  Keeper,
  KeeperConversationDelivery,
  KeeperConversationEntry,
  KeeperConversationStreamState,
  KeeperConversationRole,
  KeeperDiagnostic,
  KeeperProbeResult,
  KeeperRecoverResult,
  KeeperStatusDetail,
} from './types'
import { invalidateDashboardCache, refreshDashboard } from './store'
import { isRecord, asString, asNumber, asBoolean, toIsoTimestamp } from './components/common/normalize'

export const activeKeeperName = signal('')
export const keeperStatusDetails = signal<Record<string, KeeperStatusDetail>>({})
export const keeperThreads = signal<Record<string, KeeperConversationEntry[]>>({})
export const keeperHydrating = signal<Record<string, boolean>>({})
export const keeperSending = signal<Record<string, boolean>>({})
export const keeperProbing = signal<Record<string, boolean>>({})
export const keeperRecovering = signal<Record<string, boolean>>({})
export const keeperActionErrors = signal<Record<string, string | null>>({})
export const keeperStreamStartedAt = signal<Record<string, number | null>>({})

const keeperStreamControllers = new Map<string, AbortController>()
const keeperStreamEntryIds = new Map<string, string>()

function setRecordValue<T>(state: typeof keeperThreads | typeof keeperHydrating | typeof keeperSending | typeof keeperProbing | typeof keeperRecovering | typeof keeperActionErrors | typeof keeperStreamStartedAt, key: string, value: T): void {
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
    last_reply_at: toIsoTimestamp(raw.last_reply_at) ?? null, // undefined→null: field is string|null
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

function normalizeHistoryEntry(raw: unknown, index: number): KeeperConversationEntry | null {
  if (!isRecord(raw)) return null
  const role = normalizeRole(raw.role)
  const rawText = asString(raw.content) ?? asString(raw.preview)
  if (!rawText) return null
  const text = formatKeeperVisibleReply(rawText)
  if (!text) return null
  const timestamp = toIsoTimestamp(raw.ts_unix) ?? toIsoTimestamp(raw.timestamp)
  return {
    id: `${role}-${timestamp ?? 'entry'}-${index}`,
    role,
    label: roleLabel(role),
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
      .map((entry, index) => normalizeHistoryEntry(entry, index))
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

function appendThreadEntry(name: string, entry: KeeperConversationEntry): void {
  const existing = keeperThreads.value[name] ?? []
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: [...existing, entry].slice(-50),
  }
}

function updateThreadEntry(
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

function setAssistantStreamState(
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

function appendAssistantDelta(name: string, entryId: string, delta: string): void {
  updateThreadEntry(name, entryId, entry => ({
    ...entry,
    rawText: `${entry.rawText ?? entry.text}${delta}`,
    text: formatKeeperVisibleReply(`${entry.rawText ?? entry.text}${delta}`),
    streamState: 'streaming',
    delivery: 'streaming',
  }))
}

function finalizeAssistantEntry(
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

function setStatusDetail(name: string, detail: KeeperStatusDetail): void {
  keeperStatusDetails.value = {
    ...keeperStatusDetails.value,
    [name]: detail,
  }
  replaceThread(name, detail.history)
}

function updateDiagnostic(name: string, patch: Partial<KeeperDiagnostic>): void {
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

function setActiveStream(name: string, entryId: string, controller: AbortController): void {
  keeperStreamEntryIds.set(name, entryId)
  keeperStreamControllers.set(name, controller)
}

function clearActiveStream(name: string): void {
  keeperStreamEntryIds.delete(name)
  keeperStreamControllers.delete(name)
}

function activeStreamEntryId(name: string): string | null {
  return keeperStreamEntryIds.get(name) ?? null
}

export function abortKeeperThreadMessage(name: string): void {
  const keeperName = name.trim()
  if (!keeperName) return
  const controller = keeperStreamControllers.get(keeperName)
  const entryId = activeStreamEntryId(keeperName)
  if (controller) controller.abort()
  if (entryId) {
    finalizeAssistantEntry(keeperName, entryId, {
      delivery: 'timeout',
      streamState: null,
      error: 'Stream cancelled',
      timestamp: new Date().toISOString(),
    })
  }
  clearActiveStream(keeperName)
  setRecordValue(keeperSending, keeperName, false)
  setRecordValue(keeperStreamStartedAt, keeperName, null)
}

function applyKeeperStreamEvent(
  keeperName: string,
  assistantEntryId: string,
  event: KeeperChatStreamEvent,
): string | null {
  switch (event.type) {
    case 'RUN_STARTED':
      setAssistantStreamState(keeperName, assistantEntryId, 'opening', 'sending')
      return null
    case 'TEXT_MESSAGE_START':
      setAssistantStreamState(keeperName, assistantEntryId, 'streaming', 'streaming')
      return null
    case 'TEXT_MESSAGE_CONTENT': {
      const delta = typeof event.delta === 'string' ? event.delta : ''
      if (delta) appendAssistantDelta(keeperName, assistantEntryId, delta)
      return null
    }
    case 'TEXT_MESSAGE_END':
      setAssistantStreamState(keeperName, assistantEntryId, 'finalizing', 'streaming')
      return null
    case 'CUSTOM':
      if (event.name === 'KEEPER_REPLY_DETAILS') {
        const details = normalizeKeeperConversationDetails(event.value)
        if (details) {
          updateThreadEntry(keeperName, assistantEntryId, entry => {
            const rawText = details.replyText ?? entry.rawText ?? entry.text
            const text = formatKeeperVisibleReply(rawText)
            return {
              ...entry,
              details,
              rawText,
              text,
            }
          })
        }
      }
      return null
    case 'RUN_ERROR':
      return typeof event.value === 'string'
        ? event.value
        : (isRecord(event.value) ? asString(event.value.message) : null) ?? 'Keeper stream failed'
    default:
      return null
  }
}

async function refreshDashboardState(): Promise<void> {
  invalidateDashboardCache()
  try {
    await refreshDashboard()
  } catch (err) {
    console.warn('[keeper-runtime] dashboard refresh failed', err)
  }
}

export function selectKeeper(name: string): void {
  activeKeeperName.value = name.trim()
}

export async function hydrateKeeperStatus(name: string, force = false): Promise<KeeperStatusDetail | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  if (!force && keeperStatusDetails.value[keeperName]) return keeperStatusDetails.value[keeperName]
  setRecordValue(keeperHydrating, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const text = await callMcpTool('masc_keeper_status', {
      name: keeperName,
      fast: false,
      include_context: true,
      include_metrics_overview: true,
      include_memory_bank: false,
      include_history_tail: true,
      include_compaction_history: false,
      tail_turns: 5,
      tail_messages: 10,
    })
    let parsed: unknown = null
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }
    const detail = normalizeStatusDetail(keeperName, text, parsed)
    setStatusDetail(keeperName, detail)
    return detail
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to inspect ${keeperName}`
    setRecordValue(keeperActionErrors, keeperName, message)
    return null
  } finally {
    setRecordValue(keeperHydrating, keeperName, false)
  }
}

export async function sendKeeperThreadMessage(name: string, prompt: string): Promise<void> {
  const keeperName = name.trim()
  const message = prompt.trim()
  if (!keeperName || !message) return
  abortKeeperThreadMessage(keeperName)
  const localId = `local-${Date.now()}`
  const assistantId = `reply-${Date.now()}`
  appendThreadEntry(keeperName, {
    id: localId,
    role: 'user',
    label: 'You',
    text: message,
    timestamp: new Date().toISOString(),
    delivery: 'sending',
    streamState: null,
    details: null,
  })
  appendThreadEntry(keeperName, {
    id: assistantId,
    role: 'assistant',
    label: keeperName,
    text: '',
    rawText: '',
    timestamp: null,
    delivery: 'sending',
    streamState: 'opening',
    details: null,
  })
  setRecordValue(keeperSending, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  setRecordValue(keeperStreamStartedAt, keeperName, Date.now())
  const controller = new AbortController()
  setActiveStream(keeperName, assistantId, controller)
  let idleTimeoutId: ReturnType<typeof setInterval> | null = null
  try {
    finalizeAssistantEntry(keeperName, localId, { delivery: 'delivered' })

    let lastEventAt = Date.now()
    idleTimeoutId = setInterval(() => {
      if (Date.now() - lastEventAt > 120_000) {
        if (idleTimeoutId != null) clearInterval(idleTimeoutId)
        idleTimeoutId = null
        abortKeeperThreadMessage(keeperName)
      }
    }, 5_000)

    await streamKeeperMessage(keeperName, message, undefined, {
      signal: controller.signal,
      onEvent: event => {
        lastEventAt = Date.now()
        const error = applyKeeperStreamEvent(keeperName, assistantId, event)
        if (error) {
          throw new Error(error)
        }
      },
    })

    const finalEntry =
      (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantId) ?? null
    const finalText = finalEntry?.text.trim() || '(empty reply)'

    finalizeAssistantEntry(keeperName, assistantId, {
      text: finalText,
      delivery: 'delivered',
      streamState: null,
      timestamp: new Date().toISOString(),
      error: null,
    })
    updateDiagnostic(keeperName, {
      last_reply_status: 'delivered',
      last_reply_at: new Date().toISOString(),
      last_reply_preview: finalText.slice(0, 200),
      last_error: null,
    })
  } catch (err) {
    const isAbort =
      err instanceof Error && err.name === 'AbortError'
    if (isAbort) {
      finalizeAssistantEntry(keeperName, assistantId, {
        delivery: 'timeout',
        streamState: null,
        error: 'Stream cancelled',
        timestamp: new Date().toISOString(),
      })
      updateDiagnostic(keeperName, {
        last_reply_status: 'error',
        last_error: 'Stream cancelled',
      })
      setRecordValue(keeperActionErrors, keeperName, 'Stream cancelled')
      throw err
    }

    const fallbackAllowed =
      !((keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantId)?.text.trim())

    if (fallbackAllowed) {
      try {
        const reply = await sendKeeperMessageDetailed(keeperName, message)
        finalizeAssistantEntry(keeperName, assistantId, {
          text: reply.text.trim() || '(empty reply)',
          rawText: reply.details?.replyText ?? (reply.text.trim() || '(empty reply)'),
          delivery: 'delivered',
          streamState: null,
          details: reply.details,
          error: null,
          timestamp: new Date().toISOString(),
        })
        finalizeAssistantEntry(keeperName, localId, { delivery: 'delivered', error: null })
        updateDiagnostic(keeperName, {
          last_reply_status: 'delivered',
          last_reply_at: new Date().toISOString(),
          last_reply_preview: (reply.text.trim() || '(empty reply)').slice(0, 200),
          last_error: null,
        })
        await refreshDashboardState()
        return
      } catch {
        // Fall through to the shared error path below.
      }
    }

    const errorMessage =
      err instanceof Error ? err.message : `Failed to send direct message to ${keeperName}`
    finalizeAssistantEntry(keeperName, assistantId, {
      delivery: 'error' as KeeperConversationDelivery,
      streamState: null,
      error: errorMessage,
      timestamp: new Date().toISOString(),
    })
    finalizeAssistantEntry(keeperName, localId, {
      delivery: 'error' as KeeperConversationDelivery,
      error: errorMessage,
    })
    updateDiagnostic(keeperName, {
      last_reply_status: 'error',
      last_error: errorMessage,
    })
    setRecordValue(keeperActionErrors, keeperName, errorMessage)
    throw err
  } finally {
    if (idleTimeoutId != null) clearInterval(idleTimeoutId)
    clearActiveStream(keeperName)
    setRecordValue(keeperSending, keeperName, false)
    setRecordValue(keeperStreamStartedAt, keeperName, null)
    await refreshDashboardState()
  }
}

export async function probeKeeperRuntime(name: string, actor: string): Promise<KeeperDiagnostic | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  setRecordValue(keeperProbing, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: keeperName,
      payload: {},
    })
    const result = normalizeKeeperProbeResult(response.result)
    const diagnostic = result?.diagnostic ?? null
    if (diagnostic) {
      const existing = keeperStatusDetails.value[keeperName]
      setStatusDetail(keeperName, {
        name: keeperName,
        diagnostic,
        history: existing?.history ?? keeperThreads.value[keeperName] ?? [],
        rawText: existing?.rawText ?? '',
        rawStatus: response.result,
        loadedAt: new Date().toISOString(),
      })
    }
    await refreshDashboardState()
    return diagnostic
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to probe ${keeperName}`
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperProbing, keeperName, false)
  }
}

export async function recoverKeeperRuntime(name: string, actor: string): Promise<KeeperDiagnostic | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  setRecordValue(keeperRecovering, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'keeper_recover',
      target_type: 'keeper',
      target_id: keeperName,
      payload: {},
    })
    const result = normalizeKeeperRecoverResult(response.result)
    const after = result?.after ?? null
    if (after) {
      const existing = keeperStatusDetails.value[keeperName]
      setStatusDetail(keeperName, {
        name: keeperName,
        diagnostic: after,
        history: existing?.history ?? keeperThreads.value[keeperName] ?? [],
        rawText: existing?.rawText ?? '',
        rawStatus: response.result,
        loadedAt: new Date().toISOString(),
      })
    }
    await refreshDashboardState()
    return after
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to recover ${keeperName}`
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperRecovering, keeperName, false)
  }
}
