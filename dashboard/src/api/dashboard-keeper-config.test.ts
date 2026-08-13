import { afterEach, describe, expect, it, vi } from 'vitest'

import { fetchKeeperConfig } from './dashboard-keeper-config'

describe('keeper config source projection', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('preserves typed TOML versus live-meta override evidence', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'rtprobe',
        max_context_override: null,
        proactive: { enabled: true },
        sources: {
          live_meta_path: '/workspace/.masc/keepers/rtprobe.json',
          default_manifest_path: '/workspace/.masc/config/keepers/rtprobe.toml',
          default_source_kind: 'toml',
          precedence: ['live_meta', 'keeper_config'],
          has_live_override: true,
          override_fields: ['proactive.enabled'],
          override_field_sources: [{
            field: 'proactive.enabled',
            source: 'live_meta',
            live_source: 'runtime_overlay',
            default_source: 'toml',
            default_source_kind: 'toml',
            default_manifest_path: '/workspace/.masc/config/keepers/rtprobe.toml',
            default_manifest_exists: true,
            default_missing: false,
            default_value: false,
            live_value: true,
          }],
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const config = await fetchKeeperConfig('rtprobe')

    expect(config.proactive.enabled).toBe(true)
    expect(config.sources.override_field_sources).toEqual([{
      field: 'proactive.enabled',
      source: 'live_meta',
      live_source: 'runtime_overlay',
      default_source: 'toml',
      default_source_kind: 'toml',
      default_manifest_path: '/workspace/.masc/config/keepers/rtprobe.toml',
      default_manifest_exists: true,
      default_missing: false,
      default_value: false,
      live_value: true,
    }])
  })
})
