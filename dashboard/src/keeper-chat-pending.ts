import type {
  ChatTraceStep,
  KeeperConversationAttachment,
  KeeperConversationDelivery,
  KeeperConversationEntry,
  KeeperConversationStreamState,
} from './types'
import { IN_FLIGHT_DELIVERY } from './lib/keeper-delivery'
import {
  keeperRunRefKey,
  keeperRunRefToWire,
  parseKeeperRunRef,
} from './lib/keeper-run-ref'
import type { KeeperRunRef } from './lib/keeper-run-ref'

export interface PendingKeeperChatAssistantDraft {
  text: string
  rawText: string
  delivery: KeeperConversationDelivery
  streamState: KeeperConversationStreamState
  timestamp?: string | null
  traceSteps?: ChatTraceStep[]
  error?: string | null
}

export interface PendingKeeperChatRequest {
  runRef: KeeperRunRef
  message: string
  submittedAt: number
  attachments?: KeeperConversationAttachment[]
  assistantDraft?: PendingKeeperChatAssistantDraft
}

const STORAGE_KEY = 'masc_keeper_chat_pending_requests_v2'
const PENDING_REQUEST_FIELDS = [
  'run_ref',
  'message',
  'submittedAt',
  'attachments',
  'assistantDraft',
] as const
const KEEPER_STREAM_STATES = [
  'opening',
  'thinking',
  'streaming',
  'finalizing',
] as const satisfies ReadonlyArray<Exclude<KeeperConversationStreamState, null>>
const TRACE_TOOL_STATUSES = ['pending', 'ok', 'err'] as const

function storage(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage
  } catch (err) {
    console.warn('[keeper-chat-pending] localStorage unavailable', err instanceof Error ? err.message : err)
    return null
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stringField(record: Record<string, unknown>, key: string): string {
  const value = record[key]
  return typeof value === 'string' ? value.trim() : ''
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function nullableStringValue(value: unknown): string | null | undefined {
  if (value === null) return null
  return stringValue(value)
}

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function parseMember<const T extends string>(
  values: readonly T[],
  value: unknown,
): T | undefined {
  if (typeof value !== 'string') return undefined
  return values.includes(value as T) ? (value as T) : undefined
}

function normalizeAttachment(raw: unknown): KeeperConversationAttachment | null {
  if (!isRecord(raw)) return null
  const id = stringField(raw, 'id')
  const type = stringField(raw, 'type')
  const name = stringField(raw, 'name')
  const mimeType = stringField(raw, 'mimeType')
  const data = typeof raw.data === 'string' ? raw.data : ''
  const size = typeof raw.size === 'number' && Number.isFinite(raw.size) ? raw.size : 0
  if (!id || (type !== 'image' && type !== 'file') || !name || !mimeType || !data) return null
  return { id, type, name, size, mimeType, data }
}

function normalizeTraceStep(raw: unknown): ChatTraceStep | null {
  if (!isRecord(raw)) return null
  const kind = stringValue(raw.kind)
  if (kind === 'think') {
    const text = stringValue(raw.text)
    if (text === undefined) return null
    const step: ChatTraceStep = { kind, text }
    const ts = stringValue(raw.ts)
    const oasBlockIndex = numberValue(raw.oasBlockIndex)
    if (ts !== undefined) step.ts = ts
    if (oasBlockIndex !== undefined) step.oasBlockIndex = oasBlockIndex
    return step
  }
  if (kind === 'reason') {
    const text = stringValue(raw.text)
    if (text === undefined) return null
    const step: ChatTraceStep = { kind, text }
    const detail = stringValue(raw.detail)
    const ts = stringValue(raw.ts)
    if (detail !== undefined) step.detail = detail
    if (ts !== undefined) step.ts = ts
    return step
  }
  if (kind === 'progress') {
    const text = stringValue(raw.text)
    if (text === undefined) return null
    const step: ChatTraceStep = { kind, text }
    const ts = stringValue(raw.ts)
    const oasBlockIndex = numberValue(raw.oasBlockIndex)
    if (ts !== undefined) step.ts = ts
    if (oasBlockIndex !== undefined) step.oasBlockIndex = oasBlockIndex
    return step
  }
  if (kind === 'tool') {
    const name = stringValue(raw.name)
    if (name === undefined) return null
    const step: ChatTraceStep = { kind, name }
    const toolCallId = stringValue(raw.toolCallId)
    const status = parseMember(TRACE_TOOL_STATUSES, raw.status)
    const dur = stringValue(raw.dur)
    const args = stringValue(raw.args)
    const result = stringValue(raw.result)
    const ts = stringValue(raw.ts)
    const oasBlockIndex = numberValue(raw.oasBlockIndex)
    if (toolCallId !== undefined) step.toolCallId = toolCallId
    if (status !== undefined) step.status = status
    if (dur !== undefined) step.dur = dur
    if (args !== undefined) step.args = args
    if (result !== undefined) step.result = result
    if (ts !== undefined) step.ts = ts
    if (oasBlockIndex !== undefined) step.oasBlockIndex = oasBlockIndex
    return step
  }
  return null
}

function normalizeTraceSteps(raw: unknown): ChatTraceStep[] | undefined {
  if (!Array.isArray(raw)) return undefined
  const steps = raw.map(normalizeTraceStep)
  if (steps.some(step => step === null)) return undefined
  return steps.length > 0 ? (steps as ChatTraceStep[]) : undefined
}

function normalizeAssistantDraft(raw: unknown): PendingKeeperChatAssistantDraft | null {
  if (!isRecord(raw)) return null
  const text = stringValue(raw.text)
  if (text === undefined) return null
  const rawText = stringValue(raw.rawText) ?? text
  const delivery = parseMember(IN_FLIGHT_DELIVERY, raw.delivery) ?? 'queued'
  const streamState =
    raw.streamState === null
      ? null
      : parseMember(KEEPER_STREAM_STATES, raw.streamState) ?? null
  const timestamp = nullableStringValue(raw.timestamp)
  const traceSteps = normalizeTraceSteps(raw.traceSteps)
  const error = nullableStringValue(raw.error)
  return {
    text,
    rawText,
    delivery,
    streamState,
    ...(timestamp !== undefined ? { timestamp } : {}),
    ...(traceSteps ? { traceSteps } : {}),
    ...(error !== undefined ? { error } : {}),
  }
}

function assistantDraftFromEntry(entry: KeeperConversationEntry): PendingKeeperChatAssistantDraft | null {
  if (entry.role !== 'assistant') return null
  const traceSteps = normalizeTraceSteps(entry.traceSteps)
  return {
    text: entry.text,
    rawText: entry.rawText ?? entry.text,
    delivery: entry.delivery,
    streamState: entry.streamState ?? null,
    timestamp: entry.timestamp ?? null,
    ...(traceSteps ? { traceSteps } : {}),
    ...(entry.error !== undefined ? { error: entry.error } : {}),
  }
}

function normalizePendingRequest(raw: unknown): PendingKeeperChatRequest | null {
  if (!isRecord(raw)) return null
  if (Object.keys(raw).some(field => !PENDING_REQUEST_FIELDS.includes(
    field as (typeof PENDING_REQUEST_FIELDS)[number],
  ))) return null
  let runRef: KeeperRunRef
  try {
    runRef = parseKeeperRunRef(raw.run_ref)
  } catch {
    return null
  }
  const message = stringField(raw, 'message')
  const submittedAt = numberValue(raw.submittedAt)
  if (!message || submittedAt === undefined) return null
  const attachments = Array.isArray(raw.attachments)
    ? raw.attachments.map(normalizeAttachment).filter((att): att is KeeperConversationAttachment => att !== null)
    : []
  const assistantDraft = normalizeAssistantDraft(raw.assistantDraft)
  return {
    runRef,
    message,
    submittedAt,
    ...(attachments.length > 0 ? { attachments } : {}),
    ...(assistantDraft ? { assistantDraft } : {}),
  }
}

function readAll(): PendingKeeperChatRequest[] {
  const store = storage()
  if (!store) return []
  try {
    const raw = store.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) {
      console.warn('[keeper-chat-pending] pending request store must be an array')
      return []
    }
    const requests: PendingKeeperChatRequest[] = []
    parsed.forEach((candidate, index) => {
      const request = normalizePendingRequest(candidate)
      if (request) {
        requests.push(request)
      } else {
        console.warn(`[keeper-chat-pending] rejected invalid pending request at index ${index}`)
      }
    })
    return requests
  } catch (err) {
    console.warn('[keeper-chat-pending] failed to read pending requests', err instanceof Error ? err.message : err)
    return []
  }
}

function writeAll(requests: PendingKeeperChatRequest[]): void {
  const store = storage()
  if (!store) return
  try {
    if (requests.length === 0) {
      store.removeItem(STORAGE_KEY)
    } else {
      store.setItem(STORAGE_KEY, JSON.stringify(requests.map(request => ({
        run_ref: keeperRunRefToWire(request.runRef),
        message: request.message,
        submittedAt: request.submittedAt,
        ...(request.attachments ? { attachments: request.attachments } : {}),
        ...(request.assistantDraft ? { assistantDraft: request.assistantDraft } : {}),
      }))))
    }
  } catch (err) {
    console.warn('[keeper-chat-pending] failed to write pending requests', err instanceof Error ? err.message : err)
  }
}

export function pendingKeeperChatRequestsForKeeper(keeperName: string): PendingKeeperChatRequest[] {
  const name = keeperName.trim()
  if (!name) return []
  return readAll().filter(request => request.runRef.target.name === name)
}

export function upsertPendingKeeperChatRequest(request: PendingKeeperChatRequest): void {
  const message = request.message.trim()
  if (!message) return
  const assistantDraft = normalizeAssistantDraft(request.assistantDraft)
  const normalized: PendingKeeperChatRequest = {
    runRef: request.runRef,
    message,
    submittedAt: request.submittedAt,
    ...(request.attachments && request.attachments.length > 0 ? { attachments: request.attachments } : {}),
    ...(assistantDraft ? { assistantDraft } : {}),
  }
  const key = keeperRunRefKey(request.runRef)
  const next = readAll().filter(existing => keeperRunRefKey(existing.runRef) !== key)
  next.push(normalized)
  writeAll(next)
}

export function updatePendingKeeperChatAssistantDraft(
  reference: KeeperRunRef,
  entry: KeeperConversationEntry,
): void {
  const assistantDraft = assistantDraftFromEntry(entry)
  if (!assistantDraft) return
  const key = keeperRunRefKey(reference)
  const requests = readAll()
  let found = false
  const next = requests.map(request => {
    if (keeperRunRefKey(request.runRef) !== key) return request
    found = true
    return { ...request, assistantDraft }
  })
  if (!found) return
  writeAll(next)
}

export function removePendingKeeperChatRequest(reference: KeeperRunRef): void {
  const key = keeperRunRefKey(reference)
  writeAll(readAll().filter(request => keeperRunRefKey(request.runRef) !== key))
}

export function hasPendingKeeperChatRequest(keeperName: string): boolean {
  return pendingKeeperChatRequestsForKeeper(keeperName).length > 0
}

export function _clearPendingKeeperChatRequestsForTests(): void {
  writeAll([])
}
