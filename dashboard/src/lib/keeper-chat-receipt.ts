const KEEPER_CHAT_RECEIPT_ID_PATTERN =
  /^chatq_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isKeeperChatReceiptId(value: string): boolean {
  return KEEPER_CHAT_RECEIPT_ID_PATTERN.test(value)
}
