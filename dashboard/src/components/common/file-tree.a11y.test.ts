// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { FileTree } from './file-tree'

describe('FileTree a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeNodes = (): import('./file-tree').FileNode[] => [
    {
      id: 'root',
      name: 'src',
      type: 'directory',
      children: [
        { id: 'f1', name: 'main.ts', type: 'file', gitStatus: 'modified' },
        { id: 'f2', name: 'utils.ts', type: 'file', gitStatus: 'added' },
        {
          id: 'sub',
          name: 'components',
          type: 'directory',
          children: [{ id: 'f3', name: 'button.ts', type: 'file', gitStatus: 'deleted' }],
        },
      ],
    },
    { id: 'f4', name: 'README.md', type: 'file' },
  ]

  it('renders accessibly with nodes', async () => {
    render(
      html`<${FileTree} nodes=${makeNodes()} expandedIds=${['root']} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty nodes', async () => {
    render(html`<${FileTree} nodes=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly without expanded', async () => {
    render(html`<${FileTree} nodes=${makeNodes()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has tree role', () => {
    render(html`<${FileTree} nodes=${makeNodes()} />`, container)
    expect(container.querySelector('[role="tree"]')).not.toBeNull()
  })

  it('has treeitem roles', () => {
    render(html`<${FileTree} nodes=${makeNodes()} />`, container)
    const items = container.querySelectorAll('[role="treeitem"]')
    expect(items.length).toBeGreaterThan(0)
  })

  it('renders file names', () => {
    render(html`<${FileTree} nodes=${makeNodes()} expandedIds=${['root', 'sub']} />`, container)
    expect(container.textContent).toContain('main.ts')
    expect(container.textContent).toContain('utils.ts')
    expect(container.textContent).toContain('button.ts')
    expect(container.textContent).toContain('README.md')
  })

  it('shows directory expand indicators', () => {
    render(html`<${FileTree} nodes=${makeNodes()} expandedIds=${['root']} />`, container)
    expect(container.textContent).toContain('▼')
    expect(container.textContent).toContain('▶')
  })
})
