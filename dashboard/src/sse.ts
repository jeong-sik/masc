// MASC Dashboard — SSE (Server-Sent Events) hook
// Auto-reconnect with exponential backoff, signal-based event dispatch

import { signal, type ReadonlySignal } from '@preact/signals'
import type { JournalEntry, JournalEventType, SSEEvent } from './types'
import { pushOasAgentEvent, updateOasKeeperSnapshot, oasLastGardenerTick, oasTotalEvents } from './store'
import type { OasKeeperSnapshot } from './types/oas'

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
  extra: Partial<JournalEntry> = {},
): void {
  const entry: JournalEntry = { agent, text, timestamp: Date.now(), kind, ...extra }
  journal.value = [entry, ...journal.value].slice(0, MAX_JOURNAL)
}

function normalizePreview(preview: string | undefined, max = 88): string | undefined {
  const normalized = (preview ?? '').replace(/\s+/g, ' ').trim()
  if (!normalized) return undefined
  const clipped = normalized.length > max ? `${normalized.slice(0, max - 3)}...` : normalized
  return clipped
}

function formatBoardJournalText(label: 'Post' | 'Comment', preview: string | undefined): string {
  const clipped = normalizePreview(preview)
  if (!clipped) return `New ${label.toLowerCase()}`
  return `${label}: ${clipped}`
}

function addTypedJournalEntry(
  agent: string,
  text: string,
  kind: JournalEntry['kind'],
  eventType: JournalEventType,
  extra: Partial<JournalEntry> = {},
): void {
  addJournalEntry(agent, text, kind, { eventType, ...extra })
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
      addTypedJournalEntry(agent, 'Joined', 'system', 'agent_joined')
      break
    case 'agent_left':
      addTypedJournalEntry(agent, 'Left', 'system', 'agent_left')
      break
    case 'broadcast':
      addTypedJournalEntry(
        agent,
        `${(event.message ?? event.content ?? '').slice(0, 80)}`,
        'system',
        'broadcast',
      )
      break
    case 'task_update':
      addTypedJournalEntry(
        agent,
        `Task: ${event.task_id ?? ''} -> ${event.status ?? ''}`,
        'tasks',
        'task_update',
      )
      break
    case 'board_post':
    case 'masc/board_post':
      addTypedJournalEntry(
        agent,
        formatBoardJournalText('Post', event.content ?? event.message),
        'board',
        'board_post',
        {
          author: event.author ?? agent,
          preview: normalizePreview(event.content ?? event.message),
          postId: event.post_id,
        },
      )
      break
    case 'board_comment':
    case 'masc/board_comment':
      addTypedJournalEntry(
        agent,
        formatBoardJournalText('Comment', event.content ?? event.message),
        'board',
        'board_comment',
        {
          author: event.author ?? agent,
          preview: normalizePreview(event.content ?? event.message),
          postId: event.post_id,
        },
      )
      break
    case 'keeper_heartbeat':
      addTypedJournalEntry(
        event.name ?? agent,
        `Heartbeat gen=${event.generation ?? '?'} ctx=${event.context_ratio != null ? Math.round(event.context_ratio * 100) + '%' : '?'}`,
        'keepers',
        'keeper_heartbeat',
      )
      break
    case 'keeper_handoff':
      addTypedJournalEntry(
        event.name ?? agent,
        `Handoff gen ${event.from_generation ?? '?'} -> ${event.to_generation ?? '?'} (${event.to_model ?? '?'})`,
        'keepers',
        'keeper_handoff',
      )
      break
    case 'keeper_compaction':
      addTypedJournalEntry(
        event.name ?? agent,
        `Compaction saved ${event.saved_tokens ?? '?'} tokens (${event.trigger ?? '?'})`,
        'keepers',
        'keeper_compaction',
      )
      break
    case 'keeper_guardrail':
      addTypedJournalEntry(
        event.name ?? agent,
        `Guardrail: ${event.reason ?? 'stopped'}`,
        'keepers',
        'keeper_guardrail',
      )
      break
    // OAS bridge events
    case 'oas:masc:lodge:agent_selected': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = (p.agent_name as string) ?? agent
      pushOasAgentEvent({
        type: 'selected',
        agent_name: agentName,
        trigger: p.trigger as string | undefined,
        timestamp: (p.timestamp as number) ?? Date.now() / 1000,
      })
      addTypedJournalEntry(agentName, `Selected (${p.trigger ?? '?'})`, 'oas', 'oas_agent_selected')
      break
    }
    case 'oas:masc:lodge:agent_decision': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = (p.agent_name as string) ?? agent
      pushOasAgentEvent({
        type: 'decision',
        agent_name: agentName,
        action: p.action as string | undefined,
        trigger_reason: p.trigger_reason as string | undefined,
        timestamp: (p.timestamp as number) ?? Date.now() / 1000,
      })
      addTypedJournalEntry(agentName, `Decision: ${p.action ?? '?'}`, 'oas', 'oas_agent_decision')
      break
    }
    case 'oas:masc:lodge:agent_action_executed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = (p.agent_name as string) ?? agent
      pushOasAgentEvent({
        type: 'action_executed',
        agent_name: agentName,
        action: p.action as string | undefined,
        success: p.success as boolean | undefined,
        timestamp: (p.timestamp as number) ?? Date.now() / 1000,
      })
      const ok = p.success ? 'ok' : 'fail'
      addTypedJournalEntry(agentName, `Action: ${p.action ?? '?'} [${ok}]`, 'oas', 'oas_agent_action')
      break
    }
    case 'oas:masc:keeper:snapshot': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const snap: OasKeeperSnapshot = {
        keeper_name: (p.keeper_name as string) ?? '',
        generation: (p.generation as number) ?? 0,
        context_ratio: (p.context_ratio as number) ?? 0,
        message_count: (p.message_count as number) ?? 0,
        timestamp: (p.timestamp as number) ?? Date.now() / 1000,
      }
      updateOasKeeperSnapshot(snap)
      addTypedJournalEntry(snap.keeper_name, `Keeper snapshot gen=${snap.generation} ctx=${Math.round(snap.context_ratio * 100)}%`, 'oas', 'oas_keeper_snapshot')
      break
    }
    case 'oas:masc:gardener:tick': {
      oasLastGardenerTick.value = Date.now()
      oasTotalEvents.value++
      break
    }
    default:
      addTypedJournalEntry(agent, type, 'system', 'unknown')
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
