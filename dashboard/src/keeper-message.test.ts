import { describe, it, expect } from 'vitest'
import {
  formatKeeperVisibleReply,
  normalizeKeeperConversationDetails,
  normalizeKeeperToolResponse,
} from './keeper-message'

// ================================================================
// formatKeeperVisibleReply
// ================================================================

describe('formatKeeperVisibleReply', () => {
  it('returns trimmed text without SKILL lines', () => {
    const input = `Hello
SKILL some-skill
World`
    expect(formatKeeperVisibleReply(input)).toBe('Hello\nWorld')
  })

  it('removes SKILL lines', () => {
    const input = `Line1
SKILL route-to-keeper
Line2`
    expect(formatKeeperVisibleReply(input)).toBe('Line1\nLine2')
  })

  it('removes SKILL lines with leading whitespace', () => {
    const input = `Line1
  SKILL indented
Line2`
    expect(formatKeeperVisibleReply(input)).toBe('Line1\nLine2')
  })

  it('collapses 3+ newlines to 2', () => {
    expect(formatKeeperVisibleReply('a\n\n\nb')).toBe('a\n\nb')
  })

  it('collapses many newlines to 2', () => {
    expect(formatKeeperVisibleReply('a\n\n\n\n\nb')).toBe('a\n\nb')
  })

  it('preserves single newline', () => {
    expect(formatKeeperVisibleReply('a\nb')).toBe('a\nb')
  })

  it('preserves double newline', () => {
    expect(formatKeeperVisibleReply('a\n\nb')).toBe('a\n\nb')
  })

  it('trims leading and trailing whitespace', () => {
    expect(formatKeeperVisibleReply('  hello  ')).toBe('hello')
  })

  it('handles empty string', () => {
    expect(formatKeeperVisibleReply('')).toBe('')
  })

  it('handles whitespace-only string', () => {
    expect(formatKeeperVisibleReply('   \n\n   ')).toBe('')
  })

})

// ================================================================
// normalizeKeeperConversationDetails
// ================================================================

describe('normalizeKeeperConversationDetails', () => {
  it('returns null for null', () => {
    expect(normalizeKeeperConversationDetails(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(normalizeKeeperConversationDetails(undefined)).toBeNull()
  })

  it('returns null for string', () => {
    expect(normalizeKeeperConversationDetails('not an object')).toBeNull()
  })

  it('returns null for array', () => {
    expect(normalizeKeeperConversationDetails([1, 2, 3])).toBeNull()
  })

  it('extracts fields from direct payload', () => {
    const result = normalizeKeeperConversationDetails({
      trace_id: 'trace-123',
      generation: 5,
      model_used: 'gpt-4',
      latency_ms: 1500,
      cost_usd: 0.05,
      reply: 'Hello',
      skill_primary: 'router',
      skill_reason: 'default',
      usage: {
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        cache_creation_input_tokens: 7,
        cache_read_input_tokens: 11,
        cost_usd: 0.04,
      },
    })
    expect(result).not.toBeNull()
    expect(result!.traceId).toBe('trace-123')
    expect(result!.generation).toBe(5)
    expect(result!.modelUsed).toBe('gpt-4')
    expect(result!.latencyMs).toBe(1500)
    expect(result!.costUsd).toBe(0.05)
    expect(result!.skillPrimary).toBe('router')
    expect(result!.skillReason).toBe('default')
    expect(result!.replyText).toBe('Hello')
    expect(result!.usage).toEqual({
      inputTokens: 100,
      outputTokens: 50,
      totalTokens: 150,
      cacheCreationInputTokens: 7,
      cacheReadInputTokens: 11,
      costUsd: 0.04,
    })
  })

  it('unwraps raw_payload wrapper', () => {
    const result = normalizeKeeperConversationDetails({
      raw_payload: {
        trace_id: 'inner-trace',
        reply: 'Inner reply',
      },
    })
    expect(result).not.toBeNull()
    expect(result!.traceId).toBe('inner-trace')
    expect(result!.replyText).toBe('Inner reply')
  })

  it('prefers raw_payload over outer keys', () => {
    const result = normalizeKeeperConversationDetails({
      trace_id: 'outer-trace',
      raw_payload: {
        trace_id: 'inner-trace',
        reply: 'Inner',
      },
    })
    expect(result).not.toBeNull()
    expect(result!.traceId).toBe('inner-trace')
  })

  it('ignores raw_payload if not a record', () => {
    const result = normalizeKeeperConversationDetails({
      raw_payload: 'not-a-record',
      trace_id: 'outer',
    })
    expect(result).not.toBeNull()
    expect(result!.traceId).toBe('outer')
  })

  it('defaults null for missing string fields', () => {
    const result = normalizeKeeperConversationDetails({})
    expect(result).not.toBeNull()
    expect(result!.traceId).toBeNull()
    expect(result!.modelUsed).toBeNull()
    expect(result!.skillPrimary).toBeNull()
    expect(result!.skillReason).toBeNull()
    expect(result!.replyText).toBeNull()
  })

  it('defaults null for missing numeric fields', () => {
    const result = normalizeKeeperConversationDetails({})
    expect(result).not.toBeNull()
    expect(result!.generation).toBeNull()
    expect(result!.latencyMs).toBeNull()
    expect(result!.costUsd).toBeNull()
  })

  it('defaults null usage when usage is not a record', () => {
    const result = normalizeKeeperConversationDetails({ usage: 'invalid' })
    expect(result).not.toBeNull()
    expect(result!.usage).toBeNull()
  })

  it('extracts partial usage', () => {
    const result = normalizeKeeperConversationDetails({
      usage: { input_tokens: 100 },
    })
    expect(result).not.toBeNull()
    expect(result!.usage).toEqual({
      inputTokens: 100,
      outputTokens: null,
      totalTokens: null,
    })
  })

  it('includes rawPayload', () => {
    const payload = { trace_id: 't1', reply: 'r1' }
    const result = normalizeKeeperConversationDetails(payload)
    expect(result).not.toBeNull()
    expect(result!.rawPayload).toBe(payload)
  })

  it('handles empty reply as null replyText', () => {
    const result = normalizeKeeperConversationDetails({ reply: '' })
    expect(result).not.toBeNull()
    expect(result!.replyText).toBeNull()
  })

  it('handles whitespace-only reply as null replyText', () => {
    const result = normalizeKeeperConversationDetails({ reply: '   ' })
    expect(result).not.toBeNull()
    // reply is trimmed by asString, so '   ' becomes undefined, which ?? '' => ''
    // Then reply || null: '' is falsy => null
    expect(result!.replyText).toBeNull()
  })
})

// ================================================================
// normalizeKeeperToolResponse
// ================================================================

describe('normalizeKeeperToolResponse', () => {
  it('parses valid JSON payload', () => {
    const raw = JSON.stringify({
      reply: 'Hello World',
      trace_id: 'trace-1',
      generation: 3,
    })
    const result = normalizeKeeperToolResponse(raw)
    expect(result.text).toBe('Hello World')
    expect(result.details).not.toBeNull()
    expect(result.details!.traceId).toBe('trace-1')
    expect(result.details!.generation).toBe(3)
  })

  it('handles plain text (non-JSON)', () => {
    const result = normalizeKeeperToolResponse('Just some text')
    expect(result.text).toBe('Just some text')
    expect(result.details).toBeNull()
  })

  it('handles plain text with leading whitespace', () => {
    const result = normalizeKeeperToolResponse('  Hello World  ')
    expect(result.text).toBe('Hello World')
    expect(result.details).toBeNull()
  })

  it('handles invalid JSON gracefully', () => {
    const result = normalizeKeeperToolResponse('{not valid json}')
    expect(result.text).toBe('{not valid json}')
    expect(result.details).toBeNull()
  })

  it('strips SKILL lines from JSON reply', () => {
    const raw = JSON.stringify({
      reply: 'Line1\nSKILL route\nLine2',
    })
    const result = normalizeKeeperToolResponse(raw)
    expect(result.text).toBe('Line1\nLine2')
  })

  it('returns raw text when JSON has no reply field', () => {
    const raw = JSON.stringify({ other: 'value' })
    const result = normalizeKeeperToolResponse(raw)
    // When payload is a record but has no reply, asString returns undefined,
    // falls back to trimmed original string
    expect(result.text).toBe(raw)
  })

  it('handles JSON payload with raw_payload wrapper', () => {
    const raw = JSON.stringify({
      raw_payload: {
        reply: 'Inner reply',
        trace_id: 'inner-trace',
      },
    })
    const result = normalizeKeeperToolResponse(raw)
    // normalizeKeeperToolResponse checks outer payload.reply (absent),
    // falls back to the original JSON string for text
    expect(result.text).toBe(raw)
    // But normalizeKeeperConversationDetails unwraps raw_payload correctly
    expect(result.details).not.toBeNull()
    expect(result.details!.traceId).toBe('inner-trace')
    expect(result.details!.replyText).toBe('Inner reply')
  })

  it('extracts usage from JSON payload', () => {
    const raw = JSON.stringify({
      reply: 'Reply',
      usage: {
        input_tokens: 200,
        output_tokens: 100,
        total_tokens: 300,
      },
    })
    const result = normalizeKeeperToolResponse(raw)
    expect(result.details).not.toBeNull()
    expect(result.details!.usage).toEqual({
      inputTokens: 200,
      outputTokens: 100,
      totalTokens: 300,
    })
  })

  it('handles empty string input', () => {
    const result = normalizeKeeperToolResponse('')
    expect(result.text).toBe('')
    expect(result.details).toBeNull()
  })

  it('handles whitespace-only input', () => {
    const result = normalizeKeeperToolResponse('   ')
    expect(result.text).toBe('')
    expect(result.details).toBeNull()
  })

  it('collapses multiple newlines in reply', () => {
    const raw = JSON.stringify({
      reply: 'A\n\n\n\nB',
    })
    const result = normalizeKeeperToolResponse(raw)
    expect(result.text).toBe('A\n\nB')
  })
})
