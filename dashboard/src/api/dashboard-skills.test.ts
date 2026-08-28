import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  classifySkillEditorError,
  decodeAsyncRequestObservation,
  decodeSkillCreateReceipt,
  decodeSkillEditorLoaded,
  decodeSkillEditorPreview,
  decodeSkillEditorSaveReceipt,
  decodeSkillEvidenceResponse,
  previewSkillSource,
  readSkillSource,
  saveSkillSource,
  SkillsContractError,
} from './dashboard-skills'
import { ApiRequestError } from './core'

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

// Server_skill_editor.create_outcome_to_yojson sends exactly these two
// statuses; the old client defaulted anything else to 'created', a status
// the server never sends, and dropped the not-published reason.
describe('skill create receipt contract', () => {
  it('accepts the published receipt', () => {
    expect(decodeSkillCreateReceipt({ status: 'created_and_published', preview: {} }))
      .toEqual({ status: 'created_and_published' })
  })

  it('carries the not-published reason', () => {
    expect(decodeSkillCreateReceipt({
      status: 'created_but_unpublished',
      reason: 'catalog refresh failed',
      preview: {},
    })).toEqual({
      status: 'created_but_unpublished',
      reason: 'catalog refresh failed',
    })
  })

  it.each([
    ['a fabricated status', { status: 'created' }],
    ['a missing reason', { status: 'created_but_unpublished' }],
    ['no status at all', {}],
    ['a non-object payload', null],
  ])('rejects %s instead of inventing a label', (_label, raw) => {
    expect(() => decodeSkillCreateReceipt(raw)).toThrow('unrecognized status')
  })
})

const reference = {
  identity: {
    source_id: 'workspace',
    package_id: 'release-checklist',
    name: 'release-checklist',
  },
  content_revision: 'a'.repeat(64),
}

const editorProfile = {
  reference,
  kind: 'instruction',
  activation_tool: 'keeper_skill',
  execution: 'model_orchestrated',
  capabilities: {
    as_skill: true,
    as_tool: false,
    batch: false,
    parallel: false,
    async: false,
    tool_scope: 'registered_tools_only',
  },
  context: {
    body_bytes: 120,
    eager_body_bytes: 0,
    discovery_bytes: 48,
    tool_schema_bytes: null,
  },
  plan: {
    node_count: 0,
    batch_count: 0,
    parallel_batch_count: 0,
    max_parallelism: 0,
    statically_read_only: null,
  },
  declaration: null,
  flow: null,
}

const editorPreview = {
  profile: {
    ...editorProfile,
    reference: {
      ...reference,
      content_revision: 'b'.repeat(64),
    },
  },
  diagnostics: [],
}

describe('existing Skill editor contract', () => {
  it('strictly decodes loaded, preview, and save receipts', () => {
    expect(decodeSkillEditorLoaded({
      status: 'ready',
      reference,
      snapshot_revision: 'snapshot-1',
      source_text: '---\nname: release-checklist\n---\n',
      access: 'read_write',
    })).toMatchObject({ access: 'read_write', reference })

    expect(decodeSkillEditorPreview({
      ok: true,
      status: 'valid',
      preview: editorPreview,
    })).toEqual(editorPreview)

    expect(() => decodeSkillEditorPreview({
      ok: true,
      status: 'valid',
      preview: { ...editorPreview, reference },
    })).toThrow(SkillsContractError)

    expect(decodeSkillEditorSaveReceipt({
      status: 'saved_and_published',
      preview: editorPreview,
      snapshot_revision: 'snapshot-2',
    })).toMatchObject({ status: 'saved_and_published', preview: editorPreview })

    expect(() => decodeSkillEditorSaveReceipt({
      status: 'saved',
      preview: editorPreview,
    })).toThrow(SkillsContractError)
  })

  it('classifies only the typed 409 revision conflict', () => {
    expect(classifySkillEditorError(new ApiRequestError({
      method: 'POST',
      path: '/api/v1/skills/editor/save',
      status: 409,
      responseData: { code: 'revision_conflict' },
    }))).toBe('revision_conflict')
    expect(classifySkillEditorError(new ApiRequestError({
      method: 'POST',
      path: '/api/v1/skills/editor/save',
      status: 409,
      responseData: { code: 'package_already_exists' },
    }))).toBe('other')
    expect(classifySkillEditorError(new Error('revision_conflict'))).toBe('other')
  })

  it('posts the exact reference and source text to each editor route', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        status: 'ready',
        reference,
        snapshot_revision: 'snapshot-1',
        source_text: 'old source',
        access: 'read_write',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        ok: true,
        status: 'valid',
        preview: editorPreview,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        status: 'saved_and_published',
        preview: editorPreview,
        snapshot_revision: 'snapshot-2',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    await readSkillSource(reference)
    await previewSkillSource(reference, 'new source')
    await saveSkillSource(reference, 'new source')

    expect(fetchMock.mock.calls.map(([path]) => path)).toEqual([
      '/api/v1/skills/editor/read',
      '/api/v1/skills/editor/preview',
      '/api/v1/skills/editor/save',
    ])
    expect(JSON.parse(fetchMock.mock.calls[0]![1]!.body as string)).toEqual({ reference })
    expect(JSON.parse(fetchMock.mock.calls[1]![1]!.body as string)).toEqual({
      reference,
      source_text: 'new source',
    })
    expect(JSON.parse(fetchMock.mock.calls[2]![1]!.body as string)).toEqual({
      reference,
      source_text: 'new source',
    })
  })

  it('waits for a delayed durable save response beyond the ordinary POST timeout', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn((_path: string, init?: RequestInit) => new Promise<Response>((resolve, reject) => {
      init?.signal?.addEventListener('abort', () => {
        reject(new DOMException('Aborted', 'AbortError'))
      })
      window.setTimeout(() => {
        resolve(new Response(JSON.stringify({
          status: 'saved_and_published',
          preview: editorPreview,
          snapshot_revision: 'snapshot-2',
        }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      }, 31_000)
    }))
    vi.stubGlobal('fetch', fetchMock)

    const save = saveSkillSource(reference, 'new source')
    await vi.advanceTimersByTimeAsync(31_000)

    await expect(save).resolves.toMatchObject({ status: 'saved_and_published' })
    expect(fetchMock.mock.calls[0]![1]?.signal).toBeUndefined()
  })
})

const coverage = {
  composition_scan_limit: 5000,
  composition_rows_scanned: 17,
  instruction_ledgers_loaded: 2,
  unavailable: [],
}

describe('skill evidence contract', () => {
  it('keeps instruction activation and composition result in one exact envelope', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v1',
      status: 'observed',
      reference,
      activation: {
        keeper: 'rondo',
        activation: {
          activated_at: '2026-08-28T03:00:00Z',
          skill_tool_use_id: 'skill-call-1',
          delivery: null,
          actions: [],
        },
      },
      composition: {
        run: { success: true, composition_run_id: 'run-1' },
        nodes: [{ tool_name: 'keeper_time_now' }],
      },
      coverage,
    })

    expect(decoded.activation?.keeper).toBe('rondo')
    expect(decoded.composition?.nodes).toHaveLength(1)
  })

  it('rejects observed status without any observed evidence', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v1',
      status: 'observed',
      reference,
      activation: null,
      composition: null,
      coverage,
    })).toThrow(SkillsContractError)
  })

  it('keeps partial ledger coverage visible when nothing was observed', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v1',
      status: 'never_observed',
      reference,
      activation: null,
      composition: null,
      coverage: {
        ...coverage,
        unavailable: ['sangsu: ledger_unreadable'],
      },
    })

    expect(decoded.coverage.unavailable).toEqual(['sangsu: ledger_unreadable'])
  })
})

const recovery = {
  lost: 1,
  finalized: 0,
  cleaned: 0,
  staging_files_inspected: 0,
  staging_files_deleted: 0,
  staging_files_preserved: 0,
  unreadable: 0,
  failed: 0,
  store_errors: [],
  record_errors: [],
}

describe('async request observation contract', () => {
  it('keeps durable row and current-process ownership distinct', () => {
    const decoded = decodeAsyncRequestObservation({
      schema: 'masc.async-request-observation/v1',
      status: 'ready',
      summary: {
        active: 2,
        runtime_owned: 1,
        ownership_unknown: 1,
        record_errors: 0,
      },
      requests: [
        {
          request_id: 'request-owned',
          keeper_name: 'rondo',
          submitted_by: 'operator',
          status: 'running',
          submitted_at: 1,
          elapsed_sec: 2,
          worker_ownership: 'runtime_owned',
        },
        {
          request_id: 'request-disk-only',
          keeper_name: 'sangsu',
          submitted_by: 'operator',
          status: 'queued',
          submitted_at: 2,
          elapsed_sec: 1,
          worker_ownership: 'disk_only_ownership_unknown',
        },
      ],
      record_errors: [],
      startup_recovery: recovery,
    })

    expect(decoded.status).toBe('ready')
    if (decoded.status === 'ready') {
      expect(decoded.requests.map(row => row.worker_ownership)).toEqual([
        'runtime_owned',
        'disk_only_ownership_unknown',
      ])
    }
  })

  it('rejects summary counts that invent or omit durable rows', () => {
    expect(() => decodeAsyncRequestObservation({
      schema: 'masc.async-request-observation/v1',
      status: 'ready',
      summary: {
        active: 2,
        runtime_owned: 1,
        ownership_unknown: 1,
        record_errors: 0,
      },
      requests: [],
      record_errors: [],
      startup_recovery: null,
    })).toThrow(SkillsContractError)
  })
})
