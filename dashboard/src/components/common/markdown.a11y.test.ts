// @vitest-environment happy-dom
//
// jest-axe coverage for Markdown. The component lazy-loads its
// renderer; tests cover both phases:
//   1. Initial load (synchronous): inline spinner + "loading" label.
//   2. After renderer resolves (async): rendered markdown HTML.
// We test phase 1 directly and rely on InlineSpinner's own a11y suite
// (#11773) for the spinner internals. Phase 2 needs a flush; the
// flushUi pattern matches use-focus-scope.test.ts (Cycle 10 lesson:
// Preact's useEffect needs a setTimeout, not just microtask awaits).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { Markdown } from './markdown'

const flushUi = (): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, 50))

describe('Markdown a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('empty text renders nothing accessibly', async () => {
    render(html`<${Markdown} text="" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('initial loading state passes axe (spinner + label)', async () => {
    render(html`<${Markdown} text="Hello world" />`, container)
    // Synchronous render — should be the loading placeholder.
    expect(await axe(container)).toHaveNoViolations()
  })

  it('after renderer loads, prose passes axe', async () => {
    render(
      html`<${Markdown} text="# Title\n\nSome paragraph text." />`,
      container,
    )
    await flushUi()
    expect(await axe(container)).toHaveNoViolations()
  })

  it('list content after load passes axe', async () => {
    render(
      html`<${Markdown} text="- item 1\n- item 2\n- item 3" />`,
      container,
    )
    await flushUi()
    expect(await axe(container)).toHaveNoViolations()
  })
})
