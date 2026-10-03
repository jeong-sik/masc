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
    default_route: 'rt-a',
    default_runtime: runtime,
    runtimes: [runtime],
    lanes: [],
    assignments: [],
  }
}

describe('runtime-resolved schema', () => {
  it.each([
    'provider_override',
    'binding_override',
    'provider_override_clamped_by_capability',
    'binding_override_clamped_by_capability',
  ])('accepts scoped context provenance %s', (source) => {
    const parsed = parseRuntimeResolvedResponse(responseWith({
      ...validRuntime, max_context_source: source,
    }))
    if (parsed.default_runtime === null) throw new Error('expected a resolved default runtime')
    expect(parsed.default_runtime.max_context_source).toBe(source)
  })

  it('accepts a complete resolved max-context contract', () => {
    const parsed = parseRuntimeResolvedResponse(responseWith(validRuntime))
    expect(parsed.default_runtime).toMatchObject(validRuntime)
    expect(parsed.default_route).toBe('rt-a')
  })

  it('requires the configured route separately from the entry runtime', () => {
    const { default_route: _route, ...missingRoute } = responseWith(validRuntime)
    expect(() => parseRuntimeResolvedResponse(missingRoute)).toThrow(RuntimeResolvedSchemaDriftError)
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
      { scope: 'provider:claude_one', providers: [{ id: 'claude_one', display_name: 'Claude · one' }], state: 'reported', windows: [{
        limit_id: null, window: { kind: 'five_hour' }, utilization: { unit: 'fraction', value: 0.67 },
        resets_at: null, observed_at: 1_100, source: 'claude_code.rate_limit_event', role: 'gates_model_calls',
      }] },
      { scope: 'provider:codex_two', providers: [{ id: 'codex_two', display_name: 'Codex · two' }], state: 'not_reported_since_start', windows: [] },
    ]
    const parsed = parseRuntimeResolvedResponse({ ...base, provider_usage_windows_since: 1_000, provider_usage_windows })
    expect(parsed.provider_usage_windows?.[0]?.windows[0]?.utilization).toEqual({ unit: 'fraction', value: 0.67 })
    expect(parsed.provider_usage_windows?.[1]?.state).toBe('not_reported_since_start')
    expect(() => parseRuntimeResolvedResponse({ ...base, provider_usage_windows: [{
      ...provider_usage_windows[0], state: 'available',
    }] })).toThrow(RuntimeResolvedSchemaDriftError)
  })
})
