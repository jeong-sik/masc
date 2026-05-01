// @ts-nocheck
// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useGridNav } from './use-grid-nav'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function GridTester({ wrap }: { wrap?: boolean }) {
  const { activeRow, activeCol, handleKeyDown, getTabIndex } = useGridNav({ rowCount: 3, colCount: 3, wrap })
  const cells = []
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      cells.push(html`<div key="${r}-${c}" data-row=${r} data-col=${c} data-active=${r === activeRow && c === activeCol ? 'true' : 'false'} data-tabindex=${getTabIndex(r, c)} data-testid="cell" />`)
    }
  }
  return html`
    <div onKeyDown=${handleKeyDown} data-testid="grid">
      ${cells}
    </div>
  `
}

describe('useGridNav', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('starts at row 0 col 0', async () => {
    render(html`<${GridTester} />`, container)
    await tick()
    const active = container.querySelector('[data-active="true"]') as HTMLElement
    expect(active.getAttribute('data-row')).toBe('0')
    expect(active.getAttribute('data-col')).toBe('0')
  })

  it('moves right with ArrowRight', async () => {
    render(html`<${GridTester} />`, container)
    await tick()
    const grid = container.querySelector('[data-testid="grid"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowRight'
    grid.dispatchEvent(ev)
    await tick()
    const active = container.querySelector('[data-active="true"]') as HTMLElement
    expect(active.getAttribute('data-col')).toBe('1')
  })

  it('moves down with ArrowDown', async () => {
    render(html`<${GridTester} />`, container)
    await tick()
    const grid = container.querySelector('[data-testid="grid"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'ArrowDown'
    grid.dispatchEvent(ev)
    await tick()
    const active = container.querySelector('[data-active="true"]') as HTMLElement
    expect(active.getAttribute('data-row')).toBe('1')
  })

  it('stops at boundary without wrap', async () => {
    render(html`<${GridTester} />`, container)
    await tick()
    const grid = container.querySelector('[data-testid="grid"]') as HTMLElement
    for (let i = 0; i < 5; i++) {
      const ev = new Event('keydown', { bubbles: true }) as any
      ev.key = 'ArrowRight'
      grid.dispatchEvent(ev)
    }
    await tick()
    const active = container.querySelector('[data-active="true"]') as HTMLElement
    expect(active.getAttribute('data-col')).toBe('2')
  })

  it('wraps with wrap=true', async () => {
    render(html`<${GridTester} wrap=${true} />`, container)
    await tick()
    const grid = container.querySelector('[data-testid="grid"]') as HTMLElement
    // move right 3 times from 0,0 -> should wrap to 0,0
    for (let i = 0; i < 3; i++) {
      const ev = new Event('keydown', { bubbles: true }) as any
      ev.key = 'ArrowRight'
      grid.dispatchEvent(ev)
    }
    await tick()
    const active = container.querySelector('[data-active="true"]') as HTMLElement
    expect(active.getAttribute('data-col')).toBe('0')
  })

  it('jumps to start with Home', async () => {
    render(html`<${GridTester} />`, container)
    await tick()
    const grid = container.querySelector('[data-testid="grid"]') as HTMLElement
    const down = new Event('keydown', { bubbles: true }) as any
    down.key = 'ArrowDown'
    grid.dispatchEvent(down)
    await tick()
    const home = new Event('keydown', { bubbles: true }) as any
    home.key = 'Home'
    grid.dispatchEvent(home)
    await tick()
    const active = container.querySelector('[data-active="true"]') as HTMLElement
    expect(active.getAttribute('data-col')).toBe('0')
  })

  it('jumps to end with Ctrl+End', async () => {
    render(html`<${GridTester} />`, container)
    await tick()
    const grid = container.querySelector('[data-testid="grid"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'End'
    ev.ctrlKey = true
    grid.dispatchEvent(ev)
    await tick()
    const active = container.querySelector('[data-active="true"]') as HTMLElement
    expect(active.getAttribute('data-row')).toBe('2')
    expect(active.getAttribute('data-col')).toBe('2')
  })

  it('returns 0 tabindex for active cell and -1 for others', async () => {
    render(html`<${GridTester} />`, container)
    await tick()
    const cells = container.querySelectorAll('[data-testid="cell"]')
    expect(cells[0].getAttribute('data-tabindex')).toBe('0')
    expect(cells[1].getAttribute('data-tabindex')).toBe('-1')
  })
})
