import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { ChronicleNavigator } from './chronicle-navigator'
import {
  gitCommitToChronicleEvent,
  keeperStepToChronicleEvent,
  planProgressToChronicleEvent,
} from './chronicle-model'

const events = [
  planProgressToChronicleEvent({
    id: 'plan-1',
    timestamp: Date.parse('2026-05-06T09:00:00Z'),
    planId: 'goal:p1',
    stepId: 'chronicle-ui',
    eventType: 'plan.step.completed',
    summary: 'Chronicle UI planned',
    detail: '3-panel navigator becomes the first P1 surface.',
    statedGoal: 'restore work history context',
    relatedEventIds: ['keeper-1'],
    sessionId: 'session-a',
  }),
  keeperStepToChronicleEvent({
    id: 'keeper-1',
    timestamp: Date.parse('2026-05-06T09:02:00Z'),
    keeperId: 'keeper:sigma',
    keeperName: 'sigma',
    summary: 'Mapped keeper trace into chronicle event',
    targetUri: 'keeper:sigma/trace',
    relatedEventIds: ['plan-1', 'git-1'],
    sessionId: 'session-a',
    metadata: { traceId: 'trace-123' },
    intent: { inferredIntent: 'connect trace and plan progress', confidence: 0.82 },
  }),
  gitCommitToChronicleEvent({
    id: 'git-1',
    timestamp: Date.parse('2026-05-06T09:04:00Z'),
    commitSha: 'abc1234',
    branch: 'feat/chronicle',
    summary: 'Add chronicle read model',
    author: 'codex',
    filesChanged: 3,
    relatedEventIds: ['keeper-1'],
    sessionId: 'session-a',
  }),
]

describe('ChronicleNavigator', () => {
  it('renders the three chronicle panels and summary metadata', () => {
    const container = document.createElement('div')
    render(h(ChronicleNavigator, { events, selectedEventId: 'keeper-1', testId: 'chronicle' }), container)
    const root = container.querySelector('[data-chronicle-navigator]') as HTMLElement

    expect(root.dataset.chronicleTotalCount).toBe('3')
    expect(root.dataset.chronicleVisibleCount).toBe('3')
    expect(root.dataset.chronicleSelectedId).toBe('keeper-1')
    expect(container.querySelector('[data-chronicle-panel="timeline"]')).not.toBeNull()
    expect(container.querySelector('[data-chronicle-panel="context"]')).not.toBeNull()
    expect(container.querySelector('[data-chronicle-panel="detail"]')).not.toBeNull()
    expect(container.querySelectorAll('[data-chronicle-event-id]')).toHaveLength(3)
  })

  it('shows related events, linked targets, metadata, and intent for the selected event', () => {
    const container = document.createElement('div')
    render(h(ChronicleNavigator, { events, selectedEventId: 'keeper-1' }), container)

    expect(container.textContent).toContain('Add chronicle read model')
    expect(container.textContent).toContain('Chronicle UI planned')
    expect(container.textContent).toContain('keeper:sigma/trace')
    expect(container.textContent).toContain('traceId')
    expect(container.textContent).toContain('trace-123')
    expect(container.querySelector('[data-chronicle-intent]')?.textContent).toContain('82%')
  })

  it('updates detail selection when an event row is clicked', async () => {
    const container = document.createElement('div')
    render(h(ChronicleNavigator, { events }), container)
    const planButton = container.querySelector('[data-chronicle-event-id="plan-1"] button') as HTMLButtonElement

    expect(container.querySelector('[data-chronicle-navigator]')?.getAttribute('data-chronicle-selected-id')).toBe('git-1')
    planButton.click()
    await Promise.resolve()
    expect(container.querySelector('[data-chronicle-navigator]')?.getAttribute('data-chronicle-selected-id')).toBe('plan-1')
    expect(container.textContent).toContain('3-panel navigator becomes the first P1 surface.')
  })
})
