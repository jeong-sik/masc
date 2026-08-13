import { describe, expect, it } from 'vitest'
import {
  parseRuntimeResolvedResponse,
  RuntimeResolvedSchemaDriftError,
} from './runtime-resolved'

const validRuntime = {
  id: 'rt-a',
  provider: 'Provider A',
  model: 'model-a',
  effective_max_context: 128_000,
  max_context_source: 'capability',
  max_output_tokens: null,
  is_local: false,
  is_default: true,
  keeper_dispatchable: true,
  keeper_dispatch_blocked_reason: null,
} as const

const validLane = {
  id: 'lane-x',
  runtime_ids: ['rt-a', 'rt-b'],
  preferred_candidate: 'rt-b',
  preferred_at_ts: 1_750_000_000,
} as const

function responseWith(runtime: Record<string, unknown>) {
  return {
    config_path: '/workspace/.masc/config/runtime.toml',
    default_runtime: runtime,
    runtimes: [runtime],
    lanes: [],
    assignments: [],
  }
}

describe('runtime-resolved schema', () => {
  it('accepts a complete resolved max-context contract', () => {
    expect(parseRuntimeResolvedResponse(responseWith(validRuntime)).default_runtime)
      .toMatchObject(validRuntime)
  })

  it('rejects an unresolved max-context instead of accepting null fallback data', () => {
    expect(() => parseRuntimeResolvedResponse(responseWith({
      ...validRuntime,
      effective_max_context: null,
      max_context_source: null,
    }))).toThrow(RuntimeResolvedSchemaDriftError)
  })

  it('accepts a lane carrying the sticky failover preference', () => {
    const parsed = parseRuntimeResolvedResponse({ ...responseWith(validRuntime), lanes: [validLane] })
    expect(parsed.lanes[0]).toMatchObject(validLane)
  })

  it('accepts a lane with no live sticky preference (nulls, not absent)', () => {
    const lane = { ...validLane, preferred_candidate: null, preferred_at_ts: null }
    const parsed = parseRuntimeResolvedResponse({ ...responseWith(validRuntime), lanes: [lane] })
    expect(parsed.lanes[0]?.preferred_candidate).toBeNull()
    expect(parsed.lanes[0]?.preferred_at_ts).toBeNull()
  })

  it('rejects a lane missing the sticky fields (schema drift guard)', () => {
    const { preferred_candidate: _candidate, preferred_at_ts: _ts, ...lane } = validLane
    expect(() => parseRuntimeResolvedResponse({ ...responseWith(validRuntime), lanes: [lane] }))
      .toThrow(RuntimeResolvedSchemaDriftError)
  })

  it('carries the blocker for a runtime no keeper can be assigned to', () => {
    const blocked = {
      ...validRuntime,
      keeper_dispatchable: false,
      keeper_dispatch_blocked_reason:
        'no positive max-request-body-bytes; declare [local.dormant].max-request-body-bytes',
    }
    const parsed = parseRuntimeResolvedResponse(responseWith(blocked))
    expect(parsed.runtimes[0]?.keeper_dispatchable).toBe(false)
    expect(parsed.runtimes[0]?.keeper_dispatch_blocked_reason)
      .toContain('max-request-body-bytes')
  })

  it('rejects a runtime missing the dispatch fields (schema drift guard)', () => {
    // Required, not optional: a runtime that omits these is a server old enough
    // not to know whether it is assignable, and reading that as "dispatchable"
    // would hide masc#28404 in the one document meant to expose it.
    const {
      keeper_dispatchable: _dispatchable,
      keeper_dispatch_blocked_reason: _reason,
      ...runtime
    } = validRuntime
    expect(() => parseRuntimeResolvedResponse(responseWith(runtime)))
      .toThrow(RuntimeResolvedSchemaDriftError)
  })
})
