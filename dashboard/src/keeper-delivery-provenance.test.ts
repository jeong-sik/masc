import { describe, expect, it } from 'vitest'

import {
  isOperationDeliveryProvenance,
  operationDeliveryProvenance,
  sameDeliveryProvenance,
  toolCallDeliveryProvenance,
  toolDeliveryProvenance,
} from './keeper-delivery-provenance'
import {
  decodeKeeperChatDeliveryProvenance,
  normalizeKeeperStatusPayloadDeliveryProvenance,
} from './api/schemas/keeper-chat-delivery-provenance'

// Each key below is the object delivery_key_to_yojson writes for one
// delivery_key constructor
// (lib/keeper_chat_delivery_identity/keeper_chat_delivery_identity.ml:96).
const checkpointKey = {
  kind: 'operation_checkpoint',
  operation_id: 'kmsg-3',
  trace_id: 'trace-3',
  turn_count: 4,
  sha256: 'a'.repeat(64),
}
const nativeKey = {
  kind: 'operation_native',
  operation_id: 'kmsg-4',
  continuation_id: 'thread-4',
}
const goalNotificationKey = {
  kind: 'goal_notification',
  goal_id: 'goal-1',
  owner: 'rondo',
  event: 'overdue',
}

describe('keeper chat delivery provenance', () => {
  it.each([
    [{ kind: 'operation', operation_id: 'kmsg-1' }, { kind: 'accepted_user' }],
    [checkpointKey, { kind: 'tool_call', execution_id: 'exec-3', ordinal: 0 }],
    [nativeKey, { kind: 'tool_delivery', ordinal: 2 }],
    [{ kind: 'fusion_run', request_id: 'fusion-1' }, { kind: 'terminal_assistant' }],
    [{ kind: 'workspace_message', request_id: 'workspace-message-1' }, {
      kind: 'tool_call',
      execution_id: 'exec-1',
      ordinal: 0,
    }],
    [{ kind: 'operation', operation_id: 'kmsg-2' }, {
      kind: 'tool_delivery',
      ordinal: 1,
    }],
    [{ kind: 'approval_lifecycle', approval_id: 'approval-1' }, { kind: 'approval_request' }],
    [goalNotificationKey, { kind: 'terminal_assistant' }],
  ])('decodes every backend delivery-key variant with its transcript slot', (deliveryKey, slot) => {
    const decoded = decodeKeeperChatDeliveryProvenance(deliveryKey, slot)
    expect(decoded.status).toBe('valid')
    expect(decoded.value).toEqual({ delivery_key: deliveryKey, transcript_slot: slot })
  })

  it.each([
    [{ kind: 'operation', operation_id: 'kmsg-1', extra: true }, { kind: 'accepted_user' }],
    [{ kind: 'operation', operation_id: 'bad id' }, { kind: 'accepted_user' }],
    [{ kind: 'operation', operation_id: 'kmsg-1' }, {
      kind: 'tool_call',
      execution_id: 'call-1',
      ordinal: -1,
    }],
    [{ kind: 'operation', operation_id: 'kmsg-1' }, {
      kind: 'tool_call',
      execution_id: ' ',
      ordinal: 0,
    }],
    [{ kind: 'operation', operation_id: 'kmsg-1' }, {
      kind: 'tool_delivery',
      execution_id: 'provider-call',
      ordinal: 0,
    }],
    [{ kind: 'operation_resume', operation_id: 'kmsg-1' }, { kind: 'accepted_user' }],
    [{ ...checkpointKey, sha256: 'A'.repeat(64) }, { kind: 'accepted_user' }],
    [{ ...checkpointKey, turn_count: -1 }, { kind: 'accepted_user' }],
    [{ ...checkpointKey, trace_id: 'trace.3' }, { kind: 'accepted_user' }],
    [{ kind: 'operation_native', operation_id: 'kmsg-4' }, { kind: 'accepted_user' }],
    [{ ...goalNotificationKey, owner: ' \t' }, { kind: 'accepted_user' }],
  ])('rejects provenance that is outside the backend contract', (deliveryKey, slot) => {
    expect(decodeKeeperChatDeliveryProvenance(deliveryKey, slot)).toEqual({
      status: 'invalid',
      value: null,
    })
  })

  it('distinguishes an absent pair from a half-written pair', () => {
    expect(decodeKeeperChatDeliveryProvenance(undefined, undefined).status).toBe('absent')
    expect(
      decodeKeeperChatDeliveryProvenance(
        { kind: 'operation', operation_id: 'kmsg-1' },
        undefined,
      ).status,
    ).toBe('invalid')
  })

  it('uses the complete pair for equality', () => {
    const user = operationDeliveryProvenance('kmsg-1', 'accepted_user')
    const assistant = operationDeliveryProvenance('kmsg-1', 'terminal_assistant')
    expect(sameDeliveryProvenance(user, assistant)).toBe(false)
    expect(sameDeliveryProvenance(user, { ...user })).toBe(true)
    expect(isOperationDeliveryProvenance(user, 'kmsg-1', 'accepted_user')).toBe(true)
    expect(isOperationDeliveryProvenance(user, 'kmsg-1', 'terminal_assistant')).toBe(false)
  })

  it('compares every field of a multi-field delivery key', () => {
    const slot = { kind: 'terminal_assistant' } as const
    const decode = (deliveryKey: unknown) => {
      const decoded = decodeKeeperChatDeliveryProvenance(deliveryKey, slot)
      if (decoded.status !== 'valid') throw new Error(`fixture did not decode: ${JSON.stringify(deliveryKey)}`)
      return decoded.value
    }
    const checkpoint = decode(checkpointKey)
    const native = decode(nativeKey)
    const goal = decode(goalNotificationKey)
    expect(sameDeliveryProvenance(checkpoint, decode({ ...checkpointKey }))).toBe(true)
    expect(sameDeliveryProvenance(checkpoint, decode({ ...checkpointKey, turn_count: 5 }))).toBe(false)
    expect(sameDeliveryProvenance(native, decode({ ...nativeKey, continuation_id: 'thread-5' }))).toBe(false)
    expect(sameDeliveryProvenance(goal, decode({ ...goalNotificationKey, event: 'refuted' }))).toBe(false)
    expect(sameDeliveryProvenance(checkpoint, decode({ kind: 'operation', operation_id: 'kmsg-3' }))).toBe(false)
  })

  it('derives a tool slot without changing the parent delivery key', () => {
    const parent = operationDeliveryProvenance('kmsg-1', 'terminal_assistant')
    expect(toolCallDeliveryProvenance(parent, 'exec-2', 1)).toEqual({
      delivery_key: parent.delivery_key,
      transcript_slot: { kind: 'tool_call', execution_id: 'exec-2', ordinal: 1 },
    })
  })

  it('keeps a pre-result tool slot delivery-only and ordinal-specific', () => {
    const parent = operationDeliveryProvenance('kmsg-1', 'terminal_assistant')
    const first = toolDeliveryProvenance(parent, 0)
    const second = toolDeliveryProvenance(parent, 1)
    expect(first).toEqual({
      delivery_key: parent.delivery_key,
      transcript_slot: { kind: 'tool_delivery', ordinal: 0 },
    })
    expect(first && second && sameDeliveryProvenance(first, second)).toBe(false)
  })

  it('normalizes status history through the same closed decoder', () => {
    expect(normalizeKeeperStatusPayloadDeliveryProvenance({
      history_tail: [{
        role: 'user',
        delivery_key: { kind: 'operation', operation_id: 'kmsg-1' },
        transcript_slot: { kind: 'accepted_user' },
      }],
    })).toEqual({
      history_tail: [{
        role: 'user',
        delivery_provenance: operationDeliveryProvenance('kmsg-1', 'accepted_user'),
        delivery_provenance_status: 'valid',
      }],
    })
  })
})
