import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from '@testing-library/preact'
import { Portal } from './portal'

describe('Portal', () => {
  it('renders children into document.body', () => {
    const { unmount } = render(h(Portal, null, h('span', null, 'PortalContent')))
    const portalEl = document.body.querySelector('[data-masc-portal]')
    expect(portalEl).not.toBeNull()
    expect(portalEl?.textContent).toContain('PortalContent')
    unmount()
  })

  it('mounts portal outside the render container', () => {
    const { container, unmount } = render(h(Portal, null, h('span', null, 'Outside')))
    expect(container.textContent).not.toContain('Outside')
    expect(document.body.textContent).toContain('Outside')
    unmount()
  })

  it('removes portal element from body on unmount', () => {
    const { unmount } = render(h(Portal, null, h('span', null, 'Cleanup')))
    expect(document.body.querySelector('[data-masc-portal]')).not.toBeNull()
    unmount()
    expect(document.body.querySelector('[data-masc-portal]')).toBeNull()
  })
})
