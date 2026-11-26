// MASC Dashboard — the questions Keepers are waiting on a human for.
//
// GET  /api/v1/keepers/asks        the open questions, fleet-wide by default
// POST /api/v1/keepers/ask-answer  one answer per question of one ask
//
// Parsing and draft state live in ../lib/keeper-ask-wire and
// ../lib/keeper-ask-draft; this module is only the transport. A response the
// parser refuses is surfaced as an error rather than drawn half-understood: a
// row whose mode this build does not know would offer the operator a control
// the server will reject.

import { ApiRequestError, get, post } from './core'
import { parseAsksSnapshot, type AsksSnapshot } from '../lib/keeper-ask-wire'
import type { AnswerRequestBody } from '../lib/keeper-ask-draft'

export type AnswerAccepted = {
  readonly askId: string
  readonly answerCount: number
  readonly openRemaining: number
  readonly delivered?: boolean
}

/** Someone else answered first. The store settles on first write, so this is
    a normal outcome for two operators on the same question rather than a
    request failure. The winning answer is not carried here on purpose: the
    caller refetches, and the refreshed row is the authority on what was
    recorded. */
export class AskAnswerConflict extends Error {
  readonly askId: string
  constructor(askId: string, detail: string) {
    super(detail)
    this.name = 'AskAnswerConflict'
    this.askId = askId
  }
}

export async function fetchKeeperAsks(
  keeper?: string,
  opts?: { readonly signal?: AbortSignal },
): Promise<AsksSnapshot> {
  const query = keeper !== undefined && keeper !== '' ? `?name=${encodeURIComponent(keeper)}` : ''
  const raw = await get<unknown>(`/api/v1/keepers/asks${query}`, opts)
  const parsed = parseAsksSnapshot(raw)
  if (!parsed.ok) throw new Error(`keeper asks response could not be read: ${parsed.error}`)
  return parsed.value
}

/**
 * Shared SSOT for the server's `ask-answer` HTTP 500 partial-delivery contract:
 * when the durable store recorded the answer (`recorded === true`) and only
 * immediate wakeup awaits outbox recovery (`state !== 'recording_unconfirmed'`),
 * callers must treat the answer as recorded rather than leaving the draft open.
 */
export function isAskAnswerRecordedOn500(
  status: number | null | undefined,
  body: unknown,
): body is Record<string, unknown> {
  if (status !== 500 || typeof body !== 'object' || body === null || Array.isArray(body)) {
    return false
  }
  const payload = body as Record<string, unknown>
  return payload['recorded'] === true && payload['state'] !== 'recording_unconfirmed'
}

export async function answerKeeperAsk(body: AnswerRequestBody): Promise<AnswerAccepted> {
  try {
    const raw = await post<Record<string, unknown>>('/api/v1/keepers/ask-answer', body)
    return {
      askId: typeof raw['ask_id'] === 'string' ? raw['ask_id'] : body.ask_id,
      answerCount: typeof raw['answer_count'] === 'number' ? raw['answer_count'] : 0,
      openRemaining: typeof raw['open_remaining'] === 'number' ? raw['open_remaining'] : 0,
      delivered: raw['delivered'] !== false,
    }
  } catch (error) {
    // 409 is the store telling us someone answered first. Read off the status
    // rather than the message: the prose is for a person, the code is the
    // contract.
    if (error instanceof ApiRequestError && error.status === 409) {
      throw new AskAnswerConflict(body.ask_id, error.detail ?? 'already answered')
    }
    if (error instanceof ApiRequestError && isAskAnswerRecordedOn500(error.status, error.responseData)) {
      const payload = error.responseData
      return {
        askId: typeof payload['ask_id'] === 'string' ? payload['ask_id'] : body.ask_id,
        answerCount: typeof payload['answer_count'] === 'number' ? payload['answer_count'] : 0,
        openRemaining: typeof payload['open_remaining'] === 'number' ? payload['open_remaining'] : 0,
        delivered: false,
      }
    }
    throw error
  }
}
