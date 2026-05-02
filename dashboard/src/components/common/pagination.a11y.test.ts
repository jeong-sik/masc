// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { CursorPagination, Pagination } from './pagination'

describe('Pagination a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders numeric pagination accessibly', async () => {
    render(html`<${Pagination} totalPages=${12} page=${6} ariaLabel="Task pages" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('marks the current page and hides summary from assistive tech', () => {
    render(html`<${Pagination} totalPages=${7} page=${4} />`, container)
    const current = container.querySelector('[aria-current="page"]')
    expect(current?.getAttribute('aria-label')).toBe('Page 4, current page')
    expect(container.querySelector('nav > span')?.getAttribute('aria-hidden')).toBe('true')
  })

  it('exposes disabled boundary controls', () => {
    render(html`<${Pagination} totalPages=${3} page=${3} />`, container)
    const next = container.querySelector('[aria-label="Next page"]') as HTMLButtonElement
    expect(next.disabled).toBe(true)
  })

  it('renders cursor pagination accessibly', async () => {
    render(
      html`<${CursorPagination}
        cursor="evt-2604-a3f9"
        hasPrevious=${true}
        hasNext=${false}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('does not fire disabled cursor actions', async () => {
    const onNext = vi.fn()
    render(
      html`<${CursorPagination}
        hasNext=${false}
        onNext=${onNext}
      />`,
      container,
    )
    const next = container.querySelector('[aria-label="Newer"]') as HTMLButtonElement
    expect(next.getAttribute('aria-disabled')).toBe('true')
    next.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onNext).not.toHaveBeenCalled()
  })
})
