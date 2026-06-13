import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  _resetChatStoreForTests,
  enqueueInput,
  dequeueInput,
  markInputSent,
  clearInputQueue,
  getQueueLength,
  getQueueTotal,
} from './keeper-chat-store'

describe('keeper-chat-store input queue', () => {
  beforeEach(() => {
    _resetChatStoreForTests()
  })

  afterEach(() => {
    _resetChatStoreForTests()
  })

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

  it('carries attachments selected at enqueue time through dequeue', () => {
    enqueueInput('keeper-q', 'with file', [{
      id: 'att-1',
      type: 'image',
      name: 'screenshot.png',
      size: 1024,
      mimeType: 'image/png',
      data: 'data:image/png;base64,abc123',
    }])
    const msg = dequeueInput('keeper-q')
    expect(msg!.attachments).toHaveLength(1)
    expect(msg!.attachments![0]!.name).toBe('screenshot.png')
  })

  it('omits the attachments key for plain messages', () => {
    enqueueInput('keeper-q', 'plain')
    const msg = dequeueInput('keeper-q')
    expect(msg!.attachments).toBeUndefined()
  })
})
