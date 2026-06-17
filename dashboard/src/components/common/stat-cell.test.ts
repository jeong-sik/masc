import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { StatCell } from './stat-cell'

describe('StatCell', () => {
  it('renders label and value', () => {
    const container = document.createElement('div')
    render(html`<${StatCell} label="Running" value=${7} />`, container)
    expect(container.textContent).toContain('Running')
    expect(container.textContent).toContain('7')
  })

  it('renders sub suffix', () => {
    const container = document.createElement('div')
    render(html`<${StatCell} label="Tok/s" value=${41} sub="avg" />`, container)
    expect(container.textContent).toContain('41')
    expect(container.textContent).toContain('avg')
  })

  it('applies tone class', () => {
    const container = document.createElement('div')
    render(html`<${StatCell} label="Blocked" value=${2} tone="bad" />`, container)
    const el = container.querySelector('.stat-cell-v')
    expect(el?.classList.contains('bad')).toBe(true)
  })
})
