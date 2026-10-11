import { describe, expect, it } from 'vitest'
import { captureToolObservations, toolObservationContinues, toolObservationsFromUnknown } from './keeper-tool-observations'
import { operationDeliveryProvenance, toolCallDeliveryProvenance, toolDeliveryProvenance } from './keeper-delivery-provenance'
import type { KeeperConversationEntry } from './types'

const parent: KeeperConversationEntry = { id: 'reply', role: 'assistant', label: 'keeper', text: '', delivery: 'streaming',
  deliveryProvenance: operationDeliveryProvenance('operation', 'terminal_result') }
const tool: KeeperConversationEntry = { id: 'opaque-tool-row', role: 'tool', label: 'Read', text: '', rawText: 'args', delivery: 'error',
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

  it('permits directed planned-to-bound continuity and rejects lost ownership evidence', () => {
    const planned = { ...tool, executionId: undefined, deliveryProvenance: toolDeliveryProvenance(parent.deliveryProvenance, 0) }
    expect(toolObservationContinues(planned, tool)).toBe(true)
    expect(toolObservationContinues(tool, planned)).toBe(false)
    expect(toolObservationContinues({ ...tool, toolCallEnded: true }, { ...tool, toolCallEnded: false })).toBe(false)
    expect(toolObservationContinues({ ...tool, toolCallId: 'a' }, { ...tool, toolCallId: 'b' })).toBe(false)
    expect(toolObservationContinues(tool, { ...tool, toolOccurrenceQuarantined: undefined })).toBe(false)
    expect(toolObservationContinues(tool, { ...tool, toolOccurrence: { kind: 'identified', streamScope: 3, blockIndex: 0 } })).toBe(false)
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
