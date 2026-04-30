// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import type { MenuItemDescriptor } from '../headless-core/menu'
import { useMenu } from './use-menu'

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

const items: ReadonlyArray<MenuItemDescriptor> = [
  { id: 'open', kind: 'action', label: 'Open' },
  { id: 'save', kind: 'action', label: 'Save' },
  { id: 'sep', kind: 'separator' },
  { id: 'quit', kind: 'action', label: 'Quit' },
]

describe('useMenu', () => {
  it('starts closed', async () => {
    let captured!: ReturnType<typeof useMenu>
    function Probe(): unknown {
      captured = useMenu({ id: 'm1', items })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.isOpen).toBe(false)
  })

  it('open() flips isOpen and re-renders', async () => {
    let captured!: ReturnType<typeof useMenu>
    function Probe(): unknown {
      captured = useMenu({ id: 'm1', items })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    captured.open()
    await flushEffects()
    expect(captured.isOpen).toBe(true)
  })

  it('toggle flips state', async () => {
    let captured!: ReturnType<typeof useMenu>
    function Probe(): unknown {
      captured = useMenu({ id: 'm1', items })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    captured.toggle()
    await flushEffects()
    expect(captured.isOpen).toBe(true)
    captured.toggle()
    await flushEffects()
    expect(captured.isOpen).toBe(false)
  })

  it('getTriggerProps reports aria-haspopup=menu', async () => {
    let captured!: ReturnType<typeof useMenu>
    function Probe(): unknown {
      captured = useMenu({ id: 'm1', items })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.getTriggerProps()['aria-haspopup']).toBe('menu')
  })

  it('getMenuProps role=menu', async () => {
    let captured!: ReturnType<typeof useMenu>
    function Probe(): unknown {
      captured = useMenu({ id: 'm1', items })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.getMenuProps().role).toBe('menu')
  })

  it('select fires onSelect handler', async () => {
    const calls: ReadonlyArray<string>[] = []
    let captured!: ReturnType<typeof useMenu>
    function Probe(): unknown {
      captured = useMenu({
        id: 'm1',
        items,
        onSelect: (id, path) => calls.push([id, ...path]),
      })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    captured.open()
    captured.select('save')
    await flushEffects()
    expect(calls.length).toBe(1)
    expect(calls[0]![0]).toBe('save')
  })
})
