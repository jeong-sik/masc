import { decodeKeeperChatDeliveryProvenance } from '../../keeper-delivery-provenance'

export { decodeKeeperChatDeliveryProvenance }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Decode status-tool history rows into the canonical projection the UI state
 * module consumes, with the same decoder as the REST chat-history endpoint. */
export function normalizeKeeperStatusPayloadDeliveryProvenance(data: unknown): unknown {
  if (!isRecord(data) || !Array.isArray(data.history_tail)) return data
  return {
    ...data,
    history_tail: data.history_tail.map((raw) => {
      if (!isRecord(raw)) return raw
      const { delivery_key, transcript_slot, ...message } = raw
      const provenance = decodeKeeperChatDeliveryProvenance(delivery_key, transcript_slot)
      return {
        ...message,
        delivery_provenance: provenance.value,
        delivery_provenance_status: provenance.status,
      }
    }),
  }
}
