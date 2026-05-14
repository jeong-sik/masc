import { describe, expect, it } from 'vitest'
import {
  CascadeSchemaDriftError,
  parseCascadeConfigResponse,
  parseCascadeHealthResponse,
  parseCascadeRawConfigResponse,
} from './cascade'

const validConfig = {
  updated_at: '2026-05-12T00:00:00Z',
  source_path: '/tmp/masc/cascade.toml',
  validation_status: 'validated',
  validation_errors: [],
  invalid_profiles: [{ name: 'broken', errors: ['missing model'] }],
  profiles: [
    {
      name: 'keeper_unified',
      source: 'named',
      keeper_assignable: true,
      candidates: [
        {
          model: 'glm-coding:auto',
          display_model: 'glm-coding',
          provider_name: 'glm',
          display_provider_name: 'GLM',
          runtime_kind: 'cli',
          expanded_models: ['glm-coding:auto'],
          config_weight: 1,
          effective_weight: 1,
          success_rate: 0.98,
          in_cooldown: false,
        },
      ],
    },
  ],
  keeper_profiles: [
    {
      keeper: 'sangsu',
      cascade_name: 'keeper_unified',
      canonical: 'keeper_unified',
    },
  ],
}

describe('cascade API schemas', () => {
  it('parses valid cascade config payloads', () => {
    const parsed = parseCascadeConfigResponse(validConfig)

    expect(parsed.validation_status).toBe('validated')
    expect(parsed.profiles[0]?.candidates[0]?.model).toBe('glm-coding:auto')
  })

  it('throws typed drift errors when a required config field is missing', () => {
    const drifted: Record<string, unknown> = { ...validConfig }
    delete drifted.validation_status

    expect(() => parseCascadeConfigResponse(drifted)).toThrow(CascadeSchemaDriftError)
  })

  it('parses raw cascade config payloads', () => {
    const parsed = parseCascadeRawConfigResponse({
      updated_at: '2026-05-12T00:00:00Z',
      source_path: '/tmp/masc/cascade.toml',
      source_editable: true,
      source_text: '[profiles.keeper_unified]\n',
    })

    expect(parsed.source_editable).toBe(true)
    expect(parsed.source_text).toContain('keeper_unified')
  })

  it('parses valid cascade health payloads', () => {
    const parsed = parseCascadeHealthResponse({
      updated_at: '2026-05-12T00:00:00Z',
      window_sec: 300,
      cooldown_threshold: 3,
      cooldown_sec: 120,
      hard_quota_cooldown_sec: 900,
      perf_window_minutes: null,
      providers: [
        {
          provider_key: 'glm',
          success_rate: 1,
          consecutive_failures: 0,
          in_cooldown: false,
          cooldown_expires_at: null,
          events_in_window: 4,
          rejected_in_window: 0,
          declared: true,
          status: 'active',
          request_count: null,
        },
      ],
    })

    expect(parsed.providers[0]?.status).toBe('active')
  })
})
