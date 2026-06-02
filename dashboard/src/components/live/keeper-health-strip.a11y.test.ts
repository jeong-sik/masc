// @vitest-environment happy-dom
//
// jest-axe coverage for KeeperHealthStrip. With totalCount=0 the
// component returns null (no render), which axe should treat as a
// valid clean container. Populated state requires seeding live-store
// from SSE input — out of scope for atom a11y.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { KeeperHealthStrip } from './keeper-health-strip'

describe('KeeperHealthStrip a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('empty state (totalCount=0 → null render) passes axe', async () => {
    render(html`<${KeeperHealthStrip} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
