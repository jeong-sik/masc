import { beforeEach, describe, expect, it } from 'vitest'
import {
  _resetLiveSendRequestOwnersForTests,
  activeStreamRequestId,
  appendThreadEntry,
  setActiveStreamRequestId,
} from './keeper-state'
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
    _resetLiveSendRequestOwnersForTests()
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

  it('surfaces failed request terminal events before stream error close', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_sangsu_1',
        status: 'error',
        ok: false,
        message: 'Timeout after 630.0s',
      },
    })).toBe('Timeout after 630.0s')

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('error')
    expect(entry?.streamState).toBeNull()
    expect(entry?.error).toBe('Timeout after 630.0s')
    expect(entry?.text).toBe('Keeper request failed: Timeout after 630.0s')
  })

  it('renders cancelled request terminal events without an error bubble', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_sangsu_1',
        status: 'cancelled',
        ok: false,
        message: 'keeper chat stream cancelled by client',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('cancelled')
    expect(entry?.streamState).toBeNull()
    expect(entry?.error).toBeNull()
    expect(entry?.text).toBe('요청이 취소되었습니다.')
  })

  it('ignores terminal events for a different active request id', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_stale',
        status: 'cancelled',
        ok: false,
        message: 'stale terminal',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('sending')
    expect(entry?.streamState).toBe('opening')
  })

  it('ignores no-id terminal events while a request id is active', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        status: 'cancelled',
        ok: false,
        message: 'legacy terminal without request id',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('sending')
    expect(entry?.streamState).toBe('opening')
    expect(activeStreamRequestId('sangsu')).toBe('kmsg_current')
  })

  it('ignores non-terminal request status events', () => {
    assistantEntry()
    setActiveStreamRequestId('sangsu', 'kmsg_current')

    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: {
        request_id: 'kmsg_current',
        status: 'running',
        ok: false,
        message: 'not terminal yet',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.delivery).toBe('sending')
    expect(entry?.streamState).toBe('opening')
  })

  // RFC-0232 P2: the checkpoint distinction rides the producer-typed
  // `turn_outcome` field, not the reply text.
  it('does not render a declared continuation checkpoint as a chat reply', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'Continuation checkpoint saved; keeper remains scheduled for the next cycle.',
        turn_outcome: 'continuation_checkpoint',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.rawText).toBe('Continuation checkpoint saved; keeper remains scheduled for the next cycle.')
    expect(entry?.delivery).toBe('queued')
    expect(entry?.streamState).toBeNull()
  })

  it('renders checkpoint-shaped text as a reply when not declared a checkpoint', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'Continuation checkpoint saved; keeper remains scheduled for the next cycle.',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('Continuation checkpoint saved; keeper remains scheduled for the next cycle.')
    expect(entry?.delivery).toBe('sending')
  })

  it('suppresses a declared checkpoint regardless of reply text', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: '작업을 완료했습니다.',
        turn_outcome: 'continuation_checkpoint',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.delivery).toBe('queued')
  })

  it('suppresses a declared no-visible reply without marking it queued', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_REPLY_DETAILS',
      value: {
        reply: 'hidden runtime-only observation',
        turn_outcome: 'no_visible_reply',
      },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.text).toBe('')
    expect(entry?.rawText).toBe('hidden runtime-only observation')
    expect(entry?.delivery).toBe('no_reply')
    expect(entry?.streamState).toBeNull()
  })

  it('extracts error messages from events', () => {
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'RUN_ERROR',
      value: { message: 'boom' },
    })).toBe('boom')
  })

  it('sets thinking state on KEEPER_THINKING_DELTA', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'reasoning about the problem...' },
    })).toBeNull()

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.streamState).toBe('thinking')
    expect(entry?.delivery).toBe('streaming')
    expect(entry?.traceSteps).toEqual([
      { kind: 'think', text: 'reasoning about the problem...', ts: expect.any(String) },
    ])
  })

  it('appends multiple thinking deltas to one trace step', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'checking ' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'tools' },
    })

    const entry = keeperThreads.value.sangsu?.find(item => item.id === 'reply-1')
    expect(entry?.traceSteps).toEqual([
      { kind: 'think', text: 'checking tools', ts: expect.any(String) },
    ])
  })
})

describe('applyKeeperStreamEvent tool calls', () => {
  beforeEach(() => {
    keeperThreads.value = {}
    _resetLiveSendRequestOwnersForTests()
  })

  it('streams a live tool-call entry above the assistant bubble', () => {
    assistantEntry()
    expect(applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-1',
      toolCallName: 'masc_status',
    })).toBeNull()
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS', toolCallId: 'tc-1', delta: '{"fast":' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS', toolCallId: 'tc-1', delta: 'true}' })

    const thread = keeperThreads.value.sangsu ?? []
    const toolIndex = thread.findIndex(entry => entry.id === 'tool-tc-1')
    const replyIndex = thread.findIndex(entry => entry.id === 'reply-1')
    expect(toolIndex).toBeGreaterThanOrEqual(0)
    expect(toolIndex).toBeLessThan(replyIndex)

    const tool = thread[toolIndex]!
    expect(tool.role).toBe('tool')
    expect(tool.label).toBe('masc_status')
    expect(tool.text).toBe('{"fast":true}')
    expect(tool.delivery).toBe('streaming')
    const reply = thread[replyIndex]!
    expect(reply.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'masc_status',
        toolCallId: 'tc-1',
        status: 'pending',
        args: '{"fast":true}',
        ts: expect.any(String),
      },
    ])

    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END', toolCallId: 'tc-1' })
    const finished = keeperThreads.value.sangsu?.find(entry => entry.id === 'tool-tc-1')
    expect(finished?.delivery).toBe('delivered')
    expect(finished?.streamState).toBeNull()
  })

  it('records tool calls in the assistant trace between thinking deltas', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'think A' },
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-ordered',
      toolCallName: 'keeper_board_list',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_ARGS',
      toolCallId: 'tc-ordered',
      delta: '{"limit":1}',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_END',
      toolCallId: 'tc-ordered',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { delta: 'think B' },
    })

    const reply = keeperThreads.value.sangsu?.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      { kind: 'think', text: 'think A', ts: expect.any(String) },
      {
        kind: 'tool',
        name: 'keeper_board_list',
        toolCallId: 'tc-ordered',
        status: 'ok',
        args: '{"limit":1}',
        ts: expect.any(String),
      },
      { kind: 'think', text: 'think B', ts: expect.any(String) },
    ])
  })

  it('routes args to the last started tool call when toolCallId is missing', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-fallback',
      toolCallName: 'keeper_board_post',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS', delta: '{"post_id":"p-1"}' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END' })

    const tool = keeperThreads.value.sangsu?.find(entry => entry.id === 'tool-tc-fallback')
    expect(tool?.text).toBe('{"post_id":"p-1"}')
    expect(tool?.delivery).toBe('delivered')
  })

  it('keeps duplicate TOOL_CALL_START events idempotent', () => {
    assistantEntry()
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-repeat',
      toolCallName: 'keeper_board_post',
    })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_ARGS', toolCallId: 'tc-repeat', delta: '{"post_id":"p-1"}' })
    applyKeeperStreamEvent('sangsu', 'reply-1', { type: 'TOOL_CALL_END', toolCallId: 'tc-repeat' })
    applyKeeperStreamEvent('sangsu', 'reply-1', {
      type: 'TOOL_CALL_START',
      toolCallId: 'tc-repeat',
      toolCallName: 'keeper_board_post',
    })

    const thread = keeperThreads.value.sangsu ?? []
    expect(thread.filter(entry => entry.id === 'tool-tc-repeat')).toHaveLength(1)
    const reply = thread.find(entry => entry.id === 'reply-1')
    expect(reply?.traceSteps).toEqual([
      {
        kind: 'tool',
        name: 'keeper_board_post',
        toolCallId: 'tc-repeat',
        status: 'ok',
        args: '{"post_id":"p-1"}',
        ts: expect.any(String),
      },
    ])
  })
})
