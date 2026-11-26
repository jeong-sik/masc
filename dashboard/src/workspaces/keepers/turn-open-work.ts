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
  | { readonly kind: 'batch'; readonly batchSize: number; readonly members: readonly ToolActivity[] }

function concurrentBatchOf(activity: TurnOpenActivity): { readonly index: number; readonly size: number } | null {
  if (activity.kind !== 'tool' || activity.cohort === null) return null
  return activity.cohort.concurrent && activity.cohort.batch_size > 1
    ? { index: activity.cohort.batch_index, size: activity.cohort.batch_size }
    : null
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
    const at = batchAt.get(batch.index)
    if (at === undefined) {
      batchAt.set(batch.index, pieces.length)
      pieces.push({ kind: 'batch', batchSize: batch.size, members: [activity] })
    } else {
      const piece = pieces[at]
      if (piece?.kind === 'batch') {
        pieces[at] = {
          kind: 'batch',
          batchSize: Math.max(piece.batchSize, batch.size),
          members: [...piece.members, activity],
        }
      }
    }
  }
  return pieces
}

/** Where a tool call stands. */
export function openToolStageLabel(stage: ToolActivity['stage']): string {
  switch (stage) {
    case 'requested':
      return '호출 준비'
    case 'executing':
      return '실행 중'
  }
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
  return `${activity.name} · ${openToolStageLabel(activity.stage)}`
}

/** The piece of open work one line names, and how many more tool calls are
 *  open behind it. */
export interface OpenWorkLead {
  readonly lead: TurnOpenActivity
  readonly otherCalls: number
}

/** RFC open-tool-carries-cohort-and-reach D4: the one-line summary the rows
 *  expand. A tool call says more than the response that asked for it, and of
 *  the open calls the one that runs is named: a call that never started sits
 *  first in the server's list and must not hide it. The TUI picks the same
 *  piece (`lib/masc_tui/store/fleet_store.ml` `open_work_of_preview`).
 *  `null` when nothing is open. */
export function openWorkLead(activities: readonly TurnOpenActivity[]): OpenWorkLead | null {
  const calls = activities.filter((activity): activity is ToolActivity => activity.kind === 'tool')
  const lead = calls.find((call) => call.stage === 'executing') ?? calls[0] ?? activities[0]
  if (lead === undefined) return null
  return { lead, otherCalls: lead.kind === 'tool' ? calls.length - 1 : 0 }
}

/** How many more calls are open behind the one a line names. */
export function otherCallsLabel(count: number): string {
  return `외 ${count}건`
}

/** The lead in the row's words: for a tool, its name with the count of the
 *  other calls, then where the named call stands. */
export function openWorkLeadPhrase({ lead, otherCalls }: OpenWorkLead): string {
  if (lead.kind === 'response' || otherCalls === 0) return openActivityPhrase(lead)
  return `${lead.name} ${otherCallsLabel(otherCalls)} · ${openToolStageLabel(lead.stage)}`
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
