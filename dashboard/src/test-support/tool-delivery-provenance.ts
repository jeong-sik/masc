import type { KeeperChatDeliveryProvenance } from '../keeper-delivery-provenance'

/** Fixture builder for the stored delivery identity of a tool call.
 *  Production code receives these values from the server and never derives
 *  them, so they live with the tests. */
export function toolCallDeliveryProvenance(
  parent: KeeperChatDeliveryProvenance | null | undefined,
  executionId: string,
  ordinal: number,
): KeeperChatDeliveryProvenance | null {
  if (!parent) return null
  return {
    delivery_key: parent.delivery_key,
    transcript_slot: {
      kind: 'tool_call',
      execution_id: executionId,
      ordinal,
    },
  }
}
