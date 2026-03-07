import { signal } from '@preact/signals'
import { callMcpTool, runOperatorAction, sendKeeperMessage } from './api'
import type {
  Keeper,
  KeeperConversationDelivery,
  KeeperConversationEntry,
  KeeperConversationRole,
  KeeperDiagnostic,
  KeeperProbeResult,
  KeeperRecoverResult,
  KeeperStatusDetail,
  LodgeCheckinResult,
  LodgeRuntimeStatus,
  LodgeTickResult,
} from './types'
import { invalidateDashboardCache, refreshDashboard } from './store'

export const activeKeeperName = signal('')
export const keeperStatusDetails = signal<Record<string, KeeperStatusDetail>>({})
export const keeperThreads = signal<Record<string, KeeperConversationEntry[]>>({})
export const keeperHydrating = signal<Record<string, boolean>>({})
export const keeperSending = signal<Record<string, boolean>>({})
export const keeperProbing = signal<Record<string, boolean>>({})
export const keeperRecovering = signal<Record<string, boolean>>({})
export const keeperActionErrors = signal<Record<string, string | null>>({})

function setRecordValue<T>(state: typeof keeperThreads | typeof keeperHydrating | typeof keeperSending | typeof keeperProbing | typeof keeperRecovering | typeof keeperActionErrors, key: string, value: T): void {
  state.value = {
    ...state.value,
    [key]: value,
  } as typeof state.value
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined
}

function toIsoTimestamp(value: unknown): string | null {
  if (typeof value === 'string' && value.trim() !== '') return value
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return null
  return new Date(value * 1000).toISOString()
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => asString(item))
    .filter((item): item is string => Boolean(item))
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

function normalizeNameRows(raw: unknown, key: 'summary' | 'reason'): Array<{ name: string; summary?: string; reason?: string }> {
  if (!Array.isArray(raw)) return []
  const rows: Array<{ name: string; summary?: string; reason?: string }> = []
  for (const item of raw) {
    if (!isRecord(item)) continue
    const name = asString(item.name)
    if (!name) continue
    const detail = asString(item[key])
    if (key === 'summary') rows.push({ name, summary: detail })
    else rows.push({ name, reason: detail })
  }
  return rows
}

function normalizeCheckin(raw: unknown): LodgeCheckinResult | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    trigger: asString(raw.trigger),
    outcome: asString(raw.outcome),
    summary: asString(raw.summary),
    reason: asString(raw.reason),
  }
}

function classifyKeeperErrorKind(errorText: string): KeeperDiagnostic['quiet_reason'] {
  const lowered = errorText.toLowerCase()
  if (lowered.includes('graphql')) return 'graphql_error'
  if (
    lowered.includes('timeout')
    || lowered.includes('model')
    || lowered.includes('llm')
    || lowered.includes('api key')
    || lowered.includes('api_key')
    || lowered.includes('provider')
  ) {
    return 'llm_error'
  }
  return 'unknown'
}

function quietReasonSummary(healthState: KeeperDiagnostic['health_state'], quietReason: KeeperDiagnostic['quiet_reason']): string {
  if (healthState === 'offline' || healthState === 'degraded' || healthState === 'stale') {
    return 'Keeper is not in a healthy reply state. Probe or recover before relying on automation.'
  }
  if (quietReason === 'quiet_hours') {
    return 'Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.'
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
    last_reply_at: toIsoTimestamp(raw.last_reply_at),
    last_reply_preview: asString(raw.last_reply_preview) ?? null,
    last_error: asString(raw.last_error) ?? null,
    next_eligible_at_s: asNumber(raw.next_eligible_at_s) ?? null,
    recoverable: diagnosticRecoverable(raw.recoverable, nextActionPath as KeeperDiagnostic['next_action_path']),
    summary: diagnosticSummary(raw.summary, healthState as KeeperDiagnostic['health_state'], (asString(raw.quiet_reason) ?? null) as KeeperDiagnostic['quiet_reason']),
    keepalive_running: typeof raw.keepalive_running === 'boolean' ? raw.keepalive_running : undefined,
  }
}

export function normalizeLodgeTickResult(raw: unknown): LodgeTickResult | null {
  if (!isRecord(raw)) return null
  return {
    hour: asNumber(raw.hour),
    checked: asNumber(raw.checked) ?? 0,
    acted: asNumber(raw.acted) ?? 0,
    acted_names: asStringArray(raw.acted_names),
    activity_report: asString(raw.activity_report),
    quiet_hours_overridden: asBoolean(raw.quiet_hours_overridden),
    skipped_reason: asString(raw.skipped_reason),
    acted_rows: normalizeNameRows(raw.acted_rows, 'summary').map(row => ({ name: row.name, summary: row.summary })),
    passed_rows: normalizeNameRows(raw.passed_rows, 'reason').map(row => ({ name: row.name, reason: row.reason })),
    skipped_rows: normalizeNameRows(raw.skipped_rows, 'reason').map(row => ({ name: row.name, reason: row.reason })),
    checkins: Array.isArray(raw.checkins)
      ? raw.checkins.map(normalizeCheckin).filter((row): row is LodgeCheckinResult => row !== null)
      : [],
  }
}

export function normalizeLodgeRuntimeStatus(raw: unknown): LodgeRuntimeStatus | null {
  if (!isRecord(raw)) return null
  return {
    enabled: asBoolean(raw.enabled) ?? false,
    interval_s: asNumber(raw.interval_s) ?? 0,
    quiet_start: asNumber(raw.quiet_start),
    quiet_end: asNumber(raw.quiet_end),
    quiet_active: asBoolean(raw.quiet_active),
    use_planner: asBoolean(raw.use_planner),
    delegate_llm: asBoolean(raw.delegate_llm),
    agent_count: asNumber(raw.agent_count),
    agents: asStringArray(raw.agents),
    last_tick_ago_s: asNumber(raw.last_tick_ago_s) ?? null,
    last_tick_ago: asString(raw.last_tick_ago),
    total_ticks: asNumber(raw.total_ticks),
    total_checkins: asNumber(raw.total_checkins),
    last_skip_reason: asString(raw.last_skip_reason) ?? null,
    last_tick_result: normalizeLodgeTickResult(raw.last_tick_result),
    active_self_heartbeats: asStringArray(raw.active_self_heartbeats),
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
  lodge: LodgeRuntimeStatus | null | undefined,
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
      : lodge?.quiet_active && lastReplyStatus !== 'fresh'
        ? 'quiet_hours'
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
        ? 'manual_lodge_poke'
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
  const text = asString(raw.content) ?? asString(raw.preview)
  if (!text) return null
  const timestamp = toIsoTimestamp(raw.ts_unix) ?? toIsoTimestamp(raw.timestamp)
  return {
    id: `${role}-${timestamp ?? 'entry'}-${index}`,
    role,
    label: roleLabel(role),
    text,
    timestamp,
    delivery: 'history',
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
  const localId = `local-${Date.now()}`
  appendThreadEntry(keeperName, {
    id: localId,
    role: 'user',
    label: 'You',
    text: message,
    timestamp: new Date().toISOString(),
    delivery: 'sending',
  })
  setRecordValue(keeperSending, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const reply = await sendKeeperMessage(keeperName, message)
    keeperThreads.value = {
      ...keeperThreads.value,
      [keeperName]: (keeperThreads.value[keeperName] ?? []).map(entry =>
        entry.id === localId ? { ...entry, delivery: 'delivered' } : entry
      ),
    }
    appendThreadEntry(keeperName, {
      id: `reply-${Date.now()}`,
      role: 'assistant',
      label: keeperName,
      text: reply.trim() || '(empty reply)',
      timestamp: new Date().toISOString(),
      delivery: 'delivered',
    })
    updateDiagnostic(keeperName, {
      last_reply_status: 'delivered',
      last_reply_at: new Date().toISOString(),
      last_reply_preview: (reply.trim() || '(empty reply)').slice(0, 200),
      last_error: null,
    })
    await refreshDashboardState()
  } catch (err) {
    const message =
      err instanceof Error ? err.message : `Failed to send direct message to ${keeperName}`
    keeperThreads.value = {
      ...keeperThreads.value,
      [keeperName]: (keeperThreads.value[keeperName] ?? []).map(entry =>
        entry.id === localId
          ? { ...entry, delivery: 'error' as KeeperConversationDelivery, error: message }
          : entry
      ),
    }
    updateDiagnostic(keeperName, {
      last_reply_status: 'error',
      last_error: message,
    })
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperSending, keeperName, false)
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
