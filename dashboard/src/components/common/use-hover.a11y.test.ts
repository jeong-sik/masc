// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { useHover } from './use-hover'

async function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function Hoverable() {
  const { hoverProps, hovered } = useHover()
  return html`<button ...${hoverProps} data-hovered=${hovered ? 'true' : undefined}>Hover me</button>`
}

describe('useHover', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('marks hovered on mouse pointerenter', async () => {
    render(html`<${Hoverable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerenter', { bubbles: true, pointerType: 'mouse' }))
    await tick()
    expect(btn.getAttribute('data-hovered')).toBe('true')
  })

  it('clears hovered on pointerleave', async () => {
    render(html`<${Hoverable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerenter', { bubbles: true, pointerType: 'mouse' }))
    btn.dispatchEvent(new PointerEvent('pointerleave', { bubbles: true, pointerType: 'mouse' }))
    await tick()
    expect(btn.getAttribute('data-hovered')).toBeNull()
  })

  it('ignores touch pointerenter', async () => {
    render(html`<${Hoverable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerenter', { bubbles: true, pointerType: 'touch' }))
    await tick()
    expect(btn.getAttribute('data-hovered')).toBeNull()
  })

  it('ignores pointerleave after touch', async () => {
    render(html`<${Hoverable} />`, container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerenter', { bubbles: true, pointerType: 'touch' }))
    btn.dispatchEvent(new PointerEvent('pointerleave', { bubbles: true, pointerType: 'touch' }))
    await tick()
    expect(btn.getAttribute('data-hovered')).toBeNull()
  })

  it('renders accessibly', async () => {
    render(html`<${Hoverable} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
