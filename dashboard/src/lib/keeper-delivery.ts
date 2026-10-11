import type { KeeperConversationDelivery } from '../types/core'

// Total classification is the runtime vocabulary and decoder authority. Adding
// a delivery to the closed type requires choosing its class here.
const DELIVERY_CLASS = Object.freeze({
  history: 'other', queued: 'in-flight', sending: 'in-flight', streaming: 'in-flight',
  delivered: 'other', no_reply: 'other', timeout: 'failed', cancelled: 'other',
  error: 'failed', request_failure: 'failed', interrupted: 'failed',
} as const satisfies Record<KeeperConversationDelivery, 'in-flight' | 'failed' | 'other'>)

const deliveries = Object.keys(DELIVERY_CLASS) as KeeperConversationDelivery[]
export const IN_FLIGHT_DELIVERY: readonly KeeperConversationDelivery[] = Object.freeze(deliveries.filter(delivery => DELIVERY_CLASS[delivery] === 'in-flight'))
export const FAILED_DELIVERY: readonly KeeperConversationDelivery[] = Object.freeze(deliveries.filter(delivery => DELIVERY_CLASS[delivery] === 'failed'))

export function keeperConversationDeliveryFromUnknown(raw: unknown): KeeperConversationDelivery | null {
  return typeof raw === 'string' && Object.hasOwn(DELIVERY_CLASS, raw) ? raw as KeeperConversationDelivery : null
}

export function isInFlightDelivery(delivery: KeeperConversationDelivery): boolean {
  return DELIVERY_CLASS[delivery] === 'in-flight'
}

export function isFailedDelivery(delivery: KeeperConversationDelivery): boolean {
  return DELIVERY_CLASS[delivery] === 'failed'
}
