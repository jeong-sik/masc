// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { IdeEditorMock } from './ide-editor-mock'
import { createCodeDocumentStore } from './code-document-store'
import { createKeeperLineOwnershipStore } from './keeper-line-ownership-store'

function makeTestStores() {
  const documentStore = createCodeDocumentStore({
    file_path: 'test.ts',
    language: 'typescript',
    content: 'const x = 1\n',
  })
  const ownershipStore = createKeeperLineOwnershipStore('test.ts')
  const diffRows = () => []
  return { documentStore, ownershipStore, diffRows }
}

describe('IdeEditorMock a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders the code document and ownership-backed editor mock accessibly', async () => {
    const { documentStore, ownershipStore, diffRows } = makeTestStores()
    render(html`<${IdeEditorMock} documentStore=${documentStore} ownershipStore=${ownershipStore} diffRows=${diffRows} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
