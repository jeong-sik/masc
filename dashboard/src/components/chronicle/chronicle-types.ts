export type ChronicleActorType = 'user' | 'keeper' | 'agent' | 'system'

export type ChronicleTargetType =
  | 'file'
  | 'module'
  | 'plan'
  | 'issue'
  | 'command'
  | 'test'
  | 'conversation'

export type ChronicleEventType =
  | 'file.opened'
  | 'file.edited'
  | 'file.saved'
  | 'command.executed'
  | 'keeper.started'
  | 'keeper.step'
  | 'keeper.decision'
  | 'keeper.completed'
  | 'keeper.error'
  | 'plan.created'
  | 'plan.updated'
  | 'plan.step.completed'
  | 'plan.blocked'
  | 'build.completed'
  | 'test.passed'
  | 'test.failed'
  | 'git.commit'
  | 'git.merge'
  | 'conversation'
  | 'suggestion.accepted'
  | 'suggestion.rejected'

export type ChronicleLane = 'git' | 'keeper' | 'plan' | 'system' | 'conversation'

export interface ChronicleActor {
  type: ChronicleActorType
  id: string
  displayName: string
}

export interface ChronicleTarget {
  type: ChronicleTargetType
  uri: string
  range?: readonly [number, number]
}

export interface ChronicleProjectSnapshot {
  branch?: string
  commit?: string
  filesChanged?: number
  dirty?: boolean
}

export interface ChronicleContent {
  summary: string
  detail?: string
  diff?: string
  metadata?: Record<string, unknown>
}

export interface ChronicleContext {
  sessionId: string
  parentEventId?: string
  relatedEventIds: readonly string[]
  tags: readonly string[]
  projectState?: ChronicleProjectSnapshot
}

export interface ChronicleIntent {
  statedGoal?: string
  inferredIntent?: string
  confidence: number
}

export interface ChronicleEvent {
  id: string
  eventType: ChronicleEventType
  timestamp: number
  actor: ChronicleActor
  target: ChronicleTarget
  content: ChronicleContent
  context: ChronicleContext
  intent?: ChronicleIntent
}

export interface ChronicleSummary {
  totalCount: number
  visibleCount: number
  latestTimestamp: number | null
  oldestTimestamp: number | null
  sessionCount: number
  relatedLinkCount: number
  laneCounts: Record<ChronicleLane, number>
  intentCount: number
}

export interface ChronicleLinkedTarget {
  key: string
  type: ChronicleTargetType
  uri: string
  eventCount: number
}

export interface ChronicleViewModel {
  events: ChronicleEvent[]
  selectedEvent: ChronicleEvent | null
  relatedEvents: ChronicleEvent[]
  linkedTargets: ChronicleLinkedTarget[]
  summary: ChronicleSummary
}

export interface GitCommitChronicleInput {
  id?: string
  timestamp: number
  commitSha: string
  branch?: string
  author?: string
  summary: string
  detail?: string
  filesChanged?: number
  sessionId?: string
  relatedEventIds?: readonly string[]
  tags?: readonly string[]
}

export interface KeeperChronicleInput {
  id?: string
  timestamp: number
  keeperId: string
  keeperName: string
  eventType?: Extract<ChronicleEventType, `keeper.${string}`>
  summary: string
  detail?: string
  targetUri?: string
  sessionId?: string
  parentEventId?: string
  relatedEventIds?: readonly string[]
  tags?: readonly string[]
  metadata?: Record<string, unknown>
  intent?: ChronicleIntent
}

export interface PlanChronicleInput {
  id?: string
  timestamp: number
  planId: string
  stepId?: string
  eventType?: Extract<ChronicleEventType, `plan.${string}`>
  summary: string
  detail?: string
  statedGoal?: string
  sessionId?: string
  relatedEventIds?: readonly string[]
  tags?: readonly string[]
}
