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
        config_revision: {
          manifest: { state: 'sha256', value: 'a'.repeat(64) },
          runtime_assignment: { state: 'runtime_config_missing' },
        },
        max_context_override: null,
        proactive: { enabled: true },
        skills: { names: null },
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

  it('rejects unavailable effective config instead of normalizing raw defaults', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'rtprobe',
        effective_config: null,
        config_error: {
          keeper: 'rtprobe',
          keeper_path: '/workspace/.masc/config/keepers/rtprobe.toml',
          failing_path: '/workspace/.masc/config/keepers/rtprobe.toml',
          kind: 'profile_error',
          detail: 'missing required sandbox_profile',
          terminal_reason: 'config_invalid',
          severity: 'error',
          blocking: true,
          operator_action_required: true,
          next_action: 'fix_keeper_toml_config',
        },
        sources: {
          live_meta_path: '/workspace/.masc/keepers/rtprobe.json',
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(fetchKeeperConfig('rtprobe')).rejects.toThrow(
      'Keeper config unavailable for rtprobe: profile_error at /workspace/.masc/config/keepers/rtprobe.toml: missing required sandbox_profile',
    )
  })

  it('preserves composite config write and durability warning receipts', async () => {
    const revision = {
      manifest: { state: 'sha256', value: 'a'.repeat(64) },
      runtime_assignment: { state: 'runtime_config_missing' },
    }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'rtprobe',
        config_revision: revision,
        config_write: {
          revision,
          applied: true,
          warnings: [{
            code: 'runtime_config_parent_sync_unconfirmed',
            detail: 'runtime parent fsync failed',
          }],
        },
        config_transaction_warnings: [{
          code: 'keeper_manifest_lock_release_unconfirmed',
          detail: 'unlock failed',
        }],
        max_context_override: null,
        skills: { names: null },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const config = await fetchKeeperConfig('rtprobe')
    expect(config.config_write).toEqual({
      revision,
      applied: true,
      warnings: [{
        code: 'runtime_config_parent_sync_unconfirmed',
        detail: 'runtime parent fsync failed',
      }],
    })
    expect(config.config_transaction_warnings).toEqual([{
      code: 'keeper_manifest_lock_release_unconfirmed',
      detail: 'unlock failed',
    }])
  })
})
