import { describe, expect, it } from 'vitest'
import type { SSEEvent } from '../types'
import {
  isKeeperToolActivityEvent,
  isKeeperToolEvidenceCommittedEvent,
  sseEventMatchesKeeper,
  sseKeeperName,
} from './keeper-sse-match'

describe('keeper SSE matching', () => {
  it('matches events by the keeper name itself — nothing is parsed out of the string', () => {
    const event = {
      type: 'keeper_tool_call',
      agent_name: 'sangsu',
      tool_name: 'keeper_context_status',
    } as SSEEvent

    expect(sseKeeperName(event)).toBe('sangsu')
    expect(sseEventMatchesKeeper(event, 'sangsu')).toBe(true)
    expect(sseEventMatchesKeeper(event, 'SangSu')).toBe(true)
    expect(sseEventMatchesKeeper(event, 'other')).toBe(false)
    expect(sseEventMatchesKeeper(event, 'keeper-sangsu-agent')).toBe(false)
  })

  it('distinguishes committed evidence refresh from physical tool execution', () => {
    const event = { type: 'keeper_tool_call_evidence_committed' } as SSEEvent
    expect(isKeeperToolEvidenceCommittedEvent(event)).toBe(true)
    expect(isKeeperToolActivityEvent(event)).toBe(false)
  })

  it('recognizes tool-call events across canonical and MASC alias wire types', () => {
    expect(isKeeperToolActivityEvent({ type: 'keeper_tool_call' } as SSEEvent)).toBe(true)
    expect(isKeeperToolActivityEvent({ type: 'masc/keeper_tool_call' } as SSEEvent)).toBe(true)
    expect(isKeeperToolActivityEvent({ type: 'keeper_turn_complete' } as SSEEvent)).toBe(false)
  })
})
