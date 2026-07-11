import { describe, expect, it } from 'vitest'

import {
  RuntimeDefaultsSchemaDriftError,
  parseRuntimeDefaultsResponse,
} from './runtime-defaults'

function validResponse(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    generated_at_iso: '2026-06-21T00:00:00Z',
    dashboard_surface: '/api/v1/dashboard/runtime-defaults',
    source: 'runtime_config',
    config_path: '/cfg/runtime.toml',
    default_runtime_id: 'openai.gpt-4o',
    default_model: 'gpt-4o',
    default_max_context: 128000,
    runtimes: [
      { id: 'openai.gpt-4o', provider: 'OpenAI', model: 'gpt-4o', max_context: 128000, is_default: true },
      { id: 'anthropic.sonnet', provider: 'Anthropic', model: 'claude-sonnet-4', max_context: 200000, is_default: false },
    ],
    model_routing: {
      librarian_runtime_id: 'openai.gpt-4o',
      structured_judge_runtime_id: 'openai.gpt-4o',
      hitl_summary_runtime_id: 'anthropic.sonnet',
      cross_verifier_runtime_id: null,
      media_failover: ['openai.gpt-4o'],
    },
    ...overrides,
  }
}

describe('parseRuntimeDefaultsResponse', () => {
  it('parses a fully resolved response', () => {
    const out = parseRuntimeDefaultsResponse(validResponse())
    expect(out.default_runtime_id).toBe('openai.gpt-4o')
    expect(out.default_model).toBe('gpt-4o')
    expect(out.runtimes).toHaveLength(2)
    expect(out.runtimes[0]!.is_default).toBe(true)
    expect(out.model_routing.structured_judge_runtime_id).toBe('openai.gpt-4o')
    expect(out.model_routing.hitl_summary_runtime_id).toBe('anthropic.sonnet')
    expect(out.model_routing.cross_verifier_runtime_id).toBeNull()
  })

  it('accepts an unresolved (null/empty) config without fabricating defaults', () => {
    const out = parseRuntimeDefaultsResponse(
      validResponse({
        config_path: null,
        default_runtime_id: null,
        default_model: null,
        default_max_context: null,
        runtimes: [],
        model_routing: {
          librarian_runtime_id: null,
          structured_judge_runtime_id: null,
          hitl_summary_runtime_id: null,
          cross_verifier_runtime_id: null,
          media_failover: [],
        },
      }),
    )
    expect(out.default_runtime_id).toBeNull()
    expect(out.default_model).toBeNull()
    expect(out.runtimes).toHaveLength(0)
  })

  it('throws schema drift when a runtime entry is missing a required field', () => {
    expect(() =>
      parseRuntimeDefaultsResponse(
        validResponse({
          runtimes: [{ id: 'x', provider: 'p' /* missing model/max_context/is_default */ }],
        }),
      ),
    ).toThrow(RuntimeDefaultsSchemaDriftError)
  })

  it('throws schema drift when model_routing is absent', () => {
    const bad = validResponse()
    delete bad.model_routing
    expect(() => parseRuntimeDefaultsResponse(bad)).toThrow(RuntimeDefaultsSchemaDriftError)
  })
})
