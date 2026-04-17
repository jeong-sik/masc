import { describe, it, expect } from 'vitest'
import {
  toolCategory,
  formatDuration,
  summarizeEntries,
  durationColor,
  formatArgs,
  formatResult,
  prettyArgs,
} from './tool-call-shared'

// ================================================================
// toolCategory
// ================================================================

describe('toolCategory', () => {
  it('matches shell category', () => {
    const result = toolCategory('bash_exec')
    expect(result.label).toBe('shell')
    expect(result.icon).toBe('>')
  })

  it('matches git category', () => {
    const result = toolCategory('github_create_pr')
    expect(result.label).toBe('git')
  })

  it('matches edit category', () => {
    const result = toolCategory('edit_file')
    expect(result.label).toBe('edit')
  })

  it('matches search category', () => {
    const result = toolCategory('search_code')
    expect(result.label).toBe('search')
  })

  it('returns default for unknown tool', () => {
    const result = toolCategory('unknown_tool')
    expect(result.label).toBe('tool')
    expect(result.icon).toBe('T')
  })

  it('matches more specific before general', () => {
    // "bash_read_files" matches shell first (includes "bash"), not "read"
    const result = toolCategory('bash_read_files')
    expect(result.label).toBe('shell')
  })

  it('matches read category', () => {
    const result = toolCategory('read_output')
    expect(result.label).toBe('read')
  })

  it('matches web category', () => {
    const result = toolCategory('web_fetch_url')
    expect(result.label).toBe('web')
  })

  it('matches voice category', () => {
    const result = toolCategory('voice_synthesize')
    expect(result.label).toBe('voice')
  })

  it('matches coordination category', () => {
    const result = toolCategory('task_claim')
    expect(result.label).toBe('coord')
  })

  it('matches memory category', () => {
    const result = toolCategory('memory_recall')
    expect(result.label).toBe('memory')
  })
})

// ================================================================
// formatDuration (tool-call-shared version, milliseconds)
// ================================================================

describe('formatDuration', () => {
  it('formats milliseconds', () => {
    expect(formatDuration(500)).toBe('500ms')
  })

  it('formats seconds', () => {
    expect(formatDuration(1500)).toBe('1.5s')
  })

  it('formats minutes', () => {
    expect(formatDuration(90000)).toBe('1.5m')
  })

  it('rounds milliseconds', () => {
    expect(formatDuration(499)).toBe('499ms')
  })

  it('formats 0 as 0ms', () => {
    expect(formatDuration(0)).toBe('0ms')
  })

  it('formats exactly 1 second', () => {
    expect(formatDuration(1000)).toBe('1.0s')
  })

  it('formats exactly 1 minute', () => {
    expect(formatDuration(60000)).toBe('1.0m')
  })
})

// ================================================================
// summarizeEntries
// ================================================================

describe('summarizeEntries', () => {
  it('summarizes empty array', () => {
    expect(summarizeEntries([])).toEqual({ totalMs: 0, successCount: 0, errorCount: 0 })
  })

  it('summarizes successful entries', () => {
    const entries = [{ duration_ms: 100 }, { duration_ms: 200 }]
    expect(summarizeEntries(entries)).toEqual({ totalMs: 300, successCount: 2, errorCount: 0 })
  })

  it('counts errors', () => {
    const entries = [
      { duration_ms: 100, error: 'fail' },
      { duration_ms: 200 },
    ]
    expect(summarizeEntries(entries)).toEqual({ totalMs: 300, successCount: 1, errorCount: 1 })
  })

  it('handles missing duration_ms', () => {
    const entries = [{}]
    expect(summarizeEntries(entries)).toEqual({ totalMs: 0, successCount: 1, errorCount: 0 })
  })

  it('handles null error', () => {
    const entries = [{ duration_ms: 50, error: null }]
    expect(summarizeEntries(entries)).toEqual({ totalMs: 50, successCount: 1, errorCount: 0 })
  })
})

// ================================================================
// durationColor
// ================================================================

describe('durationColor', () => {
  it('returns ok for fast (< 500ms)', () => {
    expect(durationColor(100)).toBe('text-[var(--ok)]')
  })

  it('returns ok for just under threshold', () => {
    expect(durationColor(499)).toBe('text-[var(--ok)]')
  })

  it('returns warn for medium (500-1999ms)', () => {
    expect(durationColor(500)).toBe('text-[var(--warn)]')
  })

  it('returns warn for just under slow threshold', () => {
    expect(durationColor(1999)).toBe('text-[var(--warn)]')
  })

  it('returns bad for slow (>= 2000ms)', () => {
    expect(durationColor(2000)).toBe('text-[var(--bad)]')
  })

  it('returns bad for very slow', () => {
    expect(durationColor(10000)).toBe('text-[var(--bad)]')
  })
})

// ================================================================
// formatArgs
// ================================================================

describe('formatArgs', () => {
  it('returns string as-is with truncation', () => {
    expect(formatArgs('hello')).toBe('hello')
  })

  it('truncates long string', () => {
    const long = 'a'.repeat(100)
    const result = formatArgs(long)
    expect(result.length).toBeLessThanOrEqual(83) // 80 + "..."
  })

  it('formats empty object', () => {
    expect(formatArgs({})).toBe('{}')
  })

  it('formats simple object', () => {
    expect(formatArgs({ key: 'val' })).toBe('{key: val}')
  })

  it('limits to 3 keys', () => {
    const args = { a: '1', b: '2', c: '3', d: '4' }
    const result = formatArgs(args)
    expect(result).toContain('...')
  })

  it('handles number values', () => {
    expect(formatArgs({ count: 42 })).toBe('{count: 42}')
  })
})

// ================================================================
// formatResult
// ================================================================

describe('formatResult', () => {
  it('returns error prefixed', () => {
    expect(formatResult(null, 'bad thing')).toBe('err: bad thing')
  })

  it('returns dash for null result and null error', () => {
    expect(formatResult(null, null)).toBe('-')
  })

  it('returns result truncated', () => {
    const long = 'a'.repeat(100)
    const result = formatResult(long, null)
    expect(result.length).toBeLessThanOrEqual(83)
  })

  it('returns result as-is when short', () => {
    expect(formatResult('ok', null)).toBe('ok')
  })

  it('prioritizes error over result', () => {
    expect(formatResult('ok', 'fail')).toBe('err: fail')
  })

  it('respects custom maxLen', () => {
    const result = formatResult('a'.repeat(50), null, 20)
    expect(result.length).toBeLessThanOrEqual(23)
  })
})

// ================================================================
// prettyArgs
// ================================================================

describe('prettyArgs', () => {
  it('returns string as-is', () => {
    expect(prettyArgs('hello')).toBe('hello')
  })

  it('serializes object to pretty JSON', () => {
    expect(prettyArgs({ a: 1 })).toBe('{\n  "a": 1\n}')
  })

  it('serializes object with array', () => {
    expect(prettyArgs({ items: [1, 2] })).toBe('{\n  "items": [\n    1,\n    2\n  ]\n}')
  })
})
