// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Banner } from './banner'

describe('Banner', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(h(Banner, null, 'Welcome'), container)
    expect(container.textContent).toContain('Welcome')
  })

  it('has role="banner"', () => {
    const container = document.createElement('div')
    render(h(Banner, null, 'A'), container)
    const el = container.querySelector('[role="banner"]')
    expect(el).not.toBeNull()
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Banner, { 'aria-label': 'Site header' }, 'A'), container)
    const el = container.querySelector('[role="banner"]')
    expect(el?.getAttribute('aria-label')).toBe('Site header')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(Banner, { class: 'my-banner' }, 'A'), container)
    const el = container.querySelector('[role="banner"]')
    expect(el?.classList.contains('my-banner')).toBe(true)
  })
})
