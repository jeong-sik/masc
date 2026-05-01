// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KeeperDetailSectionCard } from './keeper-detail-layout'

describe('KeeperDetailSectionCard', () => {
  const makeContainer = () => document.createElement('div')

  it('renders title', () => {
    const container = makeContainer()
    render(html`<${KeeperDetailSectionCard} title="Test Title">content<//>`, container)
    expect(container.textContent).toContain('Test Title')
    render(null, container)
  })

  it('renders children', () => {
    const container = makeContainer()
    render(html`<${KeeperDetailSectionCard} title="Title">child content<//>`, container)
    expect(container.textContent).toContain('child content')
    render(null, container)
  })

  it('has decorative dot', () => {
    const container = makeContainer()
    render(html`<${KeeperDetailSectionCard} title="T" />`, container)
    const dot = container.querySelector('[aria-hidden="true"]')
    expect(dot).not.toBeNull()
    render(null, container)
  })
})
