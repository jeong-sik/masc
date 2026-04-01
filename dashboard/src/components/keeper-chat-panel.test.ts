import { describe, expect, it } from 'vitest'
import type { KeeperChatStreamEvent } from '../api/keeper'
import {
  isKeeperTextContentEvent,
  normalizeKeeperChatErrorValue,
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
