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
} as const

const validLane = {
  id: 'lane-x',
  declared: true,
  runtime_ids: ['rt-a', 'rt-b'],
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

  it('accepts a lane as its declared candidate order', () => {
    const parsed = parseRuntimeResolvedResponse({ ...responseWith(validRuntime), lanes: [validLane] })
    expect(parsed.lanes[0]).toMatchObject(validLane)
  })

  it('rejects a lane without its candidates (schema drift guard)', () => {
    const { runtime_ids: _ids, ...lane } = validLane
    expect(() => parseRuntimeResolvedResponse({ ...responseWith(validRuntime), lanes: [lane] }))
      .toThrow(RuntimeResolvedSchemaDriftError)
  })

  it('rejects a lane without its declaration origin', () => {
    const { declared: _declared, ...lane } = validLane
    expect(() => parseRuntimeResolvedResponse({ ...responseWith(validRuntime), lanes: [lane] }))
      .toThrow(RuntimeResolvedSchemaDriftError)
  })

  it('decodes provider usage by account scope without turning no report into zero', () => {
    const base = responseWith(validRuntime)
    const provider_usage_windows = [
      { scope: 'provider:claude_one', providers: ['claude_one'], state: 'reported', windows: [{
        limit_id: null, window: { kind: 'five_hour' }, utilization: { unit: 'fraction', value: 0.67 },
        resets_at: null, observed_at: 1_100, source: 'claude_code.rate_limit_event',
      }] },
      { scope: 'provider:codex_two', providers: ['codex_two'], state: 'not_reported_since_start', windows: [] },
    ]
    const parsed = parseRuntimeResolvedResponse({ ...base, provider_usage_windows_since: 1_000, provider_usage_windows })
    expect(parsed.provider_usage_windows?.[0]?.windows[0]?.utilization).toEqual({ unit: 'fraction', value: 0.67 })
    expect(parsed.provider_usage_windows?.[1]?.state).toBe('not_reported_since_start')
    expect(() => parseRuntimeResolvedResponse({ ...base, provider_usage_windows: [{
      ...provider_usage_windows[0], state: 'available',
    }] })).toThrow(RuntimeResolvedSchemaDriftError)
  })
})
