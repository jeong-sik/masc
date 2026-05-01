import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { PlanningStat } from './planning'

describe('PlanningStat', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders label and value', () => {
    render(
      html`<${PlanningStat} label="전체 태스크" value=${42} />`,
      container,
    )

    expect(container.textContent).toContain('전체 태스크')
    expect(container.textContent).toContain('42')
  })

  it('applies default tone class', () => {
    render(
      html`<${PlanningStat} label="Done" value=${5} />`,
      container,
    )

    const valueDiv = container.querySelector('.text-2xl')
    expect(valueDiv?.classList.contains('text-text-strong')).toBe(true)
  })

  it('applies bad tone class', () => {
    render(
      html`<${PlanningStat} label="Errors" value=${3} tone="bad" />`,
      container,
    )

    const valueDiv = container.querySelector('.text-2xl')
    expect(valueDiv?.classList.contains('text-bad')).toBe(true)
  })

  it('applies warn tone class', () => {
    render(
      html`<${PlanningStat} label="Warnings" value=${7} tone="warn" />`,
      container,
    )

    const valueDiv = container.querySelector('.text-2xl')
    expect(valueDiv?.classList.contains('text-warn')).toBe(true)
  })

  it('applies ok tone class', () => {
    render(
      html`<${PlanningStat} label="OK" value=${100} tone="ok" />`,
      container,
    )

    const valueDiv = container.querySelector('.text-2xl')
    expect(valueDiv?.classList.contains('text-ok')).toBe(true)
  })

  it('accepts string value', () => {
    render(
      html`<${PlanningStat} label="Status" value="active" />`,
      container,
    )

    expect(container.textContent).toContain('active')
  })
})
