import { describe, expect, it } from 'vitest'

import {
  OperatorActionSchemaDriftError,
  parseOperatorActionResult,
} from './operator-action'

describe('parseOperatorActionResult', () => {
  it('accepts a minimal executed result', () => {
    const out = parseOperatorActionResult({ status: 'ok' })
    expect(out.status).toBe('ok')
    expect(out.confirm_required).toBeUndefined()
  })

  it('accepts a preview result with a confirm token', () => {
    const out = parseOperatorActionResult({
      status: 'preview',
      confirm_required: true,
      confirm_token: 'abc123',
      preview: { summary: 'delete 3 tasks', reason: 'user request' },
    })
    expect(out.confirm_required).toBe(true)
    expect(out.confirm_token).toBe('abc123')
    expect(out.preview).toEqual({ summary: 'delete 3 tasks', reason: 'user request' })
  })

  it('preserves opaque result and executed_action as unknown', () => {
    const out = parseOperatorActionResult({
      status: 'executed',
      tool_name: 'masc_broadcast',
      result: { nested: { arbitrary: [1, 2, 3] } },
      executed_action: 'keeper_message',
    })
    expect(out.tool_name).toBe('masc_broadcast')
    expect(out.result).toEqual({ nested: { arbitrary: [1, 2, 3] } })
    expect(out.executed_action).toBe('keeper_message')
  })

  it('accepts the deprecated delegated_tool_result field', () => {
    const out = parseOperatorActionResult({
      status: 'executed',
      delegated_tool_result: { legacy: true },
    })
    expect(out.delegated_tool_result).toEqual({ legacy: true })
  })

  it('throws when status is missing', () => {
    expect(() => parseOperatorActionResult({})).toThrow(OperatorActionSchemaDriftError)
  })

  it('throws when status is not a string', () => {
    expect(() => parseOperatorActionResult({ status: 42 })).toThrow(
      OperatorActionSchemaDriftError,
    )
  })

  it('throws when confirm_required is not a boolean', () => {
    expect(() => parseOperatorActionResult({ status: 'preview', confirm_required: 'yes' })).toThrow(
      OperatorActionSchemaDriftError,
    )
  })

  it('throws on non-object payload', () => {
    expect(() => parseOperatorActionResult(null)).toThrow(OperatorActionSchemaDriftError)
    expect(() => parseOperatorActionResult('oops')).toThrow(OperatorActionSchemaDriftError)
  })
})
