import { describe, expect, it } from 'vitest'
import { parseKeeperShellSseFrame } from './keeper-shell'

describe('keeper shell SSE parsing', () => {
  it('parses shell data frames', () => {
    const event = parseKeeperShellSseFrame(
      'event: shell\ndata: {"type":"snapshot","keeper":"sangsu","stdout_since":"ok"}',
    )

    expect(event).toMatchObject({
      type: 'snapshot',
      keeper: 'sangsu',
      stdout_since: 'ok',
    })
  })

  it('ignores malformed frames', () => {
    expect(parseKeeperShellSseFrame('event: shell\ndata: {')).toBeNull()
  })
})
