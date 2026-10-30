// @vitest-environment happy-dom
//
// jest-axe coverage for AgentAvatar — keeper-v2 `.sigil` monogram avatar.
// Tests pin renderings across size variants, heartbeat status, and the
// interactive (onClick) path.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentAvatar } from './agent-avatar'

describe('AgentAvatar a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('default avatar passes axe', async () => {
    render(html`<${AgentAvatar} name="sigma" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('avatar with heartbeat status passes axe', async () => {
    render(
      html`<${AgentAvatar}
        name="alpha"
        status="working"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('avatar with onClick (interactive) passes axe', async () => {
    render(
      html`<${AgentAvatar}
        name="omega"
        onClick=${() => {}}
        size="lg"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('size variants pass axe', async () => {
    render(
      html`<div>
        <${AgentAvatar} name="rho" size="xs" />
        <${AgentAvatar} name="phi" size="xl" status="running" />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
