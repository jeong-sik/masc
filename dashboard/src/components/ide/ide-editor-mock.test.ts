import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { IdeEditorMock } from './ide-editor-mock'

describe('IdeEditorMock', () => {
  it('renders the RFC 0019 ownership-backed editor mock', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('에디터 (RFC 0019 line ownership mock)')
    expect(container.textContent).toContain('ownership · 3 keepers')
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
})
