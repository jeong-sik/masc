import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentLifecycle,
  formatLifecycleTransitionTime,
  lifecycleTransitionKey,
  summarizeAgentLifecycle,
} from './agent-lifecycle'

describe('AgentLifecycle', () => {
  it('formats lifecycle transition timestamps', () => {
    const timestamp = new Date('2024-01-15T09:30:00').getTime()
    expect(formatLifecycleTransitionTime(timestamp)).not.toBe('')
    expect(formatLifecycleTransitionTime(0)).not.toBe('')
    expect(formatLifecycleTransitionTime()).toBe('')
  })

  it('builds stable transition keys', () => {
    expect(lifecycleTransitionKey('created', 'active')).toBe('created→active')
  })

  it('summarizes known current state', () => {
    const timestamp = new Date('2024-01-15T09:30:00').getTime()
    const summary = summarizeAgentLifecycle(
      'active',
      { from: 'created', to: 'active', timestamp },
      lifecycleTransitionKey('created', 'active'),
    )

    expect(summary.currentLabel).toBe('활성')
    expect(summary.currentKnown).toBe(true)
    expect(summary.stateCount).toBe(4)
    expect(summary.transitionCount).toBe(5)
    expect(summary.hasLastTransition).toBe(true)
    expect(summary.lastTransitionFromLabel).toBe('생성됨')
    expect(summary.lastTransitionToLabel).toBe('활성')
    expect(summary.lastTransitionAt).toBe(timestamp)
    expect(summary.lastTransitionTimeLabel).not.toBe('')
    expect(summary.states.find((state) => state.key === 'active')?.current).toBe(true)
    expect(summary.transitions.find((transition) => transition.key === 'created→active')?.flashing).toBe(true)
    const pause = summary.transitions.find((transition) => transition.key === 'active→idle')
    const resume = summary.transitions.find((transition) => transition.key === 'idle→active')
    const timeout = summary.transitions.find((transition) => transition.key === 'idle→terminated')
    expect(Math.abs((pause?.labelX ?? 0) - (resume?.labelX ?? 0))).toBeGreaterThan(60)
    expect(pause?.labelY).toBeGreaterThan(100)
    expect(resume?.labelY).toBeGreaterThan(100)
    expect(timeout?.labelY).toBeGreaterThan((resume?.labelY ?? 0) + 20)
  })

  it('summarizes unknown current state fallback', () => {
    const summary = summarizeAgentLifecycle('unknown')
    expect(summary.currentLabel).toBe('unknown')
    expect(summary.currentKnown).toBe(false)
    expect(summary.hasLastTransition).toBe(false)
    expect(summary.lastTransitionFrom).toBe('')
    expect(summary.flashEdge).toBe('')
  })

  it('renders container', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'active' }), container)
    expect(container.querySelector('[role="region"]')).not.toBeNull()
    expect(container.querySelector('[data-agent-lifecycle]')).not.toBeNull()
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
    const root = container.querySelector('[data-agent-lifecycle]') as HTMLElement
    expect(root.dataset.lifecycleCurrentKnown).toBe('false')
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
    const root = container.querySelector('[data-agent-lifecycle]') as HTMLElement
    expect(root.dataset.lifecycleHasLastTransition).toBe('true')
    expect(root.dataset.lifecycleLastTransitionFrom).toBe('created')
    expect(root.dataset.lifecycleLastTransitionTo).toBe('active')
    expect(root.dataset.lifecycleFlashEdge).toBe('created→active')
    const transition = container.querySelector('[data-lifecycle-transition-key="created→active"]') as HTMLElement
    expect(transition.dataset.lifecycleTransitionFlashing).toBe('true')
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

  it('exposes state and transition metadata', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'active' }), container)

    const root = container.querySelector('[data-agent-lifecycle]') as HTMLElement
    expect(root.dataset.lifecycleCurrentState).toBe('active')
    expect(root.dataset.lifecycleCurrentLabel).toBe('활성')
    expect(root.dataset.lifecycleStateCount).toBe('4')
    expect(root.dataset.lifecycleTransitionCount).toBe('5')

    const current = container.querySelector('[data-lifecycle-state-key="active"]') as HTMLElement
    expect(current.dataset.lifecycleStateCurrent).toBe('true')
    const transition = container.querySelector('[data-lifecycle-transition-key="created→active"]') as HTMLElement
    expect(transition.dataset.lifecycleTransitionLabel).toBe('activate')
  })

  it('uses semantic lifecycle tokens for active state', () => {
    const container = document.createElement('div')
    render(h(AgentLifecycle, { currentState: 'active' }), container)
    const badge = container.querySelector('[aria-label="현재 상태: 활성"]')
    expect(badge?.className).toContain('text-[var(--color-accent-fg)]')
    const current = container.querySelector('[data-lifecycle-state-key="active"]')
    const circle = current?.querySelector('circle:not([opacity])')
    const label = current?.querySelector('text')
    expect(circle?.getAttribute('class')).toContain('stroke-[var(--color-accent-fg)]')
    expect(label?.getAttribute('class')).toContain('fill-[var(--color-accent-fg)]')
  })
})
