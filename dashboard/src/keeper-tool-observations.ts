import type { KeeperConversationEntry } from './types'
import { decodeKeeperChatDeliveryProvenance } from './api/schemas/keeper-chat-delivery-provenance'
import { keeperConversationDeliveryFromUnknown } from './lib/keeper-delivery'
import { sameDeliveryKey, toolDeliveryBelongsToProducer } from './keeper-delivery-provenance'

export type ToolObservation = Pick<KeeperConversationEntry, 'id' | 'label' | 'text' | 'rawText' | 'timestamp' | 'deliveryProvenance' | 'executionId' | 'toolCallId' | 'toolCallEnded' | 'toolOccurrence' | 'toolOccurrenceQuarantined' | 'toolTranscriptOrdinal' | 'toolOwnerKey' | 'delivery' | 'error'>
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
    const owner = value.toolOwnerKey === undefined ? null : decodeKeeperChatDeliveryProvenance(value.toolOwnerKey, { kind: 'terminal_result' })
    const toolOwnerKey = owner?.status === 'valid' ? owner.value.delivery_key : provenance?.status === 'valid' ? provenance.value.delivery_key : null
    if (!toolOwnerKey || !delivery || value.toolOwnerKey !== undefined && owner?.status !== 'valid'
      || value.deliveryProvenance != null && provenance?.status !== 'valid'
      || provenance?.status === 'valid' && (provenance.value.transcript_slot.kind !== 'tool_call'
        || !toolDeliveryBelongsToProducer(toolOwnerKey, provenance.value.delivery_key))) return { kind: 'unavailable' }
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
    const slot = provenance?.status === 'valid' ? provenance.value.transcript_slot : null
    if (slot?.kind === 'tool_call' && value.executionId !== slot.execution_id) return { kind: 'unavailable' }
    if (entries.some(entry => entry.id === value.id
      || entry.executionId != null && entry.executionId === value.executionId
      || entry.deliveryProvenance && provenance?.status === 'valid'
        && sameDeliveryKey(entry.deliveryProvenance.delivery_key, provenance.value.delivery_key)
        && entry.deliveryProvenance.transcript_slot.kind === 'tool_call'
        && slot?.kind === 'tool_call' && entry.deliveryProvenance.transcript_slot.ordinal === slot.ordinal
      || entry.toolOwnerKey && sameDeliveryKey(entry.toolOwnerKey, toolOwnerKey)
        && entry.toolOccurrence && (entry.toolOccurrence.kind === 'identified' ? [entry.toolOccurrence] : entry.toolOccurrence.coordinates)
          .some(left => (toolOccurrence.kind === 'identified' ? [toolOccurrence] : toolOccurrence.coordinates)
            .some(right => left.streamScope === right.streamScope && left.blockIndex === right.blockIndex)))) return { kind: 'unavailable' }
    if (value.toolTranscriptOrdinal !== undefined && (!coordinate(value.toolTranscriptOrdinal) || slot?.kind !== 'tool_call' || slot.ordinal !== value.toolTranscriptOrdinal)) return { kind: 'unavailable' }
    entries.push(Object.freeze({ id: value.id, label: value.label, text: value.text,
      rawText: value.rawText as string | null | undefined, timestamp: value.timestamp as string | null | undefined,
      executionId: value.executionId as string | null | undefined, toolCallId: value.toolCallId as string | null | undefined,
      error: value.error as string | null | undefined, toolCallEnded: value.toolCallEnded as boolean | undefined,
      deliveryProvenance: provenance?.status === 'valid' ? provenance.value : null, toolOwnerKey, delivery, toolOccurrence,
      ...(value.toolTranscriptOrdinal !== undefined ? { toolTranscriptOrdinal: value.toolTranscriptOrdinal as number } : {}),
      ...(toolOccurrence.kind === 'conflicting' || value.toolOccurrenceQuarantined === true ? { toolOccurrenceQuarantined: true as const } : {}),
    }))
  }
  return Object.freeze({ kind: 'known', entries: Object.freeze(entries) })
}

export function captureToolObservations(parent: KeeperConversationEntry, entries: readonly KeeperConversationEntry[]): StoredToolObservations {
  if (parent.toolObservationAuthority === 'unavailable') return { kind: 'unavailable' }
  const key = parent.deliveryProvenance?.delivery_key
  return toolObservationsFromUnknown({ kind: 'known', entries: entries.filter(entry => entry.role === 'tool'
    && entry.toolOccurrence !== undefined && key && (entry.toolOwnerKey ?? entry.deliveryProvenance?.delivery_key)
    && sameDeliveryKey(key, (entry.toolOwnerKey ?? entry.deliveryProvenance!.delivery_key))) })
}

/** Directed evidence continuity; presentation IDs do not establish ownership. */
export function toolObservationContinues(previous: ToolObservation, next: ToolObservation): boolean {
  const before = previous.deliveryProvenance
  const after = next.deliveryProvenance
  const oldOccurrence = previous.toolOccurrence
  const newOccurrence = next.toolOccurrence
  const beforeKey = previous.toolOwnerKey ?? before?.delivery_key
  const afterKey = next.toolOwnerKey ?? after?.delivery_key
  if (!beforeKey || !afterKey || !sameDeliveryKey(beforeKey, afterKey)
    || !oldOccurrence || !newOccurrence
    || previous.toolCallEnded === true && next.toolCallEnded !== true
    || previous.toolCallId && next.toolCallId && previous.toolCallId !== next.toolCallId
    || previous.toolOccurrenceQuarantined && !next.toolOccurrenceQuarantined
    || oldOccurrence.kind === 'conflicting' && newOccurrence.kind !== 'conflicting') return false
  const oldCoordinates = oldOccurrence.kind === 'identified' ? [oldOccurrence] : oldOccurrence.coordinates
  const newCoordinates = newOccurrence.kind === 'identified' ? [newOccurrence] : newOccurrence.coordinates
  if (!oldCoordinates.every(left => newCoordinates.some(right => left.streamScope === right.streamScope && left.blockIndex === right.blockIndex))) return false
  if (before?.transcript_slot.kind === 'tool_call' && (after?.transcript_slot.kind !== 'tool_call'
    || !sameDeliveryKey(before.delivery_key, after.delivery_key)
    || before.transcript_slot.execution_id !== after.transcript_slot.execution_id
    || before.transcript_slot.ordinal !== after.transcript_slot.ordinal)) return false
  if (previous.executionId != null && previous.executionId !== next.executionId) return false
  if (previous.toolTranscriptOrdinal !== undefined && previous.toolTranscriptOrdinal !== next.toolTranscriptOrdinal) return false
  return true
}

export function transcriptBindingsFromUnknown(raw: unknown): KeeperConversationEntry['toolTranscriptBindings'] | null {
  if (!Array.isArray(raw)) return null
  const bindings: { deliveryKey: NonNullable<KeeperConversationEntry['toolOwnerKey']>; executionId: string; ordinal: number }[] = []
  for (const binding of raw) {
    if (!record(binding) || typeof binding.executionId !== 'string' || !binding.executionId.trim() || !coordinate(binding.ordinal)
      || bindings.some(previous => previous.executionId === binding.executionId)) return null
    const ownership = decodeKeeperChatDeliveryProvenance(binding.deliveryKey, { kind: 'terminal_result' })
    if (ownership.status !== 'valid') return null
    if (bindings.some(previous => sameDeliveryKey(previous.deliveryKey, ownership.value.delivery_key) && previous.ordinal === binding.ordinal)) return null
    bindings.push(Object.freeze({ deliveryKey: ownership.value.delivery_key, executionId: binding.executionId, ordinal: binding.ordinal }))
  }
  return Object.freeze(bindings)
}

export function reconcileTranscriptBindings(values: readonly (KeeperConversationEntry['toolTranscriptBindings'])[]): KeeperConversationEntry['toolTranscriptBindings'] | null {
  if (values.every(value => value === undefined)) return undefined
  const merged: NonNullable<KeeperConversationEntry['toolTranscriptBindings']>[number][] = []
  for (const value of values) for (const binding of value ?? []) {
    if (merged.some(previous => previous.executionId === binding.executionId && (previous.ordinal !== binding.ordinal || !sameDeliveryKey(previous.deliveryKey, binding.deliveryKey))
      || sameDeliveryKey(previous.deliveryKey, binding.deliveryKey) && previous.ordinal === binding.ordinal && previous.executionId !== binding.executionId)) return null
    if (!merged.some(previous => previous.executionId === binding.executionId)) merged.push(binding)
  }
  return transcriptBindingsFromUnknown(merged)
}
