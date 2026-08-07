import { render } from 'preact'
import { html } from 'htm/preact'
import { describe, it, expect, afterEach } from 'vitest'
import { RelationshipList } from './keeper-detail-lists'

afterEach(() => {
  document.body.innerHTML = ''
})

describe('RelationshipList primitive', () => {
  it('renders relationship names with the shared status chip primitive', () => {
    const container = document.createElement('div')
    document.body.appendChild(container)

    render(html`<${RelationshipList} rels=${{ alpha: 'mentor' }} />`, container)

    const chip = container.querySelector('[data-status-chip]')
    expect(chip?.textContent).toContain('alpha')
    expect(chip?.getAttribute('data-status-chip-tone')).toBe('info')
    expect(chip?.getAttribute('data-status-chip-uppercase')).toBe('false')
  })
})
