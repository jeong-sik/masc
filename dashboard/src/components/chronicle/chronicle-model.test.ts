import { describe, expect, it } from 'vitest'
import {
  buildChronicleViewModel,
  chronicleLaneForEvent,
  gitCommitToChronicleEvent,
  keeperStepToChronicleEvent,
  planProgressToChronicleEvent,
  sortChronicleEvents,
  summarizeChronicleEvents,
} from './chronicle-model'

const planEvent = planProgressToChronicleEvent({
  id: 'plan-1',
  timestamp: Date.parse('2026-05-06T09:00:00Z'),
  planId: 'goal:p1',
  stepId: 'chronicle-ui',
  eventType: 'plan.step.completed',
  summary: 'Chronicle UI planned',
  statedGoal: 'restore work history context',
  relatedEventIds: ['keeper-1'],
  sessionId: 'session-a',
})

const keeperEvent = keeperStepToChronicleEvent({
  id: 'keeper-1',
  timestamp: Date.parse('2026-05-06T09:02:00Z'),
  keeperId: 'keeper:sigma',
  keeperName: 'sigma',
  summary: 'Mapped keeper trace into chronicle event',
  targetUri: 'keeper:sigma/trace',
  relatedEventIds: ['plan-1', 'git-1'],
  sessionId: 'session-a',
  intent: { inferredIntent: 'connect trace and plan progress', confidence: 0.82 },
})

const gitEvent = gitCommitToChronicleEvent({
  id: 'git-1',
  timestamp: Date.parse('2026-05-06T09:04:00Z'),
  commitSha: 'abc1234',
  branch: 'feat/chronicle',
  summary: 'Add chronicle read model',
  author: 'codex',
  filesChanged: 3,
  relatedEventIds: ['keeper-1'],
  sessionId: 'session-a',
})

describe('chronicle model', () => {
  it('normalizes Git, Keeper, and Plan sources into lanes', () => {
    expect(chronicleLaneForEvent(gitEvent)).toBe('git')
    expect(chronicleLaneForEvent(keeperEvent)).toBe('keeper')
    expect(chronicleLaneForEvent(planEvent)).toBe('plan')
  })

  it('sorts newest first and summarizes source coverage', () => {
    const events = [planEvent, gitEvent, keeperEvent]
    const sorted = sortChronicleEvents(events)
    const summary = summarizeChronicleEvents(events)

    expect(sorted.map(event => event.id)).toEqual(['git-1', 'keeper-1', 'plan-1'])
    expect(summary).toMatchObject({
      totalCount: 3,
      visibleCount: 3,
      sessionCount: 1,
      relatedLinkCount: 4,
      intentCount: 2,
      laneCounts: {
        git: 1,
        keeper: 1,
        plan: 1,
        system: 0,
        conversation: 0,
      },
    })
    expect(summary.latestTimestamp).toBe(gitEvent.timestamp)
    expect(summary.oldestTimestamp).toBe(planEvent.timestamp)
  })

  it('builds selected context with related events and linked targets', () => {
    const model = buildChronicleViewModel([planEvent, gitEvent, keeperEvent], 'keeper-1')

    expect(model.selectedEvent?.id).toBe('keeper-1')
    expect(model.relatedEvents.map(event => event.id)).toEqual(['git-1', 'plan-1'])
    expect(model.linkedTargets.map(target => target.key)).toEqual([
      'command:git:abc1234',
      'plan:goal:p1#chronicle-ui',
      'command:keeper:sigma/trace',
    ])
  })
})
