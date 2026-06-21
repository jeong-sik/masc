import { afterEach, describe, expect, it } from 'vitest'
import type { ToolCallEntry } from './api/dashboard'
import {
  lookupToolCallOutput,
  markToolCallOutputsHydrated,
  markToolCallOutputsHydrating,
  recordToolCallOutputs,
  resetToolCallOutputs,
  toolCallOutputsById,
  toolCallOutputsCoveredSinceMs,
  toolCallOutputsCoveredThroughMs,
} from './tool-call-output-store'

function toolCall(overrides: Partial<ToolCallEntry> = {}): ToolCallEntry {
  return {
    ts: 0,
    keeper: 'sangsu',
    tool: 'keeper_context_status',
    input: {},
    output: 'context ok',
    success: true,
    duration_ms: 12,
    ...overrides,
  }
}

describe('tool-call-output-store', () => {
  afterEach(() => {
    resetToolCallOutputs()
  })

  it('records entries keyed by tool_use_id', () => {
    recordToolCallOutputs([toolCall({ tool_use_id: 'toolu_abc', output: 'hello' })])
    expect(toolCallOutputsById.value.get('toolu_abc')?.output).toBe('hello')
  })

  it('looks up by the chat entry id, stripping the tool- prefix', () => {
    recordToolCallOutputs([toolCall({ tool_use_id: 'toolu_abc', output: 'hello' })])
    expect(lookupToolCallOutput('tool-toolu_abc')?.output).toBe('hello')
  })

  it('looks up by a bare tool_use_id (no prefix) as well', () => {
    recordToolCallOutputs([toolCall({ tool_use_id: 'toolu_abc', output: 'hello' })])
    expect(lookupToolCallOutput('toolu_abc')?.output).toBe('hello')
  })

  it('returns null for an unknown id', () => {
    recordToolCallOutputs([toolCall({ tool_use_id: 'toolu_abc' })])
    expect(lookupToolCallOutput('tool-missing')).toBeNull()
  })

  it('skips entries without a tool_use_id (no stable join key)', () => {
    recordToolCallOutputs([toolCall({ tool_use_id: undefined })])
    expect(toolCallOutputsById.value.size).toBe(0)
  })

  it('overwrites an earlier entry for the same id (idempotent re-hydration)', () => {
    recordToolCallOutputs([toolCall({ tool_use_id: 'toolu_abc', output: 'first' })])
    recordToolCallOutputs([toolCall({ tool_use_id: 'toolu_abc', output: 'second' })])
    expect(lookupToolCallOutput('tool-toolu_abc')?.output).toBe('second')
  })

  it('replaces the map reference on change so signal subscribers re-render', () => {
    const before = toolCallOutputsById.value
    recordToolCallOutputs([toolCall({ tool_use_id: 'toolu_abc' })])
    expect(toolCallOutputsById.value).not.toBe(before)
  })

  it('does not replace the map reference when nothing changed', () => {
    const before = toolCallOutputsById.value
    recordToolCallOutputs([toolCall({ tool_use_id: undefined })])
    expect(toolCallOutputsById.value).toBe(before)
  })

  it('preserves an externalised blob output descriptor', () => {
    recordToolCallOutputs([
      toolCall({
        tool_use_id: 'toolu_blob',
        output: { _blob: { sha256: 'abc', bytes: 9000, mime: 'application/json', preview: 'preview…' } },
      }),
    ])
    const stored = lookupToolCallOutput('tool-toolu_blob')?.output
    expect(typeof stored).toBe('object')
    expect(stored).toMatchObject({ _blob: { preview: 'preview…' } })
  })

  it('tracks bounded hydration coverage for tail-limited output fetches', () => {
    markToolCallOutputsHydrating('sangsu')
    markToolCallOutputsHydrated('sangsu', 2_000, 1_000)

    expect(toolCallOutputsCoveredSinceMs('sangsu')).toBe(1_000)
    expect(toolCallOutputsCoveredThroughMs('sangsu')).toBe(2_000)
  })

  it('merges unbounded hydration coverage without retaining an old lower bound', () => {
    markToolCallOutputsHydrated('sangsu', 2_000, 1_000)
    markToolCallOutputsHydrated('sangsu', 3_000, null)

    expect(toolCallOutputsCoveredSinceMs('sangsu')).toBeNull()
    expect(toolCallOutputsCoveredThroughMs('sangsu')).toBe(3_000)
  })
})
