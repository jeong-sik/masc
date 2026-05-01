// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Sep } from './sep'

describe('Sep', () => {
  const makeContainer = () => document.createElement('div')

  it('renders horizontal by default', () => {
    const container = makeContainer()
    render(html`<${Sep} />`, container)
    const div = container.querySelector('div')
    expect(div).not.toBeNull()
    expect(div!.getAttribute('data-orientation')).toBe('horizontal')
    expect(div!.getAttribute('role')).toBe('separator')
    expect(div!.getAttribute('aria-orientation')).toBe('horizontal')
    render(null, container)
  })

  it('renders vertical when specified', () => {
    const container = makeContainer()
    render(html`<${Sep} orientation="vertical" />`, container)
    const div = container.querySelector('div')
    expect(div!.getAttribute('data-orientation')).toBe('vertical')
    expect(div!.getAttribute('aria-orientation')).toBe('vertical')
    render(null, container)
  })

  it('forwards testId', () => {
    const container = makeContainer()
    render(html`<${Sep} testId="my-sep" />`, container)
    const div = container.querySelector('div')
    expect(div!.getAttribute('data-testid')).toBe('my-sep')
    render(null, container)
  })

  it('defaults tone to default', () => {
    const container = makeContainer()
    render(html`<${Sep} />`, container)
    const div = container.querySelector('div')
    expect(div!.getAttribute('data-tone')).toBe('default')
    render(null, container)
  })

  it('allows tone override to strong', () => {
    const container = makeContainer()
    render(html`<${Sep} tone="strong" />`, container)
    const div = container.querySelector('div')
    expect(div!.getAttribute('data-tone')).toBe('strong')
    render(null, container)
  })

  it('uses border-strong for vertical default tone', () => {
    const container = makeContainer()
    render(html`<${Sep} orientation="vertical" />`, container)
    const div = container.querySelector('div')
    const bg = div!.getAttribute('style') || ''
    expect(bg).toContain('var(--color-border-strong)')
    render(null, container)
  })

  it('uses border-default for horizontal default tone', () => {
    const container = makeContainer()
    render(html`<${Sep} orientation="horizontal" />`, container)
    const div = container.querySelector('div')
    const bg = div!.getAttribute('style') || ''
    expect(bg).toContain('var(--color-border-default)')
    render(null, container)
  })

  it('drops margin when noMargin is true', () => {
    const container = makeContainer()
    render(html`<${Sep} noMargin />`, container)
    const div = container.querySelector('div')
    const style = div!.getAttribute('style') || ''
    expect(style).toContain('margin: 0')
    render(null, container)
  })

  it('applies margin for horizontal', () => {
    const container = makeContainer()
    render(html`<${Sep} orientation="horizontal" />`, container)
    const div = container.querySelector('div')
    const style = div!.getAttribute('style') || ''
    expect(style).toContain('8px 0')
    render(null, container)
  })

  it('applies margin for vertical', () => {
    const container = makeContainer()
    render(html`<${Sep} orientation="vertical" />`, container)
    const div = container.querySelector('div')
    const style = div!.getAttribute('style') || ''
    expect(style).toContain('0px 8px')
    render(null, container)
  })
})
