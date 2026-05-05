import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { IdeEditor } from './ide-editor'
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
})
