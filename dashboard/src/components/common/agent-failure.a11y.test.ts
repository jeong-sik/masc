// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentFailure } from './agent-failure'

describe('AgentFailure a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly for retryable failure', async () => {
    render(
      html`<${AgentFailure}
        type="retryable"
        message="Connection timeout"
        retryCount=${1}
        maxRetries=${3}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for non_retryable failure', async () => {
    render(
      html`<${AgentFailure}
        type="non_retryable"
        message="Invalid API key"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for human_required failure', async () => {
    render(
      html`<${AgentFailure}
        type="human_required"
        message="Approval required for destructive action"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly for degraded failure', async () => {
    render(
      html`<${AgentFailure}
        type="degraded"
        message="High latency detected"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly without retry info', async () => {
    render(
      html`<${AgentFailure}
        type="retryable"
        message="Will retry automatically"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty message', async () => {
    render(
      html`<${AgentFailure} type="degraded" message="" />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
