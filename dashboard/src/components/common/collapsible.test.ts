// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { CollapsibleSection } from './collapsible'

describe('CollapsibleSection', () => {
  it('renders title and children', () => {
    const container = document.createElement('div')
    render(
      h(CollapsibleSection, { title: 'Section A' }, h('p', null, 'Content')),
      container,
    )
    expect(container.textContent).toContain('Section A')
    expect(container.textContent).toContain('Content')
  })

  it('respects mountWhenOpen and hides children initially', () => {
    const container = document.createElement('div')
    render(
      h(CollapsibleSection, { title: 'T', mountWhenOpen: true }, h('p', null, 'Hidden')),
      container,
    )
    expect(container.textContent).not.toContain('Hidden')
  })

  it('shows children when open=true with mountWhenOpen', () => {
    const container = document.createElement('div')
    render(
      h(
        CollapsibleSection,
        { title: 'T', open: true, mountWhenOpen: true },
        h('p', null, 'Visible'),
      ),
      container,
    )
    expect(container.textContent).toContain('Visible')
  })

  it('renders badge in summary', () => {
    const container = document.createElement('div')
    render(
      h(CollapsibleSection, { title: 'T', badge: h('span', null, '3') }, 'Content'),
      container,
    )
    expect(container.textContent).toContain('3')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(
      h(CollapsibleSection, { title: 'T', class: 'my-section' }, 'Content'),
      container,
    )
    const details = container.querySelector('details')
    expect(details?.classList.contains('my-section')).toBe(true)
  })

  it('applies id', () => {
    const container = document.createElement('div')
    render(
      h(CollapsibleSection, { title: 'T', id: 'sect-1' }, 'Content'),
      container,
    )
    const details = container.querySelector('details')
    expect(details?.getAttribute('id')).toBe('sect-1')
  })

  it('mounts children on toggle open when mountWhenOpen=true', async () => {
    const container = document.createElement('div')
    render(
      h(CollapsibleSection, { title: 'T', mountWhenOpen: true }, h('p', null, 'Lazy')),
      container,
    )
    const details = container.querySelector('details') as HTMLDetailsElement
    details.open = true
    details.dispatchEvent(new Event('toggle'))
    await new Promise(r => setTimeout(r, 10))
    expect(container.textContent).toContain('Lazy')
  })
})
