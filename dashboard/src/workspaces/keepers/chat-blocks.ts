/**
 * Pure Chat 3-Block View State & Structured Collapsible Card Parser (`4 Keepers > Chat`).
 *
 * Implements the 3-block visibility controls:
 * - Thinking: `hidden | collapsed | expanded` (cycled via toolbar or `Alt+T`)
 * - Tools: `hidden | summary | full`
 * - Memory & Internal (Memory Recall + Autonomous Turns): `hidden | shown`
 *
 * Parses raw `<thinking>`/`<thought>` tags, tool call/result payloads, memory recall
 * payloads, and autonomous turn JSON blobs into clean structured blocks instead of raw JSON.
 */

import type { ChatToolBlock, ChatTranscriptEntry } from './types'

export type ThinkingViewMode = 'hidden' | 'collapsed' | 'expanded'
export type ToolsViewMode = 'hidden' | 'summary' | 'full'
export type InternalViewMode = 'hidden' | 'shown'

export interface ChatBlockPrefs {
  readonly thinking: ThinkingViewMode
  readonly tools: ToolsViewMode
  readonly internal: InternalViewMode
}

export const DEFAULT_CHAT_BLOCK_PREFS: ChatBlockPrefs = Object.freeze({
  thinking: 'collapsed',
  tools: 'summary',
  internal: 'hidden',
})

const STORAGE_KEY = 'masc:keeper-chat-block-prefs:v1'

export function nextThinkingMode(cur: ThinkingViewMode): ThinkingViewMode {
  if (cur === 'hidden') return 'collapsed'
  if (cur === 'collapsed') return 'expanded'
  return 'hidden'
}

export function nextToolsMode(cur: ToolsViewMode): ToolsViewMode {
  if (cur === 'hidden') return 'summary'
  if (cur === 'summary') return 'full'
  return 'hidden'
}

export function nextInternalMode(cur: InternalViewMode): InternalViewMode {
  return cur === 'hidden' ? 'shown' : 'hidden'
}

export function thinkingModeLabel(mode: ThinkingViewMode): string {
  if (mode === 'hidden') return '숨김'
  if (mode === 'collapsed') return '접힘'
  return '펼침'
}

export function toolsModeLabel(mode: ToolsViewMode): string {
  if (mode === 'hidden') return '숨김'
  if (mode === 'summary') return '요약'
  return '전체'
}

export function internalModeLabel(mode: InternalViewMode): string {
  return mode === 'hidden' ? '숨김' : '표시'
}

export function loadChatBlockPrefs(): ChatBlockPrefs {
  if (typeof window === 'undefined') return DEFAULT_CHAT_BLOCK_PREFS
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    if (!raw) return DEFAULT_CHAT_BLOCK_PREFS
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed !== 'object' || parsed === null) return DEFAULT_CHAT_BLOCK_PREFS
    const rec = parsed as Record<string, unknown>
    const thinking: ThinkingViewMode =
      rec.thinking === 'hidden' || rec.thinking === 'collapsed' || rec.thinking === 'expanded'
        ? rec.thinking
        : DEFAULT_CHAT_BLOCK_PREFS.thinking
    const tools: ToolsViewMode =
      rec.tools === 'hidden' || rec.tools === 'summary' || rec.tools === 'full'
        ? rec.tools
        : DEFAULT_CHAT_BLOCK_PREFS.tools
    const internal: InternalViewMode =
      rec.internal === 'hidden' || rec.internal === 'shown'
        ? rec.internal
        : DEFAULT_CHAT_BLOCK_PREFS.internal
    return { thinking, tools, internal }
  } catch {
    return DEFAULT_CHAT_BLOCK_PREFS
  }
}

export function saveChatBlockPrefs(prefs: ChatBlockPrefs): void {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs))
  } catch {
    // ignore storage quota / private mode
  }
}

export interface ParsedChatBlocks {
  readonly thinkingText: string | null
  readonly bodyText: string
  readonly toolBlocks: readonly ChatToolBlock[]
  readonly memoryItems: readonly string[]
  readonly autonomousSummary: string | null
  readonly autonomousDetails: string | null
  readonly isInternalOnly: boolean
  readonly isToolOnly: boolean
}

function tryParseJsonObject(text: string): Record<string, unknown> | null {
  const trimmed = text.trim()
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return null
  try {
    const parsed: unknown = JSON.parse(trimmed)
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null
  } catch {
    return null
  }
}

export function summarizeCompact(value: unknown, maxLen = 110): string {
  if (value === null || value === undefined) return ''
  const raw = typeof value === 'string'
    ? value.replace(/\s+/g, ' ').trim()
    : JSON.stringify(value)
  if (raw.length <= maxLen) return raw
  return `${raw.slice(0, maxLen - 1)}…`
}

export function prettyFormatPayload(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') {
    const trimmed = value.trim()
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        return JSON.stringify(JSON.parse(trimmed), null, 2)
      } catch {
        return value
      }
    }
    return value
  }
  return JSON.stringify(value, null, 2)
}

function extractInlineThinkingTags(content: string): {
  readonly extractedThinking: string | null
  readonly remaining: string
} {
  const parts: string[] = []
  const cleaned = content.replace(
    /<(?:thinking|thought|reasoning)>([\s\S]*?)<\/(?:thinking|thought|reasoning)>/gi,
    (_m, inner: string) => {
      const t = inner.trim()
      if (t) parts.push(t)
      return ''
    },
  )
  return {
    extractedThinking: parts.length > 0 ? parts.join('\n\n') : null,
    remaining: cleaned.trim(),
  }
}

function extractInlineMemoryTags(content: string): {
  readonly extractedMemory: readonly string[]
  readonly remaining: string
} {
  const items: string[] = []
  const cleaned = content.replace(
    /<(?:memory_recall|memory|recalled_memory)>([\s\S]*?)<\/(?:memory_recall|memory|recalled_memory)>/gi,
    (_m, inner: string) => {
      const t = inner.trim()
      if (t) items.push(t)
      return ''
    },
  )
  return { extractedMemory: items, remaining: cleaned.trim() }
}

/**
 * Classifies a `ChatTranscriptEntry` into structured collapsible blocks so raw
 * JSON blobs from Tool Calls/Results, Memory Recall, and Autonomous Turns render
 * as clean cards governed by the 3 toolbar toggles.
 */
export function parseChatMessageBlocks(msg: ChatTranscriptEntry): ParsedChatBlocks {
  if (msg.role === 'user') {
    return {
      thinkingText: null,
      bodyText: msg.content,
      toolBlocks: [],
      memoryItems: [],
      autonomousSummary: null,
      autonomousDetails: null,
      isInternalOnly: false,
      isToolOnly: false,
    }
  }

  const { extractedThinking, remaining: afterThinking } = extractInlineThinkingTags(msg.content)
  const { extractedMemory, remaining: cleanedBody } = extractInlineMemoryTags(afterThinking)

  const thinkingParts = [msg.thinking?.trim(), extractedThinking].filter(
    (s): s is string => Boolean(s && s.length > 0),
  )
  const thinkingText = thinkingParts.length > 0 ? thinkingParts.join('\n\n') : null

  const toolBlocks: ChatToolBlock[] = [...(msg.toolCalls ?? [])]
  const memoryItems: string[] = [...(msg.memoryItems ?? []), ...extractedMemory]
  let bodyText = cleanedBody
  let autonomousSummary: string | null = null
  let autonomousDetails: string | null = null

  const jsonObj = tryParseJsonObject(cleanedBody)

  // 1. Tool message (`role === 'tool'` or explicit `toolName` or JSON tool payload)
  const isToolEntry =
    msg.role === 'tool'
    || msg.kind === 'tool_call'
    || msg.kind === 'tool_result'
    || (jsonObj !== null && (typeof jsonObj.tool_name === 'string' || typeof jsonObj.tool === 'string') && ('args' in jsonObj || 'input' in jsonObj || 'result' in jsonObj || 'output' in jsonObj))

  if (isToolEntry && toolBlocks.length === 0) {
    const inferredName =
      msg.toolName
      ?? (typeof jsonObj?.tool_name === 'string' ? jsonObj.tool_name : undefined)
      ?? (typeof jsonObj?.tool === 'string' ? jsonObj.tool : undefined)
      ?? 'tool'
    // Persisted `role: "tool"` rows from `keeper_chat_store` store the raw tool
    // input object directly in `content` (e.g. `{"command":"ls","output":"x"}`)
    // without wrapping it in `{ tool_name, args, result }`. Never steal ordinary
    // tool parameter names like `input`/`output`/`result`/`status` from those
    // rows — doing so drops sibling params and blocks lazy `/tool-result` fetch.
    const isExplicitWrapper =
      jsonObj !== null
      && (typeof jsonObj.tool_name === 'string' || typeof jsonObj.tool === 'string')
      && ('args' in jsonObj || 'input' in jsonObj || 'arguments' in jsonObj || 'result' in jsonObj || 'output' in jsonObj)

    let argsVal: unknown
    let resVal: unknown
    let statusStr: string | undefined

    if (msg.role === 'tool' && !isExplicitWrapper) {
      if (jsonObj !== null) {
        argsVal = jsonObj
      } else if (cleanedBody) {
        argsVal = cleanedBody
      }
    } else {
      const explicitArgs = jsonObj ? (jsonObj.args ?? jsonObj.input ?? jsonObj.arguments) : undefined
      const explicitRes = jsonObj ? (jsonObj.result ?? jsonObj.output) : undefined
      argsVal = explicitArgs
      resVal = explicitRes
      if (argsVal === undefined && resVal === undefined) {
        if (jsonObj !== null) {
          if (msg.kind === 'tool_call') {
            argsVal = jsonObj
          } else {
            resVal = jsonObj
          }
        } else if (cleanedBody) {
          resVal = cleanedBody
        }
      }
      statusStr = typeof jsonObj?.status === 'string'
        ? jsonObj.status
        : typeof jsonObj?.outcome === 'string'
          ? jsonObj.outcome
          : undefined
    }

    toolBlocks.push({
      executionId: msg.executionId,
      name: inferredName,
      args: argsVal !== undefined ? prettyFormatPayload(argsVal) : undefined,
      result: resVal !== undefined ? prettyFormatPayload(resVal) : undefined,
      status: statusStr,
    })
    bodyText = ''
  }

  // 2. Memory recall JSON payload or explicit kind
  if (
    msg.kind === 'memory_recall'
    || (jsonObj !== null && (Array.isArray(jsonObj.memory_recall) || Array.isArray(jsonObj.recalled_facts) || jsonObj.kind === 'memory_recall'))
  ) {
    if (jsonObj) {
      const arr = Array.isArray(jsonObj.memory_recall)
        ? jsonObj.memory_recall
        : Array.isArray(jsonObj.recalled_facts)
          ? jsonObj.recalled_facts
          : Array.isArray(jsonObj.facts)
            ? jsonObj.facts
            : []
      for (const item of arr) {
        if (typeof item === 'string' && item.trim()) memoryItems.push(item.trim())
        else if (typeof item === 'object' && item !== null) {
          const rec = item as Record<string, unknown>
          const claim = typeof rec.claim === 'string' ? rec.claim : summarizeCompact(rec, 160)
          if (claim) memoryItems.push(claim)
        }
      }
      if (memoryItems.length === 0) {
        memoryItems.push(prettyFormatPayload(jsonObj))
      }
    } else if (cleanedBody && memoryItems.length === 0) {
      memoryItems.push(cleanedBody)
    }
    bodyText = ''
  }

  // 3. Autonomous turn payload (`autonomousTurn`, `kind === 'autonomous'`, or JSON `{ turn_kind: 'autonomous' | ... }`)
  const isAutonomous =
    msg.autonomousTurn === true
    || msg.kind === 'autonomous'
    || (jsonObj !== null && (jsonObj.autonomous === true || jsonObj.turn_kind === 'autonomous' || jsonObj.source === 'autonomous'))

  if (isAutonomous) {
    if (jsonObj) {
      const headline =
        (typeof jsonObj.summary === 'string' && jsonObj.summary.trim())
        || (typeof jsonObj.reply === 'string' && jsonObj.reply.trim())
        || (typeof jsonObj.action === 'string' && jsonObj.action.trim())
        || summarizeCompact(jsonObj, 120)
      autonomousSummary = headline
      autonomousDetails = prettyFormatPayload(jsonObj)
      bodyText = ''
    } else {
      autonomousSummary = summarizeCompact(cleanedBody || '자율 턴 기록', 120)
      autonomousDetails = cleanedBody || null
      // Preserve readable assistant prose when the autonomous turn also carries
      // trace tool blocks so default `internal: hidden` never drops the reply.
      if (toolBlocks.length === 0) {
        bodyText = ''
      }
    }
  }

  const isInternalMessage =
    msg.kind === 'memory_recall'
    || msg.kind === 'autonomous'
    || msg.kind === 'system_internal'
    || msg.autonomousTurn === true
    || (msg.role === 'system' && bodyText.length === 0 && (memoryItems.length > 0 || autonomousSummary !== null))

  const isToolOnly =
    bodyText.length === 0
    && thinkingText === null
    && toolBlocks.length > 0
    && memoryItems.length === 0
    && autonomousSummary === null

  const isInternalOnly =
    bodyText.length === 0
    && toolBlocks.length === 0
    && (isInternalMessage || memoryItems.length > 0 || autonomousSummary !== null)

  return {
    thinkingText,
    bodyText,
    toolBlocks,
    memoryItems,
    autonomousSummary,
    autonomousDetails,
    isInternalOnly,
    isToolOnly,
  }
}

export function shouldRenderChatEntry(
  msg: ChatTranscriptEntry,
  blocks: ParsedChatBlocks,
  prefs: ChatBlockPrefs,
): boolean {
  if (msg.errorDetail || msg.deliveryState === 'Streaming') return true
  if (blocks.isInternalOnly && prefs.internal === 'hidden') return false
  if (blocks.isToolOnly && prefs.tools === 'hidden') return false
  const hasVisibleBody = blocks.bodyText.length > 0
  const hasVisibleThinking = blocks.thinkingText !== null && prefs.thinking !== 'hidden'
  const hasVisibleTools = blocks.toolBlocks.length > 0 && prefs.tools !== 'hidden'
  const hasVisibleInternal =
    prefs.internal === 'shown'
    && (blocks.memoryItems.length > 0 || blocks.autonomousSummary !== null)
  return hasVisibleBody || hasVisibleThinking || hasVisibleTools || hasVisibleInternal
}

// ── Live Stream Tool Matching, Status Labels & Native Tool Formatters ─────

export interface ToolCallMatchRef {
  readonly toolCallId?: string
  readonly streamKey?: string
}

/**
 * Matches a streaming tool call in a turn's `toolCalls` list without cross-
 * contaminating parallel tool calls. Prefers `(toolStreamScope, toolCallBlockIndex)`
 * (`streamKey`), then `toolCallId`, and only falls back to the last entry when
 * neither identifier was supplied by the event.
 */
export function findToolCallIndex(
  list: readonly ChatToolBlock[],
  ref: ToolCallMatchRef,
): number {
  const sk = ref.streamKey?.trim() || undefined
  const id = ref.toolCallId?.trim() || undefined
  if (sk) {
    const byKey = list.findIndex((t) => t.streamKey === sk)
    if (byKey >= 0) return byKey
  }
  if (id) {
    // Only match by provider toolCallId when stream scopes don't conflict —
    // prevents sequential IDs (`call_0`) from colliding across tool rounds.
    const byId = list.findIndex(
      (t) => t.id === id && (!sk || !t.streamKey || t.streamKey === sk),
    )
    if (byId >= 0) return byId
  }
  if (!sk && !id && list.length > 0) {
    return list.length - 1
  }
  return -1
}

export function upsertStreamToolCall(
  existing: readonly ChatToolBlock[] | undefined,
  ref: ToolCallMatchRef,
  updater: (cur: ChatToolBlock) => ChatToolBlock,
  createIfMissing?: () => ChatToolBlock,
): readonly ChatToolBlock[] {
  const list = [...(existing ?? [])]
  const idx = findToolCallIndex(list, ref)
  if (idx >= 0) {
    list[idx] = updater(list[idx]!)
    return list
  }
  if (createIfMissing) {
    list.push(createIfMissing())
  }
  return list
}

export function toolStatusMeta(
  status: string | undefined,
): { readonly label: string; readonly tone: 'info' | 'warn' | 'ok' | 'bad' } {
  switch (status) {
    case 'running':
    case 'pending':
      return { label: '실행 중', tone: 'info' }
    case 'awaiting_result':
      return { label: '결과 대기', tone: 'info' }
    case 'awaiting_approval':
      return { label: '승인 대기', tone: 'warn' }
    case 'error':
    case 'failed':
    case 'err':
    case 'denied':
    case 'rejected':
      return { label: '오류', tone: 'bad' }
    case 'completed':
    case 'ok':
    case 'settled':
      return { label: '완료', tone: 'ok' }
    default:
      return { label: status ? status : '실행됨', tone: 'info' }
  }
}

export function formatNativeProgressLabel(progress: Record<string, unknown>): string | null {
  const kind = typeof progress.kind === 'string' ? progress.kind : null
  if (!kind) return null
  if (kind === 'message_reported' && typeof progress.message === 'string' && progress.message.trim()) {
    return summarizeCompact(progress.message, 80)
  }
  if (kind === 'heartbeat_reported' && typeof progress.elapsed_seconds === 'number') {
    return `실행 중 (${progress.elapsed_seconds}s)`
  }
  if (kind === 'output_observed' && typeof progress.byte_count === 'number') {
    return `출력 ${progress.byte_count.toLocaleString('en-US')}B`
  }
  if (kind === 'retry_reported') {
    const attempt = typeof progress.attempt === 'number' ? progress.attempt : null
    const maxRetries = typeof progress.max_retries === 'number' ? progress.max_retries : null
    const cat = typeof progress.error_category === 'string' ? progress.error_category : ''
    const seq = attempt !== null && maxRetries !== null ? `${attempt}/${maxRetries}` : ''
    return `재시도 ${seq}${cat ? ` · ${cat}` : ''}`.trim()
  }
  if (kind === 'retry_cleared') {
    return '재시도 복구됨'
  }
  return null
}

export function formatNativeCompletionSummary(
  completion: Record<string, unknown>,
): { readonly status: 'completed' | 'error'; readonly summary?: string } {
  const kind = typeof completion.kind === 'string' ? completion.kind : 'end_observed'
  const exitCode = typeof completion.exit_code === 'number' ? completion.exit_code : null
  const isError =
    kind === 'error_reported'
    || kind === 'decline_reported'
    || (kind === 'result_received' && completion.is_error === true)
    || (exitCode !== null && exitCode !== 0)
  const parts: string[] = []
  if (kind === 'error_reported') parts.push('오류 보고됨')
  else if (kind === 'decline_reported') parts.push('거절됨')
  else if (kind === 'unrecognized_status' && typeof completion.status === 'string') parts.push(completion.status)
  if (exitCode !== null) parts.push(`exit ${exitCode}`)
  return {
    status: isError ? 'error' : 'completed',
    summary: parts.length > 0 ? parts.join(' · ') : undefined,
  }
}
