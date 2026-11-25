/**
 * Mode-Aware Shared Observer SSE Client & Honest View Provenance Signal.
 *
 * - `multi_account`: connects to `GET /api/v1/auth/events` with `credentials: 'same-origin'`
 *   (zero query-string token, zero Bearer header).
 * - `single_user`: connects to `GET /mcp?sse_kind=observer` with Bearer header (when set).
 * - Handles `Last-Event-ID` tracking and explicit `observer_resync_required` (`STREAM_GAP`)
 *   frames by marking `viewProvenance` honestly and notifying resync subscribers.
 * - Exposes honest provenance state: `'LIVE SSE' | 'SYNCED' | 'SNAPSHOT' | 'STREAM_GAP'`.
 */

import { signal, type ReadonlySignal } from '@preact/signals'
import {
  authSession,
  currentSessionEpoch,
  getSingleUserToken,
  isEpochCurrent,
  resolveWorkspaceUrl,
  sessionEpoch,
  type AuthSession,
} from './auth'
import { resourceCache } from './resource-cache'

export type ViewProvenance = 'LIVE SSE' | 'SYNCED' | 'SNAPSHOT' | 'STREAM_GAP'

export interface ObserverFrame {
  readonly id: string | null
  readonly event: string
  readonly data: unknown
  readonly raw: string
}

export type ObserverListener = (frame: ObserverFrame) => void
export type ResyncListener = (reason: string) => void
export type ReconnectListener = () => void

export const OBSERVER_SSE_INSTANCE_HEADER = 'x-masc-sse-instance-id'

const provenanceSignal = signal<ViewProvenance>('SNAPSHOT')
const connectedSignal = signal<boolean>(false)
const lastEventIdSignal = signal<string | null>(null)
const sseInstanceIdSignal = signal<string | null>(null)

export const viewProvenance: ReadonlySignal<ViewProvenance> = provenanceSignal
export const observerConnected: ReadonlySignal<boolean> = connectedSignal
export const observerLastEventId: ReadonlySignal<string | null> = lastEventIdSignal
export const observerSseInstanceId: ReadonlySignal<string | null> = sseInstanceIdSignal

const frameListeners = new Set<ObserverListener>()
const resyncListeners = new Set<ResyncListener>()
const reconnectListeners = new Set<ReconnectListener>()

let activeController: AbortController | null = null
let activeEpoch = 0
let sseInstanceIdEpoch = 0
let trackedInstanceEpoch = sessionEpoch.peek()
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let reconnectAttempt = 0

const DEFAULT_RECONNECT_BASE_MS = 1_000
const MAX_RECONNECT_DELAY_MS = 30_000

const SERVER_TOPIC_ALIASES: Readonly<Record<string, readonly string[]>> = {
  keeper_row_changed: ['keeper', 'keeper_lifecycle', 'shell'],
  keeper_roster_changed: ['keeper', 'keeper_lifecycle', 'shell'],
  // Preview frames carry one Owner's observation. A lifecycle change invalidates the Fleet slots.
  keeper_turn_changed: ['keeper', 'keeper_turn', 'shell'],
  keeper_turn_complete: ['keeper', 'keeper_turn', 'cost', 'shell'],
  keeper_turns: ['keeper', 'keeper_turn', 'cost', 'shell'],
  keeper_memory_health: ['keeper', 'memory'],
  keeper_waiting_inventory_changed: ['keeper', 'keeper_turn', 'tool_approval', 'approval'],
  keeper_tool_approval_waits_changed: ['tool_approval', 'approval', 'keeper_turn'],
  keeper_tool_approval_mode_changed: ['keeper', 'tool_approval', 'approval'],
  keeper_asks_changed: ['keeper_ask', 'ask'],
  'approval:pending': ['approval', 'tool_approval', 'gate'],
  'approval:resolved': ['approval', 'tool_approval', 'gate'],
  'approval:summary_updated': ['approval', 'tool_approval', 'gate'],
  pending_confirms_changed: ['goal', 'goals', 'approval'],
  schedule_store_changed: ['schedules', 'task', 'tasks'],
  scheduled_automation_changed: ['schedules', 'task', 'tasks'],
  scheduled_automation: ['schedules', 'task', 'tasks'],
  goal_projection_changed: ['goal', 'goals', 'task', 'tasks', 'shell'],
  provider_standing: ['provider', 'quota', 'keeper'],
  provider_usage: ['provider', 'quota'],
  verification_requests: ['verification', 'goal', 'goals', 'task', 'tasks'],
  board: ['board', 'board_post', 'board_comment'],
  board_changed: ['board', 'board_post', 'board_comment'],
  'notifications/board': ['board', 'board_post', 'board_comment'],
  board_post: ['board', 'board_post'],
  board_comment: ['board', 'board_comment'],
  gate: ['gate', 'approval'],
  channel_gate: ['gate', 'approval'],
  memory: ['memory', 'world_memory'],
  world_memory: ['memory', 'world_memory'],
  workspace_memory: ['memory', 'world_memory'],
  candle: ['candle'],
  candle_ledger: ['candle'],
  backlog: ['task', 'tasks', 'goal', 'goals', 'shell'],
  tasks: ['task', 'tasks', 'shell'],
  goals: ['goal', 'goals', 'shell'],
  keepers: ['keeper', 'keeper_lifecycle', 'shell'],
  schedules: ['schedules', 'task', 'tasks'],
}

sessionEpoch.subscribe((epoch) => {
  if (epoch !== trackedInstanceEpoch) {
    trackedInstanceEpoch = epoch
    clearReconnectTimer()
    reconnectAttempt = 0
    lastEventIdSignal.value = null
    sseInstanceIdSignal.value = null
    sseInstanceIdEpoch = 0
  }
})

export function getObserverSseInstanceId(): string | null {
  const id = sseInstanceIdSignal.peek()
  if (!id || sseInstanceIdEpoch !== currentSessionEpoch()) return null
  return id
}

export function setObserverSseInstanceId(id: string | null): void {
  const cleaned = typeof id === 'string' && id.trim().length > 0 ? id.trim() : null
  sseInstanceIdSignal.value = cleaned
  sseInstanceIdEpoch = cleaned ? currentSessionEpoch() : 0
}

export function resolveObserverEndpoint(session: AuthSession): {
  readonly url: string
  readonly headers: Record<string, string>
} | null {
  if (session.kind === 'multi_account_signed_in') {
    return {
      url: resolveWorkspaceUrl('/api/v1/auth/events'),
      headers: { Accept: 'text/event-stream' },
    }
  }
  if (session.kind === 'single_user_local') {
    const headers: Record<string, string> = { Accept: 'text/event-stream' }
    const token = getSingleUserToken()
    if (token) headers.Authorization = `Bearer ${token}`
    return {
      url: resolveWorkspaceUrl('/mcp?sse_kind=observer'),
      headers,
    }
  }
  return null
}

export function markViewSynced(): void {
  if (connectedSignal.peek()) {
    provenanceSignal.value = 'LIVE SSE'
  } else if (provenanceSignal.peek() !== 'STREAM_GAP') {
    provenanceSignal.value = 'SYNCED'
  }
}

export function markViewSnapshot(): void {
  if (!connectedSignal.peek()) {
    provenanceSignal.value = 'SNAPSHOT'
  }
}

export function markStreamGap(reason: string): void {
  provenanceSignal.value = 'STREAM_GAP'
  for (const listener of [...resyncListeners]) {
    try { listener(reason) } catch { /* isolate listener */ }
  }
}

export function subscribeObserverFrames(listener: ObserverListener): () => void {
  frameListeners.add(listener)
  return () => { frameListeners.delete(listener) }
}

export function subscribeObserverResync(listener: ResyncListener): () => void {
  resyncListeners.add(listener)
  return () => { resyncListeners.delete(listener) }
}

export function subscribeObserverReconnect(listener: ReconnectListener): () => void {
  reconnectListeners.add(listener)
  return () => { reconnectListeners.delete(listener) }
}

export function parseSseBlock(block: string): ObserverFrame | null {
  const lines = block.split(/\r?\n/)
  let id: string | null = null
  let event = 'message'
  const dataLines: string[] = []

  for (const line of lines) {
    if (!line || line.startsWith(':')) continue
    const sep = line.indexOf(':')
    const field = sep === -1 ? line : line.slice(0, sep)
    const rawVal = sep === -1 ? '' : line.slice(sep + 1)
    const value = rawVal.startsWith(' ') ? rawVal.slice(1) : rawVal

    if (field === 'id') id = value
    else if (field === 'event') event = value || 'message'
    else if (field === 'data') dataLines.push(value)
  }

  if (dataLines.length === 0 && id === null && event === 'message') return null
  const raw = dataLines.join('\n')
  let data: unknown = raw
  if (raw.length > 0) {
    try { data = JSON.parse(raw) } catch { /* plain text payload */ }
  }
  return { id, event, data, raw }
}

function addTopic(out: Set<string>, candidate: unknown): void {
  if (typeof candidate === 'string') {
    const trimmed = candidate.trim()
    if (trimmed.length > 0 && trimmed !== 'message') {
      out.add(trimmed)
      const aliases = SERVER_TOPIC_ALIASES[trimmed]
      if (aliases) {
        for (const alias of aliases) out.add(alias)
      }
    }
  }
}

function addTopicList(out: Set<string>, candidate: unknown): void {
  if (!Array.isArray(candidate)) return
  for (const item of candidate) addTopic(out, item)
}

export function extractObserverTopics(frame: ObserverFrame): readonly string[] {
  const topics = new Set<string>()
  addTopic(topics, frame.event)
  if (typeof frame.data === 'object' && frame.data !== null) {
    const rec = frame.data as Record<string, unknown>
    addTopic(topics, rec.type)
    addTopic(topics, rec.event_type)
    addTopic(topics, rec.method)
    addTopic(topics, rec.kind)
    addTopic(topics, rec.topic)
    addTopic(topics, rec.dataset)
    addTopicList(topics, rec.datasets)
    if (typeof rec.payload === 'object' && rec.payload !== null) {
      const payload = rec.payload as Record<string, unknown>
      addTopic(topics, payload.topic)
      addTopic(topics, payload.type)
      addTopic(topics, payload.event_type)
      addTopic(topics, payload.event)
      addTopic(topics, payload.kind)
      addTopic(topics, payload.dataset)
      addTopicList(topics, payload.datasets)
    }
    if (typeof rec.params === 'object' && rec.params !== null) {
      const params = rec.params as Record<string, unknown>
      addTopic(topics, params.topic)
      addTopic(topics, params.type)
      addTopic(topics, params.event_type)
      addTopic(topics, params.event)
      addTopic(topics, params.kind)
      addTopic(topics, params.dataset)
      addTopicList(topics, params.datasets)
    }
  }
  return [...topics]
}

function dispatchFrame(frame: ObserverFrame): void {
  if (frame.id) lastEventIdSignal.value = frame.id

  const topics = extractObserverTopics(frame)

  if (topics.includes('observer_resync_required')) {
    markStreamGap('observer_resync_required')
    return
  }

  // Invalidate matching cache topics lazily (no refetch storm!)
  for (const topic of topics) {
    resourceCache.invalidateTopic(topic)
  }

  for (const listener of [...frameListeners]) {
    try { listener(frame) } catch { /* isolate listener */ }
  }
}

function clearReconnectTimer(): void {
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
}

export function stopObserverStream(): void {
  clearReconnectTimer()
  if (activeController) {
    activeController.abort('observer_stopped')
    activeController = null
  }
  connectedSignal.value = false
}

export interface StartObserverOptions {
  readonly fetchImpl?: typeof fetch
  readonly autoReconnect?: boolean
  readonly reconnectBaseDelayMs?: number
}

function scheduleObserverReconnect(startEpoch: number, opts: StartObserverOptions): void {
  if (opts.autoReconnect === false) return
  if (!isEpochCurrent(startEpoch)) return
  if (reconnectTimer !== null) return
  const baseMs = Math.max(10, opts.reconnectBaseDelayMs ?? DEFAULT_RECONNECT_BASE_MS)
  const delayMs = Math.min(MAX_RECONNECT_DELAY_MS, baseMs * (2 ** Math.min(reconnectAttempt, 5)))
  reconnectAttempt += 1
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    if (!isEpochCurrent(startEpoch)) return
    if (activeController !== null) return
    void startObserverStream(opts)
  }, delayMs)
}

/**
 * Starts the mode-aware shared Observer SSE connection for the current `AuthSession`.
 * Automatically disconnects and clears `Last-Event-ID` if `sessionEpoch` changes,
 * and schedules bounded exponential-backoff reconnection on transient drops.
 */
export async function startObserverStream(
  opts: StartObserverOptions = {},
): Promise<void> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const session = authSession.peek()
  const endpoint = resolveObserverEndpoint(session)
  if (!endpoint) {
    stopObserverStream()
    reconnectAttempt = 0
    provenanceSignal.value = 'SNAPSHOT'
    return
  }

  stopObserverStream()
  const startEpoch = currentSessionEpoch()
  activeEpoch = startEpoch
  const controller = new AbortController()
  activeController = controller

  const unsubEpoch = sessionEpoch.subscribe((epoch) => {
    if (epoch !== startEpoch) {
      lastEventIdSignal.value = null
      reconnectAttempt = 0
      stopObserverStream()
      provenanceSignal.value = 'SNAPSHOT'
    }
  })

  const headers: Record<string, string> = { ...endpoint.headers }
  const resumeId = lastEventIdSignal.peek()
  if (resumeId) headers['Last-Event-ID'] = resumeId

  let shouldReconnect = false
  let readerRef: ReadableStreamDefaultReader<Uint8Array> | null = null
  const onAbort = () => {
    if (readerRef) {
      void readerRef.cancel().catch(() => {})
    }
  }
  controller.signal.addEventListener('abort', onAbort, { once: true })

  try {
    const response = await fetchImpl(endpoint.url, {
      method: 'GET',
      credentials: 'same-origin',
      headers,
      signal: controller.signal,
    })

    if (isEpochCurrent(startEpoch) && !controller.signal.aborted) {
      if (!response.ok || !response.body) {
        connectedSignal.value = false
        markStreamGap(`observer_http_${response.status}`)
        // Retry only transient server/network failures (408/429/5xx or empty 200 body); skip permanent 4xx.
        shouldReconnect =
          response.status === 408
          || response.status === 429
          || response.status >= 500
          || (response.ok && !response.body)
      } else {
        const prevSseInstanceId = getObserverSseInstanceId()
        const sseInstanceHeader = response.headers.get(OBSERVER_SSE_INSTANCE_HEADER)
        const nextSseInstanceId = sseInstanceHeader && sseInstanceHeader.trim().length > 0
          ? sseInstanceHeader.trim()
          : null
        if (nextSseInstanceId) {
          setObserverSseInstanceId(nextSseInstanceId)
        }

        const wasGapOrReconnect =
          provenanceSignal.peek() === 'STREAM_GAP'
          || reconnectAttempt > 0
          || (prevSseInstanceId !== null && nextSseInstanceId !== null && prevSseInstanceId !== nextSseInstanceId)

        reconnectAttempt = 0
        connectedSignal.value = true
        provenanceSignal.value = 'LIVE SSE'

        if (wasGapOrReconnect) {
          resourceCache.invalidateAll()
          for (const listener of [...reconnectListeners]) {
            try { listener() } catch { /* isolate listener */ }
          }
        }

        const reader = response.body.getReader()
        readerRef = reader
        const decoder = new TextDecoder()
        let buffer = ''

        while (true) {
          const { value, done } = await reader.read()
          if (done) break
          if (!isEpochCurrent(startEpoch) || controller.signal.aborted) break
          buffer += decoder.decode(value, { stream: true })
          const blocks = buffer.split(/\r?\n\r?\n/)
          buffer = blocks.pop() ?? ''
          for (const block of blocks) {
            const frame = parseSseBlock(block)
            if (frame) dispatchFrame(frame)
          }
        }

        if (isEpochCurrent(startEpoch) && !controller.signal.aborted) {
          connectedSignal.value = false
          markStreamGap('observer_eof')
          shouldReconnect = true
        }
      }
    }
  } catch {
    if (isEpochCurrent(startEpoch) && !controller.signal.aborted) {
      connectedSignal.value = false
      markStreamGap('observer_disconnected')
      shouldReconnect = true
    }
  } finally {
    controller.signal.removeEventListener('abort', onAbort)
    readerRef = null
    unsubEpoch()
    if (activeController === controller && activeEpoch === startEpoch) {
      activeController = null
    }
  }

  if (shouldReconnect && !controller.signal.aborted && isEpochCurrent(startEpoch)) {
    scheduleObserverReconnect(startEpoch, opts)
  }
}

export function resetObserverStateForTests(): void {
  stopObserverStream()
  reconnectAttempt = 0
  lastEventIdSignal.value = null
  sseInstanceIdSignal.value = null
  sseInstanceIdEpoch = 0
  trackedInstanceEpoch = sessionEpoch.peek()
  provenanceSignal.value = 'SNAPSHOT'
  frameListeners.clear()
  resyncListeners.clear()
  reconnectListeners.clear()
}
