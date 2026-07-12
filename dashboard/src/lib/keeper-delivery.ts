// Keeper conversation-delivery vocabulary SSOT.
//
// Typed closed-sum classifiers for `KeeperConversationDelivery`. The member
// arrays are declared `as const satisfies ReadonlyArray<KeeperConversationDelivery>`
// so a new delivery variant added to the type in `types/core.ts` forces this
// module (and its drift test) to be revisited, instead of being silently
// missed by the ad-hoc `=== 'x' || === 'y'` OR-chains this replaces
// (previously duplicated across keeper-state.ts, keeper-shared.ts, and
// chat/primitives.ts). Mirrors the `lib/agent-status.ts` precedent.

import type { KeeperConversationDelivery } from '../types/core'

/** Deliveries representing an in-flight (not-yet-terminal) turn: the request
 *  is queued, being sent, or actively streaming. */
export const IN_FLIGHT_DELIVERY = [
  'queued',
  'sending',
  'streaming',
] as const satisfies ReadonlyArray<KeeperConversationDelivery>

/** Deliveries representing a failed terminal outcome. */
export const FAILED_DELIVERY = [
  'error',
  'transport_failure',
  'agent_failure',
  'timeout',
  'interrupted',
] as const satisfies ReadonlyArray<KeeperConversationDelivery>

const IN_FLIGHT_SET: ReadonlySet<KeeperConversationDelivery> = new Set(IN_FLIGHT_DELIVERY)
const FAILED_SET: ReadonlySet<KeeperConversationDelivery> = new Set(FAILED_DELIVERY)

/** True when the turn is in flight (queued / sending / streaming). */
export function isInFlightDelivery(delivery: KeeperConversationDelivery): boolean {
  return IN_FLIGHT_SET.has(delivery)
}

/** True when the turn ended in a failed terminal state. Callers that
 *  additionally require a non-empty error string must keep that conjunct at
 *  the callsite. */
export function isFailedDelivery(delivery: KeeperConversationDelivery): boolean {
  return FAILED_SET.has(delivery)
}
