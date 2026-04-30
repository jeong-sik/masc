// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Slider } from './slider'

describe('Slider a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(
      html`<${Slider} aria-label="Volume" min=${0} max=${100} value=${50} onChange=${vi.fn()} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has slider role and aria attributes', () => {
    render(
      html`<${Slider}
        aria-label="Volume"
        min=${0}
        max=${100}
        value=${50}
        onChange=${vi.fn()}
      />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]')
    expect(slider).not.toBeNull()
    expect(slider?.getAttribute('aria-valuemin')).toBe('0')
    expect(slider?.getAttribute('aria-valuemax')).toBe('100')
    expect(slider?.getAttribute('aria-valuenow')).toBe('50')
    expect(slider?.getAttribute('aria-label')).toBe('Volume')
    expect(slider?.getAttribute('aria-orientation')).toBe('horizontal')
  })

  it('supports vertical orientation', () => {
    render(
      html`<${Slider}
        aria-label="Brightness"
        min=${0}
        max=${100}
        value=${30}
        orientation="vertical"
        onChange=${vi.fn()}
      />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]')
    expect(slider?.getAttribute('aria-orientation')).toBe('vertical')
  })

  it('increases value with ArrowRight', async () => {
    const onChange = vi.fn()
    render(
      html`<${Slider} aria-label="X" min=${0} max=${100} value=${50} step=${10} onChange=${onChange} />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.focus()

    slider.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith(60)
  })

  it('decreases value with ArrowLeft', async () => {
    const onChange = vi.fn()
    render(
      html`<${Slider} aria-label="X" min=${0} max=${100} value=${50} step=${10} onChange=${onChange} />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.focus()

    slider.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith(40)
  })

  it('increases value with ArrowUp in vertical mode', async () => {
    const onChange = vi.fn()
    render(
      html`<${Slider}
        aria-label="X"
        min=${0}
        max=${100}
        value=${50}
        step=${10}
        orientation="vertical"
        onChange=${onChange}
      />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.focus()

    slider.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith(60)
  })

  it('decreases value with ArrowDown in vertical mode', async () => {
    const onChange = vi.fn()
    render(
      html`<${Slider}
        aria-label="X"
        min=${0}
        max=${100}
        value=${50}
        step=${10}
        orientation="vertical"
        onChange=${onChange}
      />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.focus()

    slider.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith(40)
  })

  it('jumps to min with Home', async () => {
    const onChange = vi.fn()
    render(
      html`<${Slider} aria-label="X" min=${0} max=${100} value=${50} onChange=${onChange} />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.focus()

    slider.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Home', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith(0)
  })

  it('jumps to max with End', async () => {
    const onChange = vi.fn()
    render(
      html`<${Slider} aria-label="X" min=${0} max=${100} value=${50} onChange=${onChange} />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.focus()

    slider.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'End', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith(100)
  })

  it('does not respond when disabled', async () => {
    const onChange = vi.fn()
    render(
      html`<${Slider}
        aria-label="X"
        min=${0}
        max=${100}
        value=${50}
        disabled
        onChange=${onChange}
      />`,
      container,
    )
    const slider = container.querySelector('[role="slider"]') as HTMLElement
    slider.focus()

    slider.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).not.toHaveBeenCalled()
    expect(slider?.getAttribute('aria-disabled')).toBe('true')
  })
})
