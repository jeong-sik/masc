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

  it('appends legacy TEXT_DELTA events', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_DELTA',
      delta: '안녕',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('안녕')
  })

  it('ignores empty delta text events', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TEXT_MESSAGE_CONTENT',
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
  })

  it('extracts error messages from events', () => {
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'RUN_ERROR',
      value: { message: 'boom' },
    })).toBe('boom')
  })
})
