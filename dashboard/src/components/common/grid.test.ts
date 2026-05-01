import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Grid } from './grid'

describe('Grid', () => {
  const columns = [
    { key: 'name', header: 'Name' },
    { key: 'age', header: 'Age' },
  ]
  const rows = [
    { id: 'r1', name: 'Alice', age: '30' },
    { id: 'r2', name: 'Bob', age: '25' },
  ]

  it('renders table with columns and rows', () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows }), container)
    expect(container.querySelector('table')).not.toBeNull()
    expect(container.querySelector('tbody')?.querySelectorAll('tr').length).toBe(2)
  })

  it('renders headers', () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows }), container)
    const ths = container.querySelectorAll('th')
    expect(ths[0]?.textContent).toBe('Name')
    expect(ths[1]?.textContent).toBe('Age')
  })

  it('renders cell data', () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows }), container)
    expect(container.textContent).toContain('Alice')
    expect(container.textContent).toContain('Bob')
  })

  it('applies selected row styling', () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows, selectedRowId: 'r1' }), container)
    const row = container.querySelector('tbody')?.querySelectorAll('tr')[0]
    expect(row?.className).toContain('bg-[var(--color-accent-fg)]')
  })

  it('applies aria-selected to selected row', () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows, selectedRowId: 'r1' }), container)
    const row = container.querySelector('tbody')?.querySelectorAll('tr')[0]
    expect(row?.getAttribute('aria-selected')).toBe('true')
  })

  it('calls onSelectRow on row click', async () => {
    const onSelectRow = vi.fn()
    const container = document.createElement('div')
    render(h(Grid, { columns, rows, onSelectRow }), container)
    const row = container.querySelector('tbody')?.querySelectorAll('tr')[1] as HTMLElement
    row.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelectRow).toHaveBeenCalledWith('r2')
  })

  it('moves focus on ArrowDown', async () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows }), container)
    const table = container.querySelector('table') as HTMLElement
    table.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const trs = container.querySelector('tbody')?.querySelectorAll('tr')
    expect(trs?.[1]?.getAttribute('tabindex')).toBe('0')
  })

  it('moves focus on ArrowUp', async () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows }), container)
    const table = container.querySelector('table') as HTMLElement
    table.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    table.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const trs = container.querySelector('tbody')?.querySelectorAll('tr')
    expect(trs?.[0]?.getAttribute('tabindex')).toBe('0')
  })

  it('jumps to first row on Home', async () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows }), container)
    const table = container.querySelector('table') as HTMLElement
    table.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    table.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const trs = container.querySelector('tbody')?.querySelectorAll('tr')
    expect(trs?.[0]?.getAttribute('tabindex')).toBe('0')
  })

  it('jumps to last row on End', async () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows }), container)
    const table = container.querySelector('table') as HTMLElement
    table.dispatchEvent(new KeyboardEvent('keydown', { key: 'End', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    const trs = container.querySelector('tbody')?.querySelectorAll('tr')
    expect(trs?.[1]?.getAttribute('tabindex')).toBe('0')
  })

  it('calls onSelectRow on Enter', () => {
    const onSelectRow = vi.fn()
    const container = document.createElement('div')
    render(h(Grid, { columns, rows, onSelectRow }), container)
    const table = container.querySelector('table') as HTMLElement
    table.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(onSelectRow).toHaveBeenCalledWith('r1')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(Grid, { columns, rows, class: 'my-grid' }), container)
    const table = container.querySelector('table')
    expect(table?.classList.contains('my-grid')).toBe(true)
  })
})
