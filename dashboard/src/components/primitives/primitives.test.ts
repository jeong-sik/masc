import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  bumpSessionEpoch,
  resetAuthStateForTests,
  selectWorkspace,
} from '../../core/auth'
import {
  observedAbsent,
  observedUnreported,
  observedValue,
} from '../../core/resource-cache'
import {
  DataTable,
  MasterDetail,
  QuickPeekDrawer,
  TargetLockedAction,
  VirtualList,
  computeSeriesSignature,
  createCommandSearcher,
  type DataTableColumn,
} from './index'

describe('components/primitives', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    resetAuthStateForTests()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetAuthStateForTests()
  })

  it('DataTable renders "0" for numeric zero vs "없음"/"미보고" for absent/unreported and sets data-label', () => {
    interface MetricRow {
      readonly id: string
      readonly name: string
      readonly errors: ReturnType<typeof observedValue<number>> | ReturnType<typeof observedAbsent>
      readonly latency: ReturnType<typeof observedValue<number>> | ReturnType<typeof observedUnreported>
    }

    const rows: MetricRow[] = [
      { id: 'k1', name: 'sangsu', errors: observedValue(0), latency: observedValue(120) },
      { id: 'k2', name: 'dreamer', errors: observedAbsent(), latency: observedUnreported() },
    ]

    const columns: DataTableColumn<MetricRow>[] = [
      { id: 'name', header: '키퍼', accessor: (r) => r.name, sortable: true },
      { id: 'errors', header: '오류 수', observed: (r) => r.errors, numeric: true },
      { id: 'latency', header: '지연(ms)', observed: (r) => r.latency, numeric: true },
    ]

    render(
      html`<${DataTable} data=${rows} columns=${columns} getRowId=${(r: MetricRow) => r.id} />`,
      container,
    )

    const bodyRows = container.querySelectorAll('tbody tr')
    expect(bodyRows).toHaveLength(2)

    const firstCells = bodyRows[0]!.querySelectorAll('td')
    expect(firstCells[0]!.textContent).toBe('sangsu')
    expect(firstCells[1]!.textContent).toBe('0')
    expect(firstCells[1]!.classList.contains('is-num')).toBe(true)
    expect(firstCells[1]!.getAttribute('data-label')).toBe('오류 수')
    expect(firstCells[2]!.textContent).toBe('120')

    const secondCells = bodyRows[1]!.querySelectorAll('td')
    expect(secondCells[1]!.textContent).toBe('없음')
    expect(secondCells[1]!.querySelector('.dtable-absent')).not.toBeNull()
    expect(secondCells[2]!.textContent).toBe('미보고')
  })

  it('DataTable ignores row click when clicking an interactive descendant inside a clickable row', () => {
    interface Row {
      readonly id: string
      readonly name: string
    }
    const onRowClick = vi.fn()
    const onBtnClick = vi.fn()
    const rows: Row[] = [{ id: 'r1', name: 'sangsu' }]
    const columns: DataTableColumn<Row>[] = [
      { id: 'name', header: '키퍼', accessor: (r) => r.name },
      {
        id: 'act',
        header: '작업',
        cell: () => html`<button type="button" data-testid="nested-btn" onClick=${onBtnClick}>실행</button>`,
      },
    ]

    render(
      html`<${DataTable} data=${rows} columns=${columns} getRowId=${(r: Row) => r.id} onRowClick=${onRowClick} />`,
      container,
    )

    const nestedBtn = container.querySelector('[data-testid="nested-btn"]') as HTMLButtonElement
    nestedBtn.click()
    expect(onBtnClick).toHaveBeenCalledTimes(1)
    expect(onRowClick).not.toHaveBeenCalled()

    const firstCell = container.querySelector('tbody tr td') as HTMLTableCellElement
    firstCell.click()
    expect(onRowClick).toHaveBeenCalledTimes(1)
  })

  it('TargetLockedAction displays 4 identity fields and auto-locks on revision drift OR sessionEpoch change', () => {
    const target = {
      workspaceId: 'default',
      keeper: 'code-reviewer-sister',
      requestId: 'req-9001',
      revision: 4,
    }

    const renderAction = (currentRevision: number) => {
      render(
        html`
          <${TargetLockedAction} target=${target} currentRevision=${currentRevision}>
            <button type="button" class="btn-primary">승인</button>
          <//>
        `,
        container,
      )
    }

    renderAction(4)
    const root = container.querySelector('.tla')!
    expect(root.getAttribute('data-locked')).toBe('false')
    expect(container.textContent).toContain('default')
    expect(container.textContent).toContain('code-reviewer-sister')
    expect(container.textContent).toContain('req-9001')
    expect(container.textContent).toContain('4')
    expect((container.querySelector('fieldset') as HTMLFieldSetElement).disabled).toBe(false)

    // Revision drift locks immediately
    renderAction(5)
    expect(container.querySelector('.tla')!.getAttribute('data-locked')).toBe('true')
    expect(container.querySelector('.tla-lock-banner')).not.toBeNull()
    expect((container.querySelector('fieldset') as HTMLFieldSetElement).disabled).toBe(true)

    // Back to matching revision, then epoch changes via workspace switch -> auto-locks
    renderAction(4)
    expect(container.querySelector('.tla')!.getAttribute('data-locked')).toBe('false')

    bumpSessionEpoch()
    renderAction(4)
    expect(container.querySelector('.tla')!.getAttribute('data-locked')).toBe('true')
    expect((container.querySelector('fieldset') as HTMLFieldSetElement).disabled).toBe(true)

    // Workspace switch mismatch also locks
    resetAuthStateForTests()
    selectWorkspace('ws-other')
    render(
      html`
        <${TargetLockedAction} target=${target} currentRevision=${4}>
          <button type="button">실행</button>
        <//>
      `,
      container,
    )
    expect(container.querySelector('.tla')!.getAttribute('data-locked')).toBe('true')

    // Swapping to a new requestId on a mounted TargetLockedAction refreshes capturedEpoch cleanly
    resetAuthStateForTests()
    render(
      html`
        <${TargetLockedAction} target=${target} currentRevision=${4}>
          <button type="button">승인</button>
        <//>
      `,
      container,
    )
    bumpSessionEpoch()
    render(
      html`
        <${TargetLockedAction} target=${target} currentRevision=${4}>
          <button type="button">승인</button>
        <//>
      `,
      container,
    )
    expect(container.querySelector('.tla')!.getAttribute('data-locked')).toBe('true')

    const nextTarget = { ...target, requestId: 'req-9002', revision: 1 }
    render(
      html`
        <${TargetLockedAction} target=${nextTarget} currentRevision=${1}>
          <button type="button">승인</button>
        <//>
      `,
      container,
    )
    expect(container.querySelector('.tla')!.getAttribute('data-locked')).toBe('false')
  })

  it('QuickPeekDrawer focuses close button on open, does not steal focus on inline onClose re-renders, toggles [⤢], and closes on Escape', async () => {
    const triggerBtn = document.createElement('button')
    document.body.appendChild(triggerBtn)
    triggerBtn.focus()

    const onClose = vi.fn()
    try {
      render(
        html`
          <${QuickPeekDrawer} open=${true} title="Keeper Detail" mode="overlay" onClose=${() => onClose()}>
            <input id="peek-input" type="text" />
          <//>
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))

      const drawer = container.querySelector('.qpeek')!
      expect(drawer.getAttribute('data-wide')).toBe('false')
      expect(drawer.getAttribute('data-mode')).toBe('overlay')
      const closeBtn = container.querySelector('button[aria-label="닫기"]') as HTMLButtonElement
      expect(document.activeElement).toBe(closeBtn)

      // Move focus into the drawer input and re-render with a fresh inline onClose arrow
      const input = container.querySelector('#peek-input') as HTMLInputElement
      input.focus()
      render(
        html`
          <${QuickPeekDrawer} open=${true} title="Keeper Detail Updated" mode="overlay" onClose=${() => onClose()}>
            <input id="peek-input" type="text" />
          <//>
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))
      expect(document.activeElement).toBe(input)

      const wideBtn = container.querySelector('button[aria-pressed]') as HTMLButtonElement
      wideBtn.click()
      await new Promise((r) => setTimeout(r, 0))
      expect(container.querySelector('.qpeek')!.getAttribute('data-wide')).toBe('true')

      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
      expect(onClose).toHaveBeenCalledTimes(1)
    } finally {
      triggerBtn.remove()
    }
  })

  it('computeSeriesSignature stays stable across distinct inline arrays with identical series specs', () => {
    const sig1 = computeSeriesSignature([
      { label: 'Spend', colorToken: '--brass-1', width: 2 },
      { label: 'Turns', colorToken: '--info-fg', dash: [4, 2] },
    ])
    const sig2 = computeSeriesSignature([
      { label: 'Spend', colorToken: '--brass-1', width: 2 },
      { label: 'Turns', colorToken: '--info-fg', dash: [4, 2] },
    ])
    const sig3 = computeSeriesSignature([
      { label: 'Spend', colorToken: '--ok-fg', width: 2 },
    ])
    expect(sig1).toBe(sig2)
    expect(sig1).not.toBe(sig3)
  })

  it('MasterDetail renders split container and emptyDetail when hasSelection is false', () => {
    render(
      html`
        <${MasterDetail}
          hasSelection=${false}
          master=${html`<ul><li>Item 1</li></ul>`}
          detail=${html`<div>Selected Detail</div>`}
          emptyDetail=${html`<p>선택된 항목 없음</p>`}
        />
      `,
      container,
    )
    expect(container.querySelector('.md-split')).not.toBeNull()
    expect(container.querySelector('.md-master')!.textContent).toContain('Item 1')
    expect(container.querySelector('.md-detail')!.textContent).toContain('선택된 항목 없음')

    // Switching selectionKey resets detail pane scrollTop to 0
    render(
      html`<${MasterDetail} selectionKey="item-1" master=${html`<div>M</div>`} detail=${html`<div>D1</div>`} />`,
      container,
    )
    const detailEl = container.querySelector('.md-detail') as HTMLElement
    detailEl.scrollTop = 320
    render(
      html`<${MasterDetail} selectionKey="item-2" master=${html`<div>M</div>`} detail=${html`<div>D2</div>`} />`,
      container,
    )
    expect(detailEl.scrollTop).toBe(0)
  })

  it('VirtualList virtualizes large lists without rendering every DOM node', () => {
    const items = Array.from({ length: 500 }, (_, i) => `Row #${i}`)
    render(
      html`
        <${VirtualList}
          items=${items}
          estimateSize=${32}
          height=${320}
          renderItem=${(item: string) => html`<span>${item}</span>`}
        />
      `,
      container,
    )

    const renderedRows = container.querySelectorAll('.vlist-row')
    expect(renderedRows.length).toBeGreaterThan(0)
    expect(renderedRows.length).toBeLessThan(60)
  })

  // happy-dom does no layout: every box is 0 px tall unless a test says otherwise.
  function layOut(heights: { readonly viewport: number; readonly row?: number }) {
    const viewport = vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockImplementation(function (this: HTMLElement) {
      return this.classList.contains('vlist') || this.classList.contains('dtable-scroll') ? heights.viewport : 0
    })
    const row = vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function (this: Element) {
      return new DOMRect(0, 0, 0, this.hasAttribute('data-index') ? heights.row ?? 0 : 0)
    })
    return () => {
      viewport.mockRestore()
      row.mockRestore()
    }
  }

  const drawnIndexes = (selector: string) =>
    [...container.querySelectorAll(selector)].map((row) => Number(row.getAttribute('data-index')))

  it('VirtualList drawn once follows its own scroll', async () => {
    const restore = layOut({ viewport: 320 })
    try {
      const items = Array.from({ length: 500 }, (_, i) => `Row #${i}`)
      render(
        html`
          <${VirtualList}
            items=${items}
            estimateSize=${32}
            height=${320}
            renderItem=${(item: string) => html`<span>${item}</span>`}
          />
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))
      expect(drawnIndexes('.vlist-row')).toContain(0)

      // Nothing draws the list again here: only the scroll itself can move the window.
      const scroller = container.querySelector<HTMLElement>('.vlist')!
      scroller.scrollTop = 3200
      scroller.dispatchEvent(new Event('scroll'))
      await new Promise((r) => setTimeout(r, 0))

      const indexes = drawnIndexes('.vlist-row')
      expect(indexes).toContain(100)
      expect(indexes).not.toContain(0)
    } finally {
      restore()
    }
  })

  it('VirtualList places a row after the measured height of the rows before it', async () => {
    const restore = layOut({ viewport: 320, row: 57.25 })
    try {
      const items = Array.from({ length: 40 }, (_, i) => `Row #${i}`)
      render(
        html`
          <${VirtualList}
            items=${items}
            estimateSize=${76}
            height=${320}
            renderItem=${(item: string) => html`<span>${item}</span>`}
          />
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))

      const rows = [...container.querySelectorAll<HTMLElement>('.vlist-row')]
      // Not rounded: a row kept as 57 px would overlap the next one by a quarter pixel each.
      expect(rows[1]!.style.transform).toBe('translateY(57.25px)')
      expect(rows[2]!.style.transform).toBe('translateY(114.5px)')
    } finally {
      restore()
    }
  })

  it('VirtualList keeps the estimate for a row that has no layout box', async () => {
    const restore = layOut({ viewport: 320, row: 0 })
    try {
      const items = Array.from({ length: 500 }, (_, i) => `Row #${i}`)
      render(
        html`
          <${VirtualList}
            items=${items}
            estimateSize=${32}
            height=${320}
            renderItem=${(item: string) => html`<span>${item}</span>`}
          />
        `,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))

      const rows = [...container.querySelectorAll<HTMLElement>('.vlist-row')]
      expect(rows[1]!.style.transform).toBe('translateY(32px)')
      expect(rows.length).toBeLessThan(60)
    } finally {
      restore()
    }
  })

  interface LongRow {
    readonly id: string
    readonly label: string
  }
  const longRows: readonly LongRow[] = Array.from({ length: 200 }, (_, i) => ({ id: `r${i}`, label: `Row ${i}` }))
  const longColumns: readonly DataTableColumn<LongRow>[] = [
    { id: 'label', header: 'Label', accessor: (r) => r.label },
  ]

  it('DataTable windowed once follows its own scroll', async () => {
    const restore = layOut({ viewport: 280 })
    try {
      render(
        html`<${DataTable} data=${longRows} columns=${longColumns} getRowId=${(r: LongRow) => r.id} maxHeight=${280} />`,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))
      expect(drawnIndexes('tbody tr[data-index]')).toContain(0)

      const scroller = container.querySelector<HTMLElement>('.dtable-scroll')!
      scroller.scrollTop = 3800
      scroller.dispatchEvent(new Event('scroll'))
      await new Promise((r) => setTimeout(r, 0))

      const indexes = drawnIndexes('tbody tr[data-index]')
      expect(indexes).toContain(100)
      expect(indexes).not.toContain(0)
      expect(container.textContent).toContain('Row 100')
    } finally {
      restore()
    }
  })

  it('DataTable keeps the measured height of the rows it stops drawing', async () => {
    // Drawn rows are 41.5 px tall; the table guesses 38 px until it has drawn one.
    const restore = layOut({ viewport: 280, row: 41.5 })
    try {
      render(
        html`<${DataTable} data=${longRows} columns=${longColumns} getRowId=${(r: LongRow) => r.id} maxHeight=${280} />`,
        container,
      )
      await new Promise((r) => setTimeout(r, 0))

      // Row 12 is at the top of the box; with 8 rows kept above it, rows 0-3 leave the DOM.
      const scroller = container.querySelector<HTMLElement>('.dtable-scroll')!
      scroller.scrollTop = 41.5 * 12 + 10
      scroller.dispatchEvent(new Event('scroll'))
      await new Promise((r) => setTimeout(r, 0))

      expect(drawnIndexes('tbody tr[data-index]')[0]).toBe(4)
      const spaceAbove = container.querySelector<HTMLElement>('tbody tr[aria-hidden="true"] td')!
      expect(spaceAbove.style.height).toBe(`${41.5 * 4}px`)
    } finally {
      restore()
    }
  })

  it('DataTable stops watching the rows of a window once it draws every row', async () => {
    const watched = new Set<Element>()
    const observe = vi.spyOn(ResizeObserver.prototype, 'observe').mockImplementation((element) => { watched.add(element) })
    const unobserve = vi.spyOn(ResizeObserver.prototype, 'unobserve').mockImplementation((element) => { watched.delete(element) })
    const restore = layOut({ viewport: 280, row: 38 })
    try {
      const table = (rows: readonly LongRow[]) =>
        html`<${DataTable} data=${rows} columns=${longColumns} getRowId=${(r: LongRow) => r.id} maxHeight=${280} />`
      render(table(longRows), container)
      await new Promise((r) => setTimeout(r, 0))
      expect([...watched].some((element) => element.getAttribute('data-index') === '0')).toBe(true)

      // A filter leaves three rows: too few for a window, and they were drawn in it.
      render(table(longRows.slice(0, 3)), container)
      await new Promise((r) => setTimeout(r, 0))
      expect(container.querySelectorAll('tbody tr').length).toBe(3)

      // A watched row is measured by its `data-index`; one in the document
      // without it would be measured as no row at every resize.
      const leftBehind = [...watched].filter((element) => element.tagName === 'TR' && element.isConnected && !element.hasAttribute('data-index'))
      expect(leftBehind).toEqual([])
    } finally {
      restore()
      observe.mockRestore()
      unobserve.mockRestore()
    }
  })

  it('DataTable with a width on a column declares the widths of its columns', () => {
    const columns: readonly DataTableColumn<LongRow>[] = [
      { id: 'label', header: 'Label', accessor: (r) => r.label },
      { id: 'id', header: 'Id', width: '6rem', accessor: (r) => r.id },
    ]
    render(html`<${DataTable} data=${longRows.slice(0, 3)} columns=${columns} />`, container)

    expect(container.querySelector('table.dtable')?.getAttribute('data-sized')).toBe('true')
    const widths = [...container.querySelectorAll<HTMLElement>('colgroup col')].map((col) => col.style.width)
    expect(widths).toEqual(['', '6rem'])
    // A header can be cut to its column, so the whole of it is the tooltip.
    expect([...container.querySelectorAll('thead th')].map((th) => th.getAttribute('title'))).toEqual(['Label', 'Id'])
  })

  it('DataTable without column widths stays laid out from its rows', () => {
    render(html`<${DataTable} data=${longRows.slice(0, 3)} columns=${longColumns} />`, container)

    expect(container.querySelector('table.dtable')?.hasAttribute('data-sized')).toBe(false)
    expect(container.querySelector('colgroup')).toBeNull()
    expect(container.querySelector('thead th')?.hasAttribute('title')).toBe(false)
  })

  it('DataTable opens in the order it is given and shows it in the header', () => {
    const columns: readonly DataTableColumn<LongRow>[] = [
      { id: 'label', header: 'Label', accessor: (r) => r.label, sortable: true },
    ]
    render(
      html`<${DataTable} data=${longRows.slice(0, 3)} columns=${columns} initialSort=${{ id: 'label', desc: true }} />`,
      container,
    )

    expect([...container.querySelectorAll('tbody td')].map((cell) => cell.textContent)).toEqual(['Row 2', 'Row 1', 'Row 0'])
    expect(container.querySelector('th')?.getAttribute('aria-sort')).toBe('descending')
  })

  it('DataTable that opens in an order keeps saying an order, and one that opens in none can go back to none', async () => {
    const columns: readonly DataTableColumn<LongRow>[] = [
      { id: 'label', header: 'Label', accessor: (r) => r.label, sortable: true },
    ]
    const labels = () => [...container.querySelectorAll('tbody td')].map((cell) => cell.textContent)
    const said = () => container.querySelector('th')?.getAttribute('aria-sort') ?? null
    const press = async () => {
      container.querySelector<HTMLButtonElement>('th button')!.click()
      await new Promise((resolve) => setTimeout(resolve, 0))
    }

    render(
      html`<${DataTable} data=${longRows.slice(0, 3)} columns=${columns} initialSort=${{ id: 'label', desc: true }} />`,
      container,
    )
    const orders: (string | null)[] = [said()]
    for (let presses = 0; presses < 4; presses++) {
      await press()
      orders.push(said())
    }
    // Every press turns the order round: no press leaves the rows in an
    // order that the header does not name.
    expect(orders).toEqual(['descending', 'ascending', 'descending', 'ascending', 'descending'])
    expect(labels()).toEqual(['Row 2', 'Row 1', 'Row 0'])

    render(null, container)
    render(html`<${DataTable} data=${longRows.slice(0, 3)} columns=${columns} />`, container)
    const unsorted: (string | null)[] = [said()]
    for (let presses = 0; presses < 3; presses++) {
      await press()
      unsorted.push(said())
    }
    // Opened in the order of its rows, a table gets that order back by the
    // third press.
    expect(unsorted).toEqual([null, 'ascending', 'descending', null])
    expect(labels()).toEqual(['Row 0', 'Row 1', 'Row 2'])
  })

  it('command-search matches both fuzzy Latin queries (uFuzzy) and Korean/Hangul labels', () => {
    const searcher = createCommandSearcher([
      { id: 'overview', label: 'Overview 대시보드', keywords: ['home', 'summary'] },
      { id: 'approvals', label: '승인 대기열', keywords: ['hitl', 'gate', 'approve'] },
      { id: 'keeper-cs', label: 'code-reviewer-sister', keywords: ['keeper', 'review'] },
    ])

    const fuzzyHits = searcher.search('rev sis')
    expect(fuzzyHits.length).toBeGreaterThan(0)
    expect(fuzzyHits[0]!.item.id).toBe('keeper-cs')

    const hangulHits = searcher.search('승인')
    expect(hangulHits).toHaveLength(1)
    expect(hangulHits[0]!.item.id).toBe('approvals')
    expect(hangulHits[0]!.labelRanges).toEqual([[0, 2]])
  })
})
