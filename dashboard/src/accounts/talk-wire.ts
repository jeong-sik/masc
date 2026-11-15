// What the console sends to a person's Keeper and reads of its
// conversations, and how it reads the refusals of those routes
// (lib/server/server_preview_keeper_conversation.ml, `read` and `start`;
// lib/server/server_preview_keeper_turn.ml, `run`). An answer that is not
// what the route promises is not read.

import { isRecord } from '../lib/type-guards'
import { bodyOf, csrfHeader, deliver } from './wire'
import type { Send } from './wire'

export const conversationPath = '/api/v1/auth/keepers/conversation'
export const turnPath = '/api/v1/auth/keepers/turn'

/** The most bytes of UTF-8 a message may have (`max_message_bytes`). */
export const messageLimitBytes = 4096

/** A message of nothing but the characters `String.trim` of OCaml takes
    away, which the server refuses as blank. */
const blankMessage = /^[ \t\n\f\r]*$/

/** Why the page sends no message: the server would refuse it. */
export type Unsendable = 'blank' | 'too_long'

/** What the server would refuse in `message` before it reads anything else, or null. */
export function unsendable(message: string): Unsendable | null {
  if (blankMessage.test(message)) return 'blank'
  return bytesOf(message) > messageLimitBytes ? 'too_long' : null
}

export const bytesOf = (message: string): number => new TextEncoder().encode(message).length

/** The codes of a refusal of the routes of a Keeper's turn and conversation
    (lib/server/server_preview_keeper_error.ml, `code`). A screen tells the
    cases apart by the code, not by the sentence. */
const refusalCodes = [
  'invalid_request', 'message_too_long', 'message_blank', 'runtime_not_supported', 'account_runtime_invalid',
  'turn_refused', 'native_tools_refused', 'unknown_keeper', 'unknown_conversation', 'unknown_account',
  'keeper_has_no_runtime', 'account_call_running', 'conversation_on_other_subscription', 'runtime_reassigned',
  'not_signed_in', 'no_quota', 'silent', 'not_started', 'configuration_refused', 'no_answer', 'answer_unrecorded',
  'conversation_row_not_understood', 'conversation_row_half_written', 'conversation_record_unavailable',
  'server_unavailable', 'internal_error',
] as const

/** Why a route of a Keeper's conversation did not do what was asked. A code
    this console does not know is kept apart, and so is an answer with none. */
export type TalkRefusal = typeof refusalCodes[number] | 'unrecognised'

/** Why a request about a conversation did not give a value: as `Problem`
    of wire.ts, with the code of the refusal. */
export type TalkProblem =
  | { readonly kind: 'signed_out' }
  | { readonly kind: 'refused'; readonly status: number; readonly code: TalkRefusal; readonly reason: string | null }
  | { readonly kind: 'unreadable' }
  | { readonly kind: 'unreachable' }

/** A problem a page shows. A missing session is never shown: the console leaves. */
export type TalkShown = Exclude<TalkProblem, { readonly kind: 'signed_out' }>

export type TalkAnswer<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly problem: TalkProblem }

/** How a turn that has no answer ended, as the record of the conversation
    spells it (lib/server/server_keeper_conversation.ml, `failure_to_string`). */
const failureKinds = ['not_signed_in', 'no_quota', 'silent', 'not_started', 'configuration_refused', 'no_answer'] as const
export type TurnFailure = typeof failureKinds[number] | 'unrecognised'

/** What came of a message the person sent. `modelMayHaveRead` is whether the
    client was started with it, so the Keeper may go on as one who read it
    though the record has no answer. */
export type Outcome =
  | { readonly kind: 'answered'; readonly text: string; readonly model: string; readonly atMs: number }
  | { readonly kind: 'failed'; readonly failure: TurnFailure; readonly atMs: number; readonly modelMayHaveRead: boolean }
  /** The server stopped in the turn, or the row of its end was not written. */
  | { readonly kind: 'unrecorded'; readonly modelMayHaveRead: boolean }

export interface Turn {
  readonly message: string
  readonly askedAtMs: number
  readonly outcome: Outcome
}

/** The current conversation of a Keeper, the one its next turn goes on in:
    `id` is null for a Keeper that has had none. `earlier` counts the
    conversations the Keeper started before it. */
export interface Conversation {
  readonly id: string | null
  readonly turns: readonly Turn[]
  readonly earlier: number
}

/** The last millisecond a `Date` holds (ECMAScript, Time Values and Time
    Range). A time after it is not one the server records, and the page
    could not show it. */
const lastDateMs = 8_640_000_000_000_000

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)
const time = (value: unknown): number | null =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= lastDateMs ? value : null
const idOrNull = (value: unknown): string | null | undefined => (value === null ? null : text(value) ?? undefined)

function readFailure(value: unknown): TurnFailure | null {
  if (typeof value !== 'string') return null
  return failureKinds.find((known) => known === value) ?? 'unrecognised'
}

function readOutcome(json: Readonly<Record<string, unknown>>): Outcome | null {
  switch (json.outcome) {
    case 'answered': {
      const atMs = time(json.answered_at_ms)
      if (typeof json.text !== 'string' || typeof json.model !== 'string' || atMs === null) return null
      return { kind: 'answered', text: json.text, model: json.model, atMs }
    }
    case 'failed': {
      const failure = readFailure(json.failure)
      const atMs = time(json.failed_at_ms)
      if (failure === null || atMs === null || typeof json.model_may_have_read !== 'boolean') return null
      return { kind: 'failed', failure, atMs, modelMayHaveRead: json.model_may_have_read }
    }
    case 'unrecorded':
      return typeof json.model_may_have_read === 'boolean' ? { kind: 'unrecorded', modelMayHaveRead: json.model_may_have_read } : null
    default:
      return null
  }
}

function readTurn(json: unknown): Turn | null {
  if (!isRecord(json)) return null
  const askedAtMs = time(json.asked_at_ms)
  const outcome = readOutcome(json)
  if (typeof json.message !== 'string' || askedAtMs === null || outcome === null) return null
  return { message: json.message, askedAtMs, outcome }
}

/** The current conversation in the answer of a read of the Keeper
    `keeperId` that named no conversation. The server then shows the
    current one, which is the last the Keeper started, and a Keeper with no
    conversation has no turn. */
export function readConversation(json: unknown, keeperId: string): Conversation | null {
  if (!isRecord(json) || json.keeper_id !== keeperId || !Array.isArray(json.conversations) || !Array.isArray(json.turns)) return null
  const shown = idOrNull(json.conversation_id)
  const current = idOrNull(json.current_conversation_id)
  if (shown === undefined || current === undefined || shown !== current) return null
  const listed: string[] = []
  for (const one of json.conversations as readonly unknown[]) {
    if (!isRecord(one)) return null
    const id = text(one.conversation_id)
    if (id === null || text(one.provider_account_id) === null || time(one.started_at_ms) === null) return null
    listed.push(id)
  }
  if (new Set(listed).size !== listed.length) return null
  const turns = (json.turns as readonly unknown[]).map(readTurn)
  if (!turns.every((one): one is Turn => one !== null)) return null
  if (shown === null) return turns.length === 0 && listed.length === 0 ? { id: null, turns, earlier: 0 } : null
  return listed.at(-1) === shown ? { id: shown, turns, earlier: listed.length - 1 } : null
}

function readRefusalCode(value: unknown): TalkRefusal {
  return refusalCodes.find((known) => known === value) ?? 'unrecognised'
}

/** The problem of a refused answer. */
export async function talkProblemOf(response: Response): Promise<TalkProblem> {
  if (response.status === 401) return { kind: 'signed_out' }
  const json = await bodyOf(response)
  return {
    kind: 'refused',
    status: response.status,
    code: isRecord(json) ? readRefusalCode(json.code) : 'unrecognised',
    reason: isRecord(json) ? text(json.error) : null,
  }
}

/** What a turn the Keeper answered came to. `recorded` is whether the
    server wrote it in the conversation of the Keeper: a turn on a Codex
    Runtime is written nowhere, so its answer is only in this answer. */
export interface Answered {
  readonly text: string
  readonly model: string
  readonly recorded: boolean
}

/** The answer of a turn of the Keeper `keeperId`. A turn written in a
    conversation names it and says whether it continued it; one written
    nowhere names neither. */
export function readAnswered(json: unknown, keeperId: string): Answered | null {
  if (!isRecord(json) || json.keeper_id !== keeperId || text(json.runtime_id) === null || typeof json.text !== 'string') return null
  const model = text(json.model)
  const named = json.conversation_id !== undefined || json.continued !== undefined
  if (model === null || (named && (text(json.conversation_id) === null || typeof json.continued !== 'boolean'))) return null
  return { text: json.text, model, recorded: named }
}

/** The id of the conversation a start of the Keeper `keeperId` made. */
export function readStarted(json: unknown, keeperId: string): string | null {
  return isRecord(json) && json.keeper_id === keeperId ? text(json.conversation_id) : null
}

async function post<T>(to: Send, path: string, csrfToken: string, body: unknown, read: (json: unknown) => T | null): Promise<TalkAnswer<T>> {
  const response = await deliver(to, path, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify(body),
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (!response.ok) return { ok: false, problem: await talkProblemOf(response) }
  const value = read(await bodyOf(response))
  return value === null ? { ok: false, problem: { kind: 'unreadable' } } : { ok: true, value }
}

/** Sends `message` to the Keeper `keeperId` and waits for its answer. The
    page sets no deadline: the server stops a turn only once its client has
    said nothing for a while, so a turn that goes on has no end the page
    could know of (lib/runtime/runtime_claude_code.mli, `timeout_s`). */
export const say = (to: Send, csrfToken: string, keeperId: string, message: string): Promise<TalkAnswer<Answered>> =>
  post(to, turnPath, csrfToken, { keeper_id: keeperId, message }, (json) => readAnswered(json, keeperId))

/** Starts a new conversation of the Keeper `keeperId`; its next turn goes on in it. */
export const start = (to: Send, csrfToken: string, keeperId: string): Promise<TalkAnswer<string>> =>
  post(to, conversationPath, csrfToken, { keeper_id: keeperId }, (json) => readStarted(json, keeperId))

/** Reads the current conversation of the Keeper `keeperId`. */
export async function conversationOf(to: Send, keeperId: string): Promise<TalkAnswer<Conversation>> {
  const query = new URLSearchParams({ keeper_id: keeperId })
  const response = await deliver(to, `${conversationPath}?${query.toString()}`, { method: 'GET', headers: { accept: 'application/json' } })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (!response.ok) return { ok: false, problem: await talkProblemOf(response) }
  const conversation = readConversation(await bodyOf(response), keeperId)
  return conversation === null ? { ok: false, problem: { kind: 'unreadable' } } : { ok: true, value: conversation }
}
