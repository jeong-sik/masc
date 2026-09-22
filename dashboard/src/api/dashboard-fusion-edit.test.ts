// Typed fusion config write: wire shape, error decoding, and the POST itself.
//
// The wire shape is the part worth pinning. The server decodes a preset with
// an exact key check (Fusion_config_json.preset_of_yojson), so a camelCase
// field leaking into the JSON, or a key the view type dropped, is a 400 on
// every save — and nothing on this side would notice until an operator did.

import { afterEach, describe, expect, it, vi } from 'vitest'

const devTokenMock = vi.hoisted(() => ({
  ensureDevToken: vi.fn(() => Promise.resolve()),
}))

vi.mock('./dev-token', () => ({
  ensureDevToken: devTokenMock.ensureDevToken,
}))

import {
  applyFusionConfigEdit,
  FusionConfigEditError,
  operationToWire,
  parseFusionConfigEditError,
  parseFusionConfigResponse,
  presetToWire,
} from './dashboard-fusion'
import type { FusionPresetConfigView } from './dashboard-fusion'

const PRESET: FusionPresetConfigView = {
  name: 'quorum',
  panels: [
    {
      models: ['lane.fast', 'p.two'],
      label: 'wide',
      systemPrompt: 'panelist',
      webTools: true,
      maxOutputTokens: 2048,
      timeoutS: 240,
    },
    {
      models: ['p.three'],
      label: '',
      systemPrompt: 'careful panelist',
      webTools: false,
      maxOutputTokens: null,
      timeoutS: null,
    },
  ],
  judge: 'p.meta',
  judgeSystemPrompt: 'meta',
  judgeMaxOutputTokens: 4096,
  judgeTimeoutS: 90.5,
  judges: [
    {
      model: 'p.j0',
      label: 'evidence',
      systemPrompt: 'lens',
      webTools: false,
      maxOutputTokens: null,
      timeoutS: 60,
    },
  ],
  minAnswered: 2,
}

const PRESET_KEYS = [
  'name',
  'panels',
  'judge',
  'judge_system_prompt',
  'judge_max_output_tokens',
  'judge_timeout_s',
  'judges',
  'min_answered',
]
const SEAT_KEYS = ['label', 'system_prompt', 'web_tools', 'max_output_tokens', 'timeout_s']

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

// The commit receipt as the server emits it; the decoder insists on a 64-hex
// source revision and on the skill application naming that same revision.
function committedBody(): Record<string, unknown> {
  const sourceRevision = 'a'.repeat(64)
  return {
    ok: true,
    path: '/tmp/.masc/config/runtime.toml',
    file_name: 'runtime.toml',
    source_text: '[fusion]\nenabled = true\n',
    source_revision: sourceRevision,
    provider_protocols: [],
    state: 'committed',
    commit: { source_revision: sourceRevision, order: '7', durability: 'durable', warnings: [] },
    application: {
      operation: 'fusion_edit',
      routing: { status: 'applied', requires_restart: false, applied_at: null },
      keeper_overlay: {
        status: 'not_configured',
        requires_restart: false,
        applied_at: null,
        configured_count: 0,
        pending_keys: [],
        applied_keys: [],
        preempted_keys: [],
      },
      skills: {
        state: 'published',
        input_source_revision: sourceRevision,
        snapshot_revision: 'skill-snapshot-revision',
        catalog_revision: 'skill-catalog-revision',
        config_state: 'configured',
      },
    },
  }
}

afterEach(() => {
  vi.unstubAllGlobals()
  devTokenMock.ensureDevToken.mockClear()
})

describe('presetToWire', () => {
  it('emits exactly the snake_case keys the server decodes, nothing camelCase', () => {
    const wire = presetToWire(PRESET)
    expect(Object.keys(wire).sort()).toEqual([...PRESET_KEYS].sort())
    for (const group of wire.panels) {
      expect(Object.keys(group).sort()).toEqual(['models', ...SEAT_KEYS].sort())
    }
    for (const judge of wire.judges) {
      expect(Object.keys(judge).sort()).toEqual(['model', ...SEAT_KEYS].sort())
    }
    // Serialising is what the POST does; a camelCase leak would show up here.
    expect(JSON.stringify(wire)).not.toMatch(/[a-z][A-Z]/)
  })

  it('keeps an unset optional as null on the wire rather than dropping the key', () => {
    const wire = presetToWire(PRESET)
    expect(wire.panels[1]).toMatchObject({ max_output_tokens: null, timeout_s: null })
    expect(wire.judges[0]).toMatchObject({ max_output_tokens: null, timeout_s: 60 })
    expect(wire.judge_timeout_s).toBe(90.5)
  })

  it('round-trips through the config projection parser', () => {
    const parsed = parseFusionConfigResponse({
      generated_at: '2026-09-22T00:00:00Z',
      source_revision: 'rev-1',
      config: {
        enabled: true,
        default_preset: 'quorum',
        staged_judge_group_size: 3,
        presets: [presetToWire(PRESET)],
      },
    })
    expect(parsed.presets).toEqual([PRESET])
    expect(parsed.sourceRevision).toBe('rev-1')
  })
})

describe('operationToWire', () => {
  it('spells each operation with the exact keys Fusion_config_edit.operation_of_yojson accepts', () => {
    expect(operationToWire({
      kind: 'set_settings',
      enabled: false,
      defaultPreset: 'trio',
      stagedJudgeGroupSize: 4,
    })).toEqual({ kind: 'set_settings', enabled: false, default_preset: 'trio', staged_judge_group_size: 4 })
    expect(Object.keys(operationToWire({ kind: 'upsert_preset', preset: PRESET }))).toEqual(['kind', 'preset'])
    expect(operationToWire({ kind: 'delete_preset', name: 'trio' })).toEqual({ kind: 'delete_preset', name: 'trio' })
    expect(operationToWire({ kind: 'rename_preset', from: 'trio', to: 'quartet' }))
      .toEqual({ kind: 'rename_preset', from: 'trio', to: 'quartet' })
  })
})

describe('parseFusionConfigResponse', () => {
  it('refuses a response without the revision a write must send back', () => {
    expect(() => parseFusionConfigResponse({ config: { enabled: true, presets: [] } }))
      .toThrow(/source_revision/)
    expect(() => parseFusionConfigResponse({ source_revision: 7, config: { presets: [] } }))
      .toThrow(/source_revision/)
    expect(() => parseFusionConfigResponse({ source_revision: '  ', config: { presets: [] } }))
      .toThrow(/source_revision/)
  })
})

describe('parseFusionConfigEditError', () => {
  const failure = (error: Record<string, unknown>) => ({ ok: false, error })

  it.each([
    'configuration_unavailable',
    'configuration_changed',
    'edit_refused',
    'configuration_rejected',
  ])('reads %s with just its message', code => {
    expect(parseFusionConfigEditError(failure({ code, message: 'why' }))).toEqual({ code, message: 'why' })
  })

  it('reads the detail fields of preset_invalid and route_unresolved', () => {
    expect(parseFusionConfigEditError(failure({
      code: 'preset_invalid',
      message: 'preset trio has no panel models',
      preset: 'trio',
      reason: 'no_panel_models',
    }))).toEqual({
      code: 'preset_invalid',
      message: 'preset trio has no panel models',
      preset: 'trio',
      reason: 'no_panel_models',
    })
    expect(parseFusionConfigEditError(failure({
      code: 'route_unresolved',
      message: 'preset trio names ghost, which is not a loaded lane or runtime',
      preset: 'trio',
      route: 'ghost',
      reason: 'route_missing',
    }))).toEqual({
      code: 'route_unresolved',
      message: 'preset trio names ghost, which is not a loaded lane or runtime',
      preset: 'trio',
      route: 'ghost',
      reason: 'route_missing',
    })
  })

  it('reads name_invalid, default_preset_deleted and fusion_invalid', () => {
    expect(parseFusionConfigEditError(failure({ code: 'name_invalid', message: 'm', preset: ' x' })))
      .toEqual({ code: 'name_invalid', message: 'm', preset: ' x' })
    expect(parseFusionConfigEditError(failure({ code: 'default_preset_deleted', message: 'm', preset: 'trio' })))
      .toEqual({ code: 'default_preset_deleted', message: 'm', preset: 'trio' })
    expect(parseFusionConfigEditError(failure({
      code: 'fusion_invalid',
      message: 'fusion config invalid: a; b',
      messages: ['a', 'b'],
    }))).toEqual({ code: 'fusion_invalid', message: 'fusion config invalid: a; b', messages: ['a', 'b'] })
  })

  it('returns null for an unknown code, a missing message, or a body that is not a refusal', () => {
    expect(parseFusionConfigEditError(failure({ code: 'something_new', message: 'm' }))).toBeNull()
    expect(parseFusionConfigEditError(failure({ code: 'configuration_changed' }))).toBeNull()
    expect(parseFusionConfigEditError(failure({ code: 'preset_invalid', message: 'm', preset: 'trio' }))).toBeNull()
    expect(parseFusionConfigEditError({ error: 'plain string' })).toBeNull()
    expect(parseFusionConfigEditError('nope')).toBeNull()
  })
})

describe('applyFusionConfigEdit', () => {
  it('POSTs the revision and the wire operation, and decodes the commit receipt', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(200, committedBody()))
    vi.stubGlobal('fetch', fetchMock)

    const receipt = await applyFusionConfigEdit('rev-1', { kind: 'upsert_preset', preset: PRESET })

    expect(devTokenMock.ensureDevToken).toHaveBeenCalledTimes(1)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/runtime/config/fusion')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      expected_revision: 'rev-1',
      operation: { kind: 'upsert_preset', preset: presetToWire(PRESET) },
    })
    expect(receipt.state).toBe('committed')
    expect(receipt.commit.order).toBe('7')
  })

  it('rejects a 409 with the typed configuration_changed failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(409, {
      ok: false,
      error: {
        code: 'configuration_changed',
        message: 'runtime.toml changed after it was read; reload the settings and apply again',
      },
    })))

    await applyFusionConfigEdit('rev-stale', { kind: 'delete_preset', name: 'trio' }).then(
      () => { throw new Error('expected a refusal') },
      (error: unknown) => {
        if (!(error instanceof FusionConfigEditError)) throw error
        expect(error.status).toBe(409)
        expect(error.failure.code).toBe('configuration_changed')
        expect(error.message).toBe('runtime.toml changed after it was read; reload the settings and apply again')
      },
    )
  })

  it('rejects a 400 route refusal with its preset and route', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(400, {
      ok: false,
      error: {
        code: 'route_unresolved',
        message: 'preset quorum names ghost, which is not a loaded lane or runtime',
        preset: 'quorum',
        route: 'ghost',
        reason: 'route_missing',
      },
    })))

    await applyFusionConfigEdit('rev-1', { kind: 'upsert_preset', preset: PRESET }).then(
      () => { throw new Error('expected a refusal') },
      (error: unknown) => {
        if (!(error instanceof FusionConfigEditError)) throw error
        expect(error.status).toBe(400)
        expect(error.failure).toMatchObject({ code: 'route_unresolved', preset: 'quorum', route: 'ghost' })
      },
    )
  })

  it('keeps the transport error, body included, when the refusal is not a typed failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(400, { error: 'unknown key "extra"' })))

    await applyFusionConfigEdit('rev-1', { kind: 'delete_preset', name: 'trio' }).then(
      () => { throw new Error('expected a refusal') },
      (error: unknown) => {
        expect(error).not.toBeInstanceOf(FusionConfigEditError)
        expect(error).toBeInstanceOf(Error)
        expect((error as Error).message).toContain('unknown key "extra"')
      },
    )
  })
})
