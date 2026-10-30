import { describe, expect, it, vi } from 'vitest'
import { parseWebSocketSseFrames, parseIncomingPayloads } from './dashboard-ws-parse'

describe('parseWebSocketSseFrames', () => {
  it('returns empty array for empty string', () => {
    expect(parseWebSocketSseFrames('')).toEqual([])
  })

  it('parses a single SSE data line', () => {
    const result = parseWebSocketSseFrames('data: {"key":"value"}\n\n')
    expect(result).toEqual([{ key: 'value' }])
  })

  it('parses multiple SSE frames separated by double newlines', () => {
    const result = parseWebSocketSseFrames(
      'data: {"a":1}\n\ndata: {"b":2}\n\n',
    )
    expect(result).toEqual([{ a: 1 }, { b: 2 }])
  })

  it('handles CRLF line endings', () => {
    const result = parseWebSocketSseFrames('data: {"x":1}\r\n\r\n')
    expect(result).toEqual([{ x: 1 }])
  })

  it('skips non-data lines', () => {
    const result = parseWebSocketSseFrames(
      'event: message\ndata: {"payload":true}\n\n',
    )
    expect(result).toEqual([{ payload: true }])
  })

  it('strips leading space after data: prefix', () => {
    const result = parseWebSocketSseFrames('data: {"spaced":true}\n\n')
    expect(result).toEqual([{ spaced: true }])
  })

  it('joins multiple data lines into one JSON payload', () => {
    const result = parseWebSocketSseFrames(
      'data: [\ndata: 1,\ndata: 2\ndata: ]\n\n',
    )
    expect(result).toEqual([[1, 2]])
  })

  it('skips [DONE] frames', () => {
    const result = parseWebSocketSseFrames('data: [DONE]\n\n')
    expect(result).toEqual([])
  })

  it('skips empty frames', () => {
    const result = parseWebSocketSseFrames('\n\n')
    expect(result).toEqual([])
  })

  it('drops malformed JSON with a console warning', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const result = parseWebSocketSseFrames('data: not-json\n\n')
    expect(result).toEqual([])
    expect(warnSpy).toHaveBeenCalledOnce()
    expect(warnSpy.mock.calls[0]![0]).toBe('[dashboard-ws] non-JSON SSE frame dropped')
    warnSpy.mockRestore()
  })

  it('includes truncated sample in warning for long payloads', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const longPayload = 'x'.repeat(300)
    parseWebSocketSseFrames(`data: ${longPayload}\n\n`)
    const callArg = warnSpy.mock.calls[0]![1] as Record<string, unknown>
    expect(callArg.sample).toContain('…')
    expect((callArg.sample as string).length).toBeLessThan(250)
    warnSpy.mockRestore()
  })

  it('parses frames with mixed valid and invalid JSON', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const result = parseWebSocketSseFrames(
      'data: {"valid":true}\n\ndata: bad\n\n',
    )
    expect(result).toEqual([{ valid: true }])
    expect(warnSpy).toHaveBeenCalledOnce()
    warnSpy.mockRestore()
  })
})

describe('parseIncomingPayloads', () => {
  it('returns parsed JSON for valid JSON string', () => {
    expect(parseIncomingPayloads('{"direct":true}')).toEqual([{ direct: true }])
  })

  it('falls back to SSE frame parsing for non-JSON', () => {
    const result = parseIncomingPayloads('data: {"sse":true}\n\n')
    expect(result).toEqual([{ sse: true }])
  })

  it('returns empty array for completely invalid input', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    expect(parseIncomingPayloads('garbage')).toEqual([])
    warnSpy.mockRestore()
  })

  it('parses JSON array as single payload', () => {
    expect(parseIncomingPayloads('[1,2,3]')).toEqual([[1, 2, 3]])
  })

  it('parses primitive JSON values', () => {
    expect(parseIncomingPayloads('42')).toEqual([42])
    expect(parseIncomingPayloads('"hello"')).toEqual(['hello'])
    expect(parseIncomingPayloads('true')).toEqual([true])
    expect(parseIncomingPayloads('null')).toEqual([null])
  })
})
