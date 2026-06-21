// @vitest-environment jsdom

// Unit tests for the render-time think<->tool interleaving in ToolTraceCard.
// Pure-function level so the ordering contract is asserted without the jsdom
// render harness: the merge must preserve occurrence order (think -> tool ->
// think -> tool) and fall back to the legacy two-section order when a step has
// no timestamp.
import { describe, expect, it } from 'vitest'
import type { ChatTraceStep, KeeperConversationEntry } from '../../types'
import { interleaveTraceAndTools } from './primitives'

describe('interleaveTraceAndTools', () => {
  const think = (text: string, ts?: string): ChatTraceStep =>
    ts === undefined ? { kind: 'think', text } : { kind: 'think', text, ts }
  // Tool entries only need `id` and `timestamp` for ordering; interleave reads
  // nothing else off them.
  const tool = (id: string, ts: string) => ({
    entry: { id, role: 'tool', timestamp: ts } as unknown as KeeperConversationEntry,
    output: null,
  })
  const labels = (items: ReturnType<typeof interleaveTraceAndTools>) =>
    items.map((i) => (i.kind === 'trace' ? `think:${i.step.text}` : `tool:${i.entry.id}`))

  it('interleaves think and tool by occurrence time (think -> tool -> think -> tool)', () => {
    const out = interleaveTraceAndTools(
      [
        think('A', '2026-06-21T00:00:01.000Z'),
        think('B', '2026-06-21T00:00:03.000Z'),
      ],
      [
        tool('X', '2026-06-21T00:00:02.000Z'),
        tool('Y', '2026-06-21T00:00:04.000Z'),
      ],
    )
    expect(labels(out)).toEqual(['think:A', 'tool:X', 'think:B', 'tool:Y'])
  })

  it('keeps the legacy two-section order when think steps carry no timestamp', () => {
    // Absent ts (backend-normalized steps) sorts as '' and precedes any tool,
    // so thinks stay grouped above tools — matching the pre-change render.
    const out = interleaveTraceAndTools(
      [think('A'), think('B')],
      [tool('X', '2026-06-21T00:00:02.000Z')],
    )
    expect(labels(out)).toEqual(['think:A', 'think:B', 'tool:X'])
  })

  it('places an earlier tool before a later think', () => {
    const out = interleaveTraceAndTools(
      [think('A', '2026-06-21T00:00:05.000Z')],
      [tool('X', '2026-06-21T00:00:01.000Z')],
    )
    expect(labels(out)).toEqual(['tool:X', 'think:A'])
  })

  it('preserves stable trace-then-tool order on equal timestamps', () => {
    // Stable sort keeps the input order (trace before tool) when timestamps tie.
    const out = interleaveTraceAndTools(
      [think('A', '2026-06-21T00:00:01.000Z')],
      [tool('X', '2026-06-21T00:00:01.000Z')],
    )
    expect(labels(out)).toEqual(['think:A', 'tool:X'])
  })

  it('handles empty inputs without error', () => {
    expect(interleaveTraceAndTools([], [])).toEqual([])
    expect(
      labels(interleaveTraceAndTools([think('A', '2026-06-21T00:00:01.000Z')], [])),
    ).toEqual(['think:A'])
    expect(
      labels(interleaveTraceAndTools([], [tool('X', '2026-06-21T00:00:01.000Z')])),
    ).toEqual(['tool:X'])
  })
})
