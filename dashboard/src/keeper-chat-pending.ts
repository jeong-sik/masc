import type { KeeperConversationAttachment } from './types'

export interface PendingKeeperChatRequest {
  requestId: string
  keeperName: string
  message: string
  submittedAt: number
  attachments?: KeeperConversationAttachment[]
}

const STORAGE_KEY = 'masc_keeper_chat_pending_requests_v1'

function storage(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage
  } catch {
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

function normalizePendingRequest(raw: unknown): PendingKeeperChatRequest | null {
  if (!isRecord(raw)) return null
  const requestId = stringField(raw, 'requestId')
  const keeperName = stringField(raw, 'keeperName')
  const message = stringField(raw, 'message')
  const submittedAt =
    typeof raw.submittedAt === 'number' && Number.isFinite(raw.submittedAt)
      ? raw.submittedAt
      : Date.now()
  if (!requestId || !keeperName || !message) return null
  const attachments = Array.isArray(raw.attachments)
    ? raw.attachments.map(normalizeAttachment).filter((att): att is KeeperConversationAttachment => att !== null)
    : []
  return {
    requestId,
    keeperName,
    message,
    submittedAt,
    ...(attachments.length > 0 ? { attachments } : {}),
  }
}

function readAll(): PendingKeeperChatRequest[] {
  const store = storage()
  if (!store) return []
  try {
    const raw = store.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed
      .map(normalizePendingRequest)
      .filter((request): request is PendingKeeperChatRequest => request !== null)
  } catch {
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
      store.setItem(STORAGE_KEY, JSON.stringify(requests))
    }
  } catch {
    // Best-effort resilience only; the live stream remains the primary path.
  }
}

export function pendingKeeperChatRequestsForKeeper(keeperName: string): PendingKeeperChatRequest[] {
  const name = keeperName.trim()
  if (!name) return []
  return readAll().filter(request => request.keeperName === name)
}

export function upsertPendingKeeperChatRequest(request: PendingKeeperChatRequest): void {
  const requestId = request.requestId.trim()
  const keeperName = request.keeperName.trim()
  const message = request.message.trim()
  if (!requestId || !keeperName || !message) return
  const normalized: PendingKeeperChatRequest = {
    ...request,
    requestId,
    keeperName,
    message,
  }
  const next = readAll().filter(existing => existing.requestId !== requestId)
  next.push(normalized)
  writeAll(next)
}

export function removePendingKeeperChatRequest(requestId: string): void {
  const id = requestId.trim()
  if (!id) return
  writeAll(readAll().filter(request => request.requestId !== id))
}

export function hasPendingKeeperChatRequest(keeperName: string): boolean {
  return pendingKeeperChatRequestsForKeeper(keeperName).length > 0
}

export function _clearPendingKeeperChatRequestsForTests(): void {
  writeAll([])
}
