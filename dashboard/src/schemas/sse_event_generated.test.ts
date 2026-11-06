/*
  RFC-0004 Phase A0.2 PR-1 — atdts round-trip PoC.

  Verifies that the atdts-generated readAgentStartedPayload accepts
  the payload that Keeper_event_bridge.native_event_to_json emits for an
  AgentStarted event.

  Scope: agent_started payload only.
*/

import { describe, expect, it } from 'vitest'

import {
  readAgentStartedPayload,
  writeAgentStartedPayload,
  type AgentStartedPayload,
} from './sse_event_generated'

describe('atdts agent_started — round-trip', () => {
  it('reads a well-formed payload', () => {
    const wire = {
      agent_name: 'alpha',
      task_id: 'task_42',
    }
    const decoded = readAgentStartedPayload(wire)
    expect(decoded.agent_name).toBe('alpha')
    expect(decoded.task_id).toBe('task_42')
  })

  it('round-trips write→read', () => {
    const original: AgentStartedPayload = {
      agent_name: 'beta',
      task_id: 'task_99',
    }
    const wire = writeAgentStartedPayload(original)
    const decoded = readAgentStartedPayload(wire)
    expect(decoded).toEqual(original)
  })

  it('rejects missing required field', () => {
    const wire = { agent_name: 'alpha' }
    expect(() => readAgentStartedPayload(wire)).toThrow()
  })

  it('rejects wrong type for required field', () => {
    const wire = { agent_name: 'alpha', task_id: 42 }
    expect(() => readAgentStartedPayload(wire)).toThrow()
  })
})
