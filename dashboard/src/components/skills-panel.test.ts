import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type {
  SkillReference,
  SkillSnapshotEntry,
  SkillSurface,
} from '../api/dashboard-skills'

const editorApiMocks = vi.hoisted(() => ({
  previewSkillSource: vi.fn(),
  readSkillSource: vi.fn(),
  saveSkillSource: vi.fn(),
}))

vi.mock('../api/dashboard-skills', async importOriginal => ({
  ...await importOriginal<typeof import('../api/dashboard-skills')>(),
  previewSkillSource: editorApiMocks.previewSkillSource,
  readSkillSource: editorApiMocks.readSkillSource,
  saveSkillSource: editorApiMocks.saveSkillSource,
}))

import { decodeSkillsResponse, SkillsContractError } from '../api/dashboard-skills'
import { ApiRequestError } from '../api/core'
import {
  capabilityLabel,
  contextLabel,
  formatBytes,
  kindLabel,
  mergeSkillRows,
  resourceReadBoundLabel,
  skillRowKey,
  SkillSourceEditor,
  sortSkillRows,
  stateMessage,
  usageLabel,
} from './skills-panel'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function entry(
  name: string,
  options: {
    source_id?: string
    package_id?: string
    content_revision?: string
    body_bytes?: number
    diagnostics?: string[]
  } = {},
): SkillSnapshotEntry {
  return {
    identity: {
      source_id: options.source_id ?? 'workspace',
      package_id: options.package_id ?? name,
      name,
    },
    content_revision: options.content_revision ?? `revision-${name}`,
    description: `about ${name}`,
    conformance: 'conformant',
    diagnostics: options.diagnostics,
    body_bytes: options.body_bytes ?? 100,
  }
}

function reference(snapshotEntry: SkillSnapshotEntry): SkillReference {
  return {
    identity: snapshotEntry.identity,
    content_revision: snapshotEntry.content_revision,
  }
}

const mission = entry('mission-snapshot')
const intake = entry('work-intake')
const broken = entry('broken')
const surfaces: SkillSurface[] = [
  {
    reference: reference(mission),
    kind: 'composition',
    tool_name: 'keeper_compose_mission-snapshot',
    execution: 'inline',
  },
  { reference: reference(intake), kind: 'instruction' },
  {
    reference: reference(broken),
    kind: 'unavailable',
    error: 'fence declares another name',
  },
]

describe('mergeSkillRows', () => {
  it('joins the parser surface by exact reference', () => {
    const shadow = entry('work-intake', { source_id: 'shadow-source' })
    const rows = mergeSkillRows([intake, shadow], surfaces)
    expect(rows.map(row => [row.source, row.surface?.kind ?? null])).toEqual([
      ['workspace/work-intake', 'instruction'],
      ['shadow-source/work-intake', null],
    ])
  })

  it('keeps the snapshot when the surface projection is unavailable', () => {
    const rows = mergeSkillRows([intake], [])
    expect(rows.map(row => [row.name, row.surface])).toEqual([['work-intake', null]])
  })

  it('merges snapshot and exact surface diagnostics without duplicates', () => {
    const compatible = entry('compatible', {
      diagnostics: ['name differs from directory', 'shared diagnostic'],
    })
    const rows = mergeSkillRows(
      [compatible, entry('plain')],
      [{
        reference: reference(compatible),
        kind: 'instruction',
        diagnostics: ['shared diagnostic', 'composition fence malformed'],
      }],
    )
    expect(rows.map(row => row.diagnostics)).toEqual([
      ['name differs from directory', 'shared diagnostic', 'composition fence malformed'],
      [],
    ])
  })

  it('does not attach diagnostics from a same-name different reference', () => {
    const shadow = entry('work-intake', { source_id: 'shadow-source' })
    const rows = mergeSkillRows(
      [intake, shadow],
      [{
        reference: reference(shadow),
        kind: 'instruction',
        diagnostics: ['shadow-only diagnostic'],
      }],
    )
    expect(rows.map(row => row.diagnostics)).toEqual([[], ['shadow-only diagnostic']])
  })
})

describe('sortSkillRows', () => {
  it('sorts by exact identity and revision', () => {
    const rows = mergeSkillRows(
      [
        entry('same', { source_id: 'z-source', content_revision: 'b' }),
        entry('same', { source_id: 'a-source', package_id: 'z-package' }),
        entry('same', {
          source_id: 'a-source',
          package_id: 'a-package',
          content_revision: 'b',
        }),
        entry('same', {
          source_id: 'a-source',
          package_id: 'a-package',
          content_revision: 'a',
        }),
      ],
      [],
    )
    expect(
      sortSkillRows(rows).map(
        row => `${row.source}/${row.name}/${row.content_revision}`,
      ),
    ).toEqual([
      'a-source/a-package/same/a',
      'a-source/a-package/same/b',
      'a-source/z-package/same/revision-same',
      'z-source/same/same/b',
    ])
  })

  it('does not mutate its input', () => {
    const rows = mergeSkillRows([entry('b'), entry('a')], [])
    sortSkillRows(rows)
    expect(rows.map(row => row.name)).toEqual(['b', 'a'])
  })

  it('uses the complete exact reference as the Preact row key', () => {
    const rows = mergeSkillRows([
      entry('same', { source_id: 'a-source', content_revision: 'revision-a' }),
      entry('same', { source_id: 'b-source', content_revision: 'revision-b' }),
    ], [])
    expect(rows.map(skillRowKey)).toEqual([
      'a-source\u0000same\u0000same\u0000revision-a',
      'b-source\u0000same\u0000same\u0000revision-b',
    ])
  })
})

function readyPayload(
  entries: SkillSnapshotEntry[],
  readySurfaces: SkillSurface[] | undefined,
): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    schema: 'masc.skill-snapshot/v1',
    state: 'ready',
    snapshot: {
      snapshot_revision: 'snapshot-revision',
      catalog_revision: 'catalog-revision',
      config: {
        kind: 'configured',
        revision: 'config-revision',
        resource_read_max_bytes: 65_536,
      },
      sources: [],
      skills: entries.map(snapshotEntry => ({
        ...snapshotEntry,
        diagnostics: snapshotEntry.diagnostics ?? [],
      })),
      effective_skills: entries.map(snapshotEntry => snapshotEntry.identity),
      shadows: [],
      rejections: [],
    },
  }
  if (readySurfaces !== undefined) payload.surfaces = readySurfaces
  return payload
}

function expectContractCode(run: () => unknown, code: SkillsContractError['code']): void {
  try {
    run()
    throw new Error('expected SkillsContractError')
  } catch (error) {
    expect(error).toBeInstanceOf(SkillsContractError)
    expect((error as SkillsContractError).code).toBe(code)
  }
}

describe('decodeSkillsResponse', () => {
  it('accepts an empty surfaces projection only for an empty snapshot', () => {
    expect(decodeSkillsResponse(readyPayload([], []))).toMatchObject({
      state: 'ready',
      surfaces: [],
    })
  })

  it('decodes a complete non-empty exact-reference projection', () => {
    expect(decodeSkillsResponse(readyPayload(
      [intake],
      [{
        reference: reference(intake),
        kind: 'instruction',
        diagnostics: ['server projection diagnostic'],
      }],
    ))).toMatchObject({
      state: 'ready',
      surfaces: [{
        reference: reference(intake),
        kind: 'instruction',
        diagnostics: ['server projection diagnostic'],
      }],
    })
  })

  it('distinguishes a missing surfaces field from an empty non-empty projection', () => {
    expectContractCode(
      () => decodeSkillsResponse(readyPayload([intake], undefined)),
      'ready_surfaces_missing',
    )
    expectContractCode(
      () => decodeSkillsResponse(readyPayload([intake], [])),
      'ready_surfaces_empty',
    )
  })

  it('rejects a non-array surfaces carrier with its typed contract code', () => {
    expectContractCode(
      () => decodeSkillsResponse({ ...readyPayload([intake], []), surfaces: {} }),
      'ready_surfaces_invalid',
    )
  })

  it('rejects duplicate exact surface references', () => {
    const surface: SkillSurface = { reference: reference(intake), kind: 'instruction' }
    expectContractCode(
      () => decodeSkillsResponse(readyPayload([intake], [surface, surface])),
      'ready_surfaces_duplicate_reference',
    )
  })

  it('rejects missing exact-reference coverage even when names match', () => {
    const shadow = entry('work-intake', { source_id: 'shadow-source' })
    expectContractCode(
      () => decodeSkillsResponse(readyPayload(
        [intake, shadow],
        [{ reference: reference(intake), kind: 'instruction' }],
      )),
      'ready_surface_missing_reference',
    )
  })

  it('rejects a surface reference absent from the snapshot', () => {
    const shadow = entry('work-intake', { source_id: 'shadow-source' })
    expectContractCode(
      () => decodeSkillsResponse(readyPayload(
        [intake],
        [{ reference: reference(shadow), kind: 'instruction' }],
      )),
      'ready_surface_unexpected_reference',
    )
  })
})

describe('labels', () => {
  it('renders execution, context and current-user evidence from a profile', () => {
    const profiled: SkillSurface = {
      reference: reference(mission),
      kind: 'composition',
      tool_name: 'keeper_compose_mission-snapshot',
      execution: 'async',
      profile: {
        reference: reference(mission),
        kind: 'composition',
        activation_tool: 'keeper_compose_mission-snapshot',
        execution: 'async',
        capabilities: {
          as_skill: true,
          as_tool: true,
          batch: true,
          parallel: true,
          async: true,
          tool_scope: 'registered_tools_only',
        },
        context: {
          body_bytes: 2048,
          eager_body_bytes: 0,
          discovery_bytes: 320,
          tool_schema_bytes: 320,
        },
        plan: {
          node_count: 4,
          batch_count: 2,
          parallel_batch_count: 1,
          max_parallelism: 3,
          statically_read_only: true,
        },
        declaration: { start_line: 3, end_line: 30 },
        flow: null,
      },
      usage: [{
        keeper: 'rondo',
        invocations: 9,
        deliveries: 9,
        actions: 134,
        last_used_at: '2026-08-27T01:00:00Z',
      }],
    }
    expect(capabilityLabel(profiled)).toBe('async · 4 nodes · 2 batches · parallel ×3')
    expect(contextLabel(profiled, 2048)).toBe('320 B discovery · 0 B eager · 2.0 KB body')
    expect(usageLabel(profiled)).toBe(
      'rondo 9×/9 delivered/134 actions · last 2026-08-27T01:00:00Z',
    )
  })

  it('shows the parsed kind, refusal, or unavailable projection', () => {
    expect(kindLabel(surfaces[0]!)).toBe('composition · inline')
    expect(kindLabel(surfaces[1]!)).toBe('instruction')
    expect(kindLabel(surfaces[2]!)).toBe('unavailable: fence declares another name')
    expect(kindLabel(null)).toBe('surface unavailable')
  })

  it('formats body sizes and snapshot states', () => {
    expect(formatBytes(643)).toBe('643 B')
    expect(formatBytes(1536)).toBe('1.5 KB')
    expect(stateMessage('not_registered')).toMatch(/no registered skill snapshot/)
    expect(stateMessage('uninitialized')).toMatch(/not been published/)
    expect(stateMessage('invalid_workspace')).toMatch(/could not be resolved/)
  })

  it('shows only the configured resource bound', () => {
    expect(resourceReadBoundLabel({
      kind: 'configured',
      revision: 'config-revision',
      resource_read_max_bytes: 1536,
    })).toBe('resource read max 1.5 KB')
    expect(resourceReadBoundLabel({
      kind: 'configured',
      revision: 'config-revision',
      resource_read_max_bytes: null,
    })).toBe('resource read max unavailable')
    expect(resourceReadBoundLabel({ kind: 'unreadable' })).toBe(
      'resource read max unavailable',
    )
  })
})

const editorProfile = {
  reference: reference(intake),
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
    body_bytes: 100,
    eager_body_bytes: 0,
    discovery_bytes: 40,
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
  reference: reference(intake),
  profile: editorProfile,
  diagnostics: [],
}

describe('SkillSourceEditor', () => {
  it('loads, previews, and saves the current draft in order', async () => {
    const currentReference = reference(intake)
    const nextReference = { ...currentReference, content_revision: 'next-revision' }
    editorApiMocks.readSkillSource.mockResolvedValue({
      status: 'ready',
      reference: currentReference,
      snapshot_revision: 'snapshot-1',
      source_text: 'old source',
      access: 'read_write',
    })
    editorApiMocks.previewSkillSource.mockResolvedValue({
      reference: nextReference,
      profile: { ...editorProfile, reference: nextReference },
      diagnostics: [],
    })
    editorApiMocks.saveSkillSource.mockResolvedValue({
      status: 'saved_and_published',
      preview: {
        reference: nextReference,
        profile: { ...editorProfile, reference: nextReference },
        diagnostics: [],
      },
      snapshot_revision: 'snapshot-2',
    })
    const onPublished = vi.fn()
    const view = render(html`<${SkillSourceEditor}
      reference=${currentReference}
      onPublished=${onPublished}
    />`)

    fireEvent.click(view.getByTestId('skill-edit-open'))
    const textarea = await view.findByTestId('skill-source-draft') as HTMLTextAreaElement
    expect(textarea.value).toBe('old source')
    fireEvent.input(textarea, { target: { value: 'new source' } })

    fireEvent.click(view.getByText('Preview'))
    await view.findByTestId('skill-source-preview')
    expect(editorApiMocks.previewSkillSource).toHaveBeenCalledWith(
      currentReference,
      'new source',
    )

    fireEvent.click(view.getByTestId('skill-source-save'))
    await waitFor(() => expect(editorApiMocks.saveSkillSource).toHaveBeenCalledWith(
      currentReference,
      'new source',
    ))
    await waitFor(() => expect(onPublished).toHaveBeenCalledWith(
      'Skill saved and published at next-revisio.',
    ))
  })

  it('keeps the draft and gives reload/reapply guidance on a typed 409 conflict', async () => {
    const currentReference = reference(intake)
    editorApiMocks.readSkillSource.mockResolvedValue({
      status: 'ready',
      reference: currentReference,
      snapshot_revision: 'snapshot-1',
      source_text: 'old source',
      access: 'read_write',
    })
    editorApiMocks.previewSkillSource.mockResolvedValue({
      reference: currentReference,
      profile: editorProfile,
      diagnostics: [],
    })
    editorApiMocks.saveSkillSource.mockRejectedValue(new ApiRequestError({
      method: 'POST',
      path: '/api/v1/skills/editor/save',
      status: 409,
      responseData: { code: 'revision_conflict' },
    }))
    const view = render(html`<${SkillSourceEditor}
      reference=${currentReference}
      onPublished=${vi.fn()}
    />`)

    fireEvent.click(view.getByTestId('skill-edit-open'))
    const textarea = await view.findByTestId('skill-source-draft') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'draft to preserve' } })
    fireEvent.click(view.getByText('Preview'))
    await view.findByTestId('skill-source-preview')
    fireEvent.click(view.getByTestId('skill-source-save'))

    const conflict = await view.findByTestId('skill-source-conflict')
    expect(conflict.textContent).toContain('reload the Skills workspace')
    expect(conflict.textContent).toContain('reapply it')
    expect((view.getByTestId('skill-source-draft') as HTMLTextAreaElement).value)
      .toBe('draft to preserve')
  })

  it('does not accept a preview response for a draft changed while it was pending', async () => {
    const currentReference = reference(intake)
    let resolvePreview!: (value: typeof editorPreview) => void
    editorApiMocks.readSkillSource.mockResolvedValue({
      status: 'ready',
      reference: currentReference,
      snapshot_revision: 'snapshot-1',
      source_text: 'old source',
      access: 'read_write',
    })
    editorApiMocks.previewSkillSource.mockReturnValue(new Promise(resolve => {
      resolvePreview = resolve
    }))
    const view = render(html`<${SkillSourceEditor}
      reference=${currentReference}
      onPublished=${vi.fn()}
    />`)

    fireEvent.click(view.getByTestId('skill-edit-open'))
    const textarea = await view.findByTestId('skill-source-draft') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'source sent to preview' } })
    fireEvent.click(view.getByText('Preview'))
    await waitFor(() => expect(editorApiMocks.previewSkillSource).toHaveBeenCalledWith(
      currentReference,
      'source sent to preview',
    ))
    fireEvent.input(textarea, { target: { value: 'newer unpreviewed source' } })

    resolvePreview({
      reference: currentReference,
      profile: editorProfile,
      diagnostics: [],
    })

    await waitFor(() => expect(view.queryByTestId('skill-source-preview')).toBeNull())
    expect((view.getByTestId('skill-source-save') as HTMLButtonElement).disabled).toBe(true)
  })

  it('ignores a preview response from an editor generation that was closed', async () => {
    const currentReference = reference(intake)
    let resolvePreview!: (value: typeof editorPreview) => void
    editorApiMocks.readSkillSource.mockResolvedValue({
      status: 'ready',
      reference: currentReference,
      snapshot_revision: 'snapshot-1',
      source_text: 'old source',
      access: 'read_write',
    })
    editorApiMocks.previewSkillSource.mockReturnValue(new Promise(resolve => {
      resolvePreview = resolve
    }))
    const view = render(html`<${SkillSourceEditor}
      reference=${currentReference}
      onPublished=${vi.fn()}
    />`)

    fireEvent.click(view.getByTestId('skill-edit-open'))
    const textarea = await view.findByTestId('skill-source-draft') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'source from closed editor' } })
    fireEvent.click(view.getByText('Preview'))
    await waitFor(() => expect(editorApiMocks.previewSkillSource).toHaveBeenCalledOnce())
    fireEvent.click(view.getByText('Close'))

    resolvePreview(editorPreview)

    await waitFor(() => expect(view.queryByTestId('skill-source-editor')).toBeNull())
    expect(view.queryByTestId('skill-source-preview')).toBeNull()
  })

  it('locks the draft and close action until a save settles', async () => {
    const currentReference = reference(intake)
    let resolveSave!: (value: {
      status: 'saved_and_published'
      preview: typeof editorPreview
      snapshot_revision: string
    }) => void
    editorApiMocks.readSkillSource.mockResolvedValue({
      status: 'ready',
      reference: currentReference,
      snapshot_revision: 'snapshot-1',
      source_text: 'old source',
      access: 'read_write',
    })
    editorApiMocks.previewSkillSource.mockResolvedValue({
      reference: currentReference,
      profile: editorProfile,
      diagnostics: [],
    })
    editorApiMocks.saveSkillSource.mockReturnValue(new Promise(resolve => {
      resolveSave = resolve
    }))
    const onPublished = vi.fn()
    const view = render(html`<${SkillSourceEditor}
      reference=${currentReference}
      onPublished=${onPublished}
    />`)

    fireEvent.click(view.getByTestId('skill-edit-open'))
    const textarea = await view.findByTestId('skill-source-draft') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'source to save' } })
    fireEvent.click(view.getByText('Preview'))
    await view.findByTestId('skill-source-preview')
    fireEvent.click(view.getByTestId('skill-source-save'))

    await waitFor(() => expect(editorApiMocks.saveSkillSource).toHaveBeenCalledWith(
      currentReference,
      'source to save',
    ))
    expect((view.getByTestId('skill-source-draft') as HTMLTextAreaElement).readOnly).toBe(true)
    expect((view.getByText('Close') as HTMLButtonElement).disabled).toBe(true)

    resolveSave({
      status: 'saved_and_published',
      preview: editorPreview,
      snapshot_revision: 'snapshot-2',
    })
    await waitFor(() => expect(onPublished).toHaveBeenCalledOnce())
  })
})
