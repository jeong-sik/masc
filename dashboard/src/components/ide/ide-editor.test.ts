import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { currentFileFindMatches, IdeEditor } from './ide-editor'
import { createCodeDocumentStore } from './code-document-store'
import { createKeeperLineOwnershipStore } from './keeper-line-ownership-store'

describe('IdeEditor', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
  })

  afterEach(() => {
    render(null, container)
  })

  it('syncs CodeMirror when file content loads after initial mount', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'package.json',
      language: 'json',
      content: '',
    })
    const ownershipStore = createKeeperLineOwnershipStore('package.json')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
      }),
      container,
    )

    await waitFor(() => {
      expect(container.querySelector('.cm-content')).not.toBeNull()
    })
    expect(container.querySelector('.cm-lineNumbers')).not.toBeNull()
    expect(container.querySelector('.cm-content')?.textContent).toBe('')

    documentStore.load({
      file_path: 'package.json',
      language: 'json',
      content: '{\n  "name": "masc-mcp"\n}\n',
    })

    await waitFor(() => {
      expect(container.textContent).toContain('3 lines')
      expect(container.querySelector('.cm-content')?.textContent).toContain('masc-mcp')
    })
  })

  it('finds current-file matches with case and whole-word options', () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst RuntimeValue = runtime + 1\n',
    })

    expect(
      currentFileFindMatches(
        documentStore.lines(),
        'runtime',
        { caseSensitive: false, wholeWord: false },
      ).map(match => match.line),
    ).toEqual([1, 2])

    expect(
      currentFileFindMatches(
        documentStore.lines(),
        'runtime',
        { caseSensitive: true, wholeWord: false },
      ).map(match => match.line),
    ).toEqual([1, 2])

    expect(
      currentFileFindMatches(
        documentStore.lines(),
        'Runtime',
        { caseSensitive: true, wholeWord: false },
      ).map(match => match.line),
    ).toEqual([2])

    expect(
      currentFileFindMatches(
        documentStore.lines(),
        'runtime',
        { caseSensitive: false, wholeWord: true },
      ).map(match => match.line),
    ).toEqual([1, 2])
  })

  it('renders the current-file find panel and cycles matches', async () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\nconst other = 2\nreturn runtime\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        findOpen: true,
      }),
      container,
    )

    const input = container.querySelector<HTMLInputElement>('[aria-label="Find query"]')
    expect(input).not.toBeNull()
    fireEvent.input(input!, { target: { value: 'runtime' } })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="ide-find-status"]')?.textContent)
        .toContain('1 of 2 matches')
    })
    expect(container.querySelector('[data-testid="ide-find-results"]')?.textContent)
      .toContain('return runtime')

    const next = container.querySelector<HTMLButtonElement>('[aria-label="Next match"]')
    expect(next).not.toBeNull()
    fireEvent.click(next!)

    await waitFor(() => {
      expect(container.querySelector('[data-testid="ide-find-status"]')?.textContent)
        .toContain('2 of 2 matches')
    })
  })

  it('includes keeper trace in active layer summary and count', () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        activeLayers: new Set(['time', 'keeper-trace']),
      }),
      container,
    )

    expect(container.textContent).toContain('2 layers')
    expect(container.querySelector('[aria-label="Active IDE overlays"]')?.textContent)
      .toContain('Trace')
  })

  it('counts loaded annotations in the notes overlay summary', () => {
    const documentStore = createCodeDocumentStore({
      file_path: 'runtime.ts',
      language: 'typescript',
      content: 'const runtime = 1\n',
    })
    const ownershipStore = createKeeperLineOwnershipStore('runtime.ts')

    render(
      h(IdeEditor, {
        documentStore,
        ownershipStore,
        diffRows: () => [],
        activeLayers: new Set(['notes']),
        annotations: [{
          id: 'ann-1',
          file_path: 'runtime.ts',
          line_start: 1,
          line_end: 1,
          keeper_id: 'sangsu',
          kind: 'Comment',
          content: 'Keep this task linked to the line',
          goal_id: 'goal-1',
          task_id: 'task-1',
          created_at_ms: 1,
          updated_at_ms: 1,
        }],
      }),
      container,
    )

    expect(container.querySelector('[aria-label="Active IDE overlays"]')?.textContent)
      .toContain('1 note')
  })
})
