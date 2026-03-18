// MASC Dashboard — Keeper messaging (direct MCP + operator-routed + SSE streaming)

import { currentDashboardActor, jsonHeaders, runOperatorAction } from './core'
import { callMcpTool } from './mcp'
import { isRecord } from '../components/common/normalize'
import {
  formatKeeperVisibleReply,
  normalizeKeeperConversationDetails,
  normalizeKeeperToolResponse,
} from '../keeper-message'
import type { KeeperConversationDetails } from '../types'

// --- Types ---

export interface KeeperToolReply {
  text: string
  details: KeeperConversationDetails | null
}

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

// --- Keeper message calls ---

async function callKeeperMessageRaw(
  name: string,
  message: string,
  models?: string[],
): Promise<string> {
  const args: Record<string, unknown> = { name, message }
  if (models && models.length > 0) args.models = models
  return callMcpTool('masc_keeper_msg', args)
}

async function callKeeperMessageViaOperator(
  name: string,
  message: string,
  models?: string[],
): Promise<KeeperToolReply> {
  const payload: Record<string, unknown> = { message }
  if (models && models.length > 0) payload.models = models
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
  models?: string[],
): Promise<KeeperToolReply> {
  if (models && models.length > 0) {
    const raw = await callKeeperMessageRaw(name, message, models)
    return normalizeKeeperToolResponse(raw)
  }
  return callKeeperMessageViaOperator(name, message)
}

export function sendKeeperMessage(name: string, message: string, models?: string[]): Promise<string> {
  return sendKeeperMessageDetailed(name, message, models).then(reply => reply.text)
}

// --- SSE parsing ---

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
  } catch {
    return null
  }
}

export async function streamKeeperMessage(
  name: string,
  message: string,
  models: string[] | undefined,
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
      ...(models && models.length > 0 ? { models } : {}),
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
        if (event) onEvent(event)
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
