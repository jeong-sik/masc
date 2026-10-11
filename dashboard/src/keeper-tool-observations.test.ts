import { describe, expect, it } from 'vitest'
import { captureToolObservations, toolObservationContinues, toolObservationsFromUnknown } from './keeper-tool-observations'
import { operationDeliveryProvenance, toolCallDeliveryProvenance } from './keeper-delivery-provenance'
import type { KeeperConversationEntry } from './types'

const parent: KeeperConversationEntry = { id: 'reply', role: 'assistant', source: 'direct_assistant', label: 'keeper', text: '', delivery: 'streaming',
  deliveryProvenance: operationDeliveryProvenance('operation', 'terminal_result') }
const tool: KeeperConversationEntry = { id: 'opaque-tool-row', role: 'tool', source: 'tool_result', label: 'Read', text: '', rawText: 'args', delivery: 'error',
  executionId: 'execution', deliveryProvenance: toolCallDeliveryProvenance(parent.deliveryProvenance, 'execution', 0),
  toolOccurrence: { kind: 'identified', streamScope: 2, blockIndex: 0 }, toolOccurrenceQuarantined: true }

describe('stored tool observations', () => {
  it('round trips exact ownership and quarantine while excluding another delivery', () => {
    const foreign = { ...tool, id: 'foreign', deliveryProvenance: toolCallDeliveryProvenance(operationDeliveryProvenance('other', 'terminal_result'), 'execution', 0) }
    const restored = toolObservationsFromUnknown(JSON.parse(JSON.stringify(captureToolObservations(parent, [tool, foreign]))))
    expect(restored).toMatchObject({ kind: 'known', entries: [{ id: tool.id, executionId: 'execution', rawText: 'args',
      toolOccurrence: { kind: 'identified', streamScope: 2, blockIndex: 0 }, toolOccurrenceQuarantined: true }] })
    if (restored.kind !== 'known') throw new Error('Expected known observations')
    expect(restored.entries).toHaveLength(1)
  })

  it('rejects two different executions claiming the same delivery ordinal even with disjoint coordinates', () => {
    const conflicting = { ...tool, id: 'other-row', executionId: 'other-execution',
      deliveryProvenance: toolCallDeliveryProvenance(parent.deliveryProvenance, 'other-execution', 0),
      toolOccurrence: { kind: 'identified' as const, streamScope: 9, blockIndex: 4 } }
    expect(toolObservationsFromUnknown({ kind: 'known', entries: [tool, conflicting] })).toEqual({ kind: 'unavailable' })
    const distinct = { ...conflicting, deliveryProvenance: toolCallDeliveryProvenance(parent.deliveryProvenance, 'other-execution', 1) }
    expect(toolObservationsFromUnknown({ kind: 'known', entries: [tool, distinct] }).kind).toBe('known')
  })

  it('permits directed planned-to-bound continuity and rejects lost ownership evidence', () => {
    const planned = { ...tool, executionId: undefined, toolOwnerKey: parent.deliveryProvenance!.delivery_key, deliveryProvenance: null }
    expect(toolObservationContinues(planned, tool)).toBe(true)
    expect(toolObservationContinues(tool, planned)).toBe(false)
    expect(toolObservationContinues(tool, { ...tool, toolOwnerKey: parent.deliveryProvenance!.delivery_key, deliveryProvenance: null })).toBe(false)
    expect(toolObservationContinues({ ...tool, toolCallEnded: true }, { ...tool, toolCallEnded: false })).toBe(false)
    expect(toolObservationContinues({ ...tool, toolCallId: 'a' }, { ...tool, toolCallId: 'b' })).toBe(false)
    expect(toolObservationContinues(tool, { ...tool, toolOccurrenceQuarantined: undefined })).toBe(false)
    expect(toolObservationContinues(tool, { ...tool, toolOccurrence: { kind: 'identified', streamScope: 3, blockIndex: 0 } })).toBe(false)
  })

  it('rejects duplicate canonical continuation slots under a root observation owner', () => {
    const key = { kind: 'operation_native' as const, operation_id: 'operation', continuation_id: 'native' }
    const provenance = { delivery_key: key, transcript_slot: { kind: 'terminal_result' as const } }
    const first = { ...tool, toolOwnerKey: parent.deliveryProvenance!.delivery_key,
      deliveryProvenance: toolCallDeliveryProvenance(provenance, 'execution', 0) }
    const second = { ...first, id: 'second', executionId: 'different',
      toolOccurrence: { kind: 'identified' as const, streamScope: 2, blockIndex: 1 },
      deliveryProvenance: toolCallDeliveryProvenance(provenance, 'different', 0) }
    expect(toolObservationsFromUnknown({ kind: 'known', entries: [first, second] })).toEqual({ kind: 'unavailable' })
    expect(toolObservationsFromUnknown({ kind: 'known', entries: [first, { ...second,
      deliveryProvenance: toolCallDeliveryProvenance(provenance, 'different', 1) }] }).kind).toBe('known')
  })

  it('retains canonical continuation identity independently of the root observation owner', () => {
    const key = { kind: 'operation_native' as const, operation_id: 'operation', continuation_id: 'native-a' }
    const bound = { ...tool, toolOwnerKey: parent.deliveryProvenance!.delivery_key,
      deliveryProvenance: toolCallDeliveryProvenance({ delivery_key: key, transcript_slot: { kind: 'terminal_result' } }, 'execution', 0) }
    expect(toolObservationsFromUnknown({ kind: 'known', entries: [bound] }).kind).toBe('known')
    expect(toolObservationContinues(bound, { ...bound,
      deliveryProvenance: toolCallDeliveryProvenance({ delivery_key: { ...key, continuation_id: 'native-b' }, transcript_slot: { kind: 'terminal_result' } }, 'execution', 0),
    })).toBe(false)
  })

  it('keeps unavailable authority through recapture and rejects duplicate resources', () => {
    expect(captureToolObservations({ ...parent, toolObservationAuthority: 'unavailable' }, [])).toEqual({ kind: 'unavailable' })
    expect(toolObservationsFromUnknown({ kind: 'known', entries: [tool, { ...tool, toolOccurrenceQuarantined: undefined }] })).toEqual({ kind: 'unavailable' })
    expect(toolObservationsFromUnknown({ kind: 'known', entries: [tool, { ...tool, id: 'different-row', executionId: 'other',
      deliveryProvenance: toolCallDeliveryProvenance(parent.deliveryProvenance, 'other', 1) }] })).toEqual({ kind: 'unavailable' })
  })

  it.each([
    { ...tool, executionId: 'contradiction' },
    { ...tool, toolOccurrence: { kind: 'identified', streamScope: -1, blockIndex: 0 } },
    { ...tool, toolOccurrenceQuarantined: false },
  ])('rejects corrupted ownership instead of restoring an executable observation', corrupt => {
    expect(toolObservationsFromUnknown({ kind: 'known', entries: [corrupt] })).toEqual({ kind: 'unavailable' })
  })
})
