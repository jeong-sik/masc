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
})
