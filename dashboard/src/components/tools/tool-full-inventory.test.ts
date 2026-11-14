// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, h } from 'preact'
import type { DashboardToolInventoryItem } from '../../api'
import { FullInventoryView } from './tool-full-inventory'
import { showBackToTop } from './tool-state'

function makeItem(index: number): DashboardToolInventoryItem {
  return {
    name: `tool_${index}`,
    description: '',
    category: 'test',
    visibility: 'public',
    lifecycle: 'stable',
    implementationStatus: 'complete',
    direct_call_allowed: true,
    required_permission: null,
    canonicalName: null,
    replacement: null,
    reason: null,
    doc_refs: [],
    prompt_hints: [],
    surfaces: [],
    tier: 'core',
  }
}

describe('FullInventoryView tool list', () => {
  const ROW_PX = 180
  const BOX_PX = 600
  const inventory = Array.from({ length: 120 }, (_, index) => makeItem(index))
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    showBackToTop.value = false
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  /** Gives the scroll box and the list inside it the geometry a browser would:
   *  the box is BOX_PX tall and has scrolled the list up by `scrollTop`. */
  async function mountScrolled() {
    render(h(FullInventoryView, { inventory, loading: false, error: null }), container)
    const box = container.querySelector('.overflow-y-auto') as HTMLElement
    const list = await vi.waitFor(() => {
      const spacer = box.querySelector('.virtual-list-spacer')
      expect(spacer).not.toBeNull()
      return spacer?.parentElement as HTMLElement
    })
    Object.defineProperty(box, 'clientHeight', { value: BOX_PX, configurable: true })
    box.getBoundingClientRect = () => new DOMRect(0, 0, 800, BOX_PX)
    list.getBoundingClientRect = () => new DOMRect(0, -box.scrollTop, 800, inventory.length * ROW_PX)
    const scrollTo = (top: number) => {
      box.scrollTop = top
      box.dispatchEvent(new Event('scroll'))
    }
    return { box, scrollTo }
  }

  it('draws the tools at the scroll position of its scroll box, not every tool', async () => {
    const { scrollTo } = await mountScrolled()
    // The scroll listeners attach in a passive effect, so the scroll is sent
    // again until one of them has heard it.
    await vi.waitFor(() => {
      scrollTo(100 * ROW_PX)
      expect(container.querySelector('[data-vl-key="tool_100"]')).not.toBeNull()
    })
    expect(container.querySelector('[data-vl-key="tool_0"]')).toBeNull()
    expect(container.querySelectorAll('article').length).toBeLessThan(inventory.length / 2)
  })

  it('shows the back-to-top button once that scroll box has scrolled, and scrolls it back', async () => {
    const { box, scrollTo } = await mountScrolled()
    const button = container.querySelector('.tool-back-to-top') as HTMLButtonElement
    expect(button.classList.contains('visible')).toBe(false)
    await vi.waitFor(() => {
      scrollTo(600)
      expect(button.classList.contains('visible')).toBe(true)
    })

    const scrollBack = vi.fn()
    box.scrollTo = scrollBack as unknown as typeof box.scrollTo
    button.click()
    expect(scrollBack).toHaveBeenCalledWith({ top: 0, behavior: 'smooth' })
  })
})
