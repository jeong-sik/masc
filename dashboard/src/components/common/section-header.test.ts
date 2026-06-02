import { describe, expect, it } from 'vitest'
import { h, type ComponentChildren } from 'preact'
import { render } from 'preact'
import {
  SectionHeader,
  type SectionHeaderProps,
  sectionHeaderClasses,
  sectionHeaderHeadingClasses,
  summarizeSectionHeader,
} from './section-header'

function renderHeader(props: SectionHeaderProps = {}, children: ComponentChildren = 'A') {
  const container = document.createElement('div')
  render(h(SectionHeader, props, children), container)
  return container
}

describe('SectionHeader', () => {
  it('renders children', () => {
    const container = renderHeader({}, 'Overview')
    expect(container.textContent).toContain('Overview')
  })

  it('renders right slot', () => {
    const container = renderHeader({ right: h('span', null, '12') }, 'Items')
    expect(container.textContent).toContain('Items')
    expect(container.textContent).toContain('12')
  })

  it('applies xs size class', () => {
    const container = renderHeader({ size: 'xs' })
    const heading = container.querySelector('h4')
    expect(heading?.classList.contains('text-3xs')).toBe(true)
  })

  it('applies sm size class by default', () => {
    const container = renderHeader()
    const heading = container.querySelector('h4')
    expect(heading?.classList.contains('text-2xs')).toBe(true)
  })

  it('applies md size class', () => {
    const container = renderHeader({ size: 'md' })
    const heading = container.querySelector('h4')
    expect(heading?.classList.contains('text-sm')).toBe(true)
  })

  it('applies custom class', () => {
    const container = renderHeader({ class: 'my-header' })
    const el = container.querySelector('[data-section-header]')
    expect(el?.classList.contains('my-header')).toBe(true)
  })

  it('renders as uppercase tracked heading', () => {
    const container = renderHeader()
    const heading = container.querySelector('h4')
    expect(heading?.classList.contains('uppercase')).toBe(true)
    expect(heading?.classList.contains('tracking-[var(--track-sub)]')).toBe(true)
  })

  it('exposes section header summary metadata', () => {
    const container = renderHeader({
      size: 'md',
      class: 'mt-2',
      right: h('button', { type: 'button' }, 'Open'),
    }, 'Logs')
    const el = container.querySelector('[data-section-header]')

    expect(el?.getAttribute('data-section-header-size')).toBe('md')
    expect(el?.getAttribute('data-section-header-has-right')).toBe('true')
    expect(el?.getAttribute('data-section-header-has-custom-class')).toBe('true')
    expect(el?.getAttribute('data-section-header-class-length')).toBe('4')
  })

  it('summarizes default section header state', () => {
    expect(summarizeSectionHeader({})).toEqual({
      size: 'sm',
      hasRight: false,
      hasCustomClass: false,
      classNameLength: 0,
    })
  })

  it('treats null and false right slots as absent', () => {
    expect(summarizeSectionHeader({ right: null }).hasRight).toBe(false)
    expect(summarizeSectionHeader({ right: false }).hasRight).toBe(false)
  })

  it('exports stable class helpers', () => {
    expect(sectionHeaderClasses()).toBe('flex items-center justify-between gap-2')
    expect(sectionHeaderClasses('mt-2')).toBe('flex items-center justify-between gap-2 mt-2')
    expect(sectionHeaderHeadingClasses('xs')).toContain('text-3xs')
    expect(sectionHeaderHeadingClasses('sm')).toContain('text-2xs')
    expect(sectionHeaderHeadingClasses('md')).toContain('text-sm')
  })
})
