import { beforeEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { IdeEditorMock } from './ide-editor-mock'
import { activeIdeFile } from './ide-shell'

describe('IdeEditorMock', () => {
  beforeEach(() => {
    activeIdeFile.value = 'runtime/cascade/router.ts'
  })

  it('renders the code document region with file path and language', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toContain('에디터')
    expect(container.textContent).toContain('runtime/cascade/router.ts')
    expect(container.textContent).toContain('typescript')
  })

  it('shows 0 keepers when no blame data is available', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, {}), container)

    expect(container.textContent).toContain('0 keepers')
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
  })

  it('renders empty split diff body when no diff data is available', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, { activeView: 'split-diff' }), container)

    expect(container.querySelector('[aria-label="Split diff preview"]')).not.toBeNull()
    expect(container.textContent).toContain('BEFORE')
    expect(container.textContent).toContain('AFTER')
  })

  it('renders empty unified diff body when no diff data is available', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, { activeView: 'unified' }), container)

    expect(container.querySelector('[aria-label="Unified diff preview"]')).not.toBeNull()
    expect(container.textContent).toContain('SOURCE')
  })

  it('renders blame timeline metadata for the blame view', () => {
    const container = document.createElement('div')
    render(h(IdeEditorMock, { activeView: 'blame' }), container)

    expect(container.querySelector('[aria-label="Blame timeline"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="Blame editor view"]')).not.toBeNull()
    expect(container.textContent).toContain('Blame timeline')
    expect(container.textContent).toContain('no edits')
  })
})
