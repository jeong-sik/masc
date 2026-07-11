import { describe, expect, it, vi } from 'vitest'

vi.mock('../../api/ide', () => ({
  fetchIdeRegions: vi.fn().mockResolvedValue([]),
}))
import { fetchIdeRegions } from '../../api/ide'
import { createCodeDocumentStore } from './code-document-store'

const fetchIdeRegionsMock = vi.mocked(fetchIdeRegions)

describe('createCodeDocumentStore', () => {
  it('parses code content into stable one-indexed lines', () => {
    const store = createCodeDocumentStore({
      file_path: 'runtime/runtime/router.ts',
      language: 'typescript',
      content: 'const a = 1\r\n\r\nexport const b = 2\n',
    })

    expect(store.document().file_path).toBe('runtime/runtime/router.ts')
    expect(store.document().language).toBe('typescript')
    expect(store.lines()).toEqual([
      { num: 1, text: 'const a = 1', is_blank: false },
      { num: 2, text: '', is_blank: true },
      { num: 3, text: 'export const b = 2', is_blank: false },
    ])
    expect(store.line(3)?.text).toBe('export const b = 2')
    expect(store.line(4)).toBeNull()
  })

  it('rejects malformed document loads without replacing the current document', () => {
    const store = createCodeDocumentStore({
      file_path: 'a.ts',
      language: 'typescript',
      content: 'export {}',
    })

    expect(store.load({ file_path: '', language: 'typescript', content: 'oops' })).toBe(false)
    expect(store.load({ file_path: 'b.ts', language: 'typescript', content: 42 })).toBe(false)
    expect(store.document().file_path).toBe('a.ts')
  })

  it('bounds very large documents', () => {
    const store = createCodeDocumentStore({
      file_path: 'huge.ts',
      language: 'typescript',
      content: 'a\nb\nc',
    }, { maxLines: 2 })

    expect(store.lines().map(line => line.text)).toEqual(['a', 'b'])
  })

  it('notifies subscribers on successful loads', () => {
    const store = createCodeDocumentStore({
      file_path: 'a.ts',
      language: 'typescript',
      content: 'a',
    })
    let calls = 0
    const unsubscribe = store.subscribe(() => {
      calls += 1
    })

    store.load({ file_path: 'b.ts', language: 'typescript', content: 'b' })
    store.load({ file_path: '', language: 'typescript', content: 'ignored' })
    unsubscribe()
    store.load({ file_path: 'c.ts', language: 'typescript', content: 'c' })

    expect(calls).toBe(1)
  })

  it('forwards keeper and repo workspace params when loading regions', async () => {
    fetchIdeRegionsMock.mockResolvedValueOnce([])
    const store = createCodeDocumentStore({
      file_path: 'a.ts',
      language: 'typescript',
      content: 'export {}',
    })

    await store.loadRegions('a.ts', { keeper: 'sangsu', repoId: 'masc' })

    expect(fetchIdeRegionsMock).toHaveBeenCalledWith('a.ts', {
      keeper: 'sangsu',
      repoId: 'masc',
    })
  })

  it('notifies metadata subscribers as region loading settles', async () => {
    fetchIdeRegionsMock.mockResolvedValueOnce([])
    const store = createCodeDocumentStore({
      file_path: 'a.ts',
      language: 'typescript',
      content: 'export {}',
    })
    let calls = 0
    const unsubscribe = store.subscribeRegions(() => {
      calls += 1
    })

    await store.loadRegions('a.ts')

    unsubscribe()
    expect(calls).toBeGreaterThan(0)
    expect(store.regionsLoading()).toBe(false)
    expect(store.regionsState()).toBe('ready')
  })

  it('clears region metadata when a different file becomes active', async () => {
    fetchIdeRegionsMock.mockResolvedValueOnce([{
      file_path: 'a.ts',
      line_start: 1,
      line_end: 1,
      keeper_id: 'sangsu',
      source_type: 'tool_call',
      source_tool_name: 'tool_edit_file',
      source_turn: 1,
      source_note: null,
      timestamp_ms: 1,
    }])
    const store = createCodeDocumentStore({
      file_path: 'a.ts',
      language: 'typescript',
      content: 'export {}',
    })

    await store.loadRegions('a.ts')
    expect(store.regions()).toHaveLength(1)

    store.load({ file_path: 'b.ts', language: 'typescript', content: 'export {}' })
    expect(store.regions()).toEqual([])
    expect(store.regionsState()).toBe('idle')
  })

  it('exposes region fetch failure instead of presenting an empty result as ready', async () => {
    fetchIdeRegionsMock.mockRejectedValueOnce(new Error('regions offline'))
    const store = createCodeDocumentStore({
      file_path: 'a.ts',
      language: 'typescript',
      content: 'export {}',
    })

    await expect(store.loadRegions('a.ts')).rejects.toThrow('regions offline')

    expect(store.regionsState()).toBe('error')
    expect(store.regionsLoading()).toBe(false)
  })
})
