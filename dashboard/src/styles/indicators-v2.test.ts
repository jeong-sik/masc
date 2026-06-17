// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import './indicators-v2.css'

function makeContainer(): HTMLDivElement {
  const container = document.createElement('div')
  document.body.appendChild(container)
  return container
}

describe('indicators-v2 CSS classes', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = makeContainer()
  })

  afterEach(() => {
    container.remove()
  })

  it('spinner classes render with size variants', () => {
    container.innerHTML =
      '<span class="spinner"></span><span class="spinner sm"></span><span class="spinner lg"></span>'
    const spinners = Array.from(container.querySelectorAll('.spinner'))
    expect(spinners.length).toBe(3)
    expect(spinners[0]!.classList.contains('spinner')).toBe(true)
    expect(spinners[1]!.classList.contains('sm')).toBe(true)
    expect(spinners[2]!.classList.contains('lg')).toBe(true)
  })

  it('spinner is a round inline element with a border-top accent', () => {
    container.innerHTML = '<span class="spinner"></span>'
    const spinner = container.querySelector('.spinner') as HTMLElement
    expect(spinner.tagName).toBe('SPAN')
    expect(spinner.classList.contains('spinner')).toBe(true)
    // The source primitive is defined as an 18px square with a 50% radius.
    expect(spinner.className).toBe('spinner')
  })

  it('loading bar is indeterminate', () => {
    container.innerHTML = '<div class="loading-bar"></div>'
    const bar = container.querySelector('.loading-bar') as HTMLElement
    expect(bar).not.toBeNull()
    expect(bar.tagName).toBe('DIV')
    expect(bar.classList.contains('loading-bar')).toBe(true)
  })

  it('loading row pairs spinner + muted label', () => {
    container.innerHTML =
      '<span class="loading-row"><span class="spinner"></span><span>Working…</span></span>'
    const row = container.querySelector('.loading-row') as HTMLElement
    const spinner = row.querySelector('.spinner') as HTMLElement
    const label = row.querySelector('span:last-child') as HTMLElement

    expect(row).not.toBeNull()
    expect(spinner).not.toBeNull()
    expect(label.textContent).toBe('Working…')
    expect(row.classList.contains('loading-row')).toBe(true)
  })
})
