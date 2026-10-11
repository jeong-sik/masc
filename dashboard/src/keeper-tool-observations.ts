import type { KeeperConversationEntry } from './types'
import { decodeKeeperChatDeliveryProvenance } from './api/schemas/keeper-chat-delivery-provenance'
import { keeperConversationDeliveryFromUnknown } from './lib/keeper-delivery'
import { sameDeliveryKey } from './keeper-delivery-provenance'

export type ToolObservation = Pick<KeeperConversationEntry, 'id' | 'label' | 'text' | 'rawText' | 'timestamp' | 'deliveryProvenance' | 'executionId' | 'toolCallId' | 'toolCallEnded' | 'toolOccurrence' | 'toolOccurrenceQuarantined' | 'delivery' | 'error'>
export type StoredToolObservations = { readonly kind: 'known'; readonly entries: readonly ToolObservation[] } | { readonly kind: 'unavailable' }
const record = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value)
const coordinate = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0

export function toolObservationsFromUnknown(raw: unknown): StoredToolObservations {
  if (!record(raw) || raw.kind !== 'known' || !Array.isArray(raw.entries)) return Object.freeze({ kind: 'unavailable' })
  const entries: ToolObservation[] = []
  for (const value of raw.entries) {
    if (!record(value) || typeof value.id !== 'string' || !value.id.trim()
      || typeof value.label !== 'string' || typeof value.text !== 'string') return { kind: 'unavailable' }
    const provenance = record(value.deliveryProvenance) ? decodeKeeperChatDeliveryProvenance(value.deliveryProvenance.delivery_key, value.deliveryProvenance.transcript_slot) : null
    const delivery = keeperConversationDeliveryFromUnknown(value.delivery)
    if (provenance?.status !== 'valid' || !delivery
      || (provenance.value.transcript_slot.kind !== 'tool_delivery' && provenance.value.transcript_slot.kind !== 'tool_call')) return { kind: 'unavailable' }
    const occurrence = value.toolOccurrence
    let toolOccurrence: KeeperConversationEntry['toolOccurrence']
    if (record(occurrence) && occurrence.kind === 'identified' && coordinate(occurrence.streamScope) && coordinate(occurrence.blockIndex)) {
      toolOccurrence = Object.freeze({ kind: 'identified', streamScope: occurrence.streamScope, blockIndex: occurrence.blockIndex })
    } else if (record(occurrence) && occurrence.kind === 'conflicting' && Array.isArray(occurrence.coordinates) && occurrence.coordinates.length > 0
      && occurrence.coordinates.every(item => record(item) && coordinate(item.streamScope) && coordinate(item.blockIndex))) {
      toolOccurrence = Object.freeze({ kind: 'conflicting', coordinates: Object.freeze(occurrence.coordinates.map(item => Object.freeze({ streamScope: item.streamScope as number, blockIndex: item.blockIndex as number }))) })
    } else return { kind: 'unavailable' }
    for (const key of ['rawText', 'timestamp', 'executionId', 'toolCallId', 'error']) {
      if (value[key] !== undefined && value[key] !== null && typeof value[key] !== 'string') return { kind: 'unavailable' }
    }
    if (value.toolCallEnded !== undefined && typeof value.toolCallEnded !== 'boolean'
      || value.toolOccurrenceQuarantined !== undefined && value.toolOccurrenceQuarantined !== true) return { kind: 'unavailable' }
    const slot = provenance.value.transcript_slot
    if (slot.kind === 'tool_call' ? value.executionId !== slot.execution_id : value.executionId != null) return { kind: 'unavailable' }
    if (entries.some(entry => entry.id === value.id
      || entry.executionId != null && entry.executionId === value.executionId
      || entry.deliveryProvenance && sameDeliveryKey(entry.deliveryProvenance.delivery_key, provenance.value.delivery_key)
        && (entry.deliveryProvenance.transcript_slot.kind === 'tool_delivery' || entry.deliveryProvenance.transcript_slot.kind === 'tool_call')
        && entry.deliveryProvenance.transcript_slot.ordinal === slot.ordinal
      || entry.deliveryProvenance && sameDeliveryKey(entry.deliveryProvenance.delivery_key, provenance.value.delivery_key)
        && entry.toolOccurrence && (entry.toolOccurrence.kind === 'identified' ? [entry.toolOccurrence] : entry.toolOccurrence.coordinates)
          .some(left => (toolOccurrence.kind === 'identified' ? [toolOccurrence] : toolOccurrence.coordinates)
            .some(right => left.streamScope === right.streamScope && left.blockIndex === right.blockIndex)))) return { kind: 'unavailable' }
    entries.push(Object.freeze({ id: value.id, label: value.label, text: value.text,
      rawText: value.rawText as string | null | undefined, timestamp: value.timestamp as string | null | undefined,
      executionId: value.executionId as string | null | undefined, toolCallId: value.toolCallId as string | null | undefined,
      error: value.error as string | null | undefined, toolCallEnded: value.toolCallEnded as boolean | undefined,
      deliveryProvenance: provenance.value, delivery, toolOccurrence,
      ...(toolOccurrence.kind === 'conflicting' || value.toolOccurrenceQuarantined === true ? { toolOccurrenceQuarantined: true as const } : {}),
    }))
  }
  return Object.freeze({ kind: 'known', entries: Object.freeze(entries) })
}

export function captureToolObservations(parent: KeeperConversationEntry, entries: readonly KeeperConversationEntry[]): StoredToolObservations {
  if (parent.toolObservationAuthority === 'unavailable') return { kind: 'unavailable' }
  const key = parent.deliveryProvenance?.delivery_key
  return toolObservationsFromUnknown({ kind: 'known', entries: entries.filter(entry => entry.role === 'tool'
    && entry.toolOccurrence !== undefined && key && entry.deliveryProvenance && sameDeliveryKey(key, entry.deliveryProvenance.delivery_key)) })
}

/** Directed evidence continuity; presentation IDs do not establish ownership. */
export function toolObservationContinues(previous: ToolObservation, next: ToolObservation): boolean {
  const before = previous.deliveryProvenance
  const after = next.deliveryProvenance
  const oldOccurrence = previous.toolOccurrence
  const newOccurrence = next.toolOccurrence
  if (!before || !after || !sameDeliveryKey(before.delivery_key, after.delivery_key)
    || !oldOccurrence || !newOccurrence
    || previous.toolCallEnded === true && next.toolCallEnded !== true
    || previous.toolCallId && next.toolCallId && previous.toolCallId !== next.toolCallId
    || previous.toolOccurrenceQuarantined && !next.toolOccurrenceQuarantined
    || oldOccurrence.kind === 'conflicting' && newOccurrence.kind !== 'conflicting') return false
  const oldCoordinates = oldOccurrence.kind === 'identified' ? [oldOccurrence] : oldOccurrence.coordinates
  const newCoordinates = newOccurrence.kind === 'identified' ? [newOccurrence] : newOccurrence.coordinates
  if (!oldCoordinates.every(left => newCoordinates.some(right => left.streamScope === right.streamScope && left.blockIndex === right.blockIndex))) return false
  const oldSlot = before.transcript_slot
  const newSlot = after.transcript_slot
  if ((oldSlot.kind !== 'tool_delivery' && oldSlot.kind !== 'tool_call')
    || (newSlot.kind !== 'tool_delivery' && newSlot.kind !== 'tool_call') || oldSlot.ordinal !== newSlot.ordinal) return false
  if (oldSlot.kind === 'tool_call') return newSlot.kind === 'tool_call'
    && oldSlot.execution_id === newSlot.execution_id && previous.executionId === next.executionId
  return newSlot.kind === 'tool_delivery' || newSlot.kind === 'tool_call' && next.executionId === newSlot.execution_id
}
