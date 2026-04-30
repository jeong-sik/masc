// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import type { ToolbarItem } from '../headless-core/toolbar'
import { useToolbar } from './use-toolbar'

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

const items: ReadonlyArray<ToolbarItem> = [
  { id: 'save', kind: 'button', label: 'Save' },
  { id: 'bold', kind: 'toggle', label: 'Bold', pressed: false },
  { id: 'sep', kind: 'separator' },
  { id: 'left', kind: 'radio', label: 'Left', checked: true, radioGroup: 'align' },
  { id: 'right', kind: 'radio', label: 'Right', checked: false, radioGroup: 'align' },
]

describe('useToolbar', () => {
  it('exposes visibleItems matching input', async () => {
    let captured!: ReturnType<typeof useToolbar>
    function Probe(): unknown {
      captured = useToolbar({ items, ariaLabel: 'Test' })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.visibleItems.length).toBe(items.length)
    expect(captured.hasOverflow).toBe(false)
  })

  it('toggle flips pressed', async () => {
    let captured!: ReturnType<typeof useToolbar>
    function Probe(): unknown {
      captured = useToolbar({ items, ariaLabel: 'Test' })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    captured.toggle('bold')
    await flushEffects()
    const props = captured.getItemProps('bold')
    expect(props['aria-pressed']).toBe(true)
  })

  it('selectRadio enforces single-select within group', async () => {
    let captured!: ReturnType<typeof useToolbar>
    function Probe(): unknown {
      captured = useToolbar({ items, ariaLabel: 'Test' })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    captured.selectRadio('right')
    await flushEffects()
    expect(captured.getItemProps('right')['aria-checked']).toBe(true)
    expect(captured.getItemProps('left')['aria-checked']).toBe(false)
  })

  it('overflow menu trigger reports aria-expanded', async () => {
    let captured!: ReturnType<typeof useToolbar>
    function Probe(): unknown {
      captured = useToolbar({ items, ariaLabel: 'Test' })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.getOverflowMenuTriggerProps()['aria-expanded']).toBe(false)
    captured.openOverflowMenu()
    await flushEffects()
    expect(captured.getOverflowMenuTriggerProps()['aria-expanded']).toBe(true)
  })

  it('getRootProps returns role=toolbar', async () => {
    let captured!: ReturnType<typeof useToolbar>
    function Probe(): unknown {
      captured = useToolbar({ items, ariaLabel: 'Test' })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.getRootProps().role).toBe('toolbar')
    expect(captured.getRootProps()['aria-label']).toBe('Test')
  })

  it('explicit containerSize narrows visibleItems via overflowAt', async () => {
    let captured!: ReturnType<typeof useToolbar>
    function Probe(): unknown {
      captured = useToolbar({ items, ariaLabel: 'Test', overflowAt: 2 })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.visibleItems.length).toBe(2)
    expect(captured.overflowItems.length).toBeGreaterThan(0)
    expect(captured.hasOverflow).toBe(true)
  })
})
