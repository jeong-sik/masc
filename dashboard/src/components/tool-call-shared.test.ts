import { describe, it, expect } from 'vitest'
import {
  toolCategory,
  summarizeEntries,
  durationColor,
  formatArgs,
  prettyArgs,
  extractEmbeddedJson,
  prettyJsonDeep,
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

  it('matches workspace category', () => {
    const result = toolCategory('task_claim')
    expect(result.label).toBe('workspace')
  })

  it('matches memory category', () => {
    const result = toolCategory('memory_recall')
    expect(result.label).toBe('memory')
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
    expect(durationColor(100)).toBe('text-[var(--color-status-ok)]')
  })

  it('returns ok for just under threshold', () => {
    expect(durationColor(499)).toBe('text-[var(--color-status-ok)]')
  })

  it('returns warn for medium (500-1999ms)', () => {
    expect(durationColor(500)).toBe('text-[var(--color-status-warn)]')
  })

  it('returns warn for just under slow threshold', () => {
    expect(durationColor(1999)).toBe('text-[var(--color-status-warn)]')
  })

  it('returns bad for slow (>= 2000ms)', () => {
    expect(durationColor(2000)).toBe('text-[var(--color-status-err)]')
  })

  it('returns bad for very slow', () => {
    expect(durationColor(10000)).toBe('text-[var(--color-status-err)]')
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

// ================================================================
// extractEmbeddedJson / prettyJsonDeep (double-encoded tool results)
// ================================================================

describe('extractEmbeddedJson', () => {
  it('returns the object for a pure-JSON string', () => {
    expect(extractEmbeddedJson('{"id":"p-1"}')).toEqual({ id: 'p-1' })
  })

  it('extracts the JSON after a "<prose>\\n{json}" prefix', () => {
    expect(extractEmbeddedJson('Post created:\n{"id":"p-1","body":"hi"}')).toEqual({
      id: 'p-1',
      body: 'hi',
    })
  })

  it('wraps a bare top-level array as {items: [...]} to match OCaml ensure_object', () => {
    expect(extractEmbeddedJson('[1,2]')).toEqual({ items: [1, 2] })
  })

  it('wraps a suffix array as {items: [...]} to match OCaml ensure_object', () => {
    expect(extractEmbeddedJson('Items:\n[1,2]')).toEqual({ items: [1, 2] })
  })

  it('returns null for plain prose without embedded JSON', () => {
    expect(extractEmbeddedJson('just a note, see {a:1}')).toBeNull()
  })

  it('returns null when the suffix after newline is not valid JSON', () => {
    expect(extractEmbeddedJson('header\n{not json')).toBeNull()
  })
})

describe('prettyJsonDeep', () => {
  it('returns null for non-JSON input', () => {
    expect(prettyJsonDeep('not json at all')).toBeNull()
  })

  // The core bug: a tool result envelope whose `result` field embeds a
  // "Post created:\n{json}" string. JSON.stringify(parse(...)) alone re-escapes
  // the inner newlines to literal "\n"; prettyJsonDeep un-nests it instead.
  it('un-nests a double-encoded board_post result so no literal \\n remains', () => {
    const legacy = JSON.stringify({
      ok: true,
      result: 'Post created:\n{\n  "id": "p-240532",\n  "body": "hi"\n}',
    })
    const out = prettyJsonDeep(legacy)
    expect(out).not.toBeNull()
    // No literal backslash-n escape sequences survive in the rendered output.
    expect(out).not.toContain('\\n')
    // The inner post fields are now structurally addressable.
    expect(out).toContain('"id": "p-240532"')
    expect(out).toContain('"body": "hi"')
  })

  it('un-nests a field whose value is a "<prose>\\n{json}" string', () => {
    const out = prettyJsonDeep(JSON.stringify({ result: 'header\n{"n":1}' }))
    expect(out).not.toBeNull()
    expect(out).not.toContain('\\n')
    expect(out).toContain('"n": 1')
  })

  it('leaves plain string values untouched (no over-coercion)', () => {
    const out = prettyJsonDeep(JSON.stringify({ note: 'hello world' }))
    expect(out).toBe('{\n  "note": "hello world"\n}')
  })

  it('preserves legitimate JSON-text string values (no over-coercion)', () => {
    const out = prettyJsonDeep(JSON.stringify({ note: '{"x":1}' }))
    expect(out).toBe('{\n  "note": "{\\"x\\":1}"\n}')
  })
})
