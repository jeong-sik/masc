import { describe, expect, it } from 'vitest'
import type { SkillSnapshotEntry, SkillUsage } from '../api/dashboard-skills'
import {
  formatBytes,
  kindLabel,
  mergeSkillRows,
  sortSkillRows,
  stateMessage,
  usageLabel,
} from './skills-panel'

function entry(name: string, body_bytes = 100): SkillSnapshotEntry {
  return {
    identity: { source_id: 'workspace', package_id: name, name },
    content_revision: 'sha',
    description: `about ${name}`,
    conformance: 'conformant',
    body_bytes,
  }
}

const usage: SkillUsage[] = [
  { name: 'mission-snapshot', directory: 'mission-snapshot', kind: 'composition', tool_name: 'keeper_compose_mission-snapshot', execution: 'inline', recent_use_count: 5 },
  { name: 'work-intake', directory: 'work-intake', kind: 'instruction', recent_use_count: 1 },
  { name: 'broken', directory: 'broken', kind: 'unparsed', error: 'fence declares another name' },
]

describe('mergeSkillRows', () => {
  it('joins usage by name and keeps a skill with no usage row', () => {
    const rows = mergeSkillRows([entry('work-intake'), entry('orphan')], usage)
    expect(rows.map(r => [r.name, r.usage?.kind ?? null])).toEqual([
      ['work-intake', 'instruction'],
      ['orphan', null],
    ])
    expect(rows[0]!.source).toBe('workspace/work-intake')
  })

  // A server older than the usage join sends {schema,state,snapshot} and no
  // usage array. The bundle deploys separately, so that pairing is reachable;
  // it must degrade to "not reported", not throw on a non-iterable.
  it('renders the snapshot when the server reports no usage at all', () => {
    const rows = mergeSkillRows([entry('work-intake')], undefined)
    expect(rows.map(r => [r.name, r.usage])).toEqual([['work-intake', null]])
  })
})

describe('sortSkillRows', () => {
  it('puts the most used first, unparsed and unknown count as zero, ties by name', () => {
    const rows = mergeSkillRows(
      [entry('work-intake'), entry('broken'), entry('mission-snapshot'), entry('alpha')],
      usage,
    )
    expect(sortSkillRows(rows).map(r => r.name)).toEqual([
      'mission-snapshot', 'work-intake', 'alpha', 'broken',
    ])
  })

  it('does not mutate its input', () => {
    const rows = mergeSkillRows([entry('b'), entry('a')], [])
    sortSkillRows(rows)
    expect(rows.map(r => r.name)).toEqual(['b', 'a'])
  })
})

describe('labels', () => {
  it('names the window beside the count and says why there is none', () => {
    expect(usageLabel(usage[1]!, 2000)).toBe('1 in last 2000 calls')
    expect(usageLabel(usage[2]!, 2000)).toBe('—')
    expect(usageLabel(null, 2000)).toBe('—')
  })

  it('does not claim a window the server never reported', () => {
    expect(usageLabel(usage[1]!, undefined)).toBe('1 (window unreported)')
  })

  it('shows the parsed kind, the refusal, or the absence', () => {
    expect(kindLabel(usage[0]!)).toBe('composition · inline')
    expect(kindLabel(usage[1]!)).toBe('instruction')
    expect(kindLabel(usage[2]!)).toBe('unparsed: fence declares another name')
    expect(kindLabel(null)).toBe('not in usage')
  })

  it('formats body sizes and snapshot states', () => {
    expect(formatBytes(643)).toBe('643 B')
    expect(formatBytes(1536)).toBe('1.5 KB')
    expect(stateMessage('not_registered')).toMatch(/no registered skill snapshot/)
    expect(stateMessage('uninitialized')).toMatch(/not been published/)
    expect(stateMessage('invalid_workspace')).toMatch(/could not be resolved/)
  })
})
