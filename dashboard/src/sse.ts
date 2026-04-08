// MASC Dashboard — SSE (Server-Sent Events) hook
// Auto-reconnect with exponential backoff, signal-based event dispatch

import { signal, type ReadonlySignal } from '@preact/signals'
import type { JournalEntry, JournalEventType, SSEEvent } from './types'
import {
  pushOasAgentEvent,
  updateOasKeeperSnapshot,
  oasLastKeeperTick,
  oasTotalEvents,
  removeBoardPost,
} from './store'
import {
  defaultJournalSeverity,
  normalizeJournalSeverity,
  normalizeJournalSource,
} from './journal-entry'
import type { OasKeeperSnapshot } from './types/oas'
import { appendLiveToolCall } from './components/session-trace/session-trace-state'

import {
  RECONNECT_BASE_MS,
  RECONNECT_MAX_MS,
  MAX_JOURNAL_ENTRIES,
} from './config/constants'

const SSE_SESSION_KEY = 'masc_dashboard_sse_session_id'

// --- Signals ---

export const connected = signal(false)
export const eventCount = signal(0)
export const lastEvent = signal<SSEEvent | null>(null)
export const journal = signal<JournalEntry[]>([])

/** Increments each time SSE reconnects after a disconnect. */
export const reconnectCount = signal(0)
/** Timestamp of last disconnect (0 = never disconnected). */
export const lastDisconnectedAt = signal(0)

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

const MAX_JOURNAL = MAX_JOURNAL_ENTRIES

function addJournalEntry(
  agent: string,
  text: string,
  kind: JournalEntry['kind'] = 'system',
  extra: Partial<JournalEntry> = {},
): void {
  const entry: JournalEntry = {
    agent,
    text,
    narrativeText: extra.narrativeText ?? text,
    timestamp: Date.now(),
    kind,
    ...extra,
  }
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

function quotePreview(preview: string | undefined): string {
  const clipped = normalizePreview(preview)
  return clipped ? `: ${clipped}` : ''
}

function actorLabel(name: string | undefined): string {
  const normalized = (name ?? '').trim()
  return normalized || 'system'
}

function formatTaskNarrative(agent: string, taskId?: string, status?: string): string {
  const actor = actorLabel(agent)
  const task = (taskId ?? '').trim()
  const nextStatus = (status ?? '').trim()
  if (task && nextStatus) return `${actor}가 태스크 ${task}를 ${nextStatus} 상태로 갱신했습니다.`
  if (task) return `${actor}가 태스크 ${task}를 갱신했습니다.`
  return `${actor}가 태스크 상태를 갱신했습니다.`
}

function formatBoardNarrative(label: '게시글' | '댓글', author: string, preview: string | undefined): string {
  return `${actorLabel(author)}가 ${label}을 남겼습니다${quotePreview(preview)}`
}

function addTypedJournalEntry(
  agent: string,
  text: string,
  kind: JournalEntry['kind'],
  eventType: JournalEventType,
  extra: (Omit<Partial<JournalEntry>, 'severity' | 'source'> & {
    severity?: string
    source?: string
  }) = {},
): void {
  const explicitSeverity = normalizeJournalSeverity(
    typeof extra.severity === 'string' ? extra.severity : undefined,
  )
  addJournalEntry(agent, text, kind, {
    ...extra,
    source: normalizeJournalSource(extra.source),
    severity:
      explicitSeverity === 'unknown'
        ? defaultJournalSeverity(eventType)
        : explicitSeverity,
    eventType,
  })
}

// --- SSE Manager ---

let source: EventSource | null = null
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let reconnectAttempts = 0

export function buildDashboardSseUrl(sessionId: string, locationSearch = window.location.search): string {
  const urlParams = new URLSearchParams(locationSearch)
  const sseParams = new URLSearchParams()
  const agent = urlParams.get('agent') ?? urlParams.get('agent_name')
  // Token from sessionStorage (moved from URL on init) — EventSource does not
  // support custom headers, so query param is the only option.  The token is
  // no longer visible in the browser address bar or shareable links.
  const token = sessionStorage.getItem('masc_bearer_token')
  if (agent) sseParams.set('agent', agent)
  if (token) sseParams.set('token', token)
  sseParams.set('session_id', sessionId)
  sseParams.set('sse_kind', 'observer')
  return `/mcp?${sseParams.toString()}`
}

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
  console.debug(`[SSE] reconnect #${reconnectAttempts} in ${delay}ms`)
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

  const sseUrl = buildDashboardSseUrl(getOrCreateSessionId())
  console.debug('[SSE] connecting', sseUrl)
  const es = new EventSource(sseUrl)
  source = es

  es.onopen = () => {
    if (source !== es) return
    const wasDisconnected = reconnectAttempts > 0
    reconnectAttempts = 0
    connected.value = true
    if (wasDisconnected) {
      reconnectCount.value++
      console.debug(`[SSE] reconnected (count=${reconnectCount.value})`)
    } else {
      console.debug('[SSE] connected')
    }
  }

  es.onerror = () => {
    if (source !== es) return
    if (connected.value) {
      lastDisconnectedAt.value = Date.now()
    }
    console.warn('[SSE] connection error, scheduling reconnect')
    connected.value = false
    es.close()
    source = null
    scheduleReconnect()
  }

  es.onmessage = (e: MessageEvent) => {
    try {
      const raw = JSON.parse(e.data as string)
      // Unwrap JSON-RPC notifications: extract params as the actual event.
      // Server wraps events as {"jsonrpc":"2.0","method":"masc/event","params":{type,agent,...}}
      const event: SSEEvent = (raw.jsonrpc && raw.params?.type) ? raw.params : raw
      eventCount.value++
      lastEvent.value = event
      handleEvent(event)
    } catch {
      // Non-JSON SSE data (e.g., heartbeat text)
    }
  }
}

function handleEvent(event: SSEEvent): void {
  // Normalize: server may emit "masc/agent_joined" or "agent_joined".
  // Strip the "masc/" prefix for the core event types so both forms match
  // the same switch cases.  Keep the original type for OAS/namespaced events
  // that genuinely use colons or other prefixes.
  const rawType = event.type
  const MASC_PREFIX = 'masc/'
  const type =
    rawType.startsWith(MASC_PREFIX)
    && !rawType.startsWith('masc/board_')   // board_post/board_comment already have explicit cases
      ? rawType.slice(MASC_PREFIX.length)
      : rawType
  const agent = event.agent ?? event.author ?? event.from ?? event.from_agent ?? ''

  switch (type) {
    case 'agent_joined':
      addTypedJournalEntry(agent, 'Joined', 'system', 'agent_joined', {
        narrativeText: `${actorLabel(agent)}가 프로젝트에 참여했습니다.`,
      })
      break
    case 'agent_left':
      addTypedJournalEntry(agent, 'Left', 'system', 'agent_left', {
        narrativeText: `${actorLabel(agent)}가 프로젝트에서 나갔습니다.`,
      })
      break
    case 'broadcast':
      addTypedJournalEntry(
        agent,
        `${(event.message ?? event.content ?? '').slice(0, 80)}`,
        'system',
        'broadcast',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(agent)}가 공지/메시지를 보냈습니다${quotePreview(event.message ?? event.content)}`,
        },
      )
      break
    case 'task_update':
      addTypedJournalEntry(
        agent,
        `Task: ${event.task_id ?? ''} -> ${event.status ?? ''}`,
        'tasks',
        'task_update',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: formatTaskNarrative(agent, event.task_id, event.status),
        },
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
          severity: event.severity,
          source: event.source,
          narrativeText: formatBoardNarrative('게시글', event.author ?? agent, event.content ?? event.message),
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
          severity: event.severity,
          source: event.source,
          narrativeText: formatBoardNarrative('댓글', event.author ?? agent, event.content ?? event.message),
          preview: normalizePreview(event.content ?? event.message),
          postId: event.post_id,
        },
      )
      break
    case 'board_delete':
    case 'masc/board_delete':
      removeBoardPost(event.post_id)
      addTypedJournalEntry(
        agent,
        `Post deleted: ${event.post_id ?? 'unknown'}`,
        'board',
        'board_delete',
        {
          author: event.author ?? agent,
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(agent)}가 게시글을 삭제했습니다`,
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
        {
          severity: event.severity,
          source: event.source,
          narrativeText:
            `${actorLabel(event.name ?? agent)}가 하트비트를 보냈습니다`
            + ` (gen ${event.generation ?? '?'}, ctx ${event.context_ratio != null ? Math.round(event.context_ratio * 100) + '%' : '?'})`,
        },
      )
      break
    case 'keeper_handoff':
      addTypedJournalEntry(
        event.name ?? agent,
        `Handoff gen ${event.from_generation ?? '?'} -> ${event.to_generation ?? '?'} (${event.to_model ?? '?'})`,
        'keepers',
        'keeper_handoff',
        {
          severity: event.severity,
          source: event.source,
          narrativeText:
            `${actorLabel(event.name ?? agent)}가 keeper handoff를 수행했습니다`
            + ` (gen ${event.from_generation ?? '?'} → ${event.to_generation ?? '?'}, ${event.to_model ?? '?'})`,
        },
      )
      break
    case 'keeper_compaction':
      addTypedJournalEntry(
        event.name ?? agent,
        `Compaction saved ${event.saved_tokens ?? '?'} tokens (${event.trigger ?? '?'})`,
        'keepers',
        'keeper_compaction',
        {
          severity: event.severity,
          source: event.source,
          narrativeText:
            `${actorLabel(event.name ?? agent)}가 context compaction을 수행했습니다`
            + ` (${event.saved_tokens ?? '?'} tokens, ${event.trigger ?? '?'})`,
        },
      )
      break
    case 'keeper_guardrail':
      addTypedJournalEntry(
        event.name ?? agent,
        `Guardrail: ${event.reason ?? 'stopped'}`,
        'keepers',
        'keeper_guardrail',
        {
          severity: event.severity ?? 'error',
          source: event.source,
          narrativeText: `${actorLabel(event.name ?? agent)}가 guardrail에 의해 중단되었습니다: ${event.reason ?? 'stopped'}`,
        },
      )
      break
    case 'keeper_phase_changed':
      addTypedJournalEntry(
        event.name ?? agent,
        `Phase: ${event.prev_phase ?? '?'} → ${event.new_phase ?? '?'} (${event.event ?? '?'})`,
        'keepers',
        'keeper_phase_changed',
        {
          severity: (['failing', 'crashed', 'dead'].includes((event.new_phase ?? '').toLowerCase())) ? 'error' : 'info',
          source: event.source,
          narrativeText: `${actorLabel(event.name ?? agent)}의 상태가 ${event.prev_phase ?? '?'}에서 ${event.new_phase ?? '?'}로 전이되었습니다`,
        },
      )
      break
    case 'keeper_tool_call': {
      const toolName = event.tool_name ?? '?'
      const durationMs = event.duration_ms ?? 0
      const isError = event.success === false
      addTypedJournalEntry(
        event.name ?? agent,
        `Tool: ${toolName} (${durationMs}ms)${isError ? ' ERR' : ''}`,
        'keepers',
        'keeper_tool_call',
        {
          severity: isError ? 'warn' : 'info',
          source: event.source,
          narrativeText: `${actorLabel(event.name ?? agent)}가 ${toolName} 도구를 실행했습니다 (${durationMs}ms)`,
        },
      )
      // Push to live trace if session trace is open for this keeper
      if (event.name) {
        appendLiveToolCall(event.name, {
          toolName,
          durationMs,
          success: event.success !== false,
          error: event.error_text ?? null,
          tsUnix: typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000,
        })
      }
      break
    }
    case 'keeper_tool_skipped': {
      const toolName = event.tool_name ?? '?'
      const reasonCode = event.reason_code ?? 'unknown'
      addTypedJournalEntry(
        event.name ?? agent,
        `Tool skipped: ${toolName} (${reasonCode})`,
        'keepers',
        'keeper_tool_call',
        {
          severity: 'warn',
          source: event.source,
          narrativeText: `${actorLabel(event.name ?? agent)}의 ${toolName} 도구가 차단되었습니다 (${reasonCode})`,
        },
      )
      if (event.name) {
        appendLiveToolCall(event.name, {
          toolName,
          durationMs: 0,
          success: false,
          error: `skipped: ${reasonCode}`,
          tsUnix: typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000,
        })
      }
      break
    }
    // OAS bridge events
    case 'oas:masc:autonomy:agent_selected': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      pushOasAgentEvent({
        type: 'selected',
        agent_name: (p.agent_name as string) ?? '',
        trigger: (p.trigger as string) ?? undefined,
        thompson_score:
          typeof p.thompson_score === 'number' ? p.thompson_score : undefined,
        final_score: typeof p.final_score === 'number' ? p.final_score : undefined,
        timestamp:
          typeof p.timestamp === 'number'
            ? p.timestamp
            : (typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000),
      })
      break
    }
    case 'oas:masc:autonomy:agent_decision': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      pushOasAgentEvent({
        type: 'decision',
        agent_name: (p.agent_name as string) ?? '',
        action: (p.action as string) ?? undefined,
        trigger_reason: (p.trigger_reason as string) ?? undefined,
        timestamp:
          typeof p.timestamp === 'number'
            ? p.timestamp
            : (typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000),
      })
      break
    }
    case 'oas:masc:autonomy:agent_action_executed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      pushOasAgentEvent({
        type: 'action_executed',
        agent_name: (p.agent_name as string) ?? '',
        action: (p.action as string) ?? undefined,
        success: typeof p.success === 'boolean' ? p.success : undefined,
        timestamp:
          typeof p.timestamp === 'number'
            ? p.timestamp
            : (typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000),
      })
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
      addTypedJournalEntry(
        snap.keeper_name,
        `Keeper snapshot gen=${snap.generation} ctx=${Math.round(snap.context_ratio * 100)}%`,
        'oas',
        'oas_keeper_snapshot',
        {
          severity: event.severity,
          source: event.source,
          narrativeText:
            `${actorLabel(snap.keeper_name)}의 keeper snapshot이 갱신되었습니다`
            + ` (gen ${snap.generation}, ctx ${Math.round(snap.context_ratio * 100)}%)`,
        },
      )
      break
    }
    case 'oas:masc:keeper:lifecycle': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = (p.agent_name as string) ?? ''
      const lifecycleEvent = (p.event as string) ?? undefined
      const detail = (p.detail as string) ?? undefined
      pushOasAgentEvent({
        type: 'keeper_lifecycle',
        agent_name: agentName,
        event: lifecycleEvent,
        detail,
        timestamp:
          typeof p.timestamp === 'number'
            ? p.timestamp
            : (typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000),
      })
      addTypedJournalEntry(
        agentName,
        `Keeper ${[lifecycleEvent, detail].filter(Boolean).join(' · ') || 'lifecycle'}`,
        'oas',
        'oas_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText:
            `${actorLabel(agentName)} keeper lifecycle 이벤트`
            + ([lifecycleEvent, detail].filter(Boolean).length > 0
              ? ` (${[lifecycleEvent, detail].filter(Boolean).join(' · ')})`
              : ''),
        },
      )
      break
    }
    case 'oas:masc:trust_updated': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentA = (p.agent_a as string) ?? ''
      const agentB = (p.agent_b as string) ?? ''
      const trustScore = typeof p.trust_score === 'number' ? p.trust_score : undefined
      pushOasAgentEvent({
        type: 'trust_updated',
        agent_name: agentA,
        secondary_agent: agentB,
        trust_score: trustScore,
        timestamp:
          typeof p.timestamp === 'number'
            ? p.timestamp
            : (typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000),
      })
      addTypedJournalEntry(
        agentA,
        `Trust ${agentB}${trustScore != null ? ` · ${trustScore.toFixed(2)}` : ''}`,
        'oas',
        'oas_event',
        {
          narrativeText:
            `${actorLabel(agentA)}와 ${actorLabel(agentB)} 사이 trust score가 갱신되었습니다`
            + (trustScore != null ? ` (${trustScore.toFixed(2)})` : ''),
        },
      )
      break
    }
    case 'oas:masc:reputation_changed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = (p.agent_name as string) ?? ''
      const oldScore = typeof p.old_score === 'number' ? p.old_score : undefined
      const newScore = typeof p.new_score === 'number' ? p.new_score : undefined
      const trend = (p.trend as string) ?? undefined
      pushOasAgentEvent({
        type: 'reputation_changed',
        agent_name: agentName,
        old_score: oldScore,
        new_score: newScore,
        trend,
        timestamp:
          typeof p.timestamp === 'number'
            ? p.timestamp
            : (typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000),
      })
      addTypedJournalEntry(
        agentName,
        `Reputation${oldScore != null && newScore != null ? ` ${oldScore.toFixed(2)} → ${newScore.toFixed(2)}` : ''}${trend ? ` · ${trend}` : ''}`,
        'oas',
        'oas_event',
        {
          narrativeText:
            `${actorLabel(agentName)} reputation이 갱신되었습니다`
            + (oldScore != null && newScore != null ? ` (${oldScore.toFixed(2)} → ${newScore.toFixed(2)})` : '')
            + (trend ? `, trend=${trend}` : ''),
        },
      )
      break
    }
    case 'oas:masc:keeper:tick': {
      const now = Date.now()
      if (oasLastKeeperTick.value === null || now - oasLastKeeperTick.value > 100) {
        oasLastKeeperTick.value = now
      }
      oasTotalEvents.value++
      break
    }
    default:
      addTypedJournalEntry(agent, type, 'system', 'unknown', {
        narrativeText: `${actorLabel(agent)} 이벤트: ${type}`,
      })
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
