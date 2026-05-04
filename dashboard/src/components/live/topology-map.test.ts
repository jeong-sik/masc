import { describe, it, expect } from 'vitest'
import { topologyNodeColor } from './topology-map'

describe('topologyNodeColor', () => {
  it('returns dim color for offline agent', () => {
    expect(topologyNodeColor('agent', 'offline')).toBe('var(--color-fg-disabled)')
  })

  it('returns dim color for inactive agent', () => {
    expect(topologyNodeColor('agent', 'inactive')).toBe('var(--color-fg-disabled)')
  })

  it('returns cyan for active agent', () => {
    expect(topologyNodeColor('agent', 'active')).toBe('var(--cyan)')
  })

  it('returns cyan for busy agent', () => {
    expect(topologyNodeColor('agent', 'busy')).toBe('var(--cyan)')
  })

  it('returns muted cyan for idle agent', () => {
    expect(topologyNodeColor('agent', 'idle')).toBe('var(--info-border)')
  })

  it('returns green for active keeper', () => {
    expect(topologyNodeColor('keeper', 'active')).toBe('var(--color-status-ok)')
  })

  it('returns warn color for awaiting_verification task', () => {
    expect(topologyNodeColor('task', 'awaiting_verification')).toBe('var(--color-status-warn)')
  })

  it('returns muted green for done task', () => {
    expect(topologyNodeColor('task', 'done')).toBe('var(--ok-border)')
  })

  it('returns yellow for in_progress task', () => {
    expect(topologyNodeColor('task', 'in_progress')).toBe('var(--warn-fg)')
  })
})

