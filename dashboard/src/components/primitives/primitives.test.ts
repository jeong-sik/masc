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
  })

  it('QuickPeekDrawer toggles wide mode [⤢] and closes on Escape', async () => {
    const onClose = vi.fn()
    render(
      html`
        <${QuickPeekDrawer} open=${true} title="Keeper Detail" mode="overlay" onClose=${onClose}>
          <p>Read-only body</p>
        <//>
      `,
      container,
    )

    const drawer = container.querySelector('.qpeek')!
    expect(drawer.getAttribute('data-wide')).toBe('false')
    expect(drawer.getAttribute('data-mode')).toBe('overlay')

    const wideBtn = container.querySelector('button[aria-pressed]') as HTMLButtonElement
    wideBtn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('.qpeek')!.getAttribute('data-wide')).toBe('true')

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(onClose).toHaveBeenCalledTimes(1)
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
