// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Table } from './table'

interface Row {
  id: string
  name: string
  role: string
}

const COLUMNS = [
  { key: 'name', header: 'Name', sortable: true },
  { key: 'role', header: 'Role' },
]

const ROWS: Row[] = [
  { id: '1', name: 'Alice', role: 'Admin' },
  { id: '2', name: 'Bob', role: 'User' },
]

describe('Table a11y', () => {
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
      html`<${Table}
        columns=${COLUMNS}
        rows=${ROWS}
        getRowId=${(r: Row) => r.id}
        aria-label="Users"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has grid role and aria-label', () => {
    render(
      html`<${Table}
        columns=${COLUMNS}
        rows=${ROWS}
        getRowId=${(r: Row) => r.id}
        aria-label="Users"
      />`,
      container,
    )
    const grid = container.querySelector('[role="grid"]')
    expect(grid).not.toBeNull()
    expect(grid?.getAttribute('aria-label')).toBe('Users')
  })

  it('renders column headers with scope', () => {
    render(
      html`<${Table}
        columns=${COLUMNS}
        rows=${ROWS}
        getRowId=${(r: Row) => r.id}
      />`,
      container,
    )
    const headers = container.querySelectorAll('th[scope="col"]')
    expect(headers.length).toBe(2)
    expect(headers[0]?.textContent?.trim()).toMatch(/^Name/)
    expect(headers[1]?.textContent?.trim()).toBe('Role')
  })

  it('marks rows with aria-selected', () => {
    render(
      html`<${Table}
        columns=${COLUMNS}
        rows=${ROWS}
        getRowId=${(r: Row) => r.id}
        selectedIds=${['1']}
      />`,
      container,
    )
    const rows = container.querySelectorAll('[role="row"]')
    expect(rows[0]?.getAttribute('aria-selected')).toBe('true')
    expect(rows[1]?.getAttribute('aria-selected')).toBe('false')
  })

  it('calls onSelect when row is clicked', async () => {
    const onSelect = vi.fn()
    render(
      html`<${Table}
        columns=${COLUMNS}
        rows=${ROWS}
        getRowId=${(r: Row) => r.id}
        onSelect=${onSelect}
      />`,
      container,
    )
    const row = container.querySelectorAll('[role="row"]')[0] as HTMLElement
    row?.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith(['1'])
  })

  it('calls onSort when sortable header is clicked', async () => {
    const onSort = vi.fn()
    render(
      html`<${Table}
        columns=${COLUMNS}
        rows=${ROWS}
        getRowId=${(r: Row) => r.id}
        sortKey="name"
        sortDir="asc"
        onSort=${onSort}
      />`,
      container,
    )
    const header = container.querySelectorAll('th')[0] as HTMLElement
    header?.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSort).toHaveBeenCalledWith('name', 'desc')
  })

  it('toggles selection on Enter key', async () => {
    const onSelect = vi.fn()
    render(
      html`<${Table}
        columns=${COLUMNS}
        rows=${ROWS}
        getRowId=${(r: Row) => r.id}
        onSelect=${onSelect}
      />`,
      container,
    )
    const grid = container.querySelector('[role="grid"]') as HTMLElement
    grid.focus()
    grid.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith(['1'])
  })
})
