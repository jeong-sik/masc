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

  it('carries an unavailable config revision with the server detail', async () => {
    // dashboard_http_keeper_snapshot answers {state:"unavailable", detail}
    // in place of the revision pair when it could not read it. That shape
    // shares the two-key count with the success shape, so this pins the
    // discriminator being read first — the old decoder fell into
    // decodeManifestRevision(undefined) and killed the whole panel with
    // "manifest must be an object" instead of showing the detail.
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'rtprobe',
        config_revision: { state: 'unavailable', detail: 'manifest store offline' },
        max_context_override: null,
        skills: { names: null },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const config = await fetchKeeperConfig('rtprobe')
    expect(config.config_revision).toEqual({
      state: 'unavailable',
      detail: 'manifest store offline',
    })
  })

  it('rejects a write receipt whose revision is unavailable, naming the detail', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'rtprobe',
        config_revision: {
          manifest: { state: 'sha256', value: 'a'.repeat(64) },
          runtime_assignment: { state: 'runtime_config_missing' },
        },
        config_write: {
          revision: { state: 'unavailable', detail: 'post-write read failed' },
          applied: true,
          warnings: [],
        },
        max_context_override: null,
        skills: { names: null },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(fetchKeeperConfig('rtprobe')).rejects.toThrow('post-write read failed')
  })

  it.each([
    [
      'missing warnings',
      (revision: object) => ({ revision, applied: true }),
    ],
    [
      'extra field',
      (revision: object) => ({ revision, applied: true, warnings: [], extra: true }),
    ],
  ])('rejects config_write with %s', async (_label, configWrite) => {
    const revision = {
      manifest: { state: 'sha256', value: 'a'.repeat(64) },
      runtime_assignment: { state: 'runtime_config_missing' },
    }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'rtprobe',
        config_revision: revision,
        config_write: configWrite(revision),
        max_context_override: null,
        skills: { names: null },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    await expect(fetchKeeperConfig('rtprobe')).rejects.toThrow(
      'Invalid keeper config response: config_write is malformed',
    )
  })

  // remote_endpoint is not on keeper_meta -- it comes from the profile
  // defaults -- so the panel can only initialise the remote_ssh row and tell
  // an edit from a clear if this field survives the read.
  it('reads remote_endpoint, and yields null when the response omits it', async () => {
    const body = (extra: Record<string, unknown>) => JSON.stringify({
      name: 'rtprobe',
      config_revision: {
        manifest: { state: 'sha256', value: 'a'.repeat(64) },
        runtime_assignment: { state: 'runtime_config_missing' },
      },
      max_context_override: null,
      skills: { names: null },
      ...extra,
    })
    const respond = (payload: string) => vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(payload, {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    respond(body({ sandbox_profile: 'remote_ssh', remote_endpoint: 'builder' }))
    expect((await fetchKeeperConfig('rtprobe')).remote_endpoint).toBe('builder')

    respond(body({ sandbox_profile: 'docker' }))
    expect((await fetchKeeperConfig('rtprobe')).remote_endpoint).toBeNull()
  })
})
