// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Tabs, TabList, Tab, TabPanel } from './tabs'

describe('Tabs', () => {
  it('renders tablist and tabs', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a' },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
          h(Tab, { value: 'b' }, 'Tab B'),
        ),
      ),
      container,
    )
    expect(container.querySelector('[role="tablist"]')).not.toBeNull()
    expect(container.querySelectorAll('[role="tab"]').length).toBe(2)
  })

  it('uses cockpit tab defaults when no class override is provided', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a' },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
          h(Tab, { value: 'b' }, 'Tab B'),
        ),
      ),
      container,
    )
    const tablist = container.querySelector('[role="tablist"]')
    const tab = container.querySelector('[role="tab"]')
    expect(tablist?.classList.contains('bg-[var(--color-bg-panel-alt)]')).toBe(true)
    expect(tab?.classList.contains('aria-selected:bg-[var(--color-state-active-bg)]')).toBe(true)
    expect(tab?.classList.contains('aria-selected:shadow-[inset_0_-1px_0_var(--color-tab-indicator)]')).toBe(true)
  })

  it('keeps caller classes as explicit tab overrides', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a' },
        h(TabList, { class: 'custom-list' },
          h(Tab, { value: 'a', class: 'custom-tab' }, 'Tab A'),
        ),
      ),
      container,
    )
    expect(container.querySelector('[role="tablist"]')?.className).toBe('custom-list')
    expect(container.querySelector('[role="tab"]')?.className).toBe('custom-tab')
  })

  it('renders tabpanels', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a' },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
        ),
        h(TabPanel, { value: 'a' }, 'Panel A'),
      ),
      container,
    )
    expect(container.querySelector('[role="tabpanel"]')).not.toBeNull()
    expect(container.textContent).toContain('Panel A')
  })

  it('changes tab on click', async () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a' },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
          h(Tab, { value: 'b' }, 'Tab B'),
        ),
      ),
      container,
    )
    const tabs = container.querySelectorAll('[role="tab"]')
    ;(tabs[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(tabs[1]?.getAttribute('aria-selected')).toBe('true')
    expect(tabs[0]?.getAttribute('aria-selected')).toBe('false')
  })

  it('calls onValueChange on click', async () => {
    const onValueChange = vi.fn()
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a', onValueChange },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
          h(Tab, { value: 'b' }, 'Tab B'),
        ),
      ),
      container,
    )
    const tabs = container.querySelectorAll('[role="tab"]')
    ;(tabs[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onValueChange).toHaveBeenCalledWith('b')
  })

  it('applies aria-selected to active tab', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a' },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
          h(Tab, { value: 'b' }, 'Tab B'),
        ),
      ),
      container,
    )
    const tabs = container.querySelectorAll('[role="tab"]')
    expect(tabs[0]?.getAttribute('aria-selected')).toBe('true')
    expect(tabs[1]?.getAttribute('aria-selected')).toBe('false')
  })

  it('applies tabindex=0 to active tab and -1 to others', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'b' },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
          h(Tab, { value: 'b' }, 'Tab B'),
        ),
      ),
      container,
    )
    const tabs = container.querySelectorAll('[role="tab"]')
    expect(tabs[0]?.getAttribute('tabindex')).toBe('-1')
    expect(tabs[1]?.getAttribute('tabindex')).toBe('0')
  })

  it('hides inactive tabpanels', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a' },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
          h(Tab, { value: 'b' }, 'Tab B'),
        ),
        h(TabPanel, { value: 'a' }, 'Panel A'),
        h(TabPanel, { value: 'b' }, 'Panel B'),
      ),
      container,
    )
    const panels = container.querySelectorAll('[role="tabpanel"]')
    expect(panels[0]?.hasAttribute('hidden')).toBe(false)
    expect(panels[1]?.getAttribute('hidden')).not.toBeNull()
  })

  it('shows active tabpanel content', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a' },
        h(TabList, {},
          h(Tab, { value: 'a' }, 'Tab A'),
          h(Tab, { value: 'b' }, 'Tab B'),
        ),
        h(TabPanel, { value: 'a' }, 'Panel A'),
        h(TabPanel, { value: 'b' }, 'Panel B'),
      ),
      container,
    )
    expect(container.textContent).toContain('Panel A')
    expect(container.textContent).not.toContain('Panel B')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(
      h(Tabs, { defaultValue: 'a', class: 'my-tabs' },
        h(TabList, {}, h(Tab, { value: 'a' }, 'Tab A')),
      ),
      container,
    )
    const wrapper = container.querySelector('div')
    expect(wrapper?.classList.contains('my-tabs')).toBe(true)
  })
})
