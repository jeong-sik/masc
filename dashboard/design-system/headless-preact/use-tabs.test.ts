// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import type { TabDescriptor } from '../headless-core/tabs'
import { useTabs } from './use-tabs'

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

const tabsFixture: ReadonlyArray<TabDescriptor> = [
  { id: 't1', label: 'One' },
  { id: 't2', label: 'Two' },
  { id: 't3', label: 'Three' },
]

describe('useTabs', () => {
  it('exposes initial activeId from defaultActiveId', async () => {
    let captured!: ReturnType<typeof useTabs>
    function Probe(): unknown {
      captured = useTabs({ tabs: tabsFixture, defaultActiveId: 't2' })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.activeId).toBe('t2')
  })

  it('re-renders on activate', async () => {
    let captured!: ReturnType<typeof useTabs>
    function Probe(): unknown {
      captured = useTabs({ tabs: tabsFixture })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    captured.activate('t3')
    await flushEffects()
    expect(captured.activeId).toBe('t3')
  })

  it('exposes tabs snapshot from controller', async () => {
    let captured!: ReturnType<typeof useTabs>
    function Probe(): unknown {
      captured = useTabs({ tabs: tabsFixture })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.tabs.map((t) => t.id)).toEqual(['t1', 't2', 't3'])
  })

  it('close() removes a tab', async () => {
    let captured!: ReturnType<typeof useTabs>
    function Probe(): unknown {
      captured = useTabs({ tabs: tabsFixture })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    captured.close('t2')
    await flushEffects()
    expect(captured.tabs.map((t) => t.id)).toEqual(['t1', 't3'])
  })

  it('getTabListProps returns role=tablist', async () => {
    let captured!: ReturnType<typeof useTabs>
    function Probe(): unknown {
      captured = useTabs({ tabs: tabsFixture })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.getTabListProps().role).toBe('tablist')
  })

  it('getTabProps returns role=tab with aria-selected', async () => {
    let captured!: ReturnType<typeof useTabs>
    function Probe(): unknown {
      captured = useTabs({ tabs: tabsFixture, defaultActiveId: 't1' })
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    const props = captured.getTabProps('t1')
    expect(props.role).toBe('tab')
    expect(props['aria-selected']).toBe(true)
  })
})
