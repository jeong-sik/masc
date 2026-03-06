// MASC Dashboard — SSE (Server-Sent Events) hook
// Auto-reconnect with exponential backoff, signal-based event dispatch

import { signal, type ReadonlySignal } from '@preact/signals'
import type { SSEEvent, JournalEntry } from './types'

const SSE_SESSION_KEY = 'masc_dashboard_sse_session_id'
const RECONNECT_BASE_MS = 1000
const RECONNECT_MAX_MS = 15000

// --- Signals ---

export const connected = signal(false)
export const eventCount = signal(0)
export const lastEvent = signal<SSEEvent | null>(null)
export const journal = signal<JournalEntry[]>([])

// --- Session ID ---

function getOrCreateSessionId(): string {
  let sid = sessionStorage.getItem(SSE_SESSION_KEY)
  if (!sid) {
    sid = typeof crypto.randomUUID === 'function'
      ? `dash_${crypto.randomUUID()}`
      : `dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`
    sessionStorage.setItem(SSE_SESSION_KEY, sid)
  }
  return sid
}

// --- Journal ---

const MAX_JOURNAL = 200

function addJournalEntry(
  agent: string,
  text: string,
  kind: JournalEntry['kind'] = 'system',
): void {
  const entry: JournalEntry = { agent, text, timestamp: Date.now(), kind }
  journal.value = [entry, ...journal.value].slice(0, MAX_JOURNAL)
}

// --- SSE Manager ---

let source: EventSource | null = null
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let reconnectAttempts = 0

function clearReconnectTimer(): void {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
}

function scheduleReconnect(): void {
  if (reconnectTimer) return
  reconnectAttempts++
  const exp = Math.min(reconnectAttempts, 5)
  const delay = Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * Math.pow(2, exp))
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    connectSSE()
  }, delay)
}

export function connectSSE(): void {
  clearReconnectTimer()
  if (source) {
    source.close()
    source = null
  }

  const urlParams = new URLSearchParams(window.location.search)
  const sseParams = new URLSearchParams()
  const agent = urlParams.get('agent') ?? urlParams.get('agent_name')
  const token = urlParams.get('token')
  if (agent) sseParams.set('agent', agent)
  if (token) sseParams.set('token', token)
  sseParams.set('session_id', getOrCreateSessionId())

  const sseUrl = sseParams.toString() ? `/sse?${sseParams.toString()}` : '/sse'
  const es = new EventSource(sseUrl)
  source = es

  es.onopen = () => {
    if (source !== es) return
    reconnectAttempts = 0
    connected.value = true
  }

  es.onerror = () => {
    if (source !== es) return
    connected.value = false
    es.close()
    source = null
    scheduleReconnect()
  }

  es.onmessage = (e: MessageEvent) => {
    try {
      const event = JSON.parse(e.data as string) as SSEEvent
      eventCount.value++
      lastEvent.value = event
      handleEvent(event)
    } catch {
      // Non-JSON SSE data (e.g., heartbeat text)
    }
  }
}

function handleEvent(event: SSEEvent): void {
  const type = event.type
  const agent = event.agent ?? event.author ?? event.from ?? event.from_agent ?? ''

  switch (type) {
    case 'agent_joined':
      addJournalEntry(agent, 'Joined', 'system')
      break
    case 'agent_left':
      addJournalEntry(agent, 'Left', 'system')
      break
    case 'broadcast':
      addJournalEntry(agent, `${(event.message ?? event.content ?? '').slice(0, 80)}`, 'system')
      break
    case 'task_update':
      addJournalEntry(agent, `Task: ${event.task_id ?? ''} -> ${event.status ?? ''}`, 'tasks')
      break
    case 'board_post':
    case 'masc/board_post':
      addJournalEntry(agent, 'New post', 'board')
      break
    case 'board_comment':
    case 'masc/board_comment':
      addJournalEntry(agent, 'New comment', 'board')
      break
    case 'keeper_heartbeat':
      addJournalEntry(
        event.name ?? agent,
        `Heartbeat gen=${event.generation ?? '?'} ctx=${event.context_ratio != null ? Math.round(event.context_ratio * 100) + '%' : '?'}`,
        'keepers',
      )
      break
    case 'keeper_handoff':
      addJournalEntry(
        event.name ?? agent,
        `Handoff gen ${event.from_generation ?? '?'} -> ${event.to_generation ?? '?'} (${event.to_model ?? '?'})`,
        'keepers',
      )
      break
    case 'keeper_compaction':
      addJournalEntry(
        event.name ?? agent,
        `Compaction saved ${event.saved_tokens ?? '?'} tokens (${event.trigger ?? '?'})`,
        'keepers',
      )
      break
    case 'keeper_guardrail':
      addJournalEntry(event.name ?? agent, `Guardrail: ${event.reason ?? 'stopped'}`, 'keepers')
      break
    default:
      addJournalEntry(agent, type, 'system')
  }
}

export function disconnectSSE(): void {
  clearReconnectTimer()
  if (source) {
    source.close()
    source = null
  }
  connected.value = false
}

// Re-export as readable signals for components
export const isConnected: ReadonlySignal<boolean> = connected
export const totalEvents: ReadonlySignal<number> = eventCount
