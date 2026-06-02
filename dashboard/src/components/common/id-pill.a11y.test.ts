// @vitest-environment happy-dom
//
// jest-axe coverage for IdPill — accent-tinted identifier badge.
// Axe primarily guards: (1) the small text inside the pill stays
// above WCAG AA contrast threshold against the accent-tinted
// background, and (2) when used as a copy target, the wrapping
// button remains accessible.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { IdPill } from './id-pill'

describe('IdPill a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default render passes axe', async () => {
    render(html`<${IdPill}>task-12345<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('mono variant (typical SHA / hash usage) passes axe', async () => {
    render(html`<${IdPill} mono=${true}>9c09dc1a<//>`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with title attribute (hover hint) passes axe', async () => {
    render(
      html`<${IdPill} title="Full task ID: task-12345-abc">task-12345<//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
