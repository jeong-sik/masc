import { describe, expect, it } from 'vitest'
import { html } from 'htm/preact'
import { render } from '@testing-library/preact'
import { act } from 'preact/test-utils'
import { axe } from 'jest-axe'

import { AgentLifecycle } from './agent-lifecycle'

function renderInAct(ui: ReturnType<typeof html>) {
  let result: ReturnType<typeof render>
  act(() => {
    result = render(ui)
  })
  return result!
}

describe('AgentLifecycle a11y', () => {
  it('has no axe violations (created state)', async () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle} currentState="created" />`
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has no axe violations (active state)', async () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle} currentState="active" />`
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has no axe violations (idle state)', async () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle} currentState="idle" />`
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has no axe violations (terminated state)', async () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle} currentState="terminated" />`
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has region role and label', () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle} currentState="active" />`
    )
    const region = container.querySelector('[role="region"]')
    expect(region).not.toBeNull()
    expect(region?.getAttribute('aria-label')).toBe('에이전트 생명주기')
  })

  it('svg has img role and accessible name', () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle} currentState="active" />`
    )
    const svg = container.querySelector('[role="img"]')
    expect(svg).not.toBeNull()
    const label = svg?.getAttribute('aria-label')
    expect(label).toContain('생성됨')
    expect(label).toContain('활성')
  })

  it('current state badge has accessible name', () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle} currentState="active" />`
    )
    const badge = container.querySelector('[aria-label="현재 상태: 활성"]')
    expect(badge).not.toBeNull()
  })

  it('renders last transition info', () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle}
        currentState="active"
        lastTransition=${{ from: 'created', to: 'active', timestamp: Date.now() }}
      />`
    )
    const info = container.querySelector('[aria-label="에이전트 생명주기"]')
    expect(info?.textContent).toContain('마지막 전환')
    expect(info?.textContent).toContain('생성됨')
    expect(info?.textContent).toContain('활성')
  })

  it('unknown state falls back to raw state name', () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle} currentState="unknown" />`
    )
    const badge = container.querySelector('[aria-label="현재 상태: unknown"]')
    expect(badge).not.toBeNull()
  })

  it('has no axe violations with lastTransition', async () => {
    const { container } = renderInAct(
      html`<${AgentLifecycle}
        currentState="idle"
        lastTransition=${{ from: 'active', to: 'idle', timestamp: Date.now() }}
      />`
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
