import { describe, expect, it } from 'vitest'
import {
  TRACK1_DOC_IDS,
  classifyTrack1Topic,
  isTrack1ProjectionDoc,
  parseTrack1Frame,
  track1TelemetryAttributes,
  verifyTrack1TodoClaim,
} from './collaboration-track1'

describe('parseTrack1Frame', () => {
  it('accepts server-authored Yjs projection frames', () => {
    expect(parseTrack1Frame({
      topic: 'yjs:projection:keepers',
      doc_id: TRACK1_DOC_IDS.keepers,
      update_b64: 'AQIDBA==',
      seq: 42,
      server_ts: '2026-04-30T01:00:00Z',
      trace_id: 'trace-1',
    })).toEqual({
      kind: 'projection',
      layer: 'projection',
      topic: 'yjs:projection:keepers',
      doc_id: TRACK1_DOC_IDS.keepers,
      update_b64: 'AQIDBA==',
      seq: 42,
      server_ts: '2026-04-30T01:00:00Z',
      trace_id: 'trace-1',
    })
  })

  it('accepts ephemeral awareness frames', () => {
    expect(parseTrack1Frame({
      topic: 'yjs:awareness:room-1',
      client_id: 7,
      state_b64: 'AAECAw==',
      room_id: 'room-1',
    })).toEqual({
      kind: 'awareness',
      layer: 'ephemeral',
      topic: 'yjs:awareness:room-1',
      client_id: 7,
      state_b64: 'AAECAw==',
      room_id: 'room-1',
      server_ts: undefined,
    })
  })

  it('accepts explicit write rejects from the authoritative layer', () => {
    expect(parseTrack1Frame({
      topic: 'yjs:reject',
      doc_id: TRACK1_DOC_IDS.turnQueue,
      attempted_topic: 'yjs:projection:turn-queue',
      reason: 'client writes to projection docs are rejected',
    })).toEqual({
      kind: 'reject',
      layer: 'authority',
      topic: 'yjs:reject',
      doc_id: TRACK1_DOC_IDS.turnQueue,
      attempted_topic: 'yjs:projection:turn-queue',
      reason: 'client writes to projection docs are rejected',
      server_ts: undefined,
    })
  })

  it('drops unknown topics and malformed binary payloads', () => {
    expect(parseTrack1Frame({ topic: 'runtime.turn_recorded' })).toBeNull()
    expect(parseTrack1Frame({
      topic: 'yjs:projection:keepers',
      doc_id: TRACK1_DOC_IDS.keepers,
      update_b64: 'not base64',
    })).toBeNull()
    expect(parseTrack1Frame({
      topic: 'yjs:awareness:room-1',
      client_id: -1,
      state_b64: 'AAECAw==',
    })).toBeNull()
  })
})

describe('Track 1 helpers', () => {
  it('classifies authority, projection, and ephemeral topics', () => {
    expect(classifyTrack1Topic('yjs:projection:keepers')).toBe('projection')
    expect(classifyTrack1Topic('yjs:awareness:room-1')).toBe('ephemeral')
    expect(classifyTrack1Topic('yjs:reject')).toBe('authority')
    expect(classifyTrack1Topic('runtime.turn_recorded')).toBeNull()
  })

  it('recognizes dashboard projection doc ids', () => {
    expect(isTrack1ProjectionDoc('/dashboard/keepers')).toBe(true)
    expect(isTrack1ProjectionDoc('/tmp/debug')).toBe(false)
  })

  it('verifies TODO claim convergence without client-side ownership writes', () => {
    expect(verifyTrack1TodoClaim({
      id: 'todo-1',
      status: 'claimed',
      assignedTo: 'keeper-a',
      logicalClock: 12,
    }, 'keeper-a')).toMatchObject({
      won: true,
      retryable: false,
      reason: 'owned_after_convergence',
    })

    expect(verifyTrack1TodoClaim({
      id: 'todo-1',
      status: 'claimed',
      assignedTo: 'keeper-b',
      logicalClock: 13,
    }, 'keeper-a')).toMatchObject({
      won: false,
      retryable: true,
      reason: 'lost_after_convergence',
    })
  })

  it('builds OpenTelemetry-ready attributes without leaking payload bytes', () => {
    const frame = parseTrack1Frame({
      topic: 'yjs:projection:keepers',
      doc_id: TRACK1_DOC_IDS.keepers,
      update_b64: 'AQIDBA==',
      seq: 42,
    })
    expect(frame).not.toBeNull()
    expect(track1TelemetryAttributes(frame!)).toEqual({
      'masc.collab.kind': 'projection',
      'masc.collab.layer': 'projection',
      'masc.collab.topic': 'yjs:projection:keepers',
      'masc.collab.doc_id': TRACK1_DOC_IDS.keepers,
      'masc.collab.seq': 42,
    })
  })
})
