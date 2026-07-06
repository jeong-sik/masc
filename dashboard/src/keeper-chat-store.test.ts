import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  _resetChatStoreForTests,
  enqueueInput,
  dequeueInput,
  markInputSent,
  requeueInputFront,
  clearInputQueue,
  hasQueuedInputClientAction,
  getQueueLength,
  getQueueTotal,
  updateQueuedMessage,
  readKeeperDraft,
  writeKeeperDraft,
  clearKeeperDraft,
  _draftCountForTests,
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

  it('dedupes queued messages by client action id, not content', () => {
    const first = enqueueInput('keeper-q', 'same text', undefined, 'click-1')
    const duplicate = enqueueInput('keeper-q', 'same text', undefined, 'click-1')
    const repeatedContent = enqueueInput('keeper-q', 'same text', undefined, 'click-2')

    expect(duplicate).toBe(first)
    expect(repeatedContent).not.toBe(first)
    expect(getQueueLength('keeper-q')).toBe(2)
    expect(hasQueuedInputClientAction('keeper-q', 'click-1')).toBe(true)
    expect(hasQueuedInputClientAction('keeper-q', 'missing')).toBe(false)
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

  it('assigns stable enqueue sequence across dequeue and requeue', () => {
    const first = enqueueInput('keeper-q', 'first')
    const second = enqueueInput('keeper-q', 'second')

    expect(first.sequence).toBe(1)
    expect(second.sequence).toBe(2)

    const msg = dequeueInput('keeper-q')
    expect(msg!.sequence).toBe(1)

    requeueInputFront('keeper-q', msg!)

    const replay = dequeueInput('keeper-q')
    expect(replay!.sequence).toBe(1)
    markInputSent('keeper-q')

    const next = dequeueInput('keeper-q')
    expect(next!.sequence).toBe(2)
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

  it('requeues a deferred sending item at the front', () => {
    enqueueInput('keeper-q', 'first')
    enqueueInput('keeper-q', 'second')
    const msg = dequeueInput('keeper-q')
    expect(msg!.content).toBe('first')

    requeueInputFront('keeper-q', msg!)

    const replay = dequeueInput('keeper-q')
    expect(replay!.content).toBe('first')
    markInputSent('keeper-q')
    const next = dequeueInput('keeper-q')
    expect(next!.content).toBe('second')
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

  it('carries display blocks and semantic user blocks through dequeue', () => {
    enqueueInput(
      'keeper-q',
      '[Voice memo 00:03 (12 KB)]\nhello',
      undefined,
      'click-voice',
      [{ t: 'voice', secs: 3, size: '12 KB', wave: [0.2, 0.8], transcript: 'hello' }],
      [{ type: 'text', text: '[Voice memo 00:03 (12 KB)]\nhello' }],
    )

    const msg = dequeueInput('keeper-q')

    expect(msg!.blocks).toEqual([
      { t: 'voice', secs: 3, size: '12 KB', wave: [0.2, 0.8], transcript: 'hello' },
    ])
    expect(msg!.userBlocks).toEqual([
      { type: 'text', text: '[Voice memo 00:03 (12 KB)]\nhello' },
    ])
  })

  it('omits the attachments key for plain messages', () => {
    enqueueInput('keeper-q', 'plain')
    const msg = dequeueInput('keeper-q')
    expect(msg!.attachments).toBeUndefined()
  })

  it('clears the client action id when a queued message is edited', () => {
    const msg = enqueueInput('keeper-q', 'original', undefined, 'click-1')

    updateQueuedMessage('keeper-q', msg.id, { content: 'edited' })

    expect(hasQueuedInputClientAction('keeper-q', 'click-1')).toBe(false)
    enqueueInput('keeper-q', 'original', undefined, 'click-1')
    expect(getQueueLength('keeper-q')).toBe(2)
  })

  it('clears stale display and semantic blocks when a queued message is edited', () => {
    const msg = enqueueInput(
      'keeper-q',
      '[Voice memo 00:03 (12 KB)]\nhello',
      undefined,
      'click-voice',
      [{ t: 'voice', secs: 3, size: '12 KB', wave: [0.2, 0.8], transcript: 'hello' }],
      [{ type: 'text', text: '[Voice memo 00:03 (12 KB)]\nhello' }],
    )

    updateQueuedMessage('keeper-q', msg.id, { content: 'edited text' })

    const edited = dequeueInput('keeper-q')
    expect(edited!.content).toBe('edited text')
    expect(edited!.blocks).toBeUndefined()
    expect(edited!.userBlocks).toBeUndefined()
  })
})

describe('keeper-chat-store draft persistence', () => {
  beforeEach(() => { _resetChatStoreForTests() })
  afterEach(() => { _resetChatStoreForTests() })

  it('reads empty for an unknown keeper', () => {
    expect(readKeeperDraft('ghost')).toBe('')
  })

  it('round-trips a draft per keeper without leaking across keepers', () => {
    writeKeeperDraft('rondo', '소주에 갑오징어')
    writeKeeperDraft('qa-king', '리뷰 부탁')
    // Each keeper keeps its own draft — no cross-keeper leak (the old single
    // shared draft would have shown one keeper's text in another's composer).
    expect(readKeeperDraft('rondo')).toBe('소주에 갑오징어')
    expect(readKeeperDraft('qa-king')).toBe('리뷰 부탁')
  })

  it('deletes the entry when written empty (no blank accumulation after send)', () => {
    writeKeeperDraft('rondo', 'half typed')
    expect(_draftCountForTests()).toBe(1)
    writeKeeperDraft('rondo', '')
    expect(readKeeperDraft('rondo')).toBe('')
    // The entry is removed, not stored as '' — readKeeperDraft alone cannot
    // distinguish the two, so assert the map actually shrank.
    expect(_draftCountForTests()).toBe(0)
  })

  it('clearKeeperDraft drops a keeper draft', () => {
    writeKeeperDraft('rondo', 'pending')
    clearKeeperDraft('rondo')
    expect(readKeeperDraft('rondo')).toBe('')
  })

  it('trims the key so whitespace variants address the same draft', () => {
    writeKeeperDraft('rondo', 'x')
    expect(readKeeperDraft('  rondo  ')).toBe('x')
  })

  it('ignores a blank-key write', () => {
    writeKeeperDraft('   ', 'nope')
    expect(readKeeperDraft('')).toBe('')
  })
})
