import { describe, expect, it, vi } from 'vitest'

vi.mock('../../api/ide', () => ({
  fetchIdeRegions: vi.fn().mockResolvedValue([]),
}))
import { createCodeDocumentStore } from './code-document-store'

describe('createCodeDocumentStore', () => {
  it('parses code content into stable one-indexed lines', () => {
    const store = createCodeDocumentStore({
      file_path: 'runtime/cascade/router.ts',
      language: 'typescript',
      content: 'const a = 1\r\n\r\nexport const b = 2\n',
    })

    expect(store.document().file_path).toBe('runtime/cascade/router.ts')
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
})
