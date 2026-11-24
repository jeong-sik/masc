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
    const argsVal = jsonObj ? (jsonObj.args ?? jsonObj.input ?? jsonObj.arguments) : undefined
    const resVal = jsonObj ? (jsonObj.result ?? jsonObj.output) : (cleanedBody || undefined)
    const statusStr = typeof jsonObj?.status === 'string'
      ? jsonObj.status
      : typeof jsonObj?.outcome === 'string'
        ? jsonObj.outcome
        : undefined
    toolBlocks.push({
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
      bodyText = ''
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
  if (msg.errorDetail) return true
  if (blocks.isInternalOnly && prefs.internal === 'hidden') return false
  if (blocks.isToolOnly && prefs.tools === 'hidden') return false
  if (
    blocks.bodyText.length === 0
    && blocks.toolBlocks.length === 0
    && blocks.memoryItems.length === 0
    && blocks.autonomousSummary === null
    && blocks.thinkingText !== null
    && prefs.thinking === 'hidden'
  ) {
    return false
  }
  return true
}
