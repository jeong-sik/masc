// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { axe } from 'jest-axe'
import { Grid } from './grid'

const COLUMNS = [
  { key: 'name', header: 'Name' },
  { key: 'role', header: 'Role' },
]

const ROWS = [
  { id: 'r1', name: 'Alice', role: 'Admin' },
  { id: 'r2', name: 'Bob', role: 'User' },
  { id: 'r3', name: 'Carol', role: 'Guest' },
]

function StatefulGrid({ rows }: { rows: typeof ROWS }) {
  const [selectedId, setSelectedId] = useState<string>()
  return html`<${Grid}
    columns=${COLUMNS}
    rows=${rows}
    selectedRowId=${selectedId}
    onSelectRow=${setSelectedId}
    aria-label="Users"
  />`
}

describe('Grid a11y', () => {
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
      html`<${Grid} columns=${COLUMNS} rows=${ROWS} aria-label="Users" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has grid role', () => {
    render(
      html`<${Grid} columns=${COLUMNS} rows=${ROWS} aria-label="Users" />`,
      container,
    )
    expect(container.querySelector('[role="grid"]')).not.toBeNull()
  })

  it('has columnheader and gridcell roles', () => {
    render(
      html`<${Grid} columns=${COLUMNS} rows=${ROWS} aria-label="Users" />`,
      container,
    )
    expect(container.querySelectorAll('[role="columnheader"]').length).toBe(2)
    expect(container.querySelectorAll('[role="gridcell"]').length).toBe(6)
  })

  it('rows have aria-selected', () => {
    render(
      html`<${Grid}
        columns=${COLUMNS}
        rows=${ROWS}
        selectedRowId="r2"
        aria-label="Users"
      />`,
      container,
    )
    const rows = container.querySelectorAll('tbody [role="row"]')
    expect(rows[1].getAttribute('aria-selected')).toBe('true')
    expect(rows[0].getAttribute('aria-selected')).toBe('false')
    expect(rows[2].getAttribute('aria-selected')).toBe('false')
  })

  it('moves focus with ArrowDown', async () => {
    render(
      html`<${StatefulGrid} rows=${ROWS} />`,
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const grid = container.querySelector('[role="grid"]') as HTMLElement
    grid.focus()

    grid.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))

    const rows = container.querySelectorAll('tbody [role="row"]')
    expect(rows[1].getAttribute('tabindex')).toBe('0')
    expect(rows[0].getAttribute('tabindex')).toBe('-1')
  })

  it('moves focus with ArrowUp', async () => {
    render(
      html`<${Grid}
        columns=${COLUMNS}
        rows=${ROWS}
        selectedRowId="r2"
        aria-label="Users"
      />`,
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const grid = container.querySelector('[role="grid"]') as HTMLElement
    grid.focus()

    grid.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))

    const rows = container.querySelectorAll('tbody [role="row"]')
    expect(rows[0].getAttribute('tabindex')).toBe('0')
    expect(rows[1].getAttribute('tabindex')).toBe('-1')
  })

  it('selects on Enter and calls onSelectRow', async () => {
    const onSelectRow = vi.fn()
    render(
      html`<${Grid}
        columns=${COLUMNS}
        rows=${ROWS}
        onSelectRow=${onSelectRow}
        aria-label="Users"
      />`,
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const grid = container.querySelector('[role="grid"]') as HTMLElement
    grid.focus()

    grid.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelectRow).toHaveBeenCalledWith('r1')
  })

  it('jumps to first and last with Home and End', async () => {
    render(
      html`<${Grid}
        columns=${COLUMNS}
        rows=${ROWS}
        selectedRowId="r2"
        aria-label="Users"
      />`,
      container,
    )
    await new Promise((r) => setTimeout(r, 0))
    const grid = container.querySelector('[role="grid"]') as HTMLElement
    grid.focus()

    grid.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Home', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    let rows = container.querySelectorAll('tbody [role="row"]')
    expect(rows[0].getAttribute('tabindex')).toBe('0')

    grid.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'End', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    rows = container.querySelectorAll('tbody [role="row"]')
    expect(rows[2].getAttribute('tabindex')).toBe('0')
  })
})
