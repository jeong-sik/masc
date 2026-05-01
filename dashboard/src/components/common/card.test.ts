// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { SurfaceCard, SectionCard, Card } from './card'

describe('SurfaceCard', () => {
  it('renders children', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, null, 'Content'), container)
    expect(container.textContent).toContain('Content')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { testId: 'card-1' }, 'A'), container)
    expect(container.querySelector('[data-testid="card-1"]')).not.toBeNull()
  })

  it('applies standard variant class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { variant: 'standard' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('card')).toBe(true)
  })

  it('applies light variant class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { variant: 'light' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('!bg-transparent')).toBe(true)
  })

  it('applies compact variant class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { variant: 'compact' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('!p-3.5')).toBe(true)
  })

  it('applies tone class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { tone: 'ok' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('ok')).toBe(true)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(SurfaceCard, { class: 'extra' }, 'A'), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('extra')).toBe(true)
  })
})

describe('SectionCard', () => {
  it('renders label and children', () => {
    const container = document.createElement('div')
    render(h(SectionCard, { label: 'Section A' }, h('p', null, 'Body')), container)
    expect(container.textContent).toContain('Section A')
    expect(container.textContent).toContain('Body')
  })

  it('applies compact body padding', () => {
    const container = document.createElement('div')
    render(h(SectionCard, { label: 'T', variant: 'compact' }, 'Body'), container)
    expect(container.innerHTML).toContain('p-3.5')
  })
})

describe('Card', () => {
  it('renders as SurfaceCard without title', () => {
    const container = document.createElement('div')
    render(h(Card, null, 'Content'), container)
    expect(container.textContent).toContain('Content')
  })

  it('renders as SectionCard with title', () => {
    const container = document.createElement('div')
    render(h(Card, { title: 'Header' }, 'Body'), container)
    expect(container.textContent).toContain('Header')
    expect(container.textContent).toContain('Body')
  })
})
