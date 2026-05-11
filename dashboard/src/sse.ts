// MASC Dashboard — SSE (Server-Sent Events) hook
// Auto-reconnect with exponential backoff, signal-based event dispatch

import { signal, type ReadonlySignal } from '@preact/signals'
import type { JournalEntry, JournalEventType, SSEEvent } from './types'
import { formatCost } from './lib/format-number'
import {
  removeBoardPost,
} from './store'
import {
  defaultJournalSeverity,
  normalizeJournalSeverity,
  normalizeJournalSource,
} from './journal-entry'
import { appendLiveToolCall } from './components/session-trace/session-trace-live-store'
import { appendAuditEntry } from './live-store'
import { parseSSEMessage } from './schemas/sse'
import { RingBuffer } from './lib/ring-buffer'
import { createSseTransport } from './transports/sse-transport'
import type { Transport } from './transports/transport'

import {
  RECONNECT_BASE_MS,
  RECONNECT_MAX_MS,
  MAX_JOURNAL_ENTRIES,
} from './config/constants'

const SSE_SESSION_KEY = 'masc_dashboard_sse_session_id'
let oasRuntimeStorePromise: Promise<typeof import('./oas-runtime-store')> | null = null

function loadOasRuntimeStore(): Promise<typeof import('./oas-runtime-store')> {
  oasRuntimeStorePromise ??= import('./oas-runtime-store')
  return oasRuntimeStorePromise
}

// --- Signals ---

export const connected = signal(false)
const eventCount = signal(0)
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

const journalRing = new RingBuffer<JournalEntry>(MAX_JOURNAL_ENTRIES)

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
  journalRing.push(entry)
  journal.value = journalRing.toArray() as JournalEntry[]
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

function projectedActorLabel(raw: string | undefined, displayName: string | undefined): string {
  const projected = displayName?.trim()
  return actorLabel(projected || raw)
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
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

/** Extract OAS envelope fields (correlation_id, run_id, ts_unix) from an SSE
 * event into the shape expected by JournalEntry. Returns an empty object for
 * non-OAS events so spreading into `extra` stays inert. */
function envelopeFromEvent(event: SSEEvent): Pick<JournalEntry, 'correlationId' | 'runId' | 'oasTs'> {
  const out: Pick<JournalEntry, 'correlationId' | 'runId' | 'oasTs'> = {}
  if (typeof event.correlation_id === 'string' && event.correlation_id.trim() !== '') {
    out.correlationId = event.correlation_id
  }
  if (typeof event.run_id === 'string' && event.run_id.trim() !== '') {
    out.runId = event.run_id
  }
  if (typeof event.ts_unix === 'number' && Number.isFinite(event.ts_unix)) {
    out.oasTs = event.ts_unix
  }
  return out
}

// --- SSE Manager ---

let transport: Transport | null = null
let unsubscribe: (() => void) | null = null
let wasDisconnected = false
let pauseOasRuntimeIngress = false
let queuedOasEvents: SSEEvent[] = []

export function pauseQueuedOasRuntimeIngress(): void {
  pauseOasRuntimeIngress = true
}

export function resumeQueuedOasRuntimeIngress(): void {
  pauseOasRuntimeIngress = false
  if (queuedOasEvents.length === 0) return
  const pending = queuedOasEvents
  queuedOasEvents = []
  for (const event of pending) {
    handleEvent(event)
  }
}

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

export function normalizeSSEDispatchType(rawType: string): string {
  if (
    rawType === 'oas:masc:audit_event'
    || rawType === 'masc:audit_event'
    || rawType === 'masc/audit_event'
  ) {
    return 'audit_event'
  }
  const mascPrefix = 'masc/'
  return rawType.startsWith(mascPrefix)
    && !rawType.startsWith('masc/board_')
    ? rawType.slice(mascPrefix.length)
    : rawType
}



export function connectSSE(): void {
  disconnectSSE()

  const sseUrl = buildDashboardSseUrl(getOrCreateSessionId())
  console.debug('[SSE] connecting', sseUrl)
  transport = createSseTransport(sseUrl, {
    retryBaseMs: RECONNECT_BASE_MS,
    retryMaxMs: RECONNECT_MAX_MS,
  })

  unsubscribe = transport.subscribe((event) => {
    if (event.type === 'open') {
      if (wasDisconnected) {
        pauseOasRuntimeIngress = true
        reconnectCount.value++
        console.debug(`[SSE] reconnected (count=${reconnectCount.value})`)
      } else {
        console.debug('[SSE] connected')
      }
      wasDisconnected = false
      connected.value = true
    } else if (event.type === 'error' || event.type === 'close') {
      if (connected.value) {
        lastDisconnectedAt.value = Date.now()
      }
      console.warn('[SSE] connection error, scheduling reconnect')
      wasDisconnected = true
      connected.value = false
    } else if (event.type === 'message') {
      const raw = event.data
      if (typeof raw !== 'object') {
        // Non-JSON SSE data (e.g., heartbeat text) — transports layer already
        // parsed JSON when possible; fall back to ignoring plain strings.
        return
      }
      const candidate: unknown =
        raw && (raw as { jsonrpc?: unknown }).jsonrpc && (raw as { params?: { type?: unknown } }).params?.type
          ? (raw as { params?: unknown }).params
          : raw
      const parsed = parseSSEMessage(candidate)
      if (!parsed) return
      const ev = parsed as unknown as SSEEvent
      eventCount.value++
      lastEvent.value = ev
      handleEvent(ev)
    }
  })

  transport.connect()
}

function handleEvent(event: SSEEvent): void {
  // Normalize only dispatch aliases. The OAS Event_bus bridge relays
  // MASC Custom("masc.*") payloads as oas:masc:* events; audit ledger
  // events still belong to the dashboard audit stream.
  const rawType = event.type
  if (pauseOasRuntimeIngress && rawType.startsWith('oas:')) {
    queuedOasEvents.push(event)
    return
  }
  const type = normalizeSSEDispatchType(rawType)
  const agent = event.agent ?? event.author ?? event.from ?? event.from_agent ?? ''
  if (rawType.startsWith('oas:')) {
    void loadOasRuntimeStore()
      .then(({ applyOasRuntimeEvent }) => {
        applyOasRuntimeEvent(event, { includeLiveTrace: true })
      })
      .catch(err => {
        console.warn('[SSE] OAS runtime handler unavailable', err instanceof Error ? err.message : err)
      })
  }

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
      {
        const author = projectedActorLabel(event.author ?? agent, event.author_identity?.display_name)
        addTypedJournalEntry(
          author,
          formatBoardJournalText('Post', event.content ?? event.message),
          'board',
          'board_post',
          {
            author,
            severity: event.severity,
            source: event.source,
            narrativeText: formatBoardNarrative('게시글', author, event.content ?? event.message),
            preview: normalizePreview(event.content ?? event.message),
            postId: event.post_id,
          },
        )
        break
      }
    case 'board_comment':
    case 'masc/board_comment':
      {
        const author = projectedActorLabel(event.author ?? agent, event.author_identity?.display_name)
        addTypedJournalEntry(
          author,
          formatBoardJournalText('Comment', event.content ?? event.message),
          'board',
          'board_comment',
          {
            author,
            severity: event.severity,
            source: event.source,
            narrativeText: formatBoardNarrative('댓글', author, event.content ?? event.message),
            preview: normalizePreview(event.content ?? event.message),
            postId: event.post_id,
          },
        )
        break
      }
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
    // Path A board events — emitted by server_bootstrap_loops.ml via
    // JSON-RPC notifications/board envelope (unwrapped to params.type).
    case 'post_created':
      {
        const author = projectedActorLabel(event.author ?? agent, event.author_identity?.display_name)
        addTypedJournalEntry(
          author,
          formatBoardJournalText('Post', event.content ?? event.title),
          'board',
          'board_post',
          {
            author,
            severity: event.severity,
            source: event.source,
            narrativeText: formatBoardNarrative('게시글', author, event.content ?? event.title),
            preview: normalizePreview(event.content ?? event.title),
            postId: event.post_id,
          },
        )
        break
      }
    case 'comment_added':
      {
        const author = projectedActorLabel(event.author ?? agent, event.author_identity?.display_name)
        addTypedJournalEntry(
          author,
          formatBoardJournalText('Comment', event.content),
          'board',
          'board_comment',
          {
            author,
            severity: event.severity,
            source: event.source,
            narrativeText: formatBoardNarrative('댓글', author, event.content),
            preview: normalizePreview(event.content),
            postId: event.post_id,
          },
        )
        break
      }
    case 'post_voted':
      {
        const voter = projectedActorLabel(event.voter ?? agent, event.voter_identity?.display_name)
        addTypedJournalEntry(
          voter,
          `Vote ${event.direction ?? '?'} on post ${event.post_id ?? ''}`,
          'board',
          'board_vote',
          {
            author: voter,
            severity: event.severity,
            source: event.source,
            narrativeText: `${actorLabel(voter)}가 게시글에 ${event.direction === 'up' ? '추천' : '비추천'} 투표했습니다`,
            postId: event.post_id,
          },
        )
        break
      }
    case 'comment_voted':
      {
        const voter = projectedActorLabel(event.voter ?? agent, event.voter_identity?.display_name)
        addTypedJournalEntry(
          voter,
          `Vote ${event.direction ?? '?'} on comment ${event.comment_id ?? ''}`,
          'board',
          'board_vote',
          {
            author: voter,
            severity: event.severity,
            source: event.source,
            narrativeText: `${actorLabel(voter)}가 댓글에 ${event.direction === 'up' ? '추천' : '비추천'} 투표했습니다`,
          },
        )
        break
      }
    case 'keeper_turn_complete':
      addTypedJournalEntry(
        event.name ?? agent,
        `Turn ${event.turn ?? '?'} model=${event.model_used ?? '?'} tok=${((event.input_tokens ?? 0) + (event.output_tokens ?? 0))} tools=${event.tool_calls_made ?? 0}`,
        'keepers',
        'unknown',
        {
          severity: 'info',
          source: event.source,
          narrativeText:
            `${actorLabel(event.name ?? agent)} turn ${event.turn ?? '?'}`
            + ` (${event.model_used ?? '?'}, ${formatCost(event.cost_usd ?? 0)}, tools=${event.tool_calls_made ?? 0})`,
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
      break
    }
    case 'oas:masc:autonomy:agent_decision': {
      break
    }
    case 'oas:masc:autonomy:agent_action_executed': {
      break
    }
    case 'oas:masc:keeper:snapshot': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const snap = {
        keeper_name: (p.keeper_name as string) ?? '',
        generation: (p.generation as number) ?? 0,
        context_ratio: (p.context_ratio as number) ?? 0,
        message_count: (p.message_count as number) ?? 0,
        timestamp: (p.timestamp as number) ?? Date.now() / 1000,
      }
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
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'oas:masc:keeper:lifecycle': {
      break
    }
    case 'oas:masc:trust_updated': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentA = (p.agent_a as string) ?? ''
      const agentB = (p.agent_b as string) ?? ''
      const trustScore = typeof p.trust_score === 'number' ? p.trust_score : undefined
      addTypedJournalEntry(
        agentA,
        `Trust ${agentB}${trustScore != null ? ` · ${trustScore.toFixed(2)}` : ''}`,
        'oas',
        'oas_event',
        {
          narrativeText:
            `${actorLabel(agentA)}와 ${actorLabel(agentB)} 사이 trust score가 갱신되었습니다`
            + (trustScore != null ? ` (${trustScore.toFixed(2)})` : ''),
          ...envelopeFromEvent(event),
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
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'oas:agent_started':
    case 'oas:agent_completed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const taskId = asString(p.task_id)
      const elapsed = asNumber(p.elapsed_s)
      const phase = type === 'oas:agent_started' ? 'started' : 'completed'
      addTypedJournalEntry(
        agentName,
        `OAS agent ${phase}${taskId ? ` · ${taskId}` : ''}${elapsed != null ? ` · ${elapsed.toFixed(1)}s` : ''}`,
        'oas',
        'oas_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(agentName)} OAS agent ${phase}${taskId ? ` (${taskId})` : ''}`,
          preview: taskId,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'oas:agent_failed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const taskId = asString(p.task_id)
      const elapsed = asNumber(p.elapsed_s)
      const error = asString(p.error)
      addTypedJournalEntry(
        agentName,
        `OAS agent failed${taskId ? ` · ${taskId}` : ''}${elapsed != null ? ` · ${elapsed.toFixed(1)}s` : ''}${error ? ` · ${error}` : ''}`,
        'oas',
        'oas_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(agentName)} OAS agent failed${taskId ? ` (${taskId})` : ''}${error ? `: ${error}` : ''}`,
          preview: taskId ?? error,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'oas:tool_called':
    case 'oas:tool_completed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const toolName = asString(p.tool_name) ?? 'unknown'
      const phase = type === 'oas:tool_called' ? 'called' : 'completed'
      addTypedJournalEntry(
        agentName,
        `OAS tool ${phase}: ${toolName}`,
        'oas',
        'oas_tool',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(agentName)} OAS 도구 ${phase}: ${toolName}`,
        },
      )
      break
    }
    case 'oas:handoff_requested':
    case 'oas:handoff_completed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const fromAgent = asString(p.from_agent) ?? asString(event.agent_name) ?? agent
      const toAgent = asString(p.to_agent) ?? 'unknown'
      const elapsed = asNumber(p.elapsed_s)
      const reason = asString(p.reason)
      const phase = type === 'oas:handoff_requested' ? 'requested' : 'completed'
      addTypedJournalEntry(
        fromAgent,
        `OAS handoff ${phase} · ${fromAgent}→${toAgent}${elapsed != null ? ` · ${elapsed.toFixed(1)}s` : ''}${reason ? ` · ${reason}` : ''}`,
        'oas',
        'oas_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `OAS handoff ${phase}: ${actorLabel(fromAgent)} → ${actorLabel(toAgent)}${reason ? ` (${reason})` : ''}`,
          preview: `${fromAgent}→${toAgent}`,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'oas:turn_started':
    case 'oas:turn_completed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const turn = asNumber(p.turn)
      const phase = type === 'oas:turn_started' ? 'started' : 'completed'
      addTypedJournalEntry(
        agentName,
        `OAS turn ${phase}${turn != null ? ` · T${turn}` : ''}`,
        'oas',
        'oas_turn',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(agentName)} OAS turn ${phase}${turn != null ? ` (T${turn})` : ''}`,
        },
      )
      break
    }
    case 'oas:context_compacted': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const before = asNumber(p.before_tokens)
      const after = asNumber(p.after_tokens)
      const phase = asString(p.phase)
      addTypedJournalEntry(
        agentName,
        `OAS compact${before != null && after != null ? ` · ${before}→${after}` : ''}${phase ? ` · ${phase}` : ''}`,
        'oas',
        'oas_context',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(agentName)} OAS context compact${phase ? ` (${phase})` : ''}`,
        },
      )
      break
    }
    case 'oas:task_state_changed': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const taskId = asString(p.task_id) ?? event.task_id ?? 'unknown'
      const fromState = asString(p.from_state)
      const toState = asString(p.to_state)
      addTypedJournalEntry(
        taskId,
        `OAS task ${taskId}${fromState || toState ? ` · ${fromState ?? '?'}→${toState ?? '?'}` : ''}`,
        'oas',
        'oas_task',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `OAS task 상태 전이 ${taskId}${fromState || toState ? ` (${fromState ?? '?'} → ${toState ?? '?'})` : ''}`,
        },
      )
      break
    }
    case 'oas:durable:llm_request': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const turn = asNumber(p.turn)
      const model = asString(p.model) ?? 'unknown'
      const inputTokens = asNumber(p.input_tokens) ?? 0
      addTypedJournalEntry(
        agentName,
        `OAS durable llm_request${turn != null ? ` · T${turn}` : ''} · ${model} · ${inputTokens}tok`,
        'oas',
        'oas_event',
        {
          severity: event.severity,
          source: event.source,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'oas:durable:llm_response': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const turn = asNumber(p.turn)
      const outputTokens = asNumber(p.output_tokens) ?? 0
      const stopReason = asString(p.stop_reason) ?? 'unknown'
      const durationMs = asNumber(p.duration_ms)
      addTypedJournalEntry(
        agentName,
        `OAS durable llm_response${turn != null ? ` · T${turn}` : ''} · ${outputTokens}tok · ${stopReason}${durationMs != null ? ` · ${durationMs.toFixed(0)}ms` : ''}`,
        'oas',
        'oas_event',
        {
          severity: event.severity,
          source: event.source,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'oas:durable:error_occurred': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const turn = asNumber(p.turn)
      const errorDomain = asString(p.error_domain) ?? 'unknown'
      const detail = asString(p.detail) ?? ''
      addTypedJournalEntry(
        agentName,
        `OAS 에러 · ${errorDomain}${turn != null ? ` · T${turn}` : ''}`,
        'oas',
        'oas_event',
        {
          severity: event.severity,
          source: event.source,
          preview: detail || undefined,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'oas:durable:turn_started':
    case 'oas:durable:tool_called':
    case 'oas:durable:tool_completed':
    case 'oas:durable:state_transition':
    case 'oas:durable:checkpoint_saved': {
      // Already covered by non-durable oas:* events; journal-only.
      addTypedJournalEntry(agent, type, 'oas', 'oas_event', {
        severity: event.severity,
        source: event.source,
      })
      break
    }
    case 'audit_event': {
      // Global audit ledger event pushed via SSE (O2 Phase 2).
      // Payload fields mirror the /api/v1/audit entry shape.
      const p = (event.payload ?? {}) as Record<string, unknown>
      const auditId = (event.audit_id ?? (p.id as string)) ?? ''
      const auditTs = (event.audit_ts ?? (p.ts as string)) ?? new Date().toISOString()
      const auditActor = (event.audit_actor ?? (p.actor as string)) ?? agent
      const auditKind = (event.audit_kind ?? (p.kind as string)) ?? type
      const auditTarget = event.audit_target ?? (p.target as string | undefined)
      const auditSummary = (event.audit_summary ?? (p.summary as string)) ?? auditKind
      const auditSeverity = (event.audit_severity ?? (p.severity as string)) ?? 'info'
      appendAuditEntry({
        id: auditId,
        ts: auditTs,
        actor: auditActor,
        kind: auditKind,
        target: auditTarget,
        summary: auditSummary,
        severity: auditSeverity,
        payload: event.audit_payload ?? p.payload,
      })
      break
    }
    case 'ide:presence': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const runtimeId = asString(p.runtime_id) ?? 'unknown'
      const branch = asString(p.branch) ?? 'unknown'
      // supervisor extracted for future use
      const connected = p.connected === true
      const entries = Array.isArray(p.entries) ? p.entries.length : 0
      addTypedJournalEntry(
        agent,
        `IDE presence · ${runtimeId} · ${branch} · ${entries} keepers`,
        'system',
        'unknown',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `IDE presence snapshot ${runtimeId}/${branch} (${entries} keepers, connected=${connected})`,
        },
      )
      break
    }
    default:
      addTypedJournalEntry(agent, type, 'system', 'unknown', {
        narrativeText: `${actorLabel(agent)} 이벤트: ${type}`,
      })
  }
}

export function disconnectSSE(): void {
  unsubscribe?.()
  unsubscribe = null
  transport?.disconnect()
  transport = null
  pauseOasRuntimeIngress = false
  queuedOasEvents = []
  connected.value = false
}

// Re-export as readable signal for components
export const totalEvents: ReadonlySignal<number> = eventCount
