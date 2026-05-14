// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { IdeActivityPanel } from './ide-activity-panel'

describe('IdeActivityPanel a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({ events: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ))
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    vi.unstubAllGlobals()
  })

  it('renders the run activity pane accessibly', async () => {
    render(html`<${IdeActivityPanel} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
