// MASC Dashboard server-push event projection.
// Transport ownership lives in dashboard-ws.ts; this module only applies the
// typed events that arrive through that single WebSocket connection.

import { signal, type ReadonlySignal } from '@preact/signals'
import type { JournalEntry, JournalEventType, SSEEvent } from './types'
import { SYSTEM_ACTOR_NAME } from './types/core'
import { formatCost } from './lib/format-number'
import { isRecord } from './lib/type-guards'
import {
  removeBoardPost,
  refreshFusionRuns,
} from './store'
import {
  defaultJournalSeverity,
  normalizeJournalSeverity,
  normalizeJournalSource,
} from './journal-entry'
import { appendLiveToolCall } from './components/session-trace/session-trace-live-store'
import { scheduleSessionTraceReload } from './components/session-trace/session-trace-state'
import { appendAuditEntry } from './live-store'
import { applyKeeperOperationTurnEvent } from './keeper-stream'
import type { KeeperChatStreamEvent } from './api'
import { isCrashedPhase } from './lib/keeper-predicates'
import {
  parseAgentCorePayload,
  type TypedAgentCorePayload,
} from './schemas/sse-event-payload'
import { asNumber } from './components/common/normalize'
import { RingBuffer } from './lib/ring-buffer'
import type * as AgentCoreRuntimeStore from './agent-core-runtime-store'

import { isAgentCoreEventType, sseEventFamily, withoutMascNamespace } from './lib/sse-event-type'
import {
  MAX_JOURNAL_ENTRIES,
} from './config/constants'

let agentCoreRuntimeStorePromise: Promise<typeof AgentCoreRuntimeStore> | null = null

function loadAgentCoreRuntimeStore(): Promise<typeof AgentCoreRuntimeStore> {
  agentCoreRuntimeStorePromise ??= import('./agent-core-runtime-store')
  return agentCoreRuntimeStorePromise
}

function traceValueString(value: unknown): string | null {
  if (typeof value === 'string') return value
  if (value == null) return null
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function traceToolArgs(value: unknown): string | Record<string, unknown> | null {
  if (typeof value === 'string') return value
  if (isRecord(value)) {
    return value
  }
  return traceValueString(value)
}

function normalizeKeeperTraceName(raw: string | undefined): string {
  const name = (raw ?? '').trim()
  const match = /^keeper-(.+)-agent$/.exec(name)
  return match?.[1] ?? name
}

function keeperTraceNameFromEvent(event: SSEEvent, fallback: string): string {
  return normalizeKeeperTraceName(
    event.name
      ?? event.keeper_name
      ?? event.agent_name
      ?? fallback,
  )
}

// Per-turn cache observability (RFC-0382). Two sources with different
// semantics, shown side by side and never merged: `cache_read_tokens` is
// usage-reported by cloud providers; `cache_n`/`prompt_n` are wire timings
// (llama-server, Ollama) — KV-reused vs freshly prefilled prompt tokens.
function turnCacheSuffix(event: SSEEvent): string {
  const parts: string[] = []
  const cacheRead = asNumber(event.cache_read_tokens)
  if (cacheRead != null && cacheRead > 0) parts.push(`캐시 read ${cacheRead}tok`)
  const cacheN = asNumber(event.cache_n)
  const promptN = asNumber(event.prompt_n)
  if (cacheN != null && promptN != null) {
    const seen = cacheN + promptN
    const pct = seen > 0 ? ` (${Math.round((cacheN / seen) * 100)}%)` : ''
    parts.push(`KV 재사용 ${cacheN}/${seen}tok${pct}`)
  }
  return parts.length > 0 ? ` · ${parts.join(' · ')}` : ''
}

// --- Signals ---

const eventCount = signal(0)
export const lastEvent = signal<SSEEvent | null>(null)
export const journal = signal<JournalEntry[]>([])

// --- Journal ---

const journalRing = new RingBuffer<JournalEntry>(MAX_JOURNAL_ENTRIES)

export function _resetJournalForTests(): void {
  journalRing.clear()
  journal.value = []
}

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
  return normalized || SYSTEM_ACTOR_NAME
}

function projectedActorLabel(raw: string | undefined, displayName: string | undefined): string {
  const projected = displayName?.trim()
  return actorLabel(projected || raw)
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
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

/** Extract Agent Core envelope fields (correlation_id, run_id, ts_unix) from an SSE
 * event into the shape expected by JournalEntry. Returns an empty object for
 * non-Agent Core events so spreading into `extra` stays inert. */
function envelopeFromEvent(event: SSEEvent): Pick<JournalEntry, 'correlationId' | 'runId' | 'agentCoreTs'> {
  const out: Pick<JournalEntry, 'correlationId' | 'runId' | 'agentCoreTs'> = {}
  if (typeof event.correlation_id === 'string' && event.correlation_id.trim() !== '') {
    out.correlationId = event.correlation_id
  }
  if (typeof event.run_id === 'string' && event.run_id.trim() !== '') {
    out.runId = event.run_id
  }
  if (typeof event.ts_unix === 'number' && Number.isFinite(event.ts_unix)) {
    out.agentCoreTs = event.ts_unix
  }
  return out
}

/** Parse an Agent Core event payload through the atdgen-generated typed boundary.
 *  Returns the typed payload on success, or null on failure; failures are
 *  logged with structured issues so malformed events are not silently dropped. */
function parseAgentCorePayloadOrWarn(
  eventType: string,
  payload: unknown,
): TypedAgentCorePayload | null {
  const result = parseAgentCorePayload(eventType, payload)
  if (result.success) return result.data
  console.warn('[server-push] dropping malformed Agent Core payload', {
    issues: result.error.issues,
    payload,
  })
  return null
}

// --- WebSocket event ingress ---

let pauseAgentCoreRuntimeIngress = false
let queuedAgentCoreEvents: SSEEvent[] = []

export function pauseQueuedAgentCoreRuntimeIngress(): void {
  pauseAgentCoreRuntimeIngress = true
}

export function resumeQueuedAgentCoreRuntimeIngress(): void {
  pauseAgentCoreRuntimeIngress = false
  if (queuedAgentCoreEvents.length === 0) return
  const pending = queuedAgentCoreEvents
  queuedAgentCoreEvents = []
  for (const event of pending) {
    handleEvent(event)
  }
}

export function normalizeSSEDispatchType(rawType: string): string {
  if (
    rawType === 'agent_core:masc:audit_event'
    || rawType === 'masc:audit_event'
    || rawType === 'masc/audit_event'
  ) {
    return 'audit_event'
  }
  // Board events keep their namespace: the bare `board_*` names mean something
  // else to the dispatcher.
  return sseEventFamily(rawType) === 'board' ? rawType : withoutMascNamespace(rawType)
}

/** Apply one typed event delivered by the dashboard WebSocket. */
export function recordServerPushEvent(event: SSEEvent): void {
  lastEvent.value = event
  eventCount.value++
  handleEvent(event)
}

function handleEvent(event: SSEEvent): void {
  // Normalize only dispatch aliases. The Agent Core Event_bus bridge relays
  // MASC Custom("masc.*") payloads as agent_core:masc:* events; audit ledger
  // events still belong to the dashboard audit stream.
  const rawType = event.type
  if (pauseAgentCoreRuntimeIngress && isAgentCoreEventType(rawType)) {
    queuedAgentCoreEvents.push(event)
    return
  }
  const type = normalizeSSEDispatchType(rawType)
  const agent = event.agent ?? event.author ?? event.from ?? event.from_agent ?? ''
  if (isAgentCoreEventType(rawType)) {
    void loadAgentCoreRuntimeStore()
      .then(({ applyAgentCoreRuntimeEvent }) => {
        applyAgentCoreRuntimeEvent(event, { includeLiveTrace: true })
      })
      .catch(err => {
        console.warn('[server-push] Agent Core runtime handler unavailable', err instanceof Error ? err.message : err)
      })
  }

  switch (type) {
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
    case 'fusion_run_status':
      // RFC-0266 §7 Phase 4: a fusion run changed state (running →
      // completed/failed). Re-fetch the registry snapshot, which is the SSOT;
      // the event is only a change trigger, never the source of truth, so a
      // missed/duplicated event self-heals on the next change or route visit.
      void refreshFusionRuns()
      break
    case 'keeper_turn_complete':
      {
        const keeperName = keeperTraceNameFromEvent(event, agent)
        if (keeperName) scheduleSessionTraceReload(keeperName, true)
      }
      addTypedJournalEntry(
        event.name ?? agent,
        `Turn ${event.turn ?? '?'} tok=${((event.input_tokens ?? 0) + (event.output_tokens ?? 0))} tools=${event.tool_calls_made ?? 0}${turnCacheSuffix(event)}`,
        'keepers',
        'unknown',
        {
          severity: 'info',
          source: event.source,
          narrativeText:
            `${actorLabel(event.name ?? agent)} turn ${event.turn ?? '?'}`
            + ` (${formatCost(event.cost_usd ?? 0)}, tools=${event.tool_calls_made ?? 0})`,
        },
      )
      break
    case 'keeper_heartbeat':
      addTypedJournalEntry(
        event.name ?? agent,
        `Heartbeat gen=${event.generation ?? '?'}`,
        'keepers',
        'keeper_heartbeat',
        {
          severity: event.severity,
          source: event.source,
          narrativeText:
            `${actorLabel(event.name ?? agent)}가 하트비트를 보냈습니다`
            + ` (gen ${event.generation ?? '?'})`,
        },
      )
      break
    case 'keeper_handoff':
      addTypedJournalEntry(
        event.name ?? agent,
        `Handoff gen ${event.from_generation ?? '?'} -> ${event.to_generation ?? '?'} (runtime)`,
        'keepers',
        'keeper_handoff',
        {
          severity: event.severity,
          source: event.source,
          narrativeText:
            `${actorLabel(event.name ?? agent)}가 keeper handoff를 수행했습니다`
            + ` (gen ${event.from_generation ?? '?'} → ${event.to_generation ?? '?'}, runtime)`,
        },
      )
      break
    case 'keeper_phase_changed':
      addTypedJournalEntry(
        event.name ?? agent,
        `KSM phase: ${event.prev_phase ?? '?'} → ${event.new_phase ?? '?'} (${event.event ?? '?'})`,
        'keepers',
        'keeper_phase_changed',
        {
          severity: isCrashedPhase(event.new_phase) ? 'error' : 'info',
          source: event.source,
          narrativeText: `${actorLabel(event.name ?? agent)}의 KSM phase가 ${event.prev_phase ?? '?'}에서 ${event.new_phase ?? '?'}로 변경되었습니다`,
        },
      )
      break
    case 'keeper_tool_call': {
      const toolName = event.tool_name ?? '?'
      const durationMs = event.duration_ms ?? 0
      const isError = event.disposition === 'failed'
      const isDeferred = event.disposition === 'deferred'
      let dispositionSuffix = ''
      if (isError) dispositionSuffix = ' ERR'
      else if (isDeferred) dispositionSuffix = ' DEFERRED'
      addTypedJournalEntry(
        event.name ?? agent,
        `Tool: ${toolName} (${durationMs}ms)${dispositionSuffix}`,
        'keepers',
        'keeper_tool_call',
        {
          severity: isError ? 'warn' : 'info',
          source: event.source,
          narrativeText: `${actorLabel(event.name ?? agent)}가 ${toolName} 도구를 실행했습니다 (${durationMs}ms)`,
        },
      )
      // Push to live trace if session trace is open for this keeper
      {
        const keeperName = keeperTraceNameFromEvent(event, agent)
        if (!keeperName) break
        const toolArgs = traceToolArgs(event.tool_args) ?? event.tool_args_preview ?? null
        const toolResult = traceValueString(event.tool_result) ?? event.tool_output_preview ?? null
        appendLiveToolCall(keeperName, {
          toolName,
          durationMs,
          success: !isError,
          error: event.error_text ?? null,
          tsUnix: typeof event.ts_unix === 'number' ? event.ts_unix : Date.now() / 1000,
          toolArgs,
          toolResult,
          toolIoRedacted: event.tool_io_redacted === true,
        })
      }
      break
    }
    case 'keeper_chat_operation_event': {
      const keeperName = event.name ?? agent
      const operationId = event.operation_id?.trim()
      if (!keeperName || !operationId || !isRecord(event.ag_ui_event)) break
      applyKeeperOperationTurnEvent(keeperName, {
        operationId,
        event: event.ag_ui_event as unknown as KeeperChatStreamEvent,
      })
      if (
        event.ag_ui_event.type === 'CUSTOM'
        && event.ag_ui_event.name === 'KEEPER_TOOL_RESULT_READY'
      ) {
        void import('./keeper-runtime')
          .then(mod => mod.hydrateKeeperToolOutputs(keeperName))
          .catch(err => {
            console.debug(
              '[keeper-stream] queued tool output hydration unavailable',
              err instanceof Error ? err.message : '',
            )
          })
      }
      break
    }
    // Agent Core bridge events
    case 'agent_core:masc:keeper:lifecycle': {
      break
    }
    case 'agent_core:agent_started': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'agent_started') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Agent run started${payload.task_id ? ` · ${payload.task_id}` : ''}`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} agent run started${payload.task_id ? ` (${payload.task_id})` : ''}`,
          preview: payload.task_id,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:agent_completed': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'agent_completed') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Agent run completed${payload.task_id ? ` · ${payload.task_id}` : ''} · ${payload.elapsed_s.toFixed(1)}s`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} agent run completed${payload.task_id ? ` (${payload.task_id})` : ''}`,
          preview: payload.task_id,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:agent_yielded': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'agent_yielded') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Agent run yielded · T${payload.turn} · ${payload.elapsed_s.toFixed(1)}s`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} agent run yielded at turn ${payload.turn}`,
          preview: payload.task_id,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:agent_input_required': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'agent_input_required') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Agent input required · ${payload.request_id}`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} agent run requires input: ${payload.question}`,
          preview: payload.question,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:agent_failed': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'agent_failed') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Agent run failed${payload.task_id ? ` · ${payload.task_id}` : ''} · ${payload.elapsed_s.toFixed(1)}s${payload.error ? ` · ${payload.error}` : ''}`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} agent run failed${payload.task_id ? ` (${payload.task_id})` : ''}${payload.error ? `: ${payload.error}` : ''}`,
          preview: payload.task_id ?? payload.error,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:tool_called': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'tool_called') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Tool called: ${payload.tool_name}`,
        'agentCore',
        'agent_core_tool',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} 도구 called: ${payload.tool_name}`,
        },
      )
      break
    }
    case 'agent_core:tool_completed': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'tool_completed') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Tool completed: ${payload.tool_name}`,
        'agentCore',
        'agent_core_tool',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} 도구 completed: ${payload.tool_name}`,
        },
      )
      break
    }
    case 'agent_core:handoff_requested': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'handoff_requested') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.from_agent,
        `Handoff requested · ${payload.from_agent}→${payload.to_agent}${payload.reason ? ` · ${payload.reason}` : ''}`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `Handoff requested: ${actorLabel(payload.from_agent)} → ${actorLabel(payload.to_agent)}${payload.reason ? ` (${payload.reason})` : ''}`,
          preview: `${payload.from_agent}→${payload.to_agent}`,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:handoff_completed': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'handoff_completed') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.from_agent,
        `Handoff completed · ${payload.from_agent}→${payload.to_agent} · ${payload.elapsed_s.toFixed(1)}s`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `Handoff completed: ${actorLabel(payload.from_agent)} → ${actorLabel(payload.to_agent)}`,
          preview: `${payload.from_agent}→${payload.to_agent}`,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:turn_started': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'turn_started') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Turn started · T${payload.turn}`,
        'agentCore',
        'agent_core_turn',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} turn started (T${payload.turn})`,
        },
      )
      break
    }
    case 'agent_core:turn_completed': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'turn_completed') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Turn completed · T${payload.turn}`,
        'agentCore',
        'agent_core_turn',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} turn completed (T${payload.turn})`,
        },
      )
      break
    }
    case 'agent_core:context_compacted': {
      const parsed = parseAgentCorePayloadOrWarn(type, event.payload)
      if (!parsed || parsed.kind !== 'context_compacted') break
      const { payload } = parsed
      addTypedJournalEntry(
        payload.agent_name,
        `Agent Core compact · ${payload.before_tokens}→${payload.after_tokens} · ${payload.phase}`,
        'agentCore',
        'agent_core_context',
        {
          severity: event.severity,
          source: event.source,
          narrativeText: `${actorLabel(payload.agent_name)} Agent Core context compact (${payload.phase})`,
        },
      )
      break
    }
    case 'agent_core:durable:llm_request': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const turn = asNumber(p.turn)
      const inputTokens = asNumber(p.input_tokens) ?? 0
      const cacheReadTokens =
        asNumber(p.cache_read_tokens)
        ?? asNumber(p.cache_read_input_tokens)
      const cacheMissInputTokens = asNumber(p.cache_miss_input_tokens)
      const cacheSuffix =
        cacheReadTokens != null || cacheMissInputTokens != null
          ? ` · cache read ${cacheReadTokens ?? 0}tok · miss ${cacheMissInputTokens ?? 0}tok`
          : ''
      addTypedJournalEntry(
        agentName,
        `Agent Core durable llm_request${turn != null ? ` · T${turn}` : ''} · runtime · ${inputTokens}tok${cacheSuffix}`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:durable:llm_response': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const turn = asNumber(p.turn)
      const outputTokens = asNumber(p.output_tokens) ?? 0
      const stopReason = asString(p.stop_reason) ?? 'unknown'
      const durationMs = asNumber(p.duration_ms)
      addTypedJournalEntry(
        agentName,
        `Agent Core durable llm_response${turn != null ? ` · T${turn}` : ''} · ${outputTokens}tok · ${stopReason}${durationMs != null ? ` · ${durationMs.toFixed(0)}ms` : ''}`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:durable:error_occurred': {
      const p = (event.payload ?? {}) as Record<string, unknown>
      const agentName = asString(p.agent_name) ?? asString(event.agent_name) ?? agent
      const turn = asNumber(p.turn)
      const errorDomain = asString(p.error_domain) ?? 'unknown'
      const detail = asString(p.detail) ?? ''
      addTypedJournalEntry(
        agentName,
        `Agent Core 에러 · ${errorDomain}${turn != null ? ` · T${turn}` : ''}`,
        'agentCore',
        'agent_core_event',
        {
          severity: event.severity,
          source: event.source,
          preview: detail || undefined,
          ...envelopeFromEvent(event),
        },
      )
      break
    }
    case 'agent_core:durable:turn_started':
    case 'agent_core:durable:tool_called':
    case 'agent_core:durable:tool_completed':
    case 'agent_core:durable:state_transition':
    case 'agent_core:durable:checkpoint_saved': {
      // Already covered by non-durable agent_core:* events; journal-only.
      addTypedJournalEntry(agent, type, 'agentCore', 'agent_core_event', {
        severity: event.severity,
        source: event.source,
      })
      break
    }
    case 'audit_event': {
      // Global audit ledger event pushed by the server event bus (O2 Phase 2).
      // Payload fields mirror the /api/v1/audit entry shape.
      const p = (event.payload ?? {}) as Record<string, unknown>
      const auditId = (event.audit_id ?? (p.id as string)) ?? ''
      const auditTs = (event.audit_ts ?? (p.ts as string)) ?? new Date().toISOString()
      const auditActor = (event.audit_actor ?? (p.actor as string)) ?? agent
      const auditKind = (event.audit_kind ?? (p.kind as string)) ?? type
      const auditTarget = event.audit_target ?? (p.target as string | undefined)
      const auditSummary = (event.audit_summary ?? (p.summary as string)) ?? auditKind
      const auditSeverity = (event.audit_severity ?? (p.severity as string)) ?? '(unknown severity)'
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

// Re-export as readable signal for components
export const totalEvents: ReadonlySignal<number> = eventCount
