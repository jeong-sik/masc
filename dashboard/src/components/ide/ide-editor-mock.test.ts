import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { IdeEditorMock } from './ide-editor-mock'

describe('IdeEditorMock', () => {
  it('renders the code document and RFC 0019 ownership-backed editor mock', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('에디터 (code document store + RFC 0019 ownership mock)')
    expect(container.textContent).toContain('runtime/cascade/router.ts')
    expect(container.textContent).toContain('typescript')
    expect(container.textContent).toContain('23 lines · ownership · 3 keepers')
    expect(container.textContent).toContain('nick0cave')
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('masc-improver')
  })

  it('leaves blank lines unowned', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {}), container)
    const rows = container.querySelectorAll('li')
    expect(rows[6]?.textContent).toContain('—')
    expect(rows[14]?.textContent).toContain('—')
  })

  it('upgrades editor text rows through the read-only shiki renderer', async () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {}), container)

    await waitFor(() => {
      expect(container.querySelector('.ide-code-line[data-syntax="shiki"]')).not.toBeNull()
    })
    expect(container.textContent).toContain("import { Provider, ProviderKind } from './provider'")
  })
})
