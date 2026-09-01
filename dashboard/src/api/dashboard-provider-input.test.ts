import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())
const ensureDevToken = vi.hoisted(() => vi.fn(async () => undefined))

vi.mock('./core', () => ({ get: getMock }))
vi.mock('./dev-token', () => ({ ensureDevToken }))

import {
  decodeProviderInputSnapshot,
  fetchKeeperProviderInput,
} from './dashboard-provider-input'

function payload(overrides: Record<string, unknown> = {}) {
  const systemPrompt = 'exact system prompt'
  return {
    dashboard_surface: '/api/v1/keepers/:name/provider-input',
    schema: 'masc.resolved-provider-input.v1',
    keeper: 'albini',
    trace_id: 'trace-one',
    absolute_turn: 7,
    turn_ref: 'trace-one#7',
    runtime_profile: 'local',
    captured_at: 1_788_220_000.125,
    wire: {
      phase: 'Pre_dispatch_serialization',
      capture_id: 'capture-7',
      provider: 'openai-compatible',
      model: 'model-seven',
      http_codec: 'responses',
      stream: true,
      body_bytes: 8192,
      body_sha256: 'a'.repeat(64),
    },
    system_prompt: {
      bytes: new TextEncoder().encode(systemPrompt).length,
      sha256: 'b'.repeat(64),
      text: systemPrompt,
    },
    messages: [{
      index: 0,
      role: 'user',
      bytes: 42,
      sha256: 'c'.repeat(64),
      content: { role: 'user', content: 'hello' },
    }],
    tool_schemas: [{
      index: 0,
      name: 'masc_status',
      bytes: 64,
      sha256: 'd'.repeat(64),
      content: { name: 'masc_status', input_schema: { type: 'object' } },
    }],
    ...overrides,
  }
}

afterEach(() => {
  getMock.mockReset()
  ensureDevToken.mockClear()
})

describe('keeper provider input', () => {
  it('decodes the exact turn, wire digest, messages, and tool schemas', () => {
    expect(decodeProviderInputSnapshot(payload())).toMatchObject({
      keeper: 'albini',
      traceId: 'trace-one',
      absoluteTurn: 7,
      turnRef: 'trace-one#7',
      wire: {
        provider: 'openai-compatible',
        model: 'model-seven',
        bodyBytes: 8192,
        bodySha256: 'a'.repeat(64),
      },
      systemPrompt: { text: 'exact system prompt' },
      messages: [{ index: 0, role: 'user' }],
      toolSchemas: [{ index: 0, name: 'masc_status' }],
    })
  })

  it('requests the selected turn_ref without weakening the join key', async () => {
    getMock.mockResolvedValue(payload())

    await expect(fetchKeeperProviderInput('albini', 'trace-one#7')).resolves.toMatchObject({
      keeper: 'albini',
      turnRef: 'trace-one#7',
    })
    expect(getMock).toHaveBeenCalledWith(
      '/api/v1/keepers/albini/provider-input?turn_ref=trace-one%237',
      { signal: undefined },
    )
  })

  it('rejects a turn_ref that disagrees with trace_id and absolute_turn', () => {
    expect(decodeProviderInputSnapshot(payload({ turn_ref: 'trace-one#8' }))).toBeNull()
  })

  it('rejects unknown fields and a malformed wire digest', () => {
    expect(decodeProviderInputSnapshot(payload({ fabricated_context: 'no' }))).toBeNull()
    expect(decodeProviderInputSnapshot(payload({
      wire: {
        ...(payload().wire as Record<string, unknown>),
        body_sha256: 'short',
      },
    }))).toBeNull()
  })

  it('rejects a system prompt whose declared byte length is false', () => {
    expect(decodeProviderInputSnapshot(payload({
      system_prompt: {
        bytes: 1,
        sha256: 'b'.repeat(64),
        text: 'exact system prompt',
      },
    }))).toBeNull()
  })
})
