// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { CursorPagination, Pagination, paginationItems } from './pagination'

describe('paginationItems', () => {
  it('returns every page when the range is small', () => {
    expect(paginationItems({ page: 2, totalPages: 5 })).toEqual([1, 2, 3, 4, 5])
  })

  it('returns ellipses around the current window', () => {
    expect(paginationItems({ page: 9, totalPages: 18 })).toEqual([
      1,
      'ellipsis-start',
      8,
      9,
      10,
      'ellipsis-end',
      18,
    ])
  })

  it('clamps invalid current pages', () => {
    expect(paginationItems({ page: 99, totalPages: 4 })).toEqual([1, 2, 3, 4])
  })

  it('falls back to a single page for non-finite totals and counts', () => {
    expect(paginationItems({ page: 2, totalPages: Number.NaN })).toEqual([1])
    expect(paginationItems({ page: 2, totalPages: Number.POSITIVE_INFINITY })).toEqual([1])
    expect(paginationItems({
      page: 9,
      totalPages: 18,
      siblingCount: Number.NaN,
      boundaryCount: Number.NaN,
    })).toEqual([
      1,
      'ellipsis-start',
      8,
      9,
      10,
      'ellipsis-end',
      18,
    ])
  })
})

describe('Pagination', () => {
  it('renders nav and page buttons', () => {
    const container = document.createElement('div')
    render(h(Pagination, { totalPages: 4, defaultPage: 2 }), container)
    expect(container.querySelector('nav')?.getAttribute('aria-label')).toBe('Pagination')
    expect(container.textContent).toContain('page 2 / 4')
    expect(container.querySelectorAll('button').length).toBe(6)
  })

  it('marks current page with aria-current', () => {
    const container = document.createElement('div')
    render(h(Pagination, { totalPages: 8, page: 3 }), container)
    const current = container.querySelector('[aria-current="page"]') as HTMLButtonElement
    expect(current).not.toBeNull()
    expect(current.textContent).toBe('3')
    expect(current.disabled).toBe(true)
  })

  it('calls onPageChange when a numbered page is clicked', async () => {
    const onPageChange = vi.fn()
    const container = document.createElement('div')
    render(h(Pagination, { totalPages: 5, page: 2, onPageChange }), container)
    const page4 = Array.from(container.querySelectorAll('button')).find(
      (btn) => btn.textContent === '4',
    ) as HTMLButtonElement
    page4.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onPageChange).toHaveBeenCalledWith(4)
  })

  it('updates uncontrolled page when next is clicked', async () => {
    const container = document.createElement('div')
    render(h(Pagination, { totalPages: 5, defaultPage: 2 }), container)
    const next = container.querySelector('[aria-label="Next page"]') as HTMLButtonElement
    next.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('[aria-current="page"]')?.textContent).toBe('3')
  })

  it('disables boundary controls', () => {
    const container = document.createElement('div')
    render(h(Pagination, { totalPages: 3, page: 1 }), container)
    expect((container.querySelector('[aria-label="Previous page"]') as HTMLButtonElement).disabled).toBe(true)
    expect((container.querySelector('[aria-label="Next page"]') as HTMLButtonElement).disabled).toBe(false)
  })

  it('applies testId and custom aria label', () => {
    const container = document.createElement('div')
    render(h(Pagination, { totalPages: 3, ariaLabel: 'Task pages', testId: 'pager' }), container)
    const nav = container.querySelector('[data-testid="pager"]')
    expect(nav).not.toBeNull()
    expect(nav?.getAttribute('aria-label')).toBe('Task pages')
  })

  it('renders a safe fallback when totalPages is not finite', () => {
    const container = document.createElement('div')
    render(h(Pagination, { totalPages: Number.NaN, defaultPage: 2 }), container)
    expect(container.textContent).toContain('page 1 / 1')
    expect(container.querySelectorAll('[aria-current="page"]').length).toBe(1)
  })
})

describe('CursorPagination', () => {
  it('renders cursor and labels', () => {
    const container = document.createElement('div')
    render(h(CursorPagination, { cursor: 'evt-123' }), container)
    expect(container.textContent).toContain('evt-123')
    expect(container.textContent).toContain('Older')
    expect(container.textContent).toContain('Newer')
  })

  it('calls cursor callbacks', async () => {
    const onPrevious = vi.fn()
    const onNext = vi.fn()
    const container = document.createElement('div')
    render(h(CursorPagination, { onPrevious, onNext }), container)
    const buttons = container.querySelectorAll('button')
    ;(buttons[0] as HTMLButtonElement).click()
    ;(buttons[1] as HTMLButtonElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onPrevious).toHaveBeenCalledTimes(1)
    expect(onNext).toHaveBeenCalledTimes(1)
  })

  it('disables unavailable cursor directions', async () => {
    const onPrevious = vi.fn()
    const container = document.createElement('div')
    render(h(CursorPagination, { hasPrevious: false, hasNext: false, onPrevious }), container)
    const buttons = container.querySelectorAll('button')
    expect((buttons[0] as HTMLButtonElement).disabled).toBe(true)
    expect((buttons[1] as HTMLButtonElement).disabled).toBe(true)
    ;(buttons[0] as HTMLButtonElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onPrevious).not.toHaveBeenCalled()
  })
})
