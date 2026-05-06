import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentPresence,
  agentStatusToPresence,
  presenceConfig,
  summarizeAgentPresence,
} from './agent-presence'

describe('agentStatusToPresence', () => {
  it('maps active to online', () => {
    expect(agentStatusToPresence('active')).toBe('online')
  })

  it('maps busy to working', () => {
    expect(agentStatusToPresence('busy')).toBe('working')
  })

  it('maps listening to working', () => {
    expect(agentStatusToPresence('listening')).toBe('working')
  })

  it('maps idle to idle', () => {
    expect(agentStatusToPresence('idle')).toBe('idle')
  })

  it('maps inactive to offline', () => {
    expect(agentStatusToPresence('inactive')).toBe('offline')
  })

  it('maps offline to offline', () => {
    expect(agentStatusToPresence('offline')).toBe('offline')
  })

  it('defaults unknown to offline', () => {
    expect(agentStatusToPresence('unknown')).toBe('offline')
  })

  it('handles null', () => {
    expect(agentStatusToPresence(null)).toBe('offline')
  })
})

describe('presenceConfig', () => {
  it('returns config for each state', () => {
    expect(presenceConfig('online').label).toBe('온라인')
    expect(presenceConfig('online').colorClass).toContain('var(--color-status-ok)')
    expect(presenceConfig('working').pulse).toBe(true)
    expect(presenceConfig('working').colorClass).toContain('var(--color-accent-fg)')
    expect(presenceConfig('idle').label).toBe('대기')
    expect(presenceConfig('idle').colorClass).toContain('var(--color-status-warn)')
    expect(presenceConfig('offline').label).toBe('오프라인')
  })
})

describe('summarizeAgentPresence', () => {
  it('summarizes mapped status, label, size, and detail', () => {
    expect(summarizeAgentPresence('busy', 'compacting', 'md')).toEqual({
      rawStatus: 'busy',
      state: 'working',
      label: '작업 중',
      pulse: true,
      size: 'md',
      detail: 'compacting',
      detailPresent: true,
    })
  })

  it('normalizes null status and detail', () => {
    expect(summarizeAgentPresence(null, null, 'sm')).toEqual({
      rawStatus: '',
      state: 'offline',
      label: '오프라인',
      pulse: false,
      size: 'sm',
      detail: '',
      detailPresent: false,
    })
  })
})

describe('AgentPresence', () => {
  it('renders data attribute', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: 'active' }), container)
    const el = container.querySelector('[data-presence-state]')
    expect(el?.getAttribute('data-presence-state')).toBe('online')
  })

  it('exposes summary data attributes', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: 'busy', detail: 'task-123', size: 'md' }), container)
    const el = container.querySelector('[data-agent-presence]') as HTMLElement
    expect(el.dataset.presenceRawStatus).toBe('busy')
    expect(el.dataset.presenceState).toBe('working')
    expect(el.dataset.presenceLabel).toBe('작업 중')
    expect(el.dataset.presencePulse).toBe('true')
    expect(el.dataset.presenceSize).toBe('md')
    expect(el.dataset.presenceDetailPresent).toBe('true')
    expect(el.dataset.presenceDetail).toBe('task-123')
  })

  it('exposes empty detail metadata', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: null }), container)
    const el = container.querySelector('[data-agent-presence]') as HTMLElement
    expect(el.dataset.presenceRawStatus).toBe('')
    expect(el.dataset.presenceDetailPresent).toBe('false')
    expect(el.dataset.presenceDetail).toBe('')
  })

  it('renders label text', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: 'busy' }), container)
    expect(container.textContent).toContain('작업 중')
  })

  it('renders detail when provided', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: 'active', detail: 'task-123' }), container)
    expect(container.textContent).toContain('task-123')
    expect(container.querySelector('[title="task-123"]')).not.toBeNull()
  })

  it('uses sm size by default', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: 'idle' }), container)
    expect(container.querySelector('[data-agent-presence]')).not.toBeNull()
  })

  it('uses md size', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: 'active', size: 'md' }), container)
    expect(container.querySelector('[data-agent-presence]')).not.toBeNull()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: 'offline', testId: 'ap-1' }), container)
    expect(container.querySelector('[data-testid="ap-1"]')).not.toBeNull()
  })
})
