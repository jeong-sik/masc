import { describe, it, expect } from 'vitest'
import { EditorState, type Extension } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import {
  readOnlyExt,
  themeExt,
  languageExt,
  lineNumberExt,
  syntaxHighlightExt,
  blameExtensions,
  pushOwnership,
  setOwnership,
} from './ide-editor-extensions'
import type { LineOwnership } from './keeper-line-ownership-store'

function createTestView(extensions: Extension[], doc = 'hello\nworld\n') {
  const container = document.createElement('div')
  document.body.appendChild(container)
  const state = EditorState.create({ doc, extensions })
  const view = new EditorView({ state, parent: container })
  return { view, container }
}

describe('readOnlyExt', () => {
  it('blocks all changes', () => {
    const { view } = createTestView([readOnlyExt()])
    const len = view.state.doc.length
    view.dispatch({ changes: { from: 0, to: len, insert: 'changed' } })
    expect(view.state.doc.toString()).toBe('hello\nworld\n')
    view.destroy()
  })
})

describe('themeExt', () => {
  it('returns a non-empty extension', () => {
    const ext = themeExt()
    expect(ext).toBeDefined()
    const { view, container } = createTestView([ext])
    expect(view.dom).toBeInstanceOf(HTMLElement)
    view.destroy()
    container.remove()
  })
})

describe('lineNumberExt + syntaxHighlightExt', () => {
  it('renders line numbers and syntax highlight spans', async () => {
    const lang = await languageExt('index.ts')
    const { view, container } = createTestView([
      themeExt(),
      lineNumberExt(),
      syntaxHighlightExt(),
      lang,
    ], 'const answer = 42\n')

    expect(container.querySelector('.cm-lineNumbers')).not.toBeNull()
    expect(container.querySelectorAll('.cm-lineNumbers .cm-gutterElement').length).toBeGreaterThan(0)
    expect(container.querySelector('.cm-line span')).not.toBeNull()

    view.destroy()
    container.remove()
  })
})

describe('languageExt', () => {
  it('returns empty extension for unknown file types', async () => {
    const ext = await languageExt('readme.xyz')
    expect(ext).toEqual([])
  })

  it('returns a language extension for .ts files', async () => {
    const ext = await languageExt('index.ts')
    expect(Array.isArray(ext) ? ext.length : ext).toBeDefined()
  })

  it('returns a language extension for .py files', async () => {
    const ext = await languageExt('main.py')
    expect(ext).toBeDefined()
  })

  it('returns a language extension for .json files', async () => {
    const ext = await languageExt('package.json')
    expect(ext).toBeDefined()
  })
})

describe('blameExtensions', () => {
  it('returns an array of extensions', () => {
    const exts = blameExtensions()
    expect(Array.isArray(exts)).toBe(true)
    expect(exts.length).toBeGreaterThan(0)
  })
})

describe('pushOwnership + setOwnership effect', () => {
  it('dispatches ownership data without error', () => {
    const exts = [readOnlyExt(), ...blameExtensions()]
    const { view, container } = createTestView(exts)

    const ownership = new Map([
      [1, { keeper_id: 'alpha', hue_index: 1, last_edit_kind: 'edit', last_edit_ms: Date.now() }],
      [2, { keeper_id: 'beta', hue_index: 2, last_edit_kind: 'create', last_edit_ms: Date.now() }],
    ]) as ReadonlyMap<number, LineOwnership>

    expect(() => pushOwnership(view, ownership)).not.toThrow()
    expect(view.state.doc.toString()).toBe('hello\nworld\n')

    view.destroy()
    container.remove()
  })

  it('renders keeper sigil and name markers in the blame gutter', () => {
    const exts = [themeExt(), readOnlyExt(), ...blameExtensions()]
    const { view, container } = createTestView(exts)

    const ownership = new Map([
      [1, { keeper_id: 'alpha-keeper', hue_index: 3, last_edit_kind: 'edit', last_edit_ms: 1000 }],
    ]) as ReadonlyMap<number, LineOwnership>

    pushOwnership(view, ownership)

    expect(container.querySelector('.cm-blame-marker')).not.toBeNull()
    expect(container.querySelector('.cm-blame-sigil')?.textContent).toBe('AK')
    expect(container.querySelector('.cm-blame-name')?.textContent).toBe('alpha-keeper')

    view.destroy()
    container.remove()
  })

  it('setOwnership effect carries the ownership map', () => {
    const ownership = new Map([
      [1, { keeper_id: 'gamma', hue_index: 2, last_edit_kind: 'edit', last_edit_ms: 1000 }],
    ]) as ReadonlyMap<number, LineOwnership>
    const effect = (setOwnership as any).of(ownership)
    expect((effect as any).is(setOwnership)).toBe(true)
    expect((effect as any).value).toBe(ownership)
    expect((effect as any).value.get(1)?.keeper_id).toBe('gamma')
  })
})
