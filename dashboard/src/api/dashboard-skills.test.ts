import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  classifySkillEditorError,
  decodeAsyncRequestObservation,
  decodeSkillCreateReceipt,
  decodeSkillEditorLoaded,
  decodeSkillEditorPreview,
  decodeSkillEditorSaveReceipt,
  createSkill,
  fetchSkillAuthoringTools,
  previewNewSkillSource,
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

// Server_skill_editor.create_outcome_to_yojson sends exactly these three
// statuses; the old client defaulted anything else to 'created', a status
// the server never sends, and dropped the not-published reason.
describe('skill create receipt contract', () => {
  it('reads canonical authoring contracts and previews a new package without a published reference', async () => {
    const tool = { name: 'keeper_lane_status', description: 'Observe the lane.',
      input_schema: { type: 'object' }, output: { kind: 'opaque' }, execution: 'concurrent' }
    const fetch = vi.fn().mockResolvedValueOnce(Response.json({ schema: 'masc.skill-authoring-tools/v1', tools: [tool] }))
      .mockResolvedValueOnce(Response.json({ ok: true, status: 'valid', preview: editorPreview }))
    vi.stubGlobal('fetch', fetch)
    expect(await fetchSkillAuthoringTools()).toEqual([tool])
    const input = { kind: 'instruction' as const, source_id: 'workspace', package_id: 'release-checklist', source_text: 'new document' }
    await expect(previewNewSkillSource(input)).resolves.toEqual(editorPreview)
    expect(fetch.mock.calls[1]).toEqual(['/api/v1/skills/editor/preview-new', expect.objectContaining({ method: 'POST', body: JSON.stringify(input) })])
  })

  it('rejects drifted authoring contracts', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({ schema: 'masc.skill-authoring-tools/v1', tools: [
      { name: 'tool', description: '', input_schema: {}, output: { kind: 'guess' }, execution: 'parallel' },
    ] })))
    await expect(fetchSkillAuthoringTools()).rejects.toThrow()
  })

  it('retains a durable create response beyond the ordinary POST timeout', async () => {
    vi.useFakeTimers()
    const fetch = vi.fn((_path: string, init?: RequestInit) => new Promise<Response>((resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
      window.setTimeout(() => resolve(Response.json({ status: 'created_and_published' })), 31_000)
    }))
    vi.stubGlobal('fetch', fetch)
    const created = createSkill({ kind: 'instruction', source_id: 'workspace', package_id: 'release-checklist', source_text: 'document' })
    await vi.advanceTimersByTimeAsync(31_000)
    await expect(created).resolves.toEqual({ status: 'created_and_published' })
    expect(fetch.mock.calls[0]![1]?.signal).toBeUndefined()
  })

  it('accepts the published receipt', () => {
    expect(decodeSkillCreateReceipt({ status: 'created_and_published', preview: {} }))
      .toEqual({ status: 'created_and_published' })
  })

  it('carries the package that shadows a created one', () => {
    const winner = { source_id: 'project-masc', package_id: 'shared', name: 'shared' }
    expect(decodeSkillCreateReceipt({
      status: 'created_but_shadowed',
      preview: {},
      snapshot_revision: 'snapshot-revision',
      winner,
    })).toEqual({ status: 'created_but_shadowed', winner })
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
    ['a shadowed receipt without its winner', { status: 'created_but_shadowed' }],
    ['a winner missing its package', {
      status: 'created_but_shadowed',
      winner: { source_id: 'project-masc', name: 'shared' },
    }],
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
  io: { kind: 'model_orchestrated' as const },
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
  it('accepts the declared I/O shipped by the server and rejects malformed contracts', () => {
    const compositionIo = {
      kind: 'composition',
      input_schema: { type: 'object', required: ['task'], properties: { task: { type: 'string' } } },
      exports: [{ name: 'answer', node_id: 'result', pointer: '/data/answer' }],
    }
    for (const io of [{ kind: 'model_orchestrated' }, compositionIo]) {
      const response = { ok: true, status: 'valid', preview: {
        ...editorPreview, profile: { ...editorProfile, io },
      } }
      expect(decodeSkillEditorPreview(response).profile.io).toEqual(io)
    }
    for (const io of [
      { kind: 'unknown' },
      { ...compositionIo, input_schema: 'not an object' },
      { ...compositionIo, exports: [{ name: 'answer', node_id: 'result' }] },
      { kind: 'model_orchestrated', invented: true },
    ]) {
      expect(() => decodeSkillEditorPreview({ ok: true, status: 'valid', preview: {
        ...editorPreview, profile: { ...editorProfile, io },
      } })).toThrow()
    }
  })

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

// One active row as the server writes it: Server_async_request_observability
// .entry_to_yojson (lib/server/server_async_request_observability.ml:86) puts
// worker_ownership in front of Keeper_msg_async.entry_to_json
// (lib/keeper/keeper_msg_async_query.ml:184), which always writes request_context
// as the submitter's object or null.
function activeRequestRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    worker_ownership: 'runtime_owned',
    request_id: 'request-owned',
    keeper_name: 'rondo',
    submitted_by: 'operator',
    request_context: null,
    status: 'running',
    submitted_at: 1,
    elapsed_sec: 2,
    ...overrides,
  }
}

function readyObservation(requests: readonly Record<string, unknown>[]): Record<string, unknown> {
  const owned = requests.filter(row => row.worker_ownership === 'runtime_owned').length
  return {
    schema: 'masc.async-request-observation/v1',
    status: 'ready',
    summary: {
      active: requests.length,
      runtime_owned: owned,
      ownership_unknown: requests.length - owned,
      record_errors: 0,
    },
    requests,
    record_errors: [],
    startup_recovery: recovery,
  }
}

describe('async request observation contract', () => {
  it('keeps durable row and current-process ownership distinct', () => {
    const decoded = decodeAsyncRequestObservation(readyObservation([
      activeRequestRow(),
      activeRequestRow({
        worker_ownership: 'disk_only_ownership_unknown',
        request_id: 'request-disk-only',
        keeper_name: 'sangsu',
        status: 'queued',
        submitted_at: 2,
        elapsed_sec: 1,
      }),
    ]))

    expect(decoded.status).toBe('ready')
    if (decoded.status === 'ready') {
      expect(decoded.requests.map(row => row.worker_ownership)).toEqual([
        'runtime_owned',
        'disk_only_ownership_unknown',
      ])
    }
  })

  it('keeps the request_context object the submitter gave', () => {
    const requestContext = { source: 'board', thread: { post_id: 'p-1', depth: 2 } }
    const decoded = decodeAsyncRequestObservation(readyObservation([
      activeRequestRow({ request_context: requestContext }),
    ]))

    expect(decoded.status).toBe('ready')
    if (decoded.status === 'ready') {
      expect(decoded.requests[0]?.request_context).toEqual(requestContext)
    }
  })

  it.each([
    ['a row without request_context', (() => {
      const row = activeRequestRow()
      delete row.request_context
      return row
    })()],
    ['a request_context that is not an object', activeRequestRow({ request_context: 'board' })],
    ['a row field the server does not write', activeRequestRow({ request_ctx: null })],
  ])('rejects %s', (_label, row) => {
    expect(() => decodeAsyncRequestObservation(readyObservation([row]))).toThrow(
      SkillsContractError,
    )
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
