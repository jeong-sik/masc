// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentPresence } from './agent-presence'

describe('AgentPresence a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly for online status', async () => {
    render(html`<${AgentPresence} status="active" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for working status', async () => {
    render(html`<${AgentPresence} status="busy" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for idle status', async () => {
    render(html`<${AgentPresence} status="idle" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for offline status', async () => {
    render(html`<${AgentPresence} status="offline" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with detail text', async () => {
    render(html`<${AgentPresence} status="busy" detail="compacting" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for unknown status (fallback)', async () => {
    render(html`<${AgentPresence} status="unknown" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for null status', async () => {
    render(html`<${AgentPresence} status=${null} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('both sizes render accessibly', async () => {
    render(
      html`<div>
        <${AgentPresence} status="active" size="sm" />
        <${AgentPresence} status="active" size="md" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
