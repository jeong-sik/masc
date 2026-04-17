// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  Skeleton,
  SkeletonText,
  SkeletonCircle,
  skeletonClasses,
  skeletonTextWidths,
} from './skeleton'

describe('skeletonClasses (pure)', () => {
  it('returns base + default width + default height when nothing is passed', () => {
    const cls = skeletonClasses()
    expect(cls).toContain('animate-pulse')
    expect(cls).toContain('bg-[var(--white-4)]')
    expect(cls).toContain('w-full')
    expect(cls).toContain('h-4')
  })

  it('overrides width + height when provided', () => {
    const cls = skeletonClasses('w-32', 'h-10')
    expect(cls).toContain('w-32')
    expect(cls).toContain('h-10')
    expect(cls).not.toContain('w-full')
    expect(cls).not.toContain('h-4')
  })

  it('appends extra classes when given', () => {
    const cls = skeletonClasses(undefined, undefined, 'mt-2 border')
    expect(cls).toContain('mt-2')
    expect(cls).toContain('border')
  })

  it('empty string extra is ignored (no trailing space accumulation)', () => {
    const cls = skeletonClasses('w-8', 'h-8', '')
    // The result should not contain a double-space or trailing space
    expect(cls.includes('  ')).toBe(false)
    expect(cls.endsWith(' ')).toBe(false)
  })
})

describe('skeletonTextWidths (pure)', () => {
  it('returns [] for 0 or negative lines', () => {
    expect(skeletonTextWidths(0)).toEqual([])
    expect(skeletonTextWidths(-5)).toEqual([])
  })

  it('single line gets the short tail (reads as a one-liner preview)', () => {
    expect(skeletonTextWidths(1)).toEqual(['w-[70%]'])
  })

  it('3 lines = full / full / short tail (Stripe/Linear paragraph rhythm)', () => {
    expect(skeletonTextWidths(3)).toEqual(['w-full', 'w-full', 'w-[70%]'])
  })

  it('only the LAST line is shortened (regression guard against "every other line" patterns)', () => {
    const out = skeletonTextWidths(5)
    expect(out.slice(0, -1).every(w => w === 'w-full')).toBe(true)
    expect(out[out.length - 1]).toBe('w-[70%]')
  })
})

describe('Skeleton component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a div carrying the pulse animation + theme-bg class', () => {
    render(html`<${Skeleton} />`, container)
    const el = container.querySelector('[data-skeleton-block]') as HTMLElement
    expect(el).toBeTruthy()
    expect(el.className).toContain('animate-pulse')
    expect(el.className).toContain('bg-[var(--white-4)]')
  })

  it('defaults to aria-hidden="true" (decorative — AT hears loading from parent)', () => {
    render(html`<${Skeleton} />`, container)
    const el = container.querySelector('[data-skeleton-block]')!
    expect(el.getAttribute('aria-hidden')).toBe('true')
    expect(el.hasAttribute('role')).toBe(false)
  })

  it('ariaLabel opts in to role="status" so AT announces it (inline loader use)', () => {
    render(html`<${Skeleton} ariaLabel="Loading connector metadata" />`, container)
    const el = container.querySelector('[data-skeleton-block]')!
    expect(el.getAttribute('aria-label')).toBe('Loading connector metadata')
    expect(el.getAttribute('role')).toBe('status')
    expect(el.hasAttribute('aria-hidden')).toBe(false)
  })

  it('testId renders as data-testid', () => {
    render(html`<${Skeleton} testId="connector-tile-loading" />`, container)
    expect(container.querySelector('[data-testid="connector-tile-loading"]')).toBeTruthy()
  })

  it('width + height props override the defaults', () => {
    render(html`<${Skeleton} width="w-24" height="h-6" />`, container)
    const el = container.querySelector('[data-skeleton-block]') as HTMLElement
    expect(el.className).toContain('w-24')
    expect(el.className).toContain('h-6')
    expect(el.className).not.toContain('w-full')
  })
})

describe('SkeletonText component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders `lines` children (default 3)', () => {
    render(html`<${SkeletonText} />`, container)
    const wrapper = container.querySelector('[data-skeleton-text]') as HTMLElement
    expect(wrapper.getAttribute('data-skeleton-text-lines')).toBe('3')
    expect(wrapper.children.length).toBe(3)
  })

  it('respects custom lines prop', () => {
    render(html`<${SkeletonText} lines=${5} />`, container)
    const wrapper = container.querySelector('[data-skeleton-text]') as HTMLElement
    expect(wrapper.children.length).toBe(5)
  })

  it('last line is the short tail, others are full-width (paragraph rhythm)', () => {
    render(html`<${SkeletonText} lines=${4} />`, container)
    const children = Array.from(container.querySelectorAll('[data-skeleton-text] > div'))
    expect(children[0]!.className).toContain('w-full')
    expect(children[2]!.className).toContain('w-full')
    expect(children[3]!.className).toContain('w-[70%]')
  })

  it('aria-hidden by default (decorative)', () => {
    render(html`<${SkeletonText} />`, container)
    const wrapper = container.querySelector('[data-skeleton-text]')!
    expect(wrapper.getAttribute('aria-hidden')).toBe('true')
  })

  it('ariaLabel promotes the wrapper to role="status"', () => {
    render(html`<${SkeletonText} ariaLabel="Loading log lines" />`, container)
    const wrapper = container.querySelector('[data-skeleton-text]')!
    expect(wrapper.getAttribute('role')).toBe('status')
    expect(wrapper.getAttribute('aria-label')).toBe('Loading log lines')
  })
})

describe('SkeletonCircle component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a rounded-full pulse block with default size', () => {
    render(html`<${SkeletonCircle} />`, container)
    const el = container.querySelector('[data-skeleton-circle]') as HTMLElement
    expect(el.className).toContain('rounded-full')
    expect(el.className).toContain('h-8')
    expect(el.className).toContain('w-8')
  })

  it('custom size overrides default', () => {
    render(html`<${SkeletonCircle} size="h-12 w-12" />`, container)
    const el = container.querySelector('[data-skeleton-circle]') as HTMLElement
    expect(el.className).toContain('h-12')
    expect(el.className).toContain('w-12')
    expect(el.className).not.toContain('h-8')
  })

  it('aria-hidden by default (decorative)', () => {
    render(html`<${SkeletonCircle} />`, container)
    expect(container.querySelector('[data-skeleton-circle]')!.getAttribute('aria-hidden')).toBe('true')
  })
})
