import { afterEach, describe, expect, it, vi } from 'vitest'

import { fetchKeeperConfig } from './dashboard-keeper-config'

describe('keeper config source projection', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('preserves a typed workspace prompt failure while rejecting malformed reasons and details', async () => {
    const unavailable = {
      state: 'unavailable', reason: 'workspace_unavailable',
      detail: 'remote SSH workspace cannot be prepared',
    }
    const read = async (preview: unknown) => {
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({
        name: 'rtprobe', activation_mode: 'manual', input_policy: 'small',
        max_context_override: null, skills: { names: null },
        config_revision: { manifest: { state: 'missing' }, runtime_assignment: { state: 'runtime_config_missing' } },
        prompt: { instructions: 'retain keeper instructions', system_prompt: preview },
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })))
      return fetchKeeperConfig('rtprobe')
    }
    const config = await read(unavailable)
    expect(config.prompt.system_prompt).toEqual(unavailable)
    expect(config.prompt.instructions).toBe('retain keeper instructions')
    for (const preview of [
      { state: 'unavailable', reason: 'workspace_unavailable' },
      { ...unavailable, detail: null },
      { ...unavailable, detail: 1 },
      { ...unavailable, reason: 'future_workspace_reason' },
    ]) {
      const malformed = await read(preview)
      expect(malformed.prompt.system_prompt).toMatchObject({ state: 'decode_failed' })
      expect(malformed.prompt.instructions).toBe('retain keeper instructions')
    }
  })

  it('keeps endpoint declarations, empty registries and unavailable observations distinct', async () => {
    const endpoint = {
      name: 'builder', host: 'builder.invalid', user: 'masc', port: 22,
      remote_root: '/srv/work',
      observation: { probe: { state: 'not_asked' }, last_dispatch: null, operator_action: null },
    }
    const read = async (catalog: unknown) => {
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({
        name: 'rtprobe', activation_mode: 'autonomous', input_policy: 'small',
        max_context_override: null, skills: { names: null },
        config_revision: { manifest: { state: 'missing' }, runtime_assignment: { state: 'runtime_config_missing' } },
        remote_ssh_endpoints: catalog,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })))
      return (await fetchKeeperConfig('rtprobe')).remote_ssh_endpoints
    }
    const catalog = await read({ state: 'available', endpoints: [endpoint] })
    expect(catalog).toEqual({ state: 'available', endpoints: [endpoint] })
    expect(await read({ state: 'available', endpoints: [] })).toEqual({ state: 'available', endpoints: [] })
    expect(await read({ state: 'unavailable', detail: 'runtime config cannot be read' }))
      .toEqual({ state: 'unavailable', detail: 'runtime config cannot be read' })
    for (const invalid of [
      undefined,
      { state: 'available', endpoints: [endpoint, endpoint] },
      { state: 'available', endpoints: [{ ...endpoint, port: '22' }] },
      { state: 'available', endpoints: [{ ...endpoint, observation: { ...endpoint.observation, probe: { state: 'future' } } }] },
    ]) {
      expect(await read(invalid)).toMatchObject({ state: 'unavailable' })
    }
    const answered = {
      ...endpoint,
      observation: {
        probe: { state: 'answered', protocol_major: 3, shim_release: 'fixture', observed_at_unix: 1234 },
        last_dispatch: { outcome: 'lane_failed', at_unix: 1235, failure: 'transport_failed', detail: 'connection refused' },
        operator_action: 'check endpoint',
      },
    }
    expect(await read({ state: 'available', endpoints: [answered] }))
      .toEqual({ state: 'available', endpoints: [answered] })
  })

  it('preserves typed TOML versus live-meta override evidence', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'rtprobe',
        activation_mode: 'autonomous',
        config_revision: {
          manifest: { state: 'sha256', value: 'a'.repeat(64) },
          runtime_assignment: { state: 'runtime_config_missing' },
        },
        input_policy: 'small',
        max_context_override: null,
        skills: { names: null },
        sources: {
          live_meta_path: '/workspace/.masc/keepers/rtprobe.json',
          default_manifest_path: '/workspace/.masc/config/keepers/rtprobe.toml',
          default_source_kind: 'toml',
          precedence: ['live_meta', 'keeper_config'],
          has_live_override: true,
          override_fields: ['activation_mode'],
          override_field_sources: [{
            field: 'activation_mode',
            source: 'live_meta',
            live_source: 'runtime_overlay',
            default_source: 'toml',
            default_source_kind: 'toml',
            default_manifest_path: '/workspace/.masc/config/keepers/rtprobe.toml',
            default_manifest_exists: true,
            default_missing: false,
            default_value: 'manual',
            live_value: 'autonomous',
          }],
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))

    const config = await fetchKeeperConfig('rtprobe')

    expect(config.activation_mode).toBe('autonomous')
    expect(config.sources.override_field_sources).toEqual([{
      field: 'activation_mode',
      source: 'live_meta',
      live_source: 'runtime_overlay',
      default_source: 'toml',
      default_source_kind: 'toml',
      default_manifest_path: '/workspace/.masc/config/keepers/rtprobe.toml',
      default_manifest_exists: true,
      default_missing: false,
      default_value: 'manual',
      live_value: 'autonomous',
    }])
  })

  it('rejects unavailable effective config instead of normalizing raw defaults', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        name: 'rtprobe',
        activation_mode: 'autonomous',
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
        activation_mode: 'autonomous',
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
        input_policy: 'small',
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
        activation_mode: 'autonomous',
        config_revision: { state: 'unavailable', detail: 'manifest store offline' },
        input_policy: 'small',
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
        activation_mode: 'autonomous',
        config_revision: {
          manifest: { state: 'sha256', value: 'a'.repeat(64) },
          runtime_assignment: { state: 'runtime_config_missing' },
        },
        config_write: {
          revision: { state: 'unavailable', detail: 'post-write read failed' },
          applied: true,
          warnings: [],
        },
        input_policy: 'small',
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
        activation_mode: 'autonomous',
        config_revision: revision,
        config_write: configWrite(revision),
        input_policy: 'small',
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
        activation_mode: 'autonomous',
      config_revision: {
        manifest: { state: 'sha256', value: 'a'.repeat(64) },
        runtime_assignment: { state: 'runtime_config_missing' },
      },
      input_policy: 'small',
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

  it('reads voice_always_allow, and yields null when omitted', async () => {
    const body = (extra: Record<string, unknown>) => JSON.stringify({
      name: 'sangsu',
        activation_mode: 'autonomous',
      config_revision: {
        manifest: { state: 'sha256', value: 'a'.repeat(64) },
        runtime_assignment: { state: 'runtime_config_missing' },
      },
      input_policy: 'small',
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

    respond(body({ voice_always_allow: true }))
    expect((await fetchKeeperConfig('sangsu')).voice_always_allow).toBe(true)

    respond(body({ voice_always_allow: false }))
    expect((await fetchKeeperConfig('sangsu')).voice_always_allow).toBe(false)

    respond(body({}))
    expect((await fetchKeeperConfig('sangsu')).voice_always_allow).toBeNull()
  })
})

describe('keeper input policy wire contract', () => {
  afterEach(() => vi.unstubAllGlobals())
  it.each(['small', 'wide'])('accepts %s', async input_policy => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({
      name: 'policy', activation_mode: 'manual', input_policy,
      max_context_override: null, skills: { names: null },
      config_revision: { manifest: { state: 'missing' }, runtime_assignment: { state: 'runtime_config_missing' } },
    }))))
    expect((await fetchKeeperConfig('policy')).input_policy).toBe(input_policy)
  })
  it.each([undefined, null, 'compact', 1])('rejects invalid policy %s', async input_policy => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify({
      name: 'policy', activation_mode: 'manual', input_policy,
      max_context_override: null, skills: { names: null },
      config_revision: { manifest: { state: 'missing' }, runtime_assignment: { state: 'runtime_config_missing' } },
    }))))
    await expect(fetchKeeperConfig('policy')).rejects.toThrow('input_policy')
  })
})
