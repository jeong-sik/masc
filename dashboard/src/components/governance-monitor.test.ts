import { describe, expect, it } from 'vitest'
import { filterToolRejections, type ToolRejection } from './governance-monitor'

function makeRejection(overrides: Partial<ToolRejection> = {}): ToolRejection {
  return {
    tool: 'Bash',
    reason: 'permission_denied',
    count: 1,
    ...overrides,
  }
}

describe('filterToolRejections', () => {
  const rows: ToolRejection[] = [
    makeRejection({ tool: 'Bash', reason: 'permission_denied', count: 12 }),
    makeRejection({ tool: 'WebFetch', reason: 'network_unreachable', count: 3 }),
    makeRejection({ tool: 'Read', reason: 'path_outside_workspace', count: 7 }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterToolRejections(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterToolRejections(rows, '   ')).toBe(rows)
  })

  it('matches by tool substring (case-insensitive)', () => {
    const result = filterToolRejections(rows, 'BASH')
    expect(result).toHaveLength(1)
    expect(result[0]?.tool).toBe('Bash')
  })

  it('matches by reason substring (case-insensitive)', () => {
    const result = filterToolRejections(rows, 'PERMISSION')
    expect(result.map(r => r.tool)).toEqual(['Bash'])
  })

  it('trims query before matching', () => {
    expect(filterToolRejections(rows, '  webfetch  ')).toHaveLength(1)
  })

  it('returns empty when no field matches', () => {
    expect(filterToolRejections(rows, 'nonexistent-token')).toHaveLength(0)
  })

  it('matches across both fields in a single query', () => {
    // "e" appears in WebFetch/network_unreachable, Read/path_outside_workspace, Bash/permission_denied
    const result = filterToolRejections(rows, 'workspace')
    expect(result.map(r => r.tool)).toEqual(['Read'])
  })

  it('does not mutate the input array', () => {
    const copy = rows.slice()
    filterToolRejections(rows, 'bash')
    expect(rows).toEqual(copy)
  })
})
