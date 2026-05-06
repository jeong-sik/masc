// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Eyebrow } from './eyebrow'

describe('Eyebrow a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('main')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default render passes axe', async () => {
    render(html`<${Eyebrow}>Runtime<//>`, container)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })

  it('disabled tone with custom class passes axe', async () => {
    render(html`<${Eyebrow} tone="disabled" class="inline-block">Inactive<//>`, container)
    const results = await axe(container)
    expect(results).toHaveNoViolations()
  })
})
