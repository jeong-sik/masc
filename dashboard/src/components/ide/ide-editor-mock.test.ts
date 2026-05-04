import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { IdeEditorMock } from './ide-editor-mock'
import { IDE_MOCK_RELATED_LINE } from './ide-mock-data'

describe('IdeEditorMock', () => {
  it('renders the code document and RFC 0019 ownership-backed editor mock', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('에디터 (code document store + RFC 0019 ownership mock)')
    expect(container.textContent).toContain('package.json')
    expect(container.textContent).toContain('typescript')
    expect(container.textContent).toContain('23 lines · ownership · 3 keepers')
    expect(container.textContent).toContain('nick0cave')
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('masc-improver')
  })

  it('renders active view and layer affordances from shell state', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {
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
    expect(container.textContent).toContain('tool')
    expect(container.textContent).toContain('approve')
    expect(container.textContent).toContain('note')
  })

  it('renders line overlay chips from shared anchored annotation seed data', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {
      activeLayers: new Set(['tools', 'approve', 'notes']),
    }), container)

    const overlayLabels = Array.from(container.querySelectorAll('[aria-label]'))
      .map(node => node.getAttribute('aria-label'))
    expect(overlayLabels).toContain(`line ${IDE_MOCK_RELATED_LINE} active overlays: tool`)
    expect(overlayLabels).toContain('line 17 active overlays: note')
    expect(overlayLabels).toContain('line 20 active overlays: approve')
  })

  it('renders a split diff body for the split-diff view', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, { activeView: 'split-diff' }), container)

    expect(container.querySelector('[aria-label="Split diff preview"]')).not.toBeNull()
    expect(container.textContent).toContain('BEFORE')
    expect(container.textContent).toContain('AFTER')
    expect(container.textContent).toContain('if (req.tools === undefined)')
    expect(container.textContent).toContain('strip empty tools array')
    expect(container.textContent).toContain('return rest as CascadeReq')
  })

  it('renders a unified diff body for the unified view', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, { activeView: 'unified' }), container)

    expect(container.querySelector('[aria-label="Unified diff preview"]')).not.toBeNull()
    expect(container.textContent).toContain('UNIFIED')
    expect(container.textContent).toContain('if (req.tools === undefined)')
    expect(container.textContent).toContain('const { tools, tool_choice, ...rest } = req')
  })

  it('renders blame timeline metadata for the blame view', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, { activeView: 'blame' }), container)

    expect(container.querySelector('[aria-label="Blame timeline"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="Blame editor view"]')).not.toBeNull()
    expect(container.textContent).toContain('Blame timeline')
    expect(container.textContent).toContain('latest 12:33')
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
