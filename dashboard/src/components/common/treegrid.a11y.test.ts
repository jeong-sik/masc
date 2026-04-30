// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Treegrid, TreegridRow, TreegridCell } from './treegrid'

describe('Treegrid a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(
      html`
        <${Treegrid} aria-label="File tree">
          <${TreegridRow}>
            <${TreegridCell}>Name<//>
          <//>
        <//>
      `,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role="treegrid"', () => {
    render(
      html`
        <${Treegrid} aria-label="Files">
          <${TreegridRow}><${TreegridCell}>A<//><//>
        <//>
      `,
      container,
    )
    expect(container.querySelector('[role="treegrid"]')).not.toBeNull()
  })

  it('rows have role="row"', () => {
    render(
      html`
        <${Treegrid} aria-label="Files">
          <${TreegridRow}><${TreegridCell}>A<//><//>
          <${TreegridRow}><${TreegridCell}>B<//><//>
        <//>
      `,
      container,
    )
    expect(container.querySelectorAll('[role="row"]').length).toBe(2)
  })

  it('cells have role="gridcell"', () => {
    render(
      html`
        <${Treegrid} aria-label="Files">
          <${TreegridRow}>
            <${TreegridCell}>A<//>
            <${TreegridCell}>B<//>
          <//>
        <//>
      `,
      container,
    )
    const cells = container.querySelectorAll('[role="gridcell"]')
    expect(cells.length).toBe(2)
    expect(cells[0]?.textContent?.trim()).toBe('A')
  })

  it('passes aria-expanded', () => {
    render(
      html`
        <${Treegrid} aria-label="Files">
          <${TreegridRow} expanded=${true}>
            <${TreegridCell}>Parent<//>
          <//>
        <//>
      `,
      container,
    )
    const row = container.querySelector('[role="row"]')
    expect(row?.getAttribute('aria-expanded')).toBe('true')
  })

  it('passes aria-level', () => {
    render(
      html`
        <${Treegrid} aria-label="Files">
          <${TreegridRow} level=${2}>
            <${TreegridCell}>Child<//>
          <//>
        <//>
      `,
      container,
    )
    const row = container.querySelector('[role="row"]')
    expect(row?.getAttribute('aria-level')).toBe('2')
  })
})
