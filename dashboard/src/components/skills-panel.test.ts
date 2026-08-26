import { describe, expect, it } from 'vitest'
import type {
  SkillReference,
  SkillSnapshotEntry,
  SkillSurface,
} from '../api/dashboard-skills'
import {
  formatBytes,
  kindLabel,
  mergeSkillRows,
  resourceReadBoundLabel,
  sortSkillRows,
  stateMessage,
} from './skills-panel'

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
    const rows = mergeSkillRows([intake], undefined)
    expect(rows.map(row => [row.name, row.surface])).toEqual([['work-intake', null]])
  })

  it('keeps diagnostics and accepts an omitted diagnostics field', () => {
    const rows = mergeSkillRows(
      [entry('compatible', { diagnostics: ['name differs from directory'] }), entry('plain')],
      [],
    )
    expect(rows.map(row => row.diagnostics)).toEqual([
      ['name differs from directory'],
      [],
    ])
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
})

describe('labels', () => {
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
