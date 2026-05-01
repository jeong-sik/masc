import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentPresence, agentStatusToPresence, presenceConfig } from './agent-presence'

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
    expect(presenceConfig('working').pulse).toBe(true)
    expect(presenceConfig('idle').label).toBe('대기')
    expect(presenceConfig('offline').label).toBe('오프라인')
  })
})

describe('AgentPresence', () => {
  it('renders data attribute', () => {
    const container = document.createElement('div')
    render(h(AgentPresence, { status: 'active' }), container)
    const el = container.querySelector('[data-presence-state]')
    expect(el?.getAttribute('data-presence-state')).toBe('online')
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
