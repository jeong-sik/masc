import { describe, expect, it } from 'vitest'
import {
  contextSeverityTone,
  decodeKeeperLaneFailures,
  decodeKeeperPathRest,
  formatMilliCandleObserved,
  isKeeperHealthFailing,
} from './keeper-diagnostics'
import { patchOpForField } from './config-schema'

describe('keeper-diagnostics SSOT', () => {
  it('formats arbitrary-precision milli-Candle integers without IEEE-754 precision loss', () => {
    expect(formatMilliCandleObserved('9007199254740993123')).toMatchObject({
      kind: 'value',
      data: '9,007,199,254,740,993.123',
    })
    expect(formatMilliCandleObserved('42500.6')).toMatchObject({ kind: 'value', data: '42.501' })
    expect(formatMilliCandleObserved(0)).toMatchObject({ kind: 'value', data: '0.000' })
    expect(formatMilliCandleObserved(-45)).toMatchObject({ kind: 'value', data: '-0.045' })
    expect(formatMilliCandleObserved(null).kind).toBe('absent')
  })

  it('applies unified context severity thresholds and health failure status', () => {
    expect(contextSeverityTone(null)).toBe('absent')
    expect(contextSeverityTone(64)).toBe('ok')
    expect(contextSeverityTone(65)).toBe('warn')
    expect(contextSeverityTone(84)).toBe('warn')
    expect(contextSeverityTone(85)).toBe('bad')

    expect(isKeeperHealthFailing({ health: 'healthy', status: 'error' })).toBe(true)
    expect(isKeeperHealthFailing({ health: 'healthy', status: 'running' })).toBe(false)
    expect(isKeeperHealthFailing({ health: 'healthy', directory_issue: 'bad toml' })).toBe(true)
  })

  it('decodes path rest and lane failures once across Pulse and Keepers', () => {
    expect(decodeKeeperPathRest({ status: 'resting', runtime_id: 'glm', release_basis: 'rate_limit' })).toEqual({
      status: 'resting',
      runtime_id: 'glm',
      release_at: null,
      release_basis: 'rate_limit',
    })
    expect(decodeKeeperPathRest({ status: 'unknown' })).toBeNull()

    const failures = decodeKeeperLaneFailures({
      evidence: {
        failures: [{ runtime_id: 'codex', summary: '429', attempt: 1 }],
        terminal: { kind: 'candidate', runtime_id: 'glm', summary: '503', attempt: 2 },
      },
    })
    expect(failures.map((f) => `${f.runtime_id}:${f.attempt}:${f.summary}`)).toEqual([
      'codex:1:429',
      'glm:2:503',
    ])
  })

  it('builds typed ConfigPatchChange ops and rejects invalid numeric inputs', () => {
    const intField = { table: 'keeper', key: 'max_turns', full_key: 'keeper.max_turns', type: 'int' }
    expect(patchOpForField(intField, '42')).toEqual({
      op: 'set_int',
      table: 'keeper',
      key: 'max_turns',
      full_key: 'keeper.max_turns',
      value: 42,
    })
    expect(patchOpForField(intField, 'not-a-number')).toBeNull()

    const listField = { table: 'keeper', key: 'tools', full_key: 'keeper.tools', type: 'string_array' }
    expect(patchOpForField(listField, 'a, b, ', false, ',')).toEqual({
      op: 'set_string_array',
      table: 'keeper',
      key: 'tools',
      full_key: 'keeper.tools',
      value: ['a', 'b'],
    })
  })
})
