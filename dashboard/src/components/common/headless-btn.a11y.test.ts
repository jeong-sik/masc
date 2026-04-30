// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { HeadlessBtn } from './headless-btn'

describe('HeadlessBtn a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly with label text', async () => {
    render(html`<${HeadlessBtn}>Save</${HeadlessBtn}>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with aria-label', async () => {
    render(
      html`<${HeadlessBtn} ariaLabel="Close dialog">X</${HeadlessBtn}>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when disabled', async () => {
    render(
      html`<${HeadlessBtn} disabled>Submit</${HeadlessBtn}>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with custom class', async () => {
    render(
      html`<${HeadlessBtn} class="bg-blue-500">Custom</${HeadlessBtn}>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has button role', () => {
    render(html`<${HeadlessBtn}>Click</${HeadlessBtn}>`, container)
    const btn = container.querySelector('button')
    expect(btn).not.toBeNull()
  })

  it('has aria-label when provided', () => {
    render(
      html`<${HeadlessBtn} ariaLabel="Dismiss">X</${HeadlessBtn}>`,
      container,
    )
    const btn = container.querySelector('button')
    expect(btn?.getAttribute('aria-label')).toBe('Dismiss')
  })

  it('is disabled when disabled prop is true', () => {
    render(
      html`<${HeadlessBtn} disabled>Submit</${HeadlessBtn}>`,
      container,
    )
    const btn = container.querySelector('button')
    expect(btn?.hasAttribute('disabled')).toBe(true)
  })

  it('calls onPress when clicked', () => {
    const onPress = vi.fn()
    render(
      html`<${HeadlessBtn} onPress=${onPress}>Click</${HeadlessBtn}>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    expect(onPress).toHaveBeenCalled()
  })

  it('does not call onPress when disabled', () => {
    const onPress = vi.fn()
    render(
      html`<${HeadlessBtn} onPress=${onPress} disabled>Click</${HeadlessBtn}>`,
      container,
    )
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    btn.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))
    expect(onPress).not.toHaveBeenCalled()
  })
})
