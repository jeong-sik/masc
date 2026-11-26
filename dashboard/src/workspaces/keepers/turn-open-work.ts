/**
 * The open work of a running Keeper turn, as the chat shows it.
 *
 * RFC open-tool-carries-cohort-and-reach D4. The server sends each piece of
 * open work (`open_activities` in the turn preview): a response still
 * arriving, or a tool call. The chat draws one row each. Calls agent core
 * planned to run at once sit under one header. A call that leaves MASC says so.
 */

import type {
  TurnOpenActivity,
  TurnResponseChannel,
  TurnToolCohort,
  TurnToolReach,
} from './types'

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function finiteNumber(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function nonNegativeInt(v: unknown): number | null {
  return typeof v === 'number' && Number.isInteger(v) && v >= 0 ? v : null
}

function decodeChannel(v: unknown): TurnResponseChannel | null {
  switch (v) {
    case 'none':
    case 'thinking':
    case 'text':
      return v
    default:
      return null
  }
}

function decodeStage(v: unknown): 'requested' | 'executing' | null {
  switch (v) {
    case 'requested':
    case 'executing':
      return v
    default:
      return null
  }
}

/** `null` and an absent field both mean the server named no reach. Any other
 *  value must be one this dashboard knows. */
function decodeReach(v: unknown): { readonly ok: true; readonly value: TurnToolReach | null } | { readonly ok: false } {
  switch (v) {
    case undefined:
    case null:
      return { ok: true, value: null }
    case 'masc_state':
    case 'sandbox':
    case 'network':
    case 'model_provider':
      return { ok: true, value: v }
    default:
      return { ok: false }
  }
}

function decodeCohort(v: unknown): { readonly ok: true; readonly value: TurnToolCohort | null } | { readonly ok: false } {
  if (v === undefined || v === null) return { ok: true, value: null }
  if (!isRecord(v)) return { ok: false }
  const batchIndex = nonNegativeInt(v.batch_index)
  const batchSize = nonNegativeInt(v.batch_size)
  if (batchIndex === null || batchSize === null || typeof v.concurrent !== 'boolean') return { ok: false }
  return { ok: true, value: { batch_index: batchIndex, batch_size: batchSize, concurrent: v.concurrent } }
}

function decodeOpenActivity(raw: unknown): TurnOpenActivity | null {
  if (!isRecord(raw)) return null
  const startedAt = finiteNumber(raw.started_at_unix)
  const since = finiteNumber(raw.since_unix)
  if (startedAt === null || since === null) return null
  if (raw.kind === 'response') {
    const channel = decodeChannel(raw.channel)
    return channel === null ? null : { kind: 'response', channel, started_at_unix: startedAt, since_unix: since }
  }
  if (raw.kind === 'tool') {
    const name = typeof raw.name === 'string' ? raw.name.trim() : ''
    const stage = decodeStage(raw.stage)
    const cohort = decodeCohort(raw.cohort)
    const reach = decodeReach(raw.reach)
    const toolUseId = raw.tool_use_id
    if (name === '' || stage === null || !cohort.ok || !reach.ok) return null
    if (toolUseId !== null && toolUseId !== undefined && typeof toolUseId !== 'string') return null
    return {
      kind: 'tool',
      tool_use_id: typeof toolUseId === 'string' ? toolUseId : null,
      name,
      stage,
      started_at_unix: startedAt,
      since_unix: since,
      cohort: cohort.value,
      reach: reach.value,
    }
  }
  return null
}

/** Reads the server's list whole or not at all. An absent field, or one
 *  entry this dashboard cannot read, gives `null`: the chat then shows no
 *  rows rather than a list with a hole in it. */
export function decodeOpenActivities(raw: unknown): readonly TurnOpenActivity[] | null {
  if (!Array.isArray(raw)) return null
  const decoded: TurnOpenActivity[] = []
  for (const entry of raw) {
    const activity = decodeOpenActivity(entry)
    if (activity === null) return null
    decoded.push(activity)
  }
  return decoded
}

type ToolActivity = Extract<TurnOpenActivity, { readonly kind: 'tool' }>

export type OpenWorkPiece =
  | { readonly kind: 'single'; readonly activity: TurnOpenActivity }
  | { readonly kind: 'batch'; readonly members: readonly ToolActivity[] }

function concurrentBatchOf(activity: TurnOpenActivity): number | null {
  if (activity.kind !== 'tool' || activity.cohort === null) return null
  return activity.cohort.concurrent && activity.cohort.batch_size > 1 ? activity.cohort.batch_index : null
}

/** Server order, except that the open calls of one concurrent batch sit
 *  together at the place of the first one. A batch with one call still open
 *  stays a batch: the others ran with it. */
export function openWorkPieces(activities: readonly TurnOpenActivity[]): readonly OpenWorkPiece[] {
  const pieces: OpenWorkPiece[] = []
  const batchAt = new Map<number, number>()
  for (const activity of activities) {
    const batch = concurrentBatchOf(activity)
    if (batch === null || activity.kind !== 'tool') {
      pieces.push({ kind: 'single', activity })
      continue
    }
    const at = batchAt.get(batch)
    if (at === undefined) {
      batchAt.set(batch, pieces.length)
      pieces.push({ kind: 'batch', members: [activity] })
    } else {
      const piece = pieces[at]
      if (piece?.kind === 'batch') pieces[at] = { kind: 'batch', members: [...piece.members, activity] }
    }
  }
  return pieces
}

/** What the row says the work is doing. */
export function openActivityPhrase(activity: TurnOpenActivity): string {
  if (activity.kind === 'response') {
    switch (activity.channel) {
      case 'thinking':
        return '추론 중'
      case 'text':
        return '답변 쓰는 중'
      case 'none':
        return '모델 응답 기다리는 중'
    }
  }
  switch (activity.stage) {
    case 'requested':
      return `${activity.name} · 호출 준비`
    case 'executing':
      return `${activity.name} · 실행 중`
  }
}

/** The label for a call that leaves MASC or runs in the sandbox. MASC's own
 *  state and an unknown reach say nothing. */
export function openActivityReachLabel(activity: TurnOpenActivity): string | null {
  if (activity.kind !== 'tool') return null
  switch (activity.reach) {
    case 'network':
      return '외부 · 네트워크'
    case 'model_provider':
      return '외부 · 모델'
    case 'sandbox':
      return '샌드박스'
    case 'masc_state':
    case null:
      return null
  }
}

/** True for a call that leaves MASC: the network or a model provider. */
export function openActivityLeavesMasc(activity: TurnOpenActivity): boolean {
  return activity.kind === 'tool' && (activity.reach === 'network' || activity.reach === 'model_provider')
}

export type OpenActivityTone = 'thinking' | 'active' | 'tool'

export function openActivityTone(activity: TurnOpenActivity): OpenActivityTone {
  if (activity.kind === 'tool') return 'tool'
  return activity.channel === 'thinking' ? 'thinking' : 'active'
}
