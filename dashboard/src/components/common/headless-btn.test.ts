import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { HeadlessBtn } from './headless-btn'

describe('HeadlessBtn', () => {
  it('renders button with children', () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, {}, 'Click'), container)
    expect(container.textContent).toContain('Click')
  })

  it('has data-headless-btn attribute', () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, {}), container)
    const btn = container.querySelector('button')
    expect(btn?.hasAttribute('data-headless-btn')).toBe(true)
  })

  it('applies pressed state on pointerdown', async () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressed')).toBe('true')
  })

  it('clears pressed state on pointerup', async () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-pressed')).toBeNull()
  })

  it('applies hovered state on pointerenter', async () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerenter', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-hovered')).toBe('true')
  })

  it('clears hovered state on pointerleave', async () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerenter', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new PointerEvent('pointerleave', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-hovered')).toBeNull()
  })

  it('applies focus-visible on focus', async () => {
    const container = document.createElement('div')
    document.body.appendChild(container)
    render(h(HeadlessBtn, {}), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.focus()
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-focused')).toBe('true')
    document.body.removeChild(container)
  })

  it('has disabled attribute when disabled', () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, { disabled: true }), container)
    const btn = container.querySelector('button') as HTMLButtonElement
    expect(btn.disabled).toBe(true)
  })

  it('calls onPress on pointerup', async () => {
    const onPress = vi.fn()
    const container = document.createElement('div')
    render(h(HeadlessBtn, { onPress }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onPress).toHaveBeenCalledOnce()
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, { class: 'my-class' }), container)
    const btn = container.querySelector('button')
    expect(btn?.classList.contains('my-class')).toBe(true)
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, { ariaLabel: 'Submit' }), container)
    const btn = container.querySelector('button')
    expect(btn?.getAttribute('aria-label')).toBe('Submit')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(HeadlessBtn, { testId: 'btn-1' }), container)
    expect(container.querySelector('[data-testid="btn-1"]')).not.toBeNull()
  })
})
