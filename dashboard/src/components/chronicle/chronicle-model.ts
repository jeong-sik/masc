import type {
  ChronicleEvent,
  ChronicleLane,
  ChronicleLinkedTarget,
  ChronicleSummary,
  ChronicleViewModel,
  GitCommitChronicleInput,
  KeeperChronicleInput,
  PlanChronicleInput,
} from './chronicle-types'

const EMPTY_LANE_COUNTS: Record<ChronicleLane, number> = {
  git: 0,
  keeper: 0,
  plan: 0,
  system: 0,
  conversation: 0,
}

function finiteTimestamp(value: number): number | null {
  return Number.isFinite(value) ? value : null
}

function stableEventId(prefix: string, timestamp: number, id: string): string {
  return `${prefix}:${timestamp}:${id}`
}

export function chronicleLaneForEvent(event: ChronicleEvent): ChronicleLane {
  if (event.eventType.startsWith('git.')) return 'git'
  if (event.eventType.startsWith('keeper.') || event.actor.type === 'keeper') return 'keeper'
  if (event.eventType.startsWith('plan.') || event.target.type === 'plan') return 'plan'
  if (event.eventType === 'conversation' || event.target.type === 'conversation') return 'conversation'
  return 'system'
}

export function chronicleLaneLabel(lane: ChronicleLane): string {
  switch (lane) {
    case 'git':
      return 'Git'
    case 'keeper':
      return 'Keeper'
    case 'plan':
      return 'Plan'
    case 'conversation':
      return 'Conversation'
    case 'system':
      return 'System'
  }
}

export function sortChronicleEvents(events: readonly ChronicleEvent[]): ChronicleEvent[] {
  return [...events].sort((a, b) => {
    const aTimestamp = finiteTimestamp(a.timestamp)
    const bTimestamp = finiteTimestamp(b.timestamp)
    if (aTimestamp == null && bTimestamp == null) return a.id.localeCompare(b.id)
    if (aTimestamp == null) return 1
    if (bTimestamp == null) return -1
    const timeDelta = bTimestamp - aTimestamp
    if (timeDelta !== 0) return timeDelta
    return a.id.localeCompare(b.id)
  })
}

export function summarizeChronicleEvents(
  events: readonly ChronicleEvent[],
  totalCount = events.length,
): ChronicleSummary {
  const sorted = sortChronicleEvents(events)
  const sessionIds = new Set<string>()
  const laneCounts = { ...EMPTY_LANE_COUNTS }
  let relatedLinkCount = 0
  let intentCount = 0

  for (const event of sorted) {
    sessionIds.add(event.context.sessionId)
    laneCounts[chronicleLaneForEvent(event)] += 1
    relatedLinkCount += event.context.relatedEventIds.length
    if (event.intent) intentCount += 1
  }

  return {
    totalCount,
    visibleCount: sorted.length,
    latestTimestamp: sorted.length > 0 ? finiteTimestamp(sorted[0]!.timestamp) : null,
    oldestTimestamp: sorted.length > 0 ? finiteTimestamp(sorted[sorted.length - 1]!.timestamp) : null,
    sessionCount: sessionIds.size,
    relatedLinkCount,
    laneCounts,
    intentCount,
  }
}

export function relatedChronicleEvents(
  events: readonly ChronicleEvent[],
  selected: ChronicleEvent | null,
): ChronicleEvent[] {
  if (!selected) return []
  const relatedIds = new Set(selected.context.relatedEventIds)
  return sortChronicleEvents(events).filter(event => {
    if (event.id === selected.id) return false
    return relatedIds.has(event.id)
      || event.context.relatedEventIds.includes(selected.id)
      || event.context.parentEventId === selected.id
      || selected.context.parentEventId === event.id
  })
}

export function linkedChronicleTargets(events: readonly ChronicleEvent[]): ChronicleLinkedTarget[] {
  const counts = new Map<string, ChronicleLinkedTarget>()
  for (const event of events) {
    const key = `${event.target.type}:${event.target.uri}`
    const prev = counts.get(key)
    counts.set(key, {
      key,
      type: event.target.type,
      uri: event.target.uri,
      eventCount: (prev?.eventCount ?? 0) + 1,
    })
  }
  return Array.from(counts.values())
    .sort((a, b) => (b.eventCount - a.eventCount) || a.uri.localeCompare(b.uri))
}

export function buildChronicleViewModel(
  events: readonly ChronicleEvent[],
  selectedEventId?: string | null,
  maxEvents = 100,
): ChronicleViewModel {
  const limit = Number.isFinite(maxEvents) ? Math.max(0, Math.floor(maxEvents)) : 0
  const sorted = sortChronicleEvents(events).slice(0, limit)
  const selectedEvent =
    selectedEventId === null
      ? null
      : selectedEventId === undefined
        ? sorted[0] ?? null
        : sorted.find(event => event.id === selectedEventId) ?? sorted[0] ?? null
  const relatedEvents = relatedChronicleEvents(sorted, selectedEvent)
  const linkedTargets = linkedChronicleTargets(selectedEvent ? [selectedEvent, ...relatedEvents] : [])
  return {
    events: sorted,
    selectedEvent,
    relatedEvents,
    linkedTargets,
    summary: summarizeChronicleEvents(sorted, events.length),
  }
}

export function gitCommitToChronicleEvent(input: GitCommitChronicleInput): ChronicleEvent {
  return {
    id: input.id ?? stableEventId('git.commit', input.timestamp, input.commitSha),
    eventType: 'git.commit',
    timestamp: input.timestamp,
    actor: {
      type: 'system',
      id: input.author ?? 'git',
      displayName: input.author ?? 'Git',
    },
    target: {
      type: 'command',
      uri: `git:${input.commitSha}`,
    },
    content: {
      summary: input.summary,
      detail: input.detail,
      metadata: {
        commitSha: input.commitSha,
        branch: input.branch,
        filesChanged: input.filesChanged,
      },
    },
    context: {
      sessionId: input.sessionId ?? 'git',
      relatedEventIds: input.relatedEventIds ?? [],
      tags: input.tags ?? ['git'],
      projectState: {
        branch: input.branch,
        commit: input.commitSha,
        filesChanged: input.filesChanged,
      },
    },
  }
}

export function keeperStepToChronicleEvent(input: KeeperChronicleInput): ChronicleEvent {
  return {
    id: input.id ?? stableEventId(input.eventType ?? 'keeper.step', input.timestamp, input.keeperId),
    eventType: input.eventType ?? 'keeper.step',
    timestamp: input.timestamp,
    actor: {
      type: 'keeper',
      id: input.keeperId,
      displayName: input.keeperName,
    },
    target: {
      type: 'command',
      uri: input.targetUri ?? `keeper:${input.keeperName}`,
    },
    content: {
      summary: input.summary,
      detail: input.detail,
      metadata: input.metadata,
    },
    context: {
      sessionId: input.sessionId ?? input.keeperId,
      parentEventId: input.parentEventId,
      relatedEventIds: input.relatedEventIds ?? [],
      tags: input.tags ?? ['keeper'],
    },
    intent: input.intent,
  }
}

export function planProgressToChronicleEvent(input: PlanChronicleInput): ChronicleEvent {
  return {
    id: input.id ?? stableEventId(input.eventType ?? 'plan.updated', input.timestamp, input.stepId ?? input.planId),
    eventType: input.eventType ?? 'plan.updated',
    timestamp: input.timestamp,
    actor: {
      type: 'system',
      id: 'plan',
      displayName: 'Plan',
    },
    target: {
      type: 'plan',
      uri: input.stepId ? `${input.planId}#${input.stepId}` : input.planId,
    },
    content: {
      summary: input.summary,
      detail: input.detail,
    },
    context: {
      sessionId: input.sessionId ?? input.planId,
      relatedEventIds: input.relatedEventIds ?? [],
      tags: input.tags ?? ['plan'],
    },
    intent: input.statedGoal
      ? {
          statedGoal: input.statedGoal,
          confidence: 1,
        }
      : undefined,
  }
}
