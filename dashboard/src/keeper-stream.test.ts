import { beforeEach, describe, expect, it } from 'vitest'
import { appendThreadEntry } from './keeper-state'
import { keeperThreads } from './keeper-state'
import { applyKeeperStreamEvent } from './keeper-stream'

function assistantEntry(): void {
  appendThreadEntry('sangsu', {
    id: 'reply-1',
    role: 'assistant',
    source: 'direct_assistant',
    label: 'sangsu',
    text: '',
    rawText: '',
    timestamp: new Date().toISOString(),
    delivery: 'sending',
    streamState: 'opening',
    details: null,
  })
}

describe('applyKeeperStreamEvent', () => {
  beforeEach(() => {
    keeperThreads.value = {}
  })

  it('appends content for TEXT_MESSAGE_CONTENT', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
      delta: '안녕',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('안녕')
    expect(entry?.delivery).toBe('streaming')
    expect(entry?.streamState).toBe('streaming')
  })

  it('ignores retired TEXT_DELTA events', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_DELTA',
      delta: '안녕',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
  })

  it('ignores empty delta text events', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
  })

  it('marks the assistant entry queued when the server accepts a request', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_QUEUE_REQUEST',
      value: {
        request_id: 'kmsg_sangsu_1',
        status: 'queued',
        modalities: ['text'],
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('queued')
    expect(entry?.streamState).toBe('opening')
  })

  it('does not render continuation checkpoint text as a chat reply', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'Continuation checkpoint saved; keeper remains scheduled for the next cycle.',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.rawText).toBe('Continuation checkpoint saved; keeper remains scheduled for the next cycle.')
    expect(entry?.delivery).toBe('queued')
    expect(entry?.streamState).toBeNull()
  })

  it('extracts error messages from events', () => {
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'RUN_ERROR',
      value: { message: 'boom' },
    })).toBe('boom')
  })
})
