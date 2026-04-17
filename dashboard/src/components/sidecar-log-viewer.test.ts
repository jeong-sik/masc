import { describe, expect, it } from 'vitest'
import { filterLogLines } from './sidecar-log-viewer'

describe('filterLogLines', () => {
  const lines: readonly string[] = [
    '2026-04-17T10:00:00 INFO starting sidecar',
    '2026-04-17T10:00:01 DEBUG config loaded',
    '2026-04-17T10:00:02 ERROR connection refused',
    '2026-04-17T10:00:03 INFO retry scheduled',
    '2026-04-17T10:00:04 ERROR timeout',
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterLogLines(lines, '')).toBe(lines)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterLogLines(lines, '   ')).toBe(lines)
  })

  it('matches case-insensitively', () => {
    const result = filterLogLines(lines, 'ERROR')
    expect(result).toHaveLength(2)
    const lower = filterLogLines(lines, 'error')
    expect(lower).toEqual(result)
  })

  it('trims the query before matching', () => {
    expect(filterLogLines(lines, '  DEBUG  ')).toEqual([
      '2026-04-17T10:00:01 DEBUG config loaded',
    ])
  })

  it('returns multiple matches', () => {
    const result = filterLogLines(lines, 'info')
    expect(result).toHaveLength(2)
    expect(result.map(line => line.includes('INFO'))).toEqual([true, true])
  })

  it('returns empty array when no line matches', () => {
    expect(filterLogLines(lines, 'nonexistent-token')).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const copy = lines.slice()
    filterLogLines(lines, 'ERROR')
    expect(lines).toEqual(copy)
  })

  it('handles empty input array', () => {
    const empty: readonly string[] = []
    expect(filterLogLines(empty, 'anything')).toHaveLength(0)
    expect(filterLogLines(empty, '')).toBe(empty)
  })
})
