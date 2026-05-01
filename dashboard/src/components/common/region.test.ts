// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Region } from './region'

describe('Region', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(h(Region, { 'aria-label': 'Main' }, 'Content'), container)
    expect(container.textContent).toContain('Content')
  })

  it('renders as section element', () => {
    const container = document.createElement('div')
    render(h(Region, { 'aria-label': 'Main' }, 'A'), container)
    expect(container.querySelector('section')).not.toBeNull()
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Region, { 'aria-label': 'Overview' }, 'A'), container)
    const el = container.querySelector('section')
    expect(el?.getAttribute('aria-label')).toBe('Overview')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(Region, { 'aria-label': 'Main', class: 'region-wide' }, 'A'), container)
    const el = container.querySelector('section')
    expect(el?.classList.contains('region-wide')).toBe(true)
  })
})
