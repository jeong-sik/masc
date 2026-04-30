import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Portal } from './portal'

describe('Portal', () => {
  it('renders children into document.body', () => {
    const container = document.createElement('div')
    render(h(Portal, null, h('span', null, 'PortalContent')), container)
    const portalEl = document.body.querySelector('[data-masc-portal]')
    expect(portalEl).not.toBeNull()
    expect(portalEl?.textContent).toContain('PortalContent')
  })

  it('mounts portal outside the render container', () => {
    const container = document.createElement('div')
    render(h(Portal, null, h('span', null, 'Outside')), container)
    expect(container.textContent).not.toContain('Outside')
    expect(document.body.textContent).toContain('Outside')
  })
})
