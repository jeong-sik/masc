// @vitest-environment happy-dom
//
// jest-axe coverage for CommandPalette wrapper. The actual interactive
// element is the third-party `<ninja-keys>` Lit web component, which
// is dynamically imported. happy-dom may not fully resolve the import
// but the wrapper element + style attribute should still axe-clean.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { CommandPalette } from './command-palette'

describe('CommandPalette a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('wrapper renders accessibly even when ninja-keys lazy-import is unresolved', async () => {
    render(html`<${CommandPalette} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
