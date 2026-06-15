import { describe, expect, it } from 'vitest'
import type { SSEEvent } from '../types'
import {
  isKeeperToolActivityEvent,
  sseEventMatchesKeeper,
  sseKeeperName,
} from './keeper-sse-match'

describe('keeper SSE matching', () => {
  it('canonicalizes keeper runtime aliases for event matching', () => {
    const event = {
      type: 'keeper_tool_call',
      agent_name: 'keeper-sangsu-agent',
      tool_name: 'keeper_context_status',
    } as SSEEvent

    expect(sseKeeperName(event)).toBe('sangsu')
    expect(sseEventMatchesKeeper(event, 'sangsu')).toBe(true)
    expect(sseEventMatchesKeeper(event, 'keeper-sangsu-agent')).toBe(true)
    expect(sseEventMatchesKeeper(event, 'other')).toBe(false)
  })

  it('recognizes tool-call events across canonical and MASC alias wire types', () => {
    expect(isKeeperToolActivityEvent({ type: 'keeper_tool_call' } as SSEEvent)).toBe(true)
    expect(isKeeperToolActivityEvent({ type: 'masc/keeper_tool_call' } as SSEEvent)).toBe(true)
    expect(isKeeperToolActivityEvent({ type: 'keeper_tool_skipped' } as SSEEvent)).toBe(true)
    expect(isKeeperToolActivityEvent({ type: 'keeper_turn_complete' } as SSEEvent)).toBe(false)
  })
})
