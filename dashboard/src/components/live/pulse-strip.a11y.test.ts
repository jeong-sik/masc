// @vitest-environment happy-dom
//
// jest-axe coverage for PulseStrip — empty state. Populated state
// derives from a live-store computed signal driven by SSE input;
// covering it would require seeding the SSE source. Empty state is
// the more common boot-time path and exercises the same wrapper.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { PulseStrip } from './pulse-strip'

describe('PulseStrip a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('empty state (no agents connected) passes axe', async () => {
    render(html`<${PulseStrip} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
