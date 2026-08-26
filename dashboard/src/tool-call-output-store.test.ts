import { afterEach, describe, expect, it } from 'vitest'
import type { ToolCallEntry } from './api/dashboard'
import {
  lookupToolCallOutput,
  markToolCallOutputsHydrationFailed,
  markToolCallOutputsHydrated,
  markToolCallOutputsHydrating,
  recordToolCallOutputs,
  resetToolCallOutputs,
  toolCallOutputHydrationContract,
  toolCallOutputHydrationFailureReason,
  toolCallOutputHydrationStatus,
  toolCallOutputsByExecutionId,
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

  it('records entries keyed by canonical execution_id', () => {
    recordToolCallOutputs([toolCall({ execution_id: 'exec-abc', output: 'hello' })])
    expect(toolCallOutputsByExecutionId.value.get('exec-abc')?.output).toBe('hello')
  })

  it('looks up by canonical execution_id', () => {
    recordToolCallOutputs([toolCall({ execution_id: 'exec-abc', output: 'hello' })])
    expect(lookupToolCallOutput('exec-abc')?.output).toBe('hello')
  })

  it('preserves canonical identity bytes after rejecting blank values', () => {
    recordToolCallOutputs([
      toolCall({ execution_id: '  exec-abc \t', output: 'hello' }),
    ])
    expect(lookupToolCallOutput('  exec-abc \t')?.output).toBe('hello')
    expect(lookupToolCallOutput('exec-abc')).toBeNull()
    expect(toolCallOutputsByExecutionId.value.has('  exec-abc \t')).toBe(true)
  })

  it('returns null for an unknown id', () => {
    recordToolCallOutputs([toolCall({ execution_id: 'exec-abc' })])
    expect(lookupToolCallOutput('exec-missing')).toBeNull()
  })

  it('skips entries without an execution_id', () => {
    recordToolCallOutputs([toolCall({ execution_id: undefined, tool_use_id: 'provider-only' })])
    expect(toolCallOutputsByExecutionId.value.size).toBe(0)
  })

  it('skips entries with a whitespace-only execution_id', () => {
    recordToolCallOutputs([toolCall({ execution_id: ' \t ' })])
    expect(toolCallOutputsByExecutionId.value.size).toBe(0)
  })

  it('overwrites an earlier entry for the same execution (idempotent re-hydration)', () => {
    recordToolCallOutputs([toolCall({ execution_id: 'exec-abc', output: 'first' })])
    recordToolCallOutputs([toolCall({ execution_id: 'exec-abc', output: 'second' })])
    expect(lookupToolCallOutput('exec-abc')?.output).toBe('second')
  })

  it('does not collide when a provider id is reused', () => {
    recordToolCallOutputs([
      toolCall({ execution_id: 'exec-first', tool_use_id: 'reused', output: 'first' }),
      toolCall({ execution_id: 'exec-second', tool_use_id: 'reused', output: 'second' }),
    ])
    expect(lookupToolCallOutput('exec-first')?.output).toBe('first')
    expect(lookupToolCallOutput('exec-second')?.output).toBe('second')
  })

  it('replaces the map reference on change so signal subscribers re-render', () => {
    const before = toolCallOutputsByExecutionId.value
    recordToolCallOutputs([toolCall({ execution_id: 'exec-abc' })])
    expect(toolCallOutputsByExecutionId.value).not.toBe(before)
  })

  it('does not replace the map reference when nothing changed', () => {
    const before = toolCallOutputsByExecutionId.value
    recordToolCallOutputs([toolCall({ execution_id: undefined })])
    expect(toolCallOutputsByExecutionId.value).toBe(before)
  })

  it('preserves an externalised blob output descriptor', () => {
    recordToolCallOutputs([
      toolCall({
        execution_id: 'exec-blob',
        output: { _blob: { sha256: 'abc', bytes: 9000, mime: 'application/json', preview: 'preview…' } },
      }),
    ])
    const stored = lookupToolCallOutput('exec-blob')?.output
    expect(typeof stored).toBe('object')
    expect(stored).toMatchObject({ _blob: { preview: 'preview…' } })
  })

  it('tracks bounded hydration coverage for tail-limited output fetches', () => {
    markToolCallOutputsHydrating('sangsu')
    expect(toolCallOutputHydrationStatus('sangsu')).toBe('hydrating')
    markToolCallOutputsHydrated('sangsu', 2_000, 1_000)

    expect(toolCallOutputsCoveredSinceMs('sangsu')).toBe(1_000)
    expect(toolCallOutputsCoveredThroughMs('sangsu')).toBe(2_000)
    expect(toolCallOutputHydrationStatus('sangsu')).toBe('hydrated')
    expect(toolCallOutputHydrationContract('sangsu')).toMatchObject({
      source: 'tool_calls_endpoint',
      status: 'hydrated',
      failureReason: null,
      coveredSinceMs: 1_000,
      coveredThroughMs: 2_000,
    })
  })

  it('merges unbounded hydration coverage without retaining an old lower bound', () => {
    markToolCallOutputsHydrated('sangsu', 2_000, 1_000)
    markToolCallOutputsHydrated('sangsu', 3_000, null)

    expect(toolCallOutputsCoveredSinceMs('sangsu')).toBeNull()
    expect(toolCallOutputsCoveredThroughMs('sangsu')).toBe(3_000)
  })

  it('records hydration failure reason instead of collapsing it to pending', () => {
    markToolCallOutputsHydrating('sangsu')
    markToolCallOutputsHydrationFailed('sangsu', 'HTTP 502')

    expect(toolCallOutputHydrationStatus('sangsu')).toBe('failed')
    expect(toolCallOutputHydrationFailureReason('sangsu')).toBe('HTTP 502')
    expect(toolCallOutputHydrationContract('sangsu')).toMatchObject({
      source: 'tool_calls_endpoint',
      status: 'failed',
      failureReason: 'HTTP 502',
    })
  })
})
