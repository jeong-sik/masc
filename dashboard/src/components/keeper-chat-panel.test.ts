import { describe, expect, it } from 'vitest'
import type { KeeperChatStreamEvent } from '../api/keeper'
import {
  filterChatMessages,
  isKeeperTextContentEvent,
  normalizeKeeperChatErrorValue,
  type ChatMessage,
} from './keeper-chat-panel'

describe('isKeeperTextContentEvent', () => {
  it('accepts current AG-UI text content events', () => {
    const event: KeeperChatStreamEvent = { type: 'TEXT_MESSAGE_CONTENT', delta: 'hi' }
    expect(isKeeperTextContentEvent(event)).toBe(true)
  })

  it('keeps legacy text delta compatibility', () => {
    const event: KeeperChatStreamEvent = { type: 'TEXT_DELTA', delta: 'hi' }
    expect(isKeeperTextContentEvent(event)).toBe(true)
  })

  it('rejects non-text stream events', () => {
    const event: KeeperChatStreamEvent = { type: 'RUN_ERROR', value: { message: 'boom' } }
    expect(isKeeperTextContentEvent(event)).toBe(false)
  })

  it('rejects text content events without delta', () => {
    const event: KeeperChatStreamEvent = { type: 'TEXT_MESSAGE_CONTENT' }
    expect(isKeeperTextContentEvent(event)).toBe(false)
  })

  it('rejects text content events with empty string delta', () => {
    const event: KeeperChatStreamEvent = { type: 'TEXT_MESSAGE_CONTENT', delta: '' }
    expect(isKeeperTextContentEvent(event)).toBe(false)
  })

  it('rejects text content events with non-string delta', () => {
    const event = { type: 'TEXT_MESSAGE_CONTENT', delta: 123 } as unknown as KeeperChatStreamEvent
    expect(isKeeperTextContentEvent(event)).toBe(false)
  })
})

describe('normalizeKeeperChatErrorValue', () => {
  it('returns direct string errors unchanged', () => {
    expect(normalizeKeeperChatErrorValue('boom')).toBe('boom')
  })

  it('extracts nested error messages from object payloads', () => {
    expect(normalizeKeeperChatErrorValue({ message: 'stream failed' })).toBe('stream failed')
    expect(normalizeKeeperChatErrorValue({ error: { message: 'backend exploded' } })).toBe('backend exploded')
  })

  it('falls back to a stable generic message', () => {
    expect(normalizeKeeperChatErrorValue({ code: 500 })).toBe('스트림 오류')
  })
})

describe('filterChatMessages', () => {
  const sample: ChatMessage[] = [
    { role: 'user', content: 'Deploy the service to staging', timestamp: 1 },
    { role: 'assistant', content: 'Starting deploy pipeline…', timestamp: 2 },
    { role: 'user', content: '로그 확인 부탁해', timestamp: 3 },
    { role: 'assistant', content: 'Checked logs: no errors', timestamp: 4 },
    { role: 'user', content: 'Summarize status', timestamp: 5 },
  ]

  it('returns the input untouched for empty queries', () => {
    expect(filterChatMessages(sample, '')).toBe(sample)
  })

  it('treats whitespace-only queries as empty', () => {
    expect(filterChatMessages(sample, '   ')).toBe(sample)
  })

  it('filters messages case-insensitively on content', () => {
    const result = filterChatMessages(sample, 'DEPLOY')
    expect(result.map(m => m.timestamp)).toEqual([1, 2])
  })

  it('matches non-ASCII content', () => {
    const result = filterChatMessages(sample, '로그')
    expect(result).toHaveLength(1)
    expect(result[0]?.timestamp).toBe(3)
  })

  it('trims query whitespace before matching', () => {
    const result = filterChatMessages(sample, '  status  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.timestamp).toBe(5)
  })

  it('returns an empty array when nothing matches', () => {
    expect(filterChatMessages(sample, 'nonexistent_token')).toEqual([])
  })

  it('does not match on role labels', () => {
    // 'user' must not match just because the role is 'user'
    expect(filterChatMessages(sample, 'user')).toEqual([])
  })
})
