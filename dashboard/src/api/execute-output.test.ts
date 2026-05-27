import { describe, expect, it } from 'vitest'
import { parseExecuteOutputSseFrame } from './execute-output'

describe('Execute output SSE parsing', () => {
  it('parses Execute output data frames', () => {
    const event = parseExecuteOutputSseFrame(
      'event: output\ndata: {"type":"snapshot","keeper":"sangsu","stdout_since":"ok"}',
    )

    expect(event).toMatchObject({
      type: 'snapshot',
      keeper: 'sangsu',
      stdout_since: 'ok',
    })
  })

  it('ignores malformed frames', () => {
    expect(parseExecuteOutputSseFrame('event: output\ndata: {')).toBeNull()
  })
})
