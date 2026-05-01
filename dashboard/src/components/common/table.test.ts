// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Table, type TableColumn } from './table'

interface Row {
  id: string
  name: string
  age: number
}

describe('Table', () => {
  const columns: TableColumn<Row>[] = [
    { key: 'name', header: 'Name' },
    { key: 'age', header: 'Age' },
  ]
  const rows: Row[] = [
    { id: 'r1', name: 'Alice', age: 30 },
    { id: 'r2', name: 'Bob', age: 25 },
  ]
  const getRowId = (r: Row) => r.id

  it('renders table with columns and rows', () => {
    const container = document.createElement('div')
    render(h(Table<Row>, { columns, rows, getRowId }), container)
    expect(container.querySelector('table')).not.toBeNull()
    expect(container.querySelector('tbody')?.querySelectorAll('tr').length).toBe(2)
  })

  it('renders headers', () => {
    const container = document.createElement('div')
    render(h(Table<Row>, { columns, rows, getRowId }), container)
    const ths = container.querySelectorAll('th')
    expect(ths[0]?.textContent).toContain('Name')
    expect(ths[1]?.textContent).toContain('Age')
  })

  it('renders cell data', () => {
    const container = document.createElement('div')
    render(h(Table<Row>, { columns, rows, getRowId }), container)
    expect(container.textContent).toContain('Alice')
    expect(container.textContent).toContain('Bob')
    expect(container.textContent).toContain('30')
    expect(container.textContent).toContain('25')
  })

  it('calls onSort on header click', async () => {
    const onSort = vi.fn()
    const cols: TableColumn<Row>[] = [{ key: 'name', header: 'Name', sortable: true }]
    const container = document.createElement('div')
    render(h(Table<Row>, { columns: cols, rows, getRowId, onSort }), container)
    const th = container.querySelector('th') as HTMLElement
    th.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSort).toHaveBeenCalledWith('name', 'asc')
  })

  it('toggles sort direction', async () => {
    const onSort = vi.fn()
    const cols: TableColumn<Row>[] = [{ key: 'name', header: 'Name', sortable: true }]
    const container = document.createElement('div')
    render(h(Table<Row>, { columns: cols, rows, getRowId, onSort, sortKey: 'name', sortDir: 'asc' }), container)
    const th = container.querySelector('th') as HTMLElement
    th.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSort).toHaveBeenCalledWith('name', 'desc')
  })

  it('applies sort indicator', () => {
    const cols: TableColumn<Row>[] = [{ key: 'name', header: 'Name', sortable: true }]
    const container = document.createElement('div')
    render(h(Table<Row>, { columns: cols, rows, getRowId, sortKey: 'name', sortDir: 'asc' }), container)
    const th = container.querySelector('th')
    expect(th?.textContent).toContain('↑')
  })

  it('calls onSelect on row click', async () => {
    const onSelect = vi.fn()
    const container = document.createElement('div')
    render(h(Table<Row>, { columns, rows, getRowId, onSelect }), container)
    const trs = container.querySelector('tbody')?.querySelectorAll('tr')
    ;(trs?.[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith(['r2'])
  })

  it('toggles selection', async () => {
    const onSelect = vi.fn()
    const container = document.createElement('div')
    render(h(Table<Row>, { columns, rows, getRowId, onSelect, selectedIds: ['r2'] }), container)
    const trs = container.querySelector('tbody')?.querySelectorAll('tr')
    ;(trs?.[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith([])
  })

  it('applies aria-selected', () => {
    const container = document.createElement('div')
    render(h(Table<Row>, { columns, rows, getRowId, selectedIds: ['r1'] }), container)
    const trs = container.querySelector('tbody')?.querySelectorAll('tr')
    expect(trs?.[0]?.getAttribute('aria-selected')).toBe('true')
    expect(trs?.[1]?.getAttribute('aria-selected')).toBe('false')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(Table<Row>, { columns, rows, getRowId, testId: 'tbl-1' }), container)
    expect(container.querySelector('[data-testid="tbl-1"]')).not.toBeNull()
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Table<Row>, { columns, rows, getRowId, 'aria-label': 'Users' }), container)
    const table = container.querySelector('table')
    expect(table?.getAttribute('aria-label')).toBe('Users')
  })
})
