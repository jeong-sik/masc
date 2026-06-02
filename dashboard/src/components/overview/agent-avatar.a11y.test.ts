// @vitest-environment happy-dom
//
// jest-axe coverage for AgentAvatar — pixel-art avatar with name +
// status + activity ring. Tests pin renderings across size variants,
// activity-age states, blocker indicator, and the showName toggle.
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

  it('avatar with name + status + traits passes axe', async () => {
    render(
      html`<${AgentAvatar}
        name="alpha"
        status="working"
        traits=${['curious', 'fast']}
        showName=${true}
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

  it('avatar with operational overlays (work + activityAge + blocker + ring) passes axe', async () => {
    render(
      html`<${AgentAvatar}
        name="theta"
        size="xl"
        showName=${true}
        currentWork="processing telemetry batch"
        activityAge=${30}
        hasBlocker=${true}
        signalTruth="live"
        alwaysShowBubble=${true}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('stale + archived signal variants pass axe', async () => {
    render(
      html`<div>
        <${AgentAvatar} name="rho" signalTruth="stale" activityAge=${600} />
        <${AgentAvatar} name="phi" signalTruth="archived" activityAge=${3600} />
      </div>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
