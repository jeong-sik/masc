import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Treegrid, TreegridRow, TreegridCell } from './treegrid'

describe('Treegrid', () => {
  it('renders table with treegrid role', () => {
    const container = document.createElement('div')
    render(h(Treegrid, { 'aria-label': 'Files', children: null }), container)
    const table = container.querySelector('table')
    expect(table).not.toBeNull()
    expect(table?.getAttribute('role')).toBe('treegrid')
  })

  it('renders aria-label', () => {
    const container = document.createElement('div')
    render(h(Treegrid, { 'aria-label': 'Files', children: null }), container)
    const table = container.querySelector('table')
    expect(table?.getAttribute('aria-label')).toBe('Files')
  })

  it('applies class', () => {
    const container = document.createElement('div')
    render(h(Treegrid, { 'aria-label': 'Files', class: 'my-grid', children: null }), container)
    const table = container.querySelector('table')
    expect(table?.classList.contains('my-grid')).toBe(true)
  })

  it('renders children', () => {
    const container = document.createElement('div')
    render(
      h(Treegrid, {
        'aria-label': 'Files',
        children: h(TreegridRow, { children: h(TreegridCell, { children: 'cell content' }) }),
      }),
      container,
    )
    expect(container.textContent).toContain('cell content')
  })
})

describe('TreegridRow', () => {
  it('renders tr with row role', () => {
    const container = document.createElement('div')
    render(h(TreegridRow, { children: null }), container)
    const tr = container.querySelector('tr')
    expect(tr).not.toBeNull()
    expect(tr?.getAttribute('role')).toBe('row')
  })

  it('renders aria-expanded when provided', () => {
    const container = document.createElement('div')
    render(h(TreegridRow, { expanded: true, children: null }), container)
    const tr = container.querySelector('tr')
    expect(tr?.getAttribute('aria-expanded')).toBe('true')
  })

  it('renders aria-level when provided', () => {
    const container = document.createElement('div')
    render(h(TreegridRow, { level: 2, children: null }), container)
    const tr = container.querySelector('tr')
    expect(tr?.getAttribute('aria-level')).toBe('2')
  })

  it('applies class', () => {
    const container = document.createElement('div')
    render(h(TreegridRow, { class: 'row-class', children: null }), container)
    const tr = container.querySelector('tr')
    expect(tr?.classList.contains('row-class')).toBe(true)
  })
})

describe('TreegridCell', () => {
  it('renders td with gridcell role', () => {
    const container = document.createElement('div')
    render(h(TreegridCell, { children: 'data' }), container)
    const td = container.querySelector('td')
    expect(td).not.toBeNull()
    expect(td?.getAttribute('role')).toBe('gridcell')
  })

  it('renders children', () => {
    const container = document.createElement('div')
    render(h(TreegridCell, { children: 'cell data' }), container)
    expect(container.textContent).toContain('cell data')
  })

  it('applies class', () => {
    const container = document.createElement('div')
    render(h(TreegridCell, { class: 'cell-class', children: null }), container)
    const td = container.querySelector('td')
    expect(td?.classList.contains('cell-class')).toBe(true)
  })
})
