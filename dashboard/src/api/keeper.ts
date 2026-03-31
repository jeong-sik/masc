// MASC Dashboard — Keeper messaging (direct, operator-mediated, SSE streaming)

import { isRecord } from '../components/common/normalize'
import {
  formatKeeperVisibleReply,
  normalizeKeeperConversationDetails,
} from '../keeper-message'
import type { KeeperConversationDetails } from '../types'
import { currentDashboardActor, runOperatorAction } from './core'
import { resolveDashboardActorName } from '../lib/dashboard-actor'
import { resolveDashboardAuthToken } from '../lib/dashboard-auth'

// --- Types ---

export interface KeeperToolReply {
  text: string
  details: KeeperConversationDetails | null
}

// Server no longer enforces an external timeout for keeper_msg.
// Keeper internal limits (max_turns, max_cost_usd, max_tokens) control duration.
// Client-side abort via AbortSignal is the recommended cancellation path.

export interface KeeperChatStreamEvent {
  type: string
  threadId?: string
  runId?: string
  messageId?: string
  role?: string
  delta?: string
  name?: string
  value?: unknown
  timestamp?: number
}

// --- Direct and operator-mediated messaging ---

async function callKeeperMessageViaOperator(
  name: string,
  message: string,
): Promise<KeeperToolReply> {
  const payload: Record<string, unknown> = {
    message,
    direct_reply: true,
  }
  const response = await runOperatorAction({
    actor: currentDashboardActor(),
    action_type: 'keeper_message',
    target_type: 'keeper',
    target_id: name,
    payload,
  })

  const resultPayload = isRecord(response.result) ? response.result : null
  const rawReply =
    resultPayload && typeof resultPayload.reply === 'string'
      ? resultPayload.reply
      : ''
  const detailsRaw =
    resultPayload && isRecord(resultPayload.result)
      ? resultPayload.result
      : resultPayload
  const details = normalizeKeeperConversationDetails(detailsRaw)
  const text = formatKeeperVisibleReply(rawReply || '(empty reply)')
  return { text, details }
}

export async function sendKeeperMessageDetailed(
  name: string,
  message: string,
): Promise<KeeperToolReply> {
  return callKeeperMessageViaOperator(name, message)
}

// --- SSE streaming ---

function jsonHeaders(): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  const token = resolveDashboardAuthToken()
  const agent = resolveDashboardActorName(window.location.search)
  if (token) headers['Authorization'] = `Bearer ${token}`
  if (agent) headers['X-MASC-Agent'] = agent
  return headers
}

function parseSseFrames(chunk: string): { frames: string[]; rest: string } {
  const normalized = chunk.replace(/\r\n/g, '\n')
  const frames: string[] = []
  let start = 0
  for (;;) {
    const split = normalized.indexOf('\n\n', start)
    if (split < 0) {
      return {
        frames,
        rest: normalized.slice(start),
      }
    }
    frames.push(normalized.slice(start, split))
    start = split + 2
  }
}

function parseSseEvent(frame: string): KeeperChatStreamEvent | null {
  const dataLines = frame
    .split('\n')
    .filter(line => line.startsWith('data:'))
    .map(line => line.slice(5).trimStart())
  if (dataLines.length === 0) return null
  try {
    return JSON.parse(dataLines.join('\n')) as KeeperChatStreamEvent
  } catch (err) {
    console.debug('[keeper-stream] SSE frame parse failed', dataLines.join('\n').slice(0, 120), err instanceof Error ? err.message : err)
    return null
  }
}

function isTerminalKeeperStreamEvent(event: KeeperChatStreamEvent): boolean {
  return event.type === 'RUN_FINISHED' || event.type === 'RUN_ERROR'
}

export async function streamKeeperMessage(
  name: string,
  message: string,
  {
    signal,
    onEvent,
  }: {
    signal?: AbortSignal
    onEvent: (event: KeeperChatStreamEvent) => void
  },
): Promise<void> {
  const res = await fetch('/api/v1/keepers/chat/stream', {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      Accept: 'text/event-stream',
    },
    body: JSON.stringify({
      name,
      message,
      direct_reply: true,
      }),
    signal,
  })

  if (!res.ok) {
    const raw = await res.text()
    let message = raw || `Streaming request failed (${res.status})`
    try {
      const parsed = JSON.parse(raw) as { error?: { message?: string }; message?: string }
      message = parsed.error?.message ?? parsed.message ?? message
    } catch {
      // Keep raw text fallback.
    }
    throw new Error(message)
  }

  if (!res.body) {
    throw new Error('Streaming response body is unavailable')
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  try {
    for (;;) {
      const { done, value } = await reader.read()
      buffer += decoder.decode(value ?? new Uint8Array(), { stream: !done })
      const { frames, rest } = parseSseFrames(buffer)
      buffer = rest
      for (const frame of frames) {
        const event = parseSseEvent(frame)
        if (!event) continue
        onEvent(event)
        if (isTerminalKeeperStreamEvent(event)) {
          try {
            await reader.cancel()
          } catch {
            // Ignore stream cancellation errors after terminal events.
          }
          return
        }
      }
      if (done) break
    }
    const tail = buffer.trim()
    if (tail) {
      const event = parseSseEvent(tail)
      if (event) onEvent(event)
    }
  } finally {
    reader.releaseLock()
  }
}

// --- Chat history ---

export interface KeeperChatHistoryMessage {
  role: string
  content: string
  ts: number
}

export async function fetchKeeperChatHistory(
  name: string,
): Promise<KeeperChatHistoryMessage[]> {
  try {
    const resp = await fetch(
      `/api/v1/keepers/${encodeURIComponent(name)}/chat/history`,
      { headers: jsonHeaders() },
    )
    if (!resp.ok) return []
    const data: unknown = await resp.json()
    if (!Array.isArray(data)) return []
    return data.filter(
      (m): m is KeeperChatHistoryMessage =>
        isRecord(m) &&
        typeof m.role === 'string' &&
        typeof m.content === 'string' &&
        typeof m.ts === 'number',
    )
  } catch {
    return []
  }
}

// --- Keeper lifecycle (boot / shutdown) ---

export interface KeeperLifecycleResponse {
  ok: boolean
  action?: 'boot' | 'shutdown'
  name?: string
  detail?: unknown
  error?: string
}

async function safeJsonResponse<T>(resp: Response, fallbackError: string): Promise<T> {
  try {
    return await resp.json() as T
  } catch {
    return { ok: false, error: `${fallbackError} (HTTP ${resp.status})` } as T
  }
}

async function safeKeeperLifecycle(url: string, fallbackError: string): Promise<KeeperLifecycleResponse> {
  try {
    const resp = await fetch(url, { method: 'POST', headers: jsonHeaders() })
    return await safeJsonResponse<KeeperLifecycleResponse>(resp, fallbackError)
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : fallbackError }
  }
}

export function bootKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/boot`,
    `Failed to boot ${name}`,
  )
}

export function shutdownKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/shutdown`,
    `Failed to shut down ${name}`,
  )
}

// --- Tool allowlist/denylist editing ---

export type ToolEditAction =
  | 'set_allowlist'
  | 'set_denylist'
  | 'add_allow'
  | 'remove_allow'
  | 'add_deny'
  | 'remove_deny'

export interface ToolEditResponse {
  ok: boolean
  tool_allowlist: string[]
  tool_denylist: string[]
  active_masc_tool_count: number
  total_active: number
  error?: string
}

export async function editKeeperTools(
  name: string,
  action: ToolEditAction,
  tools: string[],
): Promise<ToolEditResponse> {
  const resp = await fetch(
    `/api/v1/keepers/${encodeURIComponent(name)}/tools`,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify({ action, tools }),
    },
  )
  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText)
    throw new Error(`Tool edit failed (${resp.status}): ${text}`)
  }
  return resp.json() as Promise<ToolEditResponse>
}
