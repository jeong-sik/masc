const KEEPER_CHAT_RECEIPT_ID_PATTERN =
  /^chatq_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isKeeperChatReceiptId(value: string): boolean {
  return KEEPER_CHAT_RECEIPT_ID_PATTERN.test(value)
}

const KEEPER_QUEUE_REVISION_PATTERN = /^(0|[1-9][0-9]*)$/

export function parseKeeperQueueRevision(value: unknown): string | undefined {
  return typeof value === 'string' && KEEPER_QUEUE_REVISION_PATTERN.test(value)
    ? value
    : undefined
}

export function compareKeeperQueueRevisions(left: string, right: string): -1 | 0 | 1 {
  if (left.length < right.length) return -1
  if (left.length > right.length) return 1
  if (left < right) return -1
  if (left > right) return 1
  return 0
}
