import { describe, expect, it, vi } from 'vitest'
import {
  acceptedReplyState,
  appendStreamNotice,
  chatProviderRetry,
  providerRetryLabel,
  runtimeAttemptLabel,
} from './chat-stream-notices'
import { dispatchContractNotice, type StreamKeeperChatCallbacks } from './keepers-api'

const custom = (name: string, value: unknown) => ({ type: 'CUSTOM', threadId: 'keeper:wkbl-growth', timestamp: 1, name, value })

const retryValue = {
  attempt: { routing_run_id: 'run-1', runtime_id: 'glm-coding.glm-5.3-flash', lane_attempt_index: 2 },
  retry: { observation_id: 'obs-1', attempt: 2, max_retries: 5, retry_delay_ms: 4000, error_status: 529 },
}

describe('keeper chat stream notices', () => {
  it('does not call a failed or cancelled operation delivered', () => {
    expect(acceptedReplyState('Failed').delivery).toBe('Failed')
    expect(acceptedReplyState('Cancelled').delivery).toBe('Failed')
    expect(acceptedReplyState('Queued').delivery).toBe('Queued')
    expect(acceptedReplyState('Running').delivery).toBe('Pending_processing')
    expect(acceptedReplyState('Succeeded')).toEqual({ delivery: 'Delivered', detail: null })
  })

  it('reads a provider retry through the stream contract', () => {
    const onProviderRetry = vi.fn()
    dispatchContractNotice('KEEPER_PROVIDER_RETRY', custom('KEEPER_PROVIDER_RETRY', retryValue), { onProviderRetry })
    expect(onProviderRetry).toHaveBeenCalledWith(retryValue)
    expect(providerRetryLabel(chatProviderRetry(retryValue)))
      .toBe('공급자 재시도 2/5 · HTTP 529 · 4초 뒤 · glm-coding.glm-5.3-flash')
  })

  it('says which runtime streams and that a later attempt replaced the earlier text', () => {
    const onAttemptStarted = vi.fn()
    dispatchContractNotice('KEEPER_RUNTIME_ATTEMPT_STARTED',
      custom('KEEPER_RUNTIME_ATTEMPT_STARTED', { runtime_id: 'glm-coding.glm-5.3-flash', attempt_index: 2 }),
      { onAttemptStarted })
    expect(onAttemptStarted).toHaveBeenCalledWith({ runtimeId: 'glm-coding.glm-5.3-flash', attemptIndex: 2 })
    expect(runtimeAttemptLabel({ runtimeId: 'glm-coding.glm-5.3-flash', attemptIndex: 2 }))
      .toBe('glm-coding.glm-5.3-flash · 다시 시도 #2')
    expect(runtimeAttemptLabel({ runtimeId: 'claude', attemptIndex: 1 })).toBe('claude')
    expect(runtimeAttemptLabel({ runtimeId: null, attemptIndex: 1 })).toBeNull()
  })

  it('names the quarantined tool occurrence of a protocol error', () => {
    const onStreamProtocolError = vi.fn()
    dispatchContractNotice('KEEPER_STREAM_PROTOCOL_ERROR', custom('KEEPER_STREAM_PROTOCOL_ERROR', {
      kind: 'tool_args_without_start', reason: 'unterminated string',
      quarantined_occurrence: { toolStreamScope: 3, toolCallBlockIndex: 1 },
    }), { onStreamProtocolError })
    expect(onStreamProtocolError).toHaveBeenCalledWith({
      message: 'tool_args_without_start · unterminated string',
      quarantinedStreamKey: 'occ:3:1',
    })
  })

  it('shows a payload outside the contract as a protocol problem, and still resets the reply', () => {
    const callbacks: StreamKeeperChatCallbacks = {
      onAttemptStarted: vi.fn(),
      onProviderRetry: vi.fn(),
      onStreamProtocolError: vi.fn(),
    }
    dispatchContractNotice('KEEPER_PROVIDER_RETRY', custom('KEEPER_PROVIDER_RETRY', { attempt: {} }), callbacks)
    expect(callbacks.onProviderRetry).not.toHaveBeenCalled()
    expect(callbacks.onStreamProtocolError).toHaveBeenCalledTimes(1)
    dispatchContractNotice('KEEPER_RUNTIME_ATTEMPT_STARTED',
      custom('KEEPER_RUNTIME_ATTEMPT_STARTED', { attempt_index: 'two' }), callbacks)
    expect(callbacks.onAttemptStarted).toHaveBeenCalledWith(null)
  })

  it('reads a continuation checkpoint message', () => {
    const onContinuationCheckpoint = vi.fn()
    dispatchContractNotice('KEEPER_CONTINUATION_CHECKPOINT',
      custom('KEEPER_CONTINUATION_CHECKPOINT', { message: 'paused at step 4' }), { onContinuationCheckpoint })
    expect(onContinuationCheckpoint).toHaveBeenCalledWith('paused at step 4')
  })

  it('keeps one copy of a notice repeated back to back', () => {
    const once = appendStreamNotice(undefined, { kind: 'checkpoint', text: 'a' })
    expect(appendStreamNotice(once, { kind: 'checkpoint', text: 'a' })).toHaveLength(1)
    expect(appendStreamNotice(once, { kind: 'protocol_error', text: 'a' })).toHaveLength(2)
  })
})
