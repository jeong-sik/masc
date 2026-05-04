import { beforeEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { IdeEditorMock } from './ide-editor-mock'
import { activeIdeFile } from './ide-shell'
import { createCodeDocumentStore } from './code-document-store'
import { createKeeperLineOwnershipStore } from './keeper-line-ownership-store'

function makeTestStores() {
  const documentStore = createCodeDocumentStore({
    file_path: 'runtime/cascade/router.ts',
    language: 'typescript',
    content: 'const x = 1\nexport { x }\n',
  })
  const ownershipStore = createKeeperLineOwnershipStore('runtime/cascade/router.ts')
  const diffRows = () => []
  return { documentStore, ownershipStore, diffRows }
}

describe('IdeEditorMock', () => {
  beforeEach(() => {
    activeIdeFile.value = 'runtime/cascade/router.ts'
  })

  it('renders the code document region with file path and language', () => {
    const { documentStore, ownershipStore, diffRows } = makeTestStores()
    const container = document.createElement('div')
    render(h(IdeEditorMock, { documentStore, ownershipStore, diffRows }), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toContain('에디터')
    expect(container.textContent).toContain('runtime/cascade/router.ts')
    expect(container.textContent).toContain('typescript')
  })

  it('shows 0 keepers when no blame data is available', () => {
    const { documentStore, ownershipStore, diffRows } = makeTestStores()
    const container = document.createElement('div')
    render(h(IdeEditorMock, { documentStore, ownershipStore, diffRows }), container)

    expect(container.textContent).toContain('0 keepers')
  })

  it('renders active view and layer affordances from shell state', () => {
    const { documentStore, ownershipStore, diffRows } = makeTestStores()
    const container = document.createElement('div')
    render(h(IdeEditorMock, {
      documentStore,
      ownershipStore,
      diffRows,
      activeView: 'blame',
      activeLayers: new Set(['time', 'parallel', 'tools', 'approve', 'notes']),
    }), container)

    expect(container.textContent).toContain('BLAME')
    expect(container.textContent).toContain('5 layers')
    expect(container.textContent).toContain('Active overlays')
    expect(container.textContent).toContain('Time')
    expect(container.textContent).toContain('Parallel')
    expect(container.textContent).toContain('Tools')
    expect(container.textContent).toContain('Approve')
    expect(container.textContent).toContain('Notes')
  })

  it('renders empty split diff body when no diff data is available', () => {
    const { documentStore, ownershipStore, diffRows } = makeTestStores()
    const container = document.createElement('div')
    render(h(IdeEditorMock, { documentStore, ownershipStore, diffRows, activeView: 'split-diff' }), container)

    expect(container.querySelector('[aria-label="Split diff preview"]')).not.toBeNull()
    expect(container.textContent).toContain('BEFORE')
    expect(container.textContent).toContain('AFTER')
  })

  it('renders empty unified diff body when no diff data is available', () => {
    const { documentStore, ownershipStore, diffRows } = makeTestStores()
    const container = document.createElement('div')
    render(h(IdeEditorMock, { documentStore, ownershipStore, diffRows, activeView: 'unified' }), container)

    expect(container.querySelector('[aria-label="Unified diff preview"]')).not.toBeNull()
    expect(container.textContent).toContain('UNIFIED')
  })

  it('renders blame timeline metadata for the blame view', () => {
    const { documentStore, ownershipStore, diffRows } = makeTestStores()
    const container = document.createElement('div')
    render(h(IdeEditorMock, { documentStore, ownershipStore, diffRows, activeView: 'blame' }), container)

    expect(container.querySelector('[aria-label="Blame timeline"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="Blame editor view"]')).not.toBeNull()
    expect(container.textContent).toContain('Blame timeline')
    expect(container.textContent).toContain('no edits')
  })
})
