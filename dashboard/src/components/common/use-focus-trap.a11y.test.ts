// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { useFocusTrap } from './use-focus-trap'

async function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

async function effectTick() {
  return new Promise((r) => setTimeout(r, 10))
}

function Trap({ active, onClose }: { active: boolean; onClose?: () => void }) {
  const { ref, focusTrapProps } = useFocusTrap({ active, onClose })
  return html`
    <div ref=${ref} ...${focusTrapProps}>
      <button id="first">First</button>
      <button id="second">Second</button>
    </div>
  `
}

describe('useFocusTrap', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('sets data-focus-trap when active', async () => {
    render(html`<${Trap} active=${true} />`, container)
    await effectTick()
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-focus-trap')).toBe('true')
  })

  it('does not set data-focus-trap when inactive', async () => {
    render(html`<${Trap} active=${false} />`, container)
    await effectTick()
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-focus-trap')).toBeNull()
  })

  it('focuses first tabbable on activation', async () => {
    render(html`<${Trap} active=${true} />`, container)
    await effectTick()
    const first = container.querySelector('#first') as HTMLElement
    expect(document.activeElement).toBe(first)
  })

  it('calls onClose on Escape', async () => {
    const onClose = vi.fn()
    render(html`<${Trap} active=${true} onClose=${onClose} />`, container)
    await effectTick()
    const el = container.querySelector('div') as HTMLElement
    el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await tick()
    expect(onClose).toHaveBeenCalled()
  })

  it('cycles focus forward on Tab at last element', async () => {
    render(html`<${Trap} active=${true} />`, container)
    await effectTick()
    const second = container.querySelector('#second') as HTMLElement
    const first = container.querySelector('#first') as HTMLElement
    second.focus()
    const ev = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true })
    second.dispatchEvent(ev)
    await tick()
    expect(document.activeElement).toBe(first)
  })

  it('cycles focus backward on Shift+Tab at first element', async () => {
    render(html`<${Trap} active=${true} />`, container)
    await effectTick()
    const second = container.querySelector('#second') as HTMLElement
    const first = container.querySelector('#first') as HTMLElement
    first.focus()
    const ev = new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true })
    first.dispatchEvent(ev)
    await tick()
    expect(document.activeElement).toBe(second)
  })

  it('restores focus on deactivation', async () => {
    const outside = document.createElement('button')
    outside.id = 'outside'
    document.body.appendChild(outside)
    outside.focus()

    render(html`<${Trap} active=${true} />`, container)
    await effectTick()
    expect(document.activeElement).not.toBe(outside)

    render(html`<${Trap} active=${false} />`, container)
    await effectTick()
    expect(document.activeElement).toBe(outside)

    document.body.removeChild(outside)
  })

  it('renders accessibly', async () => {
    render(html`<${Trap} active=${true} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
