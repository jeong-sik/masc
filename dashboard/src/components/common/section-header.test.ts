// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { SectionHeader } from './section-header'

describe('SectionHeader', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(h(SectionHeader, null, 'Overview'), container)
    expect(container.textContent).toContain('Overview')
  })

  it('renders right slot', () => {
    const container = document.createElement('div')
    render(h(SectionHeader, { right: h('span', null, '12') }, 'Items'), container)
    expect(container.textContent).toContain('Items')
    expect(container.textContent).toContain('12')
  })

  it('applies xs size class', () => {
    const container = document.createElement('div')
    render(h(SectionHeader, { size: 'xs' }, 'A'), container)
    const heading = container.querySelector('h4')
    expect(heading?.classList.contains('text-3xs')).toBe(true)
  })

  it('applies sm size class by default', () => {
    const container = document.createElement('div')
    render(h(SectionHeader, null, 'A'), container)
    const heading = container.querySelector('h4')
    expect(heading?.classList.contains('text-2xs')).toBe(true)
  })

  it('applies md size class', () => {
    const container = document.createElement('div')
    render(h(SectionHeader, { size: 'md' }, 'A'), container)
    const heading = container.querySelector('h4')
    expect(heading?.classList.contains('text-sm')).toBe(true)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(SectionHeader, { class: 'my-header' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('my-header')).toBe(true)
  })

  it('renders as uppercase tracked heading', () => {
    const container = document.createElement('div')
    render(h(SectionHeader, null, 'A'), container)
    const heading = container.querySelector('h4')
    expect(heading?.classList.contains('uppercase')).toBe(true)
    expect(heading?.classList.contains('tracking-[0.06em]')).toBe(true)
  })
})
