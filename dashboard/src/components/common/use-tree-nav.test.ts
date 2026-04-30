// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useTreeNav } from './use-tree-nav'
import type { TreeItem } from './use-tree-nav'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

const testItems: TreeItem[] = [
  { id: 'a', children: [{ id: 'a1' }, { id: 'a2' }] },
  { id: 'b' },
  { id: 'c', children: [{ id: 'c1' }] },
]

function TreeTester() {
  const { activeId, expandedIds, handleKeyDown, getTabIndex, toggleExpand } = useTreeNav({ items: testItems })
  return html`
    <div onKeyDown=${handleKeyDown} data-testid="tree">
      <div data-testid="item-a" data-active=${activeId === 'a' ? 'true' : 'false'} data-tabindex=${getTabIndex('a')} data-expanded=${expandedIds.has('a') ? 'true' : 'false'} onClick=${() => toggleExpand('a')}>a</div>
      <div data-testid="item-a1" data-active=${activeId === 'a1' ? 'true' : 'false'} data-tabindex=${getTabIndex('a1')}>a1</div>
      <div data-testid="item-b" data-active=${activeId === 'b' ? 'true' : 'false'} data-tabindex=${getTabIndex('b')}>b</div>
    </div>
  `
}

describe('useTreeNav', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('starts with first item active', async () => {
    render(html`<${TreeTester} />`, container)
    await tick()
    const a = container.querySelector('[data-testid="item-a"]') as HTMLElement
    expect(a.getAttribute('data-active')).toBe('true')
  })

  it('moves down with ArrowDown', async () => {
    render(html`<${TreeTester} />`, container)
    await tick()
    const tree = container.querySelector('[data-testid="tree"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowDown'
    tree.dispatchEvent(ev)
    await tick()
    const b = container.querySelector('[data-testid="item-b"]') as HTMLElement
    expect(b.getAttribute('data-active')).toBe('true')
  })

  it('expands with ArrowRight when item has children', async () => {
    render(html`<${TreeTester} />`, container)
    await tick()
    const tree = container.querySelector('[data-testid="tree"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowRight'
    tree.dispatchEvent(ev)
    await tick()
    const a = container.querySelector('[data-testid="item-a"]') as HTMLElement
    expect(a.getAttribute('data-expanded')).toBe('true')
  })

  it('collapses with ArrowLeft when expanded', async () => {
    render(html`<${TreeTester} />`, container)
    await tick()
    const tree = container.querySelector('[data-testid="tree"]') as HTMLElement
    // expand first
    const right = new Event('keydown', { bubbles: true }) as any
    right.key = 'ArrowRight'
    tree.dispatchEvent(right)
    await tick()
    // collapse
    const left = new Event('keydown', { bubbles: true }) as any
    left.key = 'ArrowLeft'
    tree.dispatchEvent(left)
    await tick()
    const a = container.querySelector('[data-testid="item-a"]') as HTMLElement
    expect(a.getAttribute('data-expanded')).toBe('false')
  })

  it('returns 0 tabindex for active item and -1 for others', async () => {
    render(html`<${TreeTester} />`, container)
    await tick()
    const a = container.querySelector('[data-testid="item-a"]') as HTMLElement
    const b = container.querySelector('[data-testid="item-b"]') as HTMLElement
    expect(a.getAttribute('data-tabindex')).toBe('0')
    expect(b.getAttribute('data-tabindex')).toBe('-1')
  })
})
