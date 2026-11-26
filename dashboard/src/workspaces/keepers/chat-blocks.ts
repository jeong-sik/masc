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

import { Marked } from 'marked'
import type { KeeperChatTranscriptSlot } from '../../keeper-delivery-provenance'
import { parseToolBlobMarker } from '../../lib/tool-blob-marker'
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

export function toolResultMarkdownPreview(content: string): string | null {
  const marker = parseToolBlobMarker(content)
  return marker?.mime.toLowerCase().split(';', 1)[0] === 'text/markdown' && marker.preview.trim()
    ? marker.preview : null
}

const auxiliaryTags = 'think|thinking|thought|reasoning|memory_recall|memory|recalled_memory'
const auxiliaryStart = new RegExp(`\n {0,3}<(?:${auxiliaryTags})>`, 'i')
const auxiliaryBlock = new RegExp(`^ {0,3}<(${auxiliaryTags})>([\\s\\S]*?)</\\1\\s*>`, 'i')

const chatLexer = new Marked().use({
  extensions: [{
    name: 'chatAuxiliary',
    level: 'block',
    start(source) {
      const index = source.search(auxiliaryStart)
      return index >= 0 ? index + 1 : undefined
    },
    tokenizer(source) {
      const match = auxiliaryBlock.exec(source)
      if (!match) return undefined
      const tag = match[1]?.toLowerCase()
      const kind =
        tag === 'think' || tag === 'thinking' || tag === 'thought' || tag === 'reasoning'
          ? 'thinking'
          : 'memory'
      return { type: 'chatAuxiliary', raw: match[0], kind, text: (match[2] ?? '').trim() }
    },
  }],
})

function extractAuxiliaryBlocks(content: string) {
  const thinking: string[] = []
  const memory: string[] = []
  if (!auxiliaryBlock.test(content) && !auxiliaryStart.test(content)) {
    return { thinking, memory, body: content.trim() }
  }
  const body: string[] = []
  for (const token of chatLexer.lexer(content)) {
    if (token.type === 'chatAuxiliary') {
      if (!token.text) continue
      if (token.kind === 'thinking') thinking.push(token.text)
      else memory.push(token.text)
    } else {
      body.push(token.raw)
    }
  }
  return { thinking, memory, body: body.join('').trim() }
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

  const auxiliary = extractAuxiliaryBlocks(msg.content)
  const cleanedBody = auxiliary.body

  const thinkingParts = [msg.thinking?.trim(), ...auxiliary.thinking].filter(
    (s): s is string => Boolean(s && s.length > 0),
  )
  const thinkingText = thinkingParts.length > 0 ? thinkingParts.join('\n\n') : null

  const toolBlocks: ChatToolBlock[] = [...(msg.toolCalls ?? [])]
  const memoryItems: string[] = [...(msg.memoryItems ?? []), ...auxiliary.memory]
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
        } else if (msg.content) {
          resVal = msg.content
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
      result: typeof resVal === 'string' ? resVal
        : resVal !== undefined ? prettyFormatPayload(resVal) : undefined,
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
  if (msg.errorDetail || msg.retainedImages?.length || msg.deliveryState === 'Streaming') return true
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

/**
 * Deduplicates persisted `role: 'tool'` rows against tool calls already decoded
 * from assistant `blocks[].trace[kind=tool]` (or direct `toolCalls`) sharing the
 * same `executionId`.
 *
 * When both rows exist in the history transcript (which happens because
 * `Keeper_chat_store.to_json_array` keeps `Role.Tool` rows alongside assistant
 * trace blocks), we enrich the assistant trace card with any missing `args` or
 * `name` from the `role: 'tool'` row and suppress the redundant `role: 'tool'`
 * row so each tool execution renders as a single card. Standalone `role: 'tool'`
 * rows whose `executionId` does not appear on any assistant row are preserved.
 */
export function dedupeHistoryToolRows(
  entries: readonly ChatTranscriptEntry[],
): readonly ChatTranscriptEntry[] {
  const toolRowByExecId = new Map<string, ChatToolBlock>()
  for (const entry of entries) {
    if (entry.role !== 'tool') continue
    const parsed = parseChatMessageBlocks(entry)
    for (const tb of parsed.toolBlocks) {
      const eid = tb.executionId?.trim() || entry.executionId?.trim()
      if (!eid) continue
      const existing = toolRowByExecId.get(eid)
      if (!existing) {
        toolRowByExecId.set(eid, { ...tb, executionId: eid })
      } else {
        toolRowByExecId.set(eid, {
          ...existing,
          name: existing.name !== 'tool' ? existing.name : tb.name,
          args: existing.args ?? tb.args,
          result: existing.result ?? tb.result,
          status: existing.status ?? tb.status,
          duration: existing.duration ?? tb.duration,
        })
      }
    }
  }

  const coveredExecIds = new Set<string>()
  const enriched: ChatTranscriptEntry[] = entries.map((entry) => {
    if (entry.role === 'tool' || !entry.toolCalls || entry.toolCalls.length === 0) {
      return entry
    }
    let changed = false
    const nextToolCalls = entry.toolCalls.map((tc) => {
      const eid = tc.executionId?.trim()
      if (!eid) return tc
      coveredExecIds.add(eid)
      const sibling = toolRowByExecId.get(eid)
      if (!sibling) return tc
      const nextName = tc.name !== 'tool' ? tc.name : sibling.name
      const nextArgs = tc.args ?? sibling.args
      const nextResult = tc.result ?? sibling.result
      const nextStatus = tc.status ?? sibling.status
      if (
        nextName !== tc.name
        || nextArgs !== tc.args
        || nextResult !== tc.result
        || nextStatus !== tc.status
      ) {
        changed = true
        return {
          ...tc,
          name: nextName,
          args: nextArgs,
          result: nextResult,
          status: nextStatus,
        }
      }
      return tc
    })
    return changed ? { ...entry, toolCalls: nextToolCalls } : entry
  })

  const seenStandaloneToolExecIds = new Set<string>()
  return enriched.filter((entry) => {
    if (entry.role !== 'tool') return true
    const eid =
      entry.executionId?.trim()
      || entry.toolCalls?.find((tc) => tc.executionId?.trim())?.executionId?.trim()
    if (!eid) return true
    if (coveredExecIds.has(eid)) return false
    if (seenStandaloneToolExecIds.has(eid)) return false
    seenStandaloneToolExecIds.add(eid)
    return true
  })
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

// ── Delegate Extraction & Hierarchical Transcript Grouping ────────────────

export interface DelegateCardInfo {
  readonly kind: 'delegate' | 'delegate_status' | 'delegate_cancel'
  readonly targetKeeper: string | null
  readonly targetKeepers: readonly string[]
  readonly operationCount: number
  readonly prompt: string | null
  readonly operationId: string | null
  readonly artifactCount: number
  readonly delegateState: string | null
  readonly targetTurnAgeSec: number | null
}

function asNonBlankStr(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

/**
 * Extracts structured Keeper Delegate fields from `masc_keeper_delegate*` tool
 * calls (including `masc_keeper_delegate_status_many` `operations` batches) so
 * the UI renders a clear hierarchical delegation card with target Keeper jumps
 * instead of raw JSON noise.
 */
export function extractDelegateCardInfo(tb: ChatToolBlock): DelegateCardInfo | null {
  const n = tb.name.trim()
  let kind: DelegateCardInfo['kind'] | null = null
  if (n === 'masc_keeper_delegate') kind = 'delegate'
  else if (n === 'masc_keeper_delegate_status' || n === 'masc_keeper_delegate_status_many') kind = 'delegate_status'
  else if (n === 'masc_keeper_delegate_cancel') kind = 'delegate_cancel'
  if (!kind) return null

  const argsObj = tb.args ? tryParseJsonObject(tb.args) : null
  const resObj = tb.result ? tryParseJsonObject(tb.result) : null

  const extractTarget = (obj: Record<string, unknown> | null): string | null => {
    if (!obj) return null
    if (typeof obj.target === 'object' && obj.target !== null && !Array.isArray(obj.target)) {
      const t = obj.target as Record<string, unknown>
      const name = asNonBlankStr(t.name)
      if (name) return name
    }
    return asNonBlankStr(obj.target) ?? asNonBlankStr(obj.keeper_name) ?? asNonBlankStr(obj.delegate)
  }

  const targetSet = new Set<string>()
  const directTarget = extractTarget(argsObj) ?? extractTarget(resObj)
  if (directTarget) targetSet.add(directTarget)

  let operationCount = 0
  let firstBatchOpId: string | null = null
  const opsArrays: unknown[][] = []
  if (argsObj && Array.isArray(argsObj.operations)) opsArrays.push(argsObj.operations)
  if (resObj && Array.isArray(resObj.operations)) opsArrays.push(resObj.operations)
  if (resObj && Array.isArray(resObj.results)) opsArrays.push(resObj.results)

  for (const arr of opsArrays) {
    if (arr.length > operationCount) operationCount = arr.length
    for (const item of arr) {
      if (typeof item !== 'object' || item === null || Array.isArray(item)) continue
      const rec = item as Record<string, unknown>
      const t = extractTarget(rec)
      if (t) targetSet.add(t)
      if (!firstBatchOpId) {
        firstBatchOpId = asNonBlankStr(rec.operation_id) ?? asNonBlankStr(rec.request_id)
      }
    }
  }

  const targetKeepers = Array.from(targetSet)
  const targetKeeper = targetKeepers[0] ?? null
  const prompt =
    (argsObj ? (asNonBlankStr(argsObj.prompt) ?? asNonBlankStr(argsObj.message)) : null)
    ?? (resObj ? asNonBlankStr(resObj.prompt) : null)
  const operationId =
    (argsObj ? (asNonBlankStr(argsObj.operation_id) ?? asNonBlankStr(argsObj.request_id)) : null)
    ?? (resObj ? (asNonBlankStr(resObj.operation_id) ?? asNonBlankStr(resObj.request_id)) : null)
    ?? firstBatchOpId
  if (operationCount === 0 && operationId) operationCount = 1
  const artifactCount =
    argsObj && Array.isArray(argsObj.artifacts) ? argsObj.artifacts.length : 0
  const delegateState =
    (resObj ? (asNonBlankStr(resObj.state) ?? asNonBlankStr(resObj.status)) : null)
    ?? (argsObj ? asNonBlankStr(argsObj.state) : null)
  const targetTurnAgeSec =
    resObj && typeof resObj.target_turn_age_s === 'number' && Number.isFinite(resObj.target_turn_age_s)
      ? Math.max(0, Math.round(resObj.target_turn_age_s))
      : null

  return {
    kind,
    targetKeeper,
    targetKeepers,
    operationCount,
    prompt,
    operationId,
    artifactCount,
    delegateState,
    targetTurnAgeSec,
  }
}

export function formatShortToolLabel(tb: ChatToolBlock): string {
  const del = extractDelegateCardInfo(tb)
  if (del) {
    if (del.kind === 'delegate') return del.targetKeeper ? `위임(@${del.targetKeeper})` : '위임'
    if (del.kind === 'delegate_status') {
      if (del.targetKeepers.length > 1) {
        const shown = del.targetKeepers.slice(0, 2).map((t) => `@${t}`).join(',')
        const rest = del.targetKeepers.length - 2
        return rest > 0 ? `위임조회(${shown} 외 ${rest})` : `위임조회(${shown})`
      }
      if (del.targetKeeper) return `위임조회(@${del.targetKeeper})`
      return del.operationCount > 1 ? `위임조회(${del.operationCount}건)` : '위임조회'
    }
    return del.targetKeeper ? `위임취소(@${del.targetKeeper})` : '위임취소'
  }
  return tb.name
}

/**
 * Summarizes a list of tool blocks into a compact histogram like
 * `"Read ×2 · Grep · 위임(@worker-a)"` (capped cleanly to 4 unique entries).
 */
export function summarizeToolHistogram(blocks: readonly ChatToolBlock[], maxUnique = 4): string {
  const counts = new Map<string, number>()
  for (const tb of blocks) {
    const label = formatShortToolLabel(tb)
    counts.set(label, (counts.get(label) ?? 0) + 1)
  }
  const entries = Array.from(counts.entries())
  const shown = entries.slice(0, maxUnique).map(([label, n]) => (n > 1 ? `${label} ×${n}` : label))
  const rest = entries.length - shown.length
  if (rest > 0) shown.push(`외 ${rest}종`)
  return shown.join(' · ')
}

export interface ParsedTranscriptEntry {
  readonly msg: ChatTranscriptEntry
  readonly blocks: ParsedChatBlocks
}

export type TranscriptDisplayItem =
  | {
      readonly kind: 'message'
      readonly id: string
      readonly entry: ParsedTranscriptEntry
    }
  | {
      readonly kind: 'tool_group'
      readonly id: string
      readonly entries: readonly ParsedTranscriptEntry[]
      readonly toolBlocks: readonly ChatToolBlock[]
      readonly toolSummary: string
      readonly delegateTargets: readonly string[]
    }

/**
 * Collapses runs of consecutive tool-only rows (`isToolOnly`) into structured
 * hierarchical activity groups so multi-tool turns remain calm and scannable.
 * Preserves chronological order and never absorbs user/assistant messages.
 */
export function groupTranscriptEntries(
  entries: readonly ParsedTranscriptEntry[],
): readonly TranscriptDisplayItem[] {
  const out: TranscriptDisplayItem[] = []
  let run: ParsedTranscriptEntry[] = []

  const flushRun = () => {
    if (run.length === 0) return
    const toolBlocks: ChatToolBlock[] = []
    const delegateTargets = new Set<string>()
    for (const item of run) {
      for (const tb of item.blocks.toolBlocks) {
        toolBlocks.push(tb)
        const del = extractDelegateCardInfo(tb)
        if (del) {
          for (const target of del.targetKeepers) {
            delegateTargets.add(target)
          }
        }
      }
    }
    out.push({
      kind: 'tool_group',
      id: `tool-group:${run[0]!.msg.id}`,
      entries: run,
      toolBlocks,
      toolSummary: summarizeToolHistogram(toolBlocks),
      delegateTargets: Array.from(delegateTargets),
    })
    run = []
  }

  for (const entry of entries) {
    if (entry.blocks.isToolOnly && !entry.msg.errorDetail && !entry.msg.retainedImages?.length) {
      run.push(entry)
    } else {
      flushRun()
      out.push({
        kind: 'message',
        id: entry.msg.id,
        entry,
      })
    }
  }
  flushRun()
  return out
}

function isUnconfirmedEntry(entry: ChatTranscriptEntry): boolean {
  return (entry.operationId !== undefined && entry.deliveryProvenance === undefined) || (
    entry.deliveryState !== undefined
    && entry.deliveryState !== 'Delivered'
    && entry.deliveryState !== 'Cut_recovered'
  )
}

function operationReceiptId(
  entry: ChatTranscriptEntry,
  ...slots: readonly KeeperChatTranscriptSlot['kind'][]
): string | undefined {
  const provenance = entry.deliveryProvenance
  return provenance?.delivery_key.kind === 'operation' && slots.includes(provenance.transcript_slot.kind)
    ? provenance.delivery_key.operation_id
    : undefined
}

/**
 * Merges a refreshed latest history head page into the existing transcript
 * without relying on wall-clock `ts` comparisons (which scramble same-second
 * rows) and while preserving earlier paginated rows and active optimistic turns.
 */
export function mergeLatestHistoryPage(
  prev: readonly ChatTranscriptEntry[],
  incoming: readonly ChatTranscriptEntry[],
  streaming: { readonly operationId: string; readonly executionId: string } | null = null,
): readonly ChatTranscriptEntry[] {
  // An authoritative empty latest page (e.g. after `/clear` or `/reset`) drops
  // old persisted entries while retaining local requests awaiting a transcript receipt.
  if (incoming.length === 0) {
    return prev.filter(isUnconfirmedEntry)
  }
  // Keep the open stream's bubbles at their committed positions so incoming
  // history cannot reorder them or replace entries that still receive deltas.
  let stored = incoming
  if (streaming !== null) {
    const localEntries = prev.filter((entry) => entry.operationId === streaming.operationId
      && entry.deliveryProvenance === undefined)
    const localUser = localEntries.find((entry) => entry.role === 'user')
    const localReply = localEntries.find((entry) => entry.role === 'assistant')
    const settledFor = (id: string) => incoming.find((entry) =>
      operationReceiptId(entry, 'terminal_result', 'settled_failure') === id)
    const replyReceipt = settledFor(streaming.operationId) ?? settledFor(streaming.executionId)
    stored = incoming.map((entry) => {
      if (entry === replyReceipt && localReply) return localReply
      if (localUser && operationReceiptId(entry, 'accepted_user') === streaming.operationId) return localUser
      return entry
    })
  }
  const loadedIds = new Set(incoming.map((row) => row.id))
  const accepted = new Set<string>()
  const settled = new Set<string>()
  for (const entry of stored) {
    loadedIds.add(entry.id)
    const provenance = entry.deliveryProvenance
    if (provenance?.delivery_key.kind !== 'operation') continue
    const operationId = provenance.delivery_key.operation_id
    switch (provenance.transcript_slot.kind) {
      case 'accepted_user': accepted.add(operationId); break
      case 'terminal_result':
      case 'settled_failure': settled.add(operationId); break
    }
  }
  const keep = (entry: ChatTranscriptEntry) => {
    if (loadedIds.has(entry.id)) return false
    if (entry.operationId === undefined || entry.deliveryProvenance !== undefined) return true
    if (entry.role === 'user') return !accepted.has(entry.operationId)
    return !settled.has(entry.operationId)
      && (entry.replyOperationId === undefined || !settled.has(entry.replyOperationId))
  }
  const firstOverlapIdx = prev.findIndex((m) => loadedIds.has(m.id))

  if (firstOverlapIdx >= 0) {
    const earlier = prev.slice(0, firstOverlapIdx).filter(keep)
    const trailing = prev
      .slice(firstOverlapIdx)
      .filter((m) => keep(m) && isUnconfirmedEntry(m))
    return dedupeHistoryToolRows([...earlier, ...stored, ...trailing])
  }

  // No ID overlap (e.g. initial load or >1 page burst): keep persisted rows ahead
  // of the new head page and keep in-flight/failed optimistic entries trailing.
  const earlier = prev.filter((m) => keep(m) && !isUnconfirmedEntry(m))
  const trailing = prev.filter((m) => keep(m) && isUnconfirmedEntry(m))
  return dedupeHistoryToolRows([...earlier, ...stored, ...trailing])
}

export function formatTurnLaneLabel(lane: string): string {
  switch (lane) {
    case 'autonomous':
    case 'proactive':
      return '자율 턴'
    case 'delegated':
    case 'delegate':
      return '위임 턴'
    case 'schedule':
    case 'scheduled':
      return '예약 턴'
    case 'board':
    case 'board_attention':
      return '보드 턴'
    case 'chat':
    case 'chat_operation':
    case 'direct':
      return '대화 턴'
    case 'maintenance':
      return '유지보수 턴'
    case 'keepalive':
      return '유지 턴'
    case 'task':
      return '작업 턴'
    case 'verification':
      return '검증 턴'
    case 'internal':
      return '내부 턴'
    default:
      return lane ? `${lane} 턴` : '활성 턴'
  }
}

export function formatTurnActivityLabel(activity: string | undefined): {
  readonly label: string
  readonly tone: 'info' | 'warn' | 'bad' | 'brass'
} {
  switch (activity) {
    case 'preparing':
      return { label: '준비 중', tone: 'info' }
    case 'waiting':
      return { label: '응답 대기 중', tone: 'warn' }
    case 'streaming':
      return { label: '스트리밍 중', tone: 'brass' }
    case 'tool':
      return { label: '도구 실행 중', tone: 'info' }
    case 'tool_observed':
      return { label: '도구 관측', tone: 'info' }
    case 'failed':
      return { label: '시도 실패', tone: 'bad' }
    default:
      return { label: '진행 중', tone: 'info' }
  }
}

export function formatWaitingSourceLabel(source: string): string {
  switch (source) {
    case 'event_queue_pending':
    case 'event_queue':
      return '이벤트 큐'
    case 'chat_operation_queued':
      return '대화 대기'
    case 'chat_operation_running':
    case 'chat_operation':
      return '대화 실행'
    case 'hitl_pending':
    case 'approval':
    case 'approval_count':
    case 'approval_detail':
      return '승인 대기'
    case 'fusion_running':
      return '퓨전 실행'
    case 'schedule_waiting':
      return '예약 대기'
    case 'owner_shutdown':
      return '종료 중'
    case 'operator_pending_confirm':
      return '운영자 확인'
    case 'runtime_quota_spent':
      return '할당 소진'
    case 'read_error':
      return '조회 오류'
    case 'observation_unavailable':
      return '관측 불가'
    case 'delegate':
    case 'keeper_delegate':
      return '위임'
    default:
      return source
  }
}

export function formatElapsedCompact(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`
  return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}m`
}
