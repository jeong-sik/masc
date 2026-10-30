import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Slider } from './slider'

describe('Slider', () => {
  it('renders with role="slider"', () => {
    const container = document.createElement('div')
    render(h(Slider, {}), container)
    expect(container.querySelector('[role="slider"]')).not.toBeNull()
  })

  it('applies aria-value attributes', () => {
    const container = document.createElement('div')
    render(h(Slider, { min: 10, max: 90, value: 50 }), container)
    const el = container.querySelector('[role="slider"]')
    expect(el?.getAttribute('aria-valuemin')).toBe('10')
    expect(el?.getAttribute('aria-valuemax')).toBe('90')
    expect(el?.getAttribute('aria-valuenow')).toBe('50')
  })

  it('renders thumb', () => {
    const container = document.createElement('div')
    render(h(Slider, { value: 30 }), container)
    expect(container.querySelector('[role="slider"]')).not.toBeNull()
  })

  it('increases value on ArrowRight', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Slider, { value: 50, onChange }), container)
    const el = container.querySelector('[role="slider"]') as HTMLElement
    el?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))
    expect(onChange).toHaveBeenCalledWith(51)
  })

  it('increases value on ArrowUp', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Slider, { value: 50, onChange }), container)
    const el = container.querySelector('[role="slider"]') as HTMLElement
    el?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowUp' }))
    expect(onChange).toHaveBeenCalledWith(51)
  })

  it('decreases value on ArrowLeft', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Slider, { value: 50, onChange }), container)
    const el = container.querySelector('[role="slider"]') as HTMLElement
    el?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft' }))
    expect(onChange).toHaveBeenCalledWith(49)
  })

  it('decreases value on ArrowDown', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Slider, { value: 50, onChange }), container)
    const el = container.querySelector('[role="slider"]') as HTMLElement
    el?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown' }))
    expect(onChange).toHaveBeenCalledWith(49)
  })

  it('jumps to min on Home', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Slider, { value: 50, onChange }), container)
    const el = container.querySelector('[role="slider"]') as HTMLElement
    el?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home' }))
    expect(onChange).toHaveBeenCalledWith(0)
  })

  it('jumps to max on End', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Slider, { value: 50, onChange }), container)
    const el = container.querySelector('[role="slider"]') as HTMLElement
    el?.dispatchEvent(new KeyboardEvent('keydown', { key: 'End' }))
    expect(onChange).toHaveBeenCalledWith(100)
  })

  it('respects step', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(Slider, { value: 0, step: 10, onChange }), container)
    const el = container.querySelector('[role="slider"]') as HTMLElement
    el?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))
    expect(onChange).toHaveBeenCalledWith(10)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(Slider, { class: 'my-slider' }), container)
    const el = container.querySelector('[role="slider"]')?.parentElement
    expect(el?.classList.contains('my-slider')).toBe(true)
  })
})
