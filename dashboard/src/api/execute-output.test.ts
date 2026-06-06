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

  it('parses structured line frames', () => {
    const event = parseExecuteOutputSseFrame(
      'event: output\ndata: {"type":"line","kind":"line","keeper_id":"sangsu","keeper":"sangsu","line":{"ts_ms":1000,"stream":"stdout","text":"ok","ansi":false}}',
    )

    expect(event).toMatchObject({
      type: 'line',
      keeper: 'sangsu',
      keeper_id: 'sangsu',
      line: {
        ts_ms: 1000,
        stream: 'stdout',
        text: 'ok',
        ansi: false,
      },
    })
  })

  it('ignores malformed frames', () => {
    expect(parseExecuteOutputSseFrame('event: output\ndata: {')).toBeNull()
  })
})
