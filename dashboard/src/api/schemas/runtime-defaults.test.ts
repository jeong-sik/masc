import { describe, expect, it } from 'vitest'

import {
  RuntimeDefaultsSchemaDriftError,
  parseRuntimeDefaultsResponse,
} from './runtime-defaults'

function validModelRouting(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    memory_os_consolidation_runtime_id: 'anthropic.sonnet',
    memory_os_consolidation_effective_runtime_id: 'anthropic.sonnet',
    memory_os_consolidation_status: 'resolved',
    memory_os_consolidation_error: null,
    structured_judge_runtime_id: 'openai.gpt-4o',
    cross_verifier_runtime_id: null,
    media_failover: ['openai.gpt-4o'],
    ...overrides,
  }
}

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
    model_routing: validModelRouting(),
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
    expect(out.model_routing.memory_os_consolidation_status).toBe('resolved')
    expect(out.model_routing.memory_os_consolidation_runtime_id).toBe('anthropic.sonnet')
    expect(out.model_routing.memory_os_consolidation_effective_runtime_id).toBe('anthropic.sonnet')
    expect(out.model_routing.structured_judge_runtime_id).toBe('openai.gpt-4o')
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
          memory_os_consolidation_runtime_id: null,
          memory_os_consolidation_effective_runtime_id: null,
          memory_os_consolidation_status: 'error',
          memory_os_consolidation_error: 'runtime state is not initialized',
          structured_judge_runtime_id: null,
          cross_verifier_runtime_id: null,
          media_failover: [],
        },
      }),
    )
    expect(out.default_runtime_id).toBeNull()
    expect(out.default_model).toBeNull()
    expect(out.runtimes).toHaveLength(0)
    expect(out.model_routing.memory_os_consolidation_status).toBe('error')
    expect(out.model_routing.memory_os_consolidation_runtime_id).toBeNull()
    expect(out.model_routing.memory_os_consolidation_effective_runtime_id).toBeNull()
  })

  it('preserves inherited consolidation routing without rewriting the configured selector', () => {
    const out = parseRuntimeDefaultsResponse(
      validResponse({
        model_routing: {
          memory_os_consolidation_runtime_id: null,
          memory_os_consolidation_effective_runtime_id: 'openai.gpt-4o',
          memory_os_consolidation_status: 'inherited',
          memory_os_consolidation_error: null,
          structured_judge_runtime_id: 'openai.gpt-4o',
          cross_verifier_runtime_id: null,
          media_failover: ['openai.gpt-4o'],
        },
      }),
    )
    expect(out.model_routing.memory_os_consolidation_status).toBe('inherited')
    expect(out.model_routing.memory_os_consolidation_runtime_id).toBeNull()
    expect(out.model_routing.memory_os_consolidation_effective_runtime_id).toBe('openai.gpt-4o')
  })

  it('rejects resolved status without an effective runtime', () => {
    expect(() =>
      parseRuntimeDefaultsResponse(
        validResponse({
          model_routing: validModelRouting({
            memory_os_consolidation_effective_runtime_id: null,
          }),
        }),
      ),
    ).toThrow(RuntimeDefaultsSchemaDriftError)
  })

  it('rejects error status without an error string', () => {
    expect(() =>
      parseRuntimeDefaultsResponse(
        validResponse({
          model_routing: validModelRouting({
            memory_os_consolidation_status: 'error',
            memory_os_consolidation_effective_runtime_id: null,
            memory_os_consolidation_error: null,
          }),
        }),
      ),
    ).toThrow(RuntimeDefaultsSchemaDriftError)
  })

  it('rejects inherited status with a non-null error', () => {
    expect(() =>
      parseRuntimeDefaultsResponse(
        validResponse({
          model_routing: validModelRouting({
            memory_os_consolidation_runtime_id: null,
            memory_os_consolidation_effective_runtime_id: 'openai.gpt-4o',
            memory_os_consolidation_status: 'inherited',
            memory_os_consolidation_error: 'contradictory inherited error',
          }),
        }),
      ),
    ).toThrow(RuntimeDefaultsSchemaDriftError)
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
