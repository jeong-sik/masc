import { describe, expect, it } from 'vitest'

import {
  filterTools,
  toolMatchesCategory,
  toolMatchesSearch,
} from './tool-metrics'

// Minimal shape accepted by the pure helpers. Mirrors ToolMetricsTopEntry's
// `name` field — extra `call_count` retained so tests look like real data.
interface TestTool {
  name: string
  call_count: number
}

// Names chosen so each one maps to a distinct category label via
// tool-call-shared.toolCategory(). toolCategory matchers use lowercase
// substring checks (e.g. n.includes('edit')), so names here are lowercase.
//   - bash_exec      -> 'shell'
//   - github_...     -> 'git'
//   - edit_file      -> 'edit'
//   - fs_read_file   -> 'file'
//   - board_post     -> 'board'
//   - search_symbols -> 'search'
//   - web_fetch      -> 'web'
//   - masc_task_...  -> 'coord'
//   - memory_recall  -> 'memory'
const sample: TestTool[] = [
  { name: 'bash_exec', call_count: 120 },
  { name: 'github_create_pr', call_count: 60 },
  { name: 'edit_file', call_count: 55 },
  { name: 'fs_read_file', call_count: 40 },
  { name: 'board_post', call_count: 32 },
  { name: 'search_symbols', call_count: 25 },
  { name: 'web_fetch', call_count: 18 },
  { name: 'masc_task_claim', call_count: 12 },
  { name: 'memory_recall', call_count: 8 },
]

describe('toolMatchesSearch', () => {
  const item = sample[0]!

  it('returns true for empty or whitespace-only query', () => {
    expect(toolMatchesSearch(item, '')).toBe(true)
    expect(toolMatchesSearch(item, '   ')).toBe(true)
  })

  it('matches substring in name (case-insensitive)', () => {
    expect(toolMatchesSearch(item, 'bash')).toBe(true)
    expect(toolMatchesSearch(item, 'BASH')).toBe(true)
    expect(toolMatchesSearch(item, 'exec')).toBe(true)
  })

  it('returns false when the substring is absent', () => {
    expect(toolMatchesSearch(item, 'github')).toBe(false)
  })

  it('ignores leading/trailing whitespace in the query', () => {
    expect(toolMatchesSearch(item, '  bash  ')).toBe(true)
  })
})

describe('toolMatchesCategory', () => {
  it("accepts any item when category is 'all'", () => {
    for (const item of sample) {
      expect(toolMatchesCategory(item, 'all')).toBe(true)
    }
  })

  it('matches the shell category for bash_exec', () => {
    expect(toolMatchesCategory({ name: 'bash_exec' }, 'shell')).toBe(true)
    expect(toolMatchesCategory({ name: 'bash_exec' }, 'git')).toBe(false)
  })

  it('matches the git category for github_ tools', () => {
    expect(toolMatchesCategory({ name: 'github_create_pr' }, 'git')).toBe(true)
    expect(toolMatchesCategory({ name: 'github_create_pr' }, 'edit')).toBe(false)
  })

  it('matches the file category for fs_read_ tools', () => {
    expect(toolMatchesCategory({ name: 'fs_read_file' }, 'file')).toBe(true)
  })

  it('returns false when the category label does not match', () => {
    expect(toolMatchesCategory({ name: 'edit_file' }, 'search')).toBe(false)
  })
})

describe('filterTools', () => {
  it("returns the original list when query is empty and category is 'all'", () => {
    const out = filterTools(sample, '', 'all')
    expect(out).toBe(sample) // same reference, no allocation
  })

  it("returns the original list when query is whitespace and category is 'all'", () => {
    const out = filterTools(sample, '   ', 'all')
    expect(out).toBe(sample)
  })

  it('narrows by search query only', () => {
    const out = filterTools(sample, 'board', 'all')
    expect(out.map((t) => t.name)).toEqual(['board_post'])
  })

  it('narrows by category only', () => {
    const out = filterTools(sample, '', 'git')
    expect(out.map((t) => t.name)).toEqual(['github_create_pr'])
  })

  it('applies both search and category as AND', () => {
    // 'file' matches edit_file and fs_read_file, but only edit_file is in
    // the 'edit' category (fs_read_file falls into 'file').
    const out = filterTools(sample, 'file', 'edit')
    expect(out.map((t) => t.name)).toEqual(['edit_file'])
  })

  it('returns empty array when no item matches', () => {
    const out = filterTools(sample, 'zzz_no_such_tool', 'all')
    expect(out).toEqual([])
  })

  it('returns empty array when category has no members in the input', () => {
    // 'voice' category label exists in tool-call-shared but no sample item
    // has 'voice' in its name.
    const out = filterTools(sample, '', 'voice')
    expect(out).toEqual([])
  })
})
