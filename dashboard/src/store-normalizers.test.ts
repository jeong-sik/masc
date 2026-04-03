import { describe, expect, it } from 'vitest'

import { normalizeExecutionSessionBrief } from './store-normalizers'

describe('normalizeExecutionSessionBrief', () => {
  it('promotes legacy room-only payloads to namespace while keeping the room alias', () => {
    expect(normalizeExecutionSessionBrief({
      session_id: 'session-1',
      goal: 'legacy payload',
      room: 'default',
    })).toMatchObject({
      session_id: 'session-1',
      goal: 'legacy payload',
      namespace: 'default',
      room: 'default',
    })
  })

  it('keeps namespace-only payloads canonical and mirrors the room alias', () => {
    expect(normalizeExecutionSessionBrief({
      session_id: 'session-2',
      goal: 'flattened payload',
      namespace: 'default',
    })).toMatchObject({
      session_id: 'session-2',
      goal: 'flattened payload',
      namespace: 'default',
      room: 'default',
    })
  })

  it('prefers namespace when both fields are present during rollout', () => {
    expect(normalizeExecutionSessionBrief({
      session_id: 'session-3',
      goal: 'dual payload',
      namespace: 'default',
      room: 'legacy-room',
    })).toMatchObject({
      session_id: 'session-3',
      goal: 'dual payload',
      namespace: 'default',
      room: 'default',
    })
  })
})
