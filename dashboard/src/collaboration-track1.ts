export const TRACK1_SYNC_BUDGET_MS = 50
export const TRACK1_P95_SYNC_BUDGET_MS = 200
export const TRACK1_AWARENESS_FPS = 30
export const TRACK1_AGENT_SLOTS = 12

export const TRACK1_DOC_IDS = {
  keepers: '/dashboard/keepers',
  turnQueue: '/dashboard/turn-queue',
  activityLog: '/dashboard/activity-log',
  tasks: '/dashboard/tasks',
  gitGraph: '/dashboard/git-graph',
} as const

export type Track1DocId = typeof TRACK1_DOC_IDS[keyof typeof TRACK1_DOC_IDS]
export type Track1Layer = 'authority' | 'projection' | 'ephemeral'

export interface Track1ProjectionFrame {
  kind: 'projection'
  layer: 'projection'
  topic: `yjs:projection:${string}`
  doc_id: Track1DocId | string
  update_b64: string
  seq?: number
  server_ts?: string
  trace_id?: string | null
}

export interface Track1AwarenessFrame {
  kind: 'awareness'
  layer: 'ephemeral'
  topic: `yjs:awareness:${string}`
  client_id: number
  state_b64: string
  room_id?: string
  server_ts?: string
}

export interface Track1RejectFrame {
  kind: 'reject'
  layer: 'authority'
  topic: 'yjs:reject'
  doc_id?: Track1DocId | string
  reason: string
  attempted_topic?: string
  server_ts?: string
}

export type Track1Frame = Track1ProjectionFrame | Track1AwarenessFrame | Track1RejectFrame

export interface Track1TodoSnapshot {
  id: string
  status: 'pending' | 'claimed' | 'done'
  assignedTo: string | null
  logicalClock: number
}

export interface Track1ClaimVerdict {
  taskId: string
  agentId: string
  won: boolean
  retryable: boolean
  reason: 'owned_after_convergence' | 'lost_after_convergence' | 'already_done' | 'not_claimed'
}

export function classifyTrack1Topic(topic: string): Track1Layer | null {
  if (topic.startsWith('yjs:projection:')) return 'projection'
  if (topic.startsWith('yjs:awareness:')) return 'ephemeral'
  if (topic === 'yjs:reject') return 'authority'
  return null
}

export function isTrack1ProjectionDoc(docId: string): docId is Track1DocId {
  return Object.values(TRACK1_DOC_IDS).includes(docId as Track1DocId)
}

export function parseTrack1Frame(payload: unknown): Track1Frame | null {
  if (!isRecord(payload)) return null
  const topic = asString(payload.topic)
  if (!topic) return null

  if (topic.startsWith('yjs:projection:')) {
    const docId = asString(payload.doc_id)
    const update = asString(payload.update_b64)
    if (!docId || !isBase64Payload(update)) return null
    return {
      kind: 'projection',
      layer: 'projection',
      topic: topic as `yjs:projection:${string}`,
      doc_id: docId,
      update_b64: update,
      seq: asNumber(payload.seq),
      server_ts: asString(payload.server_ts),
      trace_id: asNullableString(payload.trace_id),
    }
  }

  if (topic.startsWith('yjs:awareness:')) {
    const clientId = asNumber(payload.client_id)
    const state = asString(payload.state_b64)
    if (clientId === undefined || clientId < 0 || !isBase64Payload(state)) return null
    return {
      kind: 'awareness',
      layer: 'ephemeral',
      topic: topic as `yjs:awareness:${string}`,
      client_id: clientId,
      state_b64: state,
      room_id: asString(payload.room_id),
      server_ts: asString(payload.server_ts),
    }
  }

  if (topic === 'yjs:reject') {
    const reason = asString(payload.reason)
    if (!reason) return null
    return {
      kind: 'reject',
      layer: 'authority',
      topic,
      doc_id: asString(payload.doc_id),
      reason,
      attempted_topic: asString(payload.attempted_topic),
      server_ts: asString(payload.server_ts),
    }
  }

  return null
}

export function verifyTrack1TodoClaim(todo: Track1TodoSnapshot, agentId: string): Track1ClaimVerdict {
  if (todo.status === 'done') {
    return {
      taskId: todo.id,
      agentId,
      won: false,
      retryable: false,
      reason: 'already_done',
    }
  }
  if (todo.assignedTo === agentId) {
    return {
      taskId: todo.id,
      agentId,
      won: true,
      retryable: false,
      reason: 'owned_after_convergence',
    }
  }
  if (todo.assignedTo) {
    return {
      taskId: todo.id,
      agentId,
      won: false,
      retryable: true,
      reason: 'lost_after_convergence',
    }
  }
  return {
    taskId: todo.id,
    agentId,
    won: false,
    retryable: true,
    reason: 'not_claimed',
  }
}

export function track1TelemetryAttributes(frame: Track1Frame): Record<string, string | number> {
  const attrs: Record<string, string | number> = {
    'masc.collab.kind': frame.kind,
    'masc.collab.layer': frame.layer,
    'masc.collab.topic': frame.topic,
  }
  if (frame.kind === 'projection') {
    attrs['masc.collab.doc_id'] = frame.doc_id
    if (frame.seq !== undefined) attrs['masc.collab.seq'] = frame.seq
  } else if (frame.kind === 'awareness') {
    attrs['masc.collab.client_id'] = frame.client_id
    if (frame.room_id) attrs['masc.collab.room_id'] = frame.room_id
  } else if (frame.doc_id) {
    attrs['masc.collab.doc_id'] = frame.doc_id
  }
  return attrs
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

function asNullableString(value: unknown): string | null | undefined {
  if (value === null) return null
  return asString(value)
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function isBase64Payload(value: string | undefined): value is string {
  if (!value || value.length % 4 !== 0) return false
  return /^[A-Za-z0-9+/]+={0,2}$/.test(value)
}
