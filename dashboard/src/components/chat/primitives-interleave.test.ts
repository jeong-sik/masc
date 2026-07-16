// @vitest-environment jsdom

// Unit tests for the render-time think<->tool interleaving in ToolTraceCard.
// Pure-function level so the ordering contract is asserted without the jsdom
// render harness: live streams carry tool calls in traceSteps, so the merge
// must preserve that structural order and use sibling tool entries only for
// details/result hydration.
import { describe, expect, it } from 'vitest'
import type { ChatTraceStep, KeeperConversationEntry } from '../../types'
import { interleaveTraceAndTools } from './primitives'

describe('interleaveTraceAndTools', () => {
  const think = (text: string, ts?: string): ChatTraceStep =>
    ts === undefined ? { kind: 'think', text } : { kind: 'think', text, ts }
  const traceTool = (name: string, toolCallId: string, ts?: string): ChatTraceStep =>
    ts === undefined ? { kind: 'tool', name, toolCallId } : { kind: 'tool', name, toolCallId, ts }
  const tool = (toolCallId: string) => ({
    entry: { id: `tool-${toolCallId}`, role: 'tool' } as unknown as KeeperConversationEntry,
    output: null,
  })
  const labels = (items: ReturnType<typeof interleaveTraceAndTools>) =>
    items.map((i) => {
      if (i.kind === 'tool') return `tool:${i.entry?.id ?? i.step?.toolCallId ?? i.step?.name}`
      if (i.kind === 'tool-entry') return `tool:${i.entry.id}`
      if (i.kind === 'chat') return `chat:${i.entry.id}`
      if (i.step.kind === 'media') return `media:${i.step.mediaRef}`
      return `${i.step.kind}:${i.step.text}`
    })

  it('preserves structural trace order for think -> tool -> think -> tool', () => {
    const out = interleaveTraceAndTools(
      [
        think('A', '2026-06-21T00:00:01.000Z'),
        traceTool('status', 'X', '2026-06-21T00:00:04.000Z'),
        think('B', '2026-06-21T00:00:03.000Z'),
        traceTool('board', 'Y', '2026-06-21T00:00:02.000Z'),
      ],
      [
        tool('X'),
        tool('Y'),
      ],
    )
    expect(labels(out)).toEqual(['think:A', 'tool:tool-X', 'think:B', 'tool:tool-Y'])
  })

  it('preserves media completion between thinking and tool steps', () => {
    const out = interleaveTraceAndTools(
      [
        think('A'),
        {
          kind: 'media',
          mediaKind: 'image',
          mediaType: 'image/png',
          mediaRef: '/api/v1/media/abc123',
          oasBlockIndex: 3,
        },
        traceTool('status', 'X'),
      ],
      [tool('X')],
    )
    expect(labels(out)).toEqual([
      'think:A',
      'media:/api/v1/media/abc123',
      'tool:tool-X',
    ])
  })

  it('keeps the legacy two-section order when trace carries no tool steps', () => {
    const out = interleaveTraceAndTools(
      [think('A'), think('B')],
      [tool('X')],
    )
    expect(labels(out)).toEqual(['think:A', 'think:B', 'tool:tool-X'])
  })

  it('uses trace order even when timestamps would imply a different order', () => {
    const out = interleaveTraceAndTools(
      [
        think('A', '2026-06-21T00:00:05.000Z'),
        traceTool('status', 'X', '2026-06-21T00:00:01.000Z'),
      ],
      [tool('X')],
    )
    expect(labels(out)).toEqual(['think:A', 'tool:tool-X'])
  })

  it('can render a trace-only tool step before the sibling entry exists', () => {
    const out = interleaveTraceAndTools(
      [think('A'), traceTool('status', 'X')],
      [],
    )
    expect(labels(out)).toEqual(['think:A', 'tool:X'])
  })

  it('prefers authoritative tool rows over unjoinable trace-only tool steps', () => {
    const out = interleaveTraceAndTools(
      [think('A'), { kind: 'tool', name: 'legacy-tool' }],
      [tool('X')],
    )
    expect(labels(out)).toEqual(['think:A', 'tool:tool-X'])
  })

  it('handles empty inputs without error', () => {
    expect(interleaveTraceAndTools([], [])).toEqual([])
    expect(
      labels(interleaveTraceAndTools([think('A', '2026-06-21T00:00:01.000Z')], [])),
    ).toEqual(['think:A'])
    expect(
      labels(interleaveTraceAndTools([], [tool('X')])),
    ).toEqual(['tool:tool-X'])
  })
})
