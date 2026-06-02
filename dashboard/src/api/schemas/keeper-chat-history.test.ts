import { describe, expect, it } from 'vitest'

import {
  safeParseKeeperChatHistoryMessage,
  type KeeperChatHistoryMessage,
} from './keeper-chat-history'

function validMessage(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    role: 'user',
    content: 'hello keeper',
    ts: 1_712_000_000.25,
    ...overrides,
  }
}

describe('safeParseKeeperChatHistoryMessage', () => {
  it('accepts a well-formed message and returns a typed output', () => {
    const out = safeParseKeeperChatHistoryMessage(validMessage())
    expect(out).not.toBeNull()
    expect(out?.role).toBe('user')
    expect(out?.content).toBe('hello keeper')
    expect(out?.ts).toBeCloseTo(1_712_000_000.25)
  })

  it('accepts unknown role strings (open enum for backend-ahead deploys)', () => {
    const out = safeParseKeeperChatHistoryMessage(
      validMessage({ role: 'tool-result-v2' }),
    )
    expect(out?.role).toBe('tool-result-v2')
  })

  it('returns null when a required field is missing', () => {
    const { ts: _ts, ...withoutTs } = validMessage()
    expect(safeParseKeeperChatHistoryMessage(withoutTs)).toBeNull()
  })

  it('returns null when a field has the wrong type', () => {
    expect(
      safeParseKeeperChatHistoryMessage(validMessage({ ts: '1712000000' })),
    ).toBeNull()
    expect(
      safeParseKeeperChatHistoryMessage(validMessage({ content: 42 })),
    ).toBeNull()
  })

  it('returns null for non-object inputs', () => {
    expect(safeParseKeeperChatHistoryMessage(null)).toBeNull()
    expect(safeParseKeeperChatHistoryMessage('string')).toBeNull()
    expect(safeParseKeeperChatHistoryMessage(42)).toBeNull()
    expect(safeParseKeeperChatHistoryMessage(undefined)).toBeNull()
  })

  it('composes in a filter chain — drops garbage entries silently', () => {
    const raw: unknown[] = [
      validMessage(),
      validMessage({ role: 'assistant', content: 'hi', ts: 1 }),
      { role: 'user', content: 'missing ts' },
      'not an object',
      null,
      validMessage({ role: 'system', content: 'bye', ts: 2 }),
    ]
    const cleaned = raw
      .map(safeParseKeeperChatHistoryMessage)
      .filter((m): m is KeeperChatHistoryMessage => m !== null)
    expect(cleaned).toHaveLength(3)
    expect(cleaned.map(m => m.role)).toEqual(['user', 'assistant', 'system'])
  })
})
