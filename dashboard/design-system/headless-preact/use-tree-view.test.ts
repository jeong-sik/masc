// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import type { TreeNode } from '../headless-core/tree-view'
import { useTreeView } from './use-tree-view'

function flushEffects(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 16))
}

let container: HTMLElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
})

afterEach(() => {
  render(null, container)
  container.remove()
})

const tree: ReadonlyArray<TreeNode<{ kind: string }>> = [
  { id: 'root', label: 'Root', parentId: null, hasChildren: true },
  { id: 'a', label: 'A', parentId: 'root', hasChildren: false, data: { kind: 'file' } },
  { id: 'b', label: 'B', parentId: 'root', hasChildren: true },
  { id: 'b1', label: 'B1', parentId: 'b', hasChildren: false, data: { kind: 'file' } },
]

describe('useTreeView', () => {
  it('initial visible reflects defaultExpanded', async () => {
    let captured!: ReturnType<typeof useTreeView>
    function Probe(): unknown {
      captured = useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root'],
      })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    const ids = captured.visible.map((n) => n.id)
    expect(ids).toContain('root')
    expect(ids).toContain('a')
    expect(ids).toContain('b')
    expect(ids).not.toContain('b1')
  })

  it('expand re-renders and includes children', async () => {
    let captured!: ReturnType<typeof useTreeView>
    function Probe(): unknown {
      captured = useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root'],
      })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    await captured.expand('b')
    await flushEffects()
    expect(captured.visible.map((n) => n.id)).toContain('b1')
  })

  it('select stores id in selected set', async () => {
    let captured!: ReturnType<typeof useTreeView>
    function Probe(): unknown {
      captured = useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root'],
      })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    captured.select('a')
    await flushEffects()
    expect(captured.selected.has('a')).toBe(true)
  })

  it('getRootProps returns role=tree', async () => {
    let captured!: ReturnType<typeof useTreeView>
    function Probe(): unknown {
      captured = useTreeView({ nodes: tree, selectionMode: 'single' })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.getRootProps().role).toBe('tree')
  })

  it('getAriaLevel reports depth', async () => {
    let captured!: ReturnType<typeof useTreeView>
    function Probe(): unknown {
      captured = useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root', 'b'],
      })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.getAriaLevel('root')).toBe(1)
    expect(captured.getAriaLevel('b')).toBe(2)
    expect(captured.getAriaLevel('b1')).toBe(3)
  })
})
