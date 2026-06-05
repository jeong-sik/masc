import { beforeEach, describe, expect, it } from 'vitest'
import {
  type ChatMessage,
  getChatMessageBuffer,
  appendChatMessage,
  setChatMessages,
  clearChatMessages,
  mergeServerHistory,
  flushStreamBuffer,
  _resetChatStoreForTests,
  enqueueInput,
  dequeueInput,
  markInputSent,
  clearInputQueue,
  getQueueLength,
  getQueueTotal,
} from './keeper-chat-store'

describe('keeper-chat-store', () => {
  beforeEach(() => {
    _resetChatStoreForTests()
  })

  describe('getChatMessageBuffer', () => {
    it('returns an empty array for an unseen keeper', () => {
      const buf = getChatMessageBuffer('unknown-keeper')
      expect(buf).toEqual([])
    })

    it('returns the same array reference for repeated calls', () => {
      const a = getChatMessageBuffer('keeper-a')
      const b = getChatMessageBuffer('keeper-a')
      expect(a).toBe(b)
    })
  })

  describe('appendChatMessage', () => {
    it('adds a message and persists to sessionStorage', () => {
      const msg: ChatMessage = { role: 'user', content: 'hello', timestamp: 1000, source: 'dashboard' }
      appendChatMessage('keeper-a', msg)

      const buf = getChatMessageBuffer('keeper-a')
      expect(buf).toHaveLength(1)
      expect(buf[0]).toEqual(msg)

      // sessionStorage round-trip: clear in-memory buffer only, preserve storage
      _resetChatStoreForTests(false)
      const restored = getChatMessageBuffer('keeper-a')
      expect(restored).toHaveLength(1)
      expect(restored[0]).toEqual(msg)
    })

    it('appends multiple messages in order', () => {
      appendChatMessage('keeper-b', { role: 'user', content: 'q1', timestamp: 1000 })
      appendChatMessage('keeper-b', { role: 'assistant', content: 'a1', timestamp: 2000 })
      appendChatMessage('keeper-b', { role: 'user', content: 'q2', timestamp: 3000 })

      const buf = getChatMessageBuffer('keeper-b')
      expect(buf).toHaveLength(3)
      expect(buf.map((m) => m.content)).toEqual(['q1', 'a1', 'q2'])
    })
  })

  describe('setChatMessages', () => {
    it('replaces the entire buffer', () => {
      appendChatMessage('keeper-c', { role: 'user', content: 'old', timestamp: 1000 })
      setChatMessages('keeper-c', [{ role: 'assistant', content: 'new', timestamp: 2000 }])

      const buf = getChatMessageBuffer('keeper-c')
      expect(buf).toHaveLength(1)
      expect(buf[0]!.content).toBe('new')
    })
  })

  describe('clearChatMessages', () => {
    it('removes in-memory buffer and sessionStorage', () => {
      appendChatMessage('keeper-d', { role: 'user', content: 'x', timestamp: 1000 })
      clearChatMessages('keeper-d')

      const buf = getChatMessageBuffer('keeper-d')
      expect(buf).toEqual([])

      _resetChatStoreForTests()
      const restored = getChatMessageBuffer('keeper-d')
      expect(restored).toEqual([])
    })
  })

  describe('mergeServerHistory', () => {
    it('merges local and server messages without duplication', () => {
      appendChatMessage('keeper-e', { role: 'user', content: 'local', timestamp: 1000 })
      const serverMsgs: ChatMessage[] = [
        { role: 'user', content: 'local', timestamp: 1000, source: 'api' },
        { role: 'assistant', content: 'server', timestamp: 2000, source: 'api' },
      ]
      mergeServerHistory('keeper-e', serverMsgs)

      const buf = getChatMessageBuffer('keeper-e')
      expect(buf).toHaveLength(2)
      expect(buf.map((m) => m.content)).toEqual(['local', 'server'])
    })

    it('sorts merged messages by timestamp', () => {
      appendChatMessage('keeper-f', { role: 'user', content: 'late', timestamp: 3000 })
      const serverMsgs: ChatMessage[] = [
        { role: 'assistant', content: 'early', timestamp: 1000, source: 'api' },
        { role: 'assistant', content: 'mid', timestamp: 2000, source: 'api' },
      ]
      mergeServerHistory('keeper-f', serverMsgs)

      const buf = getChatMessageBuffer('keeper-f')
      expect(buf.map((m) => m.content)).toEqual(['early', 'mid', 'late'])
    })

    it('preserves local source when deduplicating', () => {
      appendChatMessage('keeper-g', { role: 'user', content: 'x', timestamp: 1000, source: 'dashboard' })
      mergeServerHistory('keeper-g', [
        { role: 'user', content: 'x', timestamp: 1000, source: 'api' },
      ])

      const buf = getChatMessageBuffer('keeper-g')
      expect(buf[0]!.source).toBe('dashboard')
    })
  })

  describe('flushStreamBuffer', () => {
    it('ignores empty buffer', () => {
      flushStreamBuffer('keeper-h', '   ')
      expect(getChatMessageBuffer('keeper-h')).toEqual([])
    })

    it('saves non-empty buffer as assistant message', () => {
      flushStreamBuffer('keeper-i', 'partial response')
      const buf = getChatMessageBuffer('keeper-i')
      expect(buf).toHaveLength(1)
      expect(buf[0]!.role).toBe('assistant')
      expect(buf[0]!.content).toBe('partial response')
      expect(buf[0]!.source).toBe('dashboard')
    })
  })

  describe('input queue', () => {
    it('enqueues a message while streaming', () => {
      enqueueInput('keeper-q', 'hello queue')
      expect(getQueueLength('keeper-q')).toBe(1)
    })

    it('dequeues messages in FIFO order', () => {
      enqueueInput('keeper-q', 'first')
      enqueueInput('keeper-q', 'second')
      const msg1 = dequeueInput('keeper-q')
      expect(msg1!.content).toBe('first')
      markInputSent('keeper-q')
      const msg2 = dequeueInput('keeper-q')
      expect(msg2!.content).toBe('second')
      markInputSent('keeper-q')
      expect(dequeueInput('keeper-q')).toBeNull()
    })

    it('prevents dequeue while sending', () => {
      enqueueInput('keeper-q', 'only')
      dequeueInput('keeper-q')
      expect(dequeueInput('keeper-q')).toBeNull()
    })

    it('allows dequeue after markInputSent', () => {
      enqueueInput('keeper-q', 'a')
      enqueueInput('keeper-q', 'b')
      dequeueInput('keeper-q')
      markInputSent('keeper-q')
      const next = dequeueInput('keeper-q')
      expect(next!.content).toBe('b')
    })

    it('clearInputQueue removes all items', () => {
      enqueueInput('keeper-q', 'x')
      enqueueInput('keeper-q', 'y')
      clearInputQueue('keeper-q')
      expect(getQueueLength('keeper-q')).toBe(0)
    })

    it('is isolated per keeper', () => {
      enqueueInput('keeper-a', 'a-msg')
      enqueueInput('keeper-b', 'b-msg')
      expect(getQueueLength('keeper-a')).toBe(1)
      expect(getQueueLength('keeper-b')).toBe(1)
    })

    it('getQueueTotal includes sending item', () => {
      enqueueInput('keeper-q', 'sending')
      enqueueInput('keeper-q', 'waiting')
      dequeueInput('keeper-q')
      expect(getQueueTotal('keeper-q')).toBe(2)
      expect(getQueueLength('keeper-q')).toBe(1)
    })

    it('_resetChatStoreForTests clears queues', () => {
      enqueueInput('keeper-q', 'test')
      _resetChatStoreForTests()
      expect(getQueueLength('keeper-q')).toBe(0)
    })
  })

  describe('attachments', () => {
    it('stores messages with attachments', () => {
      const msg: ChatMessage = {
        role: 'user',
        content: 'check this',
        timestamp: 1000,
        source: 'dashboard',
        attachments: [{
          id: 'att-1',
          type: 'image',
          name: 'screenshot.png',
          size: 1024,
          mimeType: 'image/png',
          data: 'data:image/png;base64,abc123',
        }],
      }
      appendChatMessage('keeper-att', msg)
      const buf = getChatMessageBuffer('keeper-att')
      expect(buf).toHaveLength(1)
      expect(buf[0]!.attachments).toHaveLength(1)
      expect(buf[0]!.attachments![0]!.name).toBe('screenshot.png')
    })

    it('round-trips attachments through sessionStorage', () => {
      const msg: ChatMessage = {
        role: 'user',
        content: 'with file',
        timestamp: 2000,
        attachments: [{
          id: 'att-2',
          type: 'file',
          name: 'log.txt',
          size: 512,
          mimeType: 'text/plain',
          data: 'data:text/plain;base64,abc',
        }],
      }
      appendChatMessage('keeper-att2', msg)
      _resetChatStoreForTests(false)
      const restored = getChatMessageBuffer('keeper-att2')
      expect(restored[0]!.attachments![0]!.name).toBe('log.txt')
    })
  })
})
