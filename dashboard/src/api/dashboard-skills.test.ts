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
  composition_scope: 'exact_reference_latest_completed' as const,
  composition_records_read: 0,
  composition_unavailable: [],
  coverage_complete: false as const,
  activation_scope: 'complete_retained_trace_snapshot' as const,
  activation_sessions_inspected: 2,
  activation_ledgers_loaded: 2,
  activation_gaps: [],
  activation_owner_gap_count: 0,
}

const compositionNode = {
  node_id: 'clock',
  execution_id: 'exec-1',
  tool_name: 'keeper_time_now',
  input: {},
  schedule: {
    planned_index: 0,
    batch_index: 0,
    batch_size: 1,
    execution_mode: 'serial' as const,
  },
  result: {
    disposition: 'completed' as const,
    data: {},
    tool_name: 'keeper_time_now',
    duration_ms: 1,
  },
  tool_use_id: '',
  failure_effect_disposition: null,
  deferred_kind: null,
  result_bytes: 2,
  truncated_to: null,
}

const compositionEvidence = {
  schema: 'masc.skill-composition-evidence/v1' as const,
  reference,
  composition_run_id: '01a045f2-cd8b-7000-a3f7-1d718a712204',
  parent_tool_use_id: '',
  parent_turn: 7,
  parent_planned_index: 0,
  request_id: null,
  keeper: 'rondo',
  composition_tool: 'keeper_compose_proof',
  composition_execution: 'inline' as const,
  result: {
    disposition: 'completed' as const,
    duration_ms: 1,
    data: { actions: [compositionNode] },
    tool_name: 'keeper_compose_proof',
  },
  executor_settlements: [compositionNode],
  recorded_at: 1,
}

const activationPayload = {
  identity: reference.identity,
  content_revision: reference.content_revision,
  snapshot_revision: 'b'.repeat(64),
  turn_ref: 'trace-proof#1',
  runtime_id: 'codex.default',
  activated_at: '2026-08-28T03:00:00Z',
  skill_tool_use_id: 'skill-call-1',
  agent_core_turn: 1,
  invocation: {
    kind: 'instruction' as const,
    origin: { kind: 'session_instruction' as const },
    served_content: {
      kind: 'skill_body' as const,
      bytes: 4,
      sha256: 'c'.repeat(64),
    },
  },
  delivery: null,
  actions: [],
}

const activationEvidence = {
  trace_id: 'trace-proof',
  owner: {
    status: 'known' as const,
    claims: [{ keeper: 'rondo', source: 'current_meta' as const }],
    gaps: [],
  },
  activation: activationPayload,
}

describe('skill evidence contract', () => {
  it('rejects the retired bounded-evidence schema', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v2',
      status: 'never_observed',
      reference,
      activation: null,
      composition: null,
      coverage: { ...coverage, composition_records_read: 1 },
    })).toThrow(SkillsContractError)
  })

  it('keeps instruction activation and composition result in one exact envelope', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: {
        selection: 'most_recent_observed',
        evidence: activationEvidence,
      },
      composition: compositionEvidence,
      coverage: { ...coverage, composition_records_read: 1 },
    })

    expect(decoded.activation?.selection).toBe('most_recent_observed')
    expect(decoded.composition?.executor_settlements).toHaveLength(1)
  })

  it('rejects async evidence without its durable request identity', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: null,
      composition: {
        ...compositionEvidence,
        composition_execution: 'async',
        request_id: null,
      },
      coverage: { ...coverage, composition_records_read: 1 },
    })).toThrow(SkillsContractError)
  })

  it('rejects impossible node batch and truncation invariants', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: null,
      composition: {
        ...compositionEvidence,
        executor_settlements: [{
          ...compositionNode,
          schedule: { ...compositionNode.schedule, batch_index: 1 },
          truncated_to: 3,
        }],
      },
      coverage: { ...coverage, composition_records_read: 1 },
    })).toThrow(SkillsContractError)
  })

  it('rejects observed status without any observed evidence', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: null,
      composition: null,
      coverage,
    })).toThrow(SkillsContractError)
  })

  it('keeps partial ledger coverage visible when nothing was observed', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'not_observed_in_retained_coverage',
      reference,
      activation: null,
      composition: null,
      coverage: {
        ...coverage,
        activation_scope: 'incomplete_retained_trace_snapshot',
        activation_gaps: [{
          code: 'ledger_unreadable',
          trace_id: 'trace-proof',
          cause_code: 'read_failed',
          detail: 'permission denied',
        }],
      },
    })

    expect(decoded.coverage.activation_gaps).toHaveLength(1)
  })

  it.each([
    'exact_reference_latest_completed',
    'unavailable',
  ] as const)('accepts the declared composition scope %s', (composition_scope) => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'not_observed_in_retained_coverage',
      reference,
      activation: null,
      composition: null,
      coverage: composition_scope === 'unavailable'
        ? { ...coverage, composition_scope, composition_unavailable: ['index unreadable'] }
        : { ...coverage, composition_scope },
    })

    expect(decoded.coverage.composition_scope).toBe(composition_scope)
  })

  it('rejects a timestamp tie with duplicate traces or different times', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: {
        selection: 'most_recent_observed_timestamp_tie',
        evidence: [
          activationEvidence,
          {
            ...activationEvidence,
            activation: { ...activationPayload, activated_at: '2026-08-28T04:00:00Z' },
          },
        ],
      },
      composition: null,
      coverage,
    })).toThrow(SkillsContractError)
  })

  it('rejects unknown activation gap codes', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'not_observed_in_retained_coverage',
      reference,
      activation: null,
      composition: null,
      coverage: {
        ...coverage,
        activation_scope: 'incomplete_retained_trace_snapshot',
        activation_gaps: [{ code: 'hologram' }],
      },
    })).toThrow(SkillsContractError)
  })

  it('rejects a known activation gap without its variant fields', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'not_observed_in_retained_coverage',
      reference,
      activation: null,
      composition: null,
      coverage: {
        ...coverage,
        activation_scope: 'incomplete_retained_trace_snapshot',
        activation_gaps: [{ code: 'ledger_unreadable' }],
      },
    })).toThrow(SkillsContractError)
  })

  it('accepts a timestamp tie expressed with different RFC3339 offsets', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: {
        selection: 'most_recent_observed_timestamp_tie',
        evidence: [
          activationEvidence,
          {
            ...activationEvidence,
            trace_id: 'trace-proof-2',
            activation: {
              ...activationPayload,
              turn_ref: 'trace-proof-2#1',
              activated_at: '2026-08-28T12:00:00.0000000000001+09:00',
            },
          },
        ],
      },
      composition: null,
      coverage,
    })
    expect(decoded.activation?.selection).toBe('most_recent_observed_timestamp_tie')
  })

  it('accepts a leap-second tie with the next civil minute', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: {
        selection: 'most_recent_observed_timestamp_tie',
        evidence: [
          {
            ...activationEvidence,
            activation: {
              ...activationPayload,
              activated_at: '2026-12-31T23:59:60Z',
            },
          },
          {
            ...activationEvidence,
            trace_id: 'trace-proof-2',
            activation: {
              ...activationPayload,
              turn_ref: 'trace-proof-2#1',
              activated_at: '2027-01-01T00:00:00Z',
            },
          },
        ],
      },
      composition: null,
      coverage,
    })
    expect(decoded.activation?.selection).toBe('most_recent_observed_timestamp_tie')
  })

  it('rejects an invalid reference without an activation', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'not_observed_in_retained_coverage',
      reference: {
        identity: { ...reference.identity, source_id: '.' },
        content_revision: 'short',
      },
      activation: null,
      composition: null,
      coverage,
    })).toThrow(SkillsContractError)
  })

  it('rejects activation semantics that the canonical ledger rejects', () => {
    const invalidActivations = [
      { ...activationPayload, turn_ref: 'trace-proof#1e0' },
      {
        ...activationPayload,
        invocation: {
          kind: 'instruction' as const,
          origin: { kind: 'task_instruction' as const, task_ids: ['task-1', 'task-1'] },
          served_content: {
            kind: 'skill_resource' as const,
            relative_path: '../secret',
            bytes: 4,
            sha256: 'short',
          },
        },
      },
      {
        ...activationPayload,
        delivery: {
          boundary: { kind: 'model_response' as const, agent_core_turn: 1 },
          runtime_id: 'codex.default',
          delivered_at: '2026-08-28T03:00:00Z',
          content_bytes: 4,
          content_sha256: 'd'.repeat(64),
        },
      },
    ]
    for (const activation of invalidActivations) {
      expect(() => decodeSkillEvidenceResponse({
        schema: 'masc.skill-evidence/v5',
        status: 'observed',
        reference,
        activation: {
          selection: 'most_recent_observed',
          evidence: { ...activationEvidence, activation },
        },
        composition: null,
        coverage,
      })).toThrow(SkillsContractError)
    }
  })

  it('rejects an invalid identity even when envelope and activation agree', () => {
    const invalidReference = {
      ...reference,
      identity: { source_id: '../workspace', package_id: '..', name: 'Bad--Name' },
    }
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference: invalidReference,
      activation: {
        selection: 'most_recent_observed',
        evidence: {
          ...activationEvidence,
          activation: { ...activationPayload, identity: invalidReference.identity },
        },
      },
      composition: null,
      coverage,
    })).toThrow(SkillsContractError)
  })

  it('rejects an RFC3339 offset outside the canonical Ptime range', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: {
        selection: 'most_recent_observed',
        evidence: {
          ...activationEvidence,
          activation: {
            ...activationPayload,
            activated_at: '0000-01-01T00:00:00+01:00',
          },
        },
      },
      composition: null,
      coverage,
    })).toThrow(SkillsContractError)
  })

  it('accepts the fractional Ptime maximum boundary', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: {
        selection: 'most_recent_observed',
        evidence: {
          ...activationEvidence,
          activation: {
            ...activationPayload,
            activated_at: '9999-12-31T23:59:59.999999999999Z',
          },
        },
      },
      composition: null,
      coverage,
    })
    expect(decoded.activation?.selection).toBe('most_recent_observed')
  })

  it('rejects activation candidates not backed by loaded ledgers', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'observed',
      reference,
      activation: { selection: 'most_recent_observed', evidence: activationEvidence },
      composition: null,
      coverage: {
        ...coverage,
        activation_sessions_inspected: 0,
        activation_ledgers_loaded: 0,
      },
    })).toThrow(SkillsContractError)
  })

  it('rejects trace-store-unavailable with observed sessions', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v5',
      status: 'not_observed_in_retained_coverage',
      reference,
      activation: null,
      composition: null,
      coverage: {
        ...coverage,
        activation_scope: 'trace_store_unavailable',
        activation_gaps: [{
          code: 'trace_root_unavailable',
          operation: 'stat_entry',
          path: '/runtime/traces',
          detail: 'permission denied',
        }],
      },
    })).toThrow(SkillsContractError)
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
