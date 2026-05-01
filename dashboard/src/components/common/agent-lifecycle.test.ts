import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentLifecycle } from './agent-lifecycle'

describe('AgentLifecycle', () => {
  it('renders container', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'active' }), container)
    expect(container.querySelector('[role="region"]')).not.toBeNull()
  })

  it('renders current state label', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'active' }), container)
    expect(container.textContent).toContain('활성')
  })

  it('renders unknown state fallback', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'unknown' }), container)
    expect(container.textContent).toContain('unknown')
  })

  it('renders svg diagram', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'created' }), container)
    expect(container.querySelector('svg')).not.toBeNull()
  })

  it('renders last transition info', () => {
    const container = document.createElement('div')
    const ts = Date.now()
    render(
      h(AgentLifecycle, {
        currentState: 'active',
        lastTransition: { from: 'created', to: 'active', timestamp: ts },
      }),
      container,
    )
    expect(container.textContent).toContain('마지막 전환')
    expect(container.textContent).toContain('생성됨')
    expect(container.textContent).toContain('활성')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'idle', testId: 'al-1' }), container)
    expect(container.querySelector('[data-testid="al-1"]')).not.toBeNull()
  })

  it('renders aria-label', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'terminated' }), container)
    const el = container.querySelector('[aria-label^="현재 상태"]')
    expect(el).not.toBeNull()
  })
})
