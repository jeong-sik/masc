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

let activeController: AbortController | null = null
let activeEpoch = 0
let sseInstanceIdEpoch = 0
let trackedInstanceEpoch = sessionEpoch.peek()

sessionEpoch.subscribe((epoch) => {
  if (epoch !== trackedInstanceEpoch) {
    trackedInstanceEpoch = epoch
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
  } else {
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
    if (trimmed.length > 0 && trimmed !== 'message') out.add(trimmed)
  }
}

export function extractObserverTopics(frame: ObserverFrame): readonly string[] {
  const topics = new Set<string>()
  addTopic(topics, frame.event)
  if (typeof frame.data === 'object' && frame.data !== null) {
    const rec = frame.data as Record<string, unknown>
    addTopic(topics, rec.type)
    addTopic(topics, rec.event_type)
    addTopic(topics, rec.method)
    if (typeof rec.params === 'object' && rec.params !== null) {
      const params = rec.params as Record<string, unknown>
      addTopic(topics, params.type)
      addTopic(topics, params.event_type)
      addTopic(topics, params.event)
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

export function stopObserverStream(): void {
  if (activeController) {
    activeController.abort('observer_stopped')
    activeController = null
  }
  connectedSignal.value = false
}

export interface StartObserverOptions {
  readonly fetchImpl?: typeof fetch
}

/**
 * Starts the mode-aware shared Observer SSE connection for the current `AuthSession`.
 * Automatically disconnects and clears `Last-Event-ID` if `sessionEpoch` changes.
 */
export async function startObserverStream(
  opts: StartObserverOptions = {},
): Promise<void> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const session = authSession.peek()
  const endpoint = resolveObserverEndpoint(session)
  if (!endpoint) {
    stopObserverStream()
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
      stopObserverStream()
      provenanceSignal.value = 'SNAPSHOT'
    }
  })

  const headers: Record<string, string> = { ...endpoint.headers }
  const resumeId = lastEventIdSignal.peek()
  if (resumeId) headers['Last-Event-ID'] = resumeId

  try {
    const response = await fetchImpl(endpoint.url, {
      method: 'GET',
      credentials: 'same-origin',
      headers,
      signal: controller.signal,
    })

    if (!isEpochCurrent(startEpoch) || controller.signal.aborted) return
    if (!response.ok || !response.body) {
      connectedSignal.value = false
      markStreamGap(`observer_http_${response.status}`)
      return
    }

    const sseInstanceHeader = response.headers.get(OBSERVER_SSE_INSTANCE_HEADER)
    if (sseInstanceHeader && sseInstanceHeader.trim().length > 0) {
      setObserverSseInstanceId(sseInstanceHeader)
    }

    connectedSignal.value = true
    provenanceSignal.value = 'LIVE SSE'

    const reader = response.body.getReader()
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
    }
  } catch {
    if (isEpochCurrent(startEpoch) && !controller.signal.aborted) {
      connectedSignal.value = false
      markStreamGap('observer_disconnected')
    }
  } finally {
    unsubEpoch()
    if (activeController === controller && activeEpoch === startEpoch) {
      activeController = null
    }
  }
}

export function resetObserverStateForTests(): void {
  stopObserverStream()
  lastEventIdSignal.value = null
  sseInstanceIdSignal.value = null
  sseInstanceIdEpoch = 0
  trackedInstanceEpoch = sessionEpoch.peek()
  provenanceSignal.value = 'SNAPSHOT'
  frameListeners.clear()
  resyncListeners.clear()
}
