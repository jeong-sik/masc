// Checking a model of a connected account. The server calls the model once
// through the account, with one tool to call, and records a Runtime of the
// person when the model answered and called it
// (lib/server/server_setup_account_login.ml, `verify`). A Keeper of the
// person runs only on such a Runtime.
//
// `createChecks` holds the latest check of each account; account-rows.ts
// draws it in the card of the account. Once a check passes, the panel reads
// the subscriptions again, so the card shows the new Runtime.

import { signal, type ReadonlySignal } from '@preact/signals'
import { isRecord } from '../lib/type-guards'
import type { Shown } from './notes'
import { bodyOf, csrfHeader, deliver, problemOf } from './wire'
import type { Answer, Send } from './wire'

export const checkPath = '/api/v1/setup/accounts/verify'

/** How long a check may take, in minutes: the server gives the call of a
    model two minutes (`verification_timeout_s`). */
export const checkLimitMinutes = 2

/** How long the page waits for the answer of a check: the server's two
    minutes, and the start and stop of the client around them. A check with
    no answer by then is one whose end the page does not know. */
export const checkDeadlineMs = 150_000

/** The codes of a call that could not be made (status `unavailable`) and of
    a call that was made and did not pass (status `failed`), as
    lib/runtime/runtime_verification.ml gives them (`failure_code`,
    `status_of_failure`). */
const unavailableCodes = [
  'missing_credential', 'invalid_credential', 'unsupported_runtime', 'tools_not_declared',
  'invalid_configuration', 'client_not_authenticated', 'client_not_started', 'account_not_authorized',
] as const
const failedCodes = [
  'rate_limited', 'quota_exhausted', 'provider_overloaded', 'provider_auth_refused',
  'provider_unreachable', 'model_not_found', 'provider_rejected', 'timed_out',
  'tool_not_called', 'tool_result_not_consumed', 'empty_response', 'model_unreported',
] as const

/** Why the call of a model did not pass. A code this console does not know
    is kept apart. */
export type CheckFailure = typeof unavailableCodes[number] | typeof failedCodes[number] | 'unrecognised'

/** What the server's call of a model found. */
export type Checked =
  /** The model answered and called the tool, and the person has a Runtime
      of it. `made` when this check made the Runtime; a Runtime of the same
      model made before is kept. */
  | { readonly kind: 'passed'; readonly made: boolean }
  /** `reason` is the server's own sentence. */
  | { readonly kind: 'failed'; readonly failure: CheckFailure; readonly reason: string | null }

const schema = 'masc.runtime_verification.v1'

/** The failure of `code` under `status`, or null when the server gives
    that code under the other status. */
function failureOf(status: 'failed' | 'unavailable', code: string): CheckFailure | null {
  const unavailable = unavailableCodes.find((known) => known === code)
  if (unavailable !== undefined) return status === 'unavailable' ? unavailable : null
  const failed = failedCodes.find((known) => known === code)
  if (failed !== undefined) return status === 'failed' ? failed : null
  return 'unrecognised'
}

/** The answer of a check: a passed call comes with its Runtime and no
    failure, and a failed one with a failure and no Runtime
    (`Runtime_verification.status_of_failure`). */
export function readChecked(json: unknown): Checked | null {
  if (!isRecord(json) || !isRecord(json.verification)) return null
  const { verification, runtime } = json
  if (verification.schema !== schema) return null
  const failure = verification.failure
  switch (verification.status) {
    case 'verified': {
      if (failure !== null || !isRecord(runtime) || typeof runtime.runtime_id !== 'string' || runtime.runtime_id === '') return null
      if (runtime.record !== 'made' && runtime.record !== 'existing') return null
      return { kind: 'passed', made: runtime.record === 'made' }
    }
    case 'failed':
    case 'unavailable': {
      if (runtime !== null || !isRecord(failure) || typeof failure.code !== 'string') return null
      const known = failureOf(verification.status, failure.code)
      if (known === null) return null
      const reason = typeof failure.message === 'string' && failure.message !== '' ? failure.message : null
      return { kind: 'failed', failure: known, reason }
    }
    default:
      return null
  }
}

/** Asks the server to call `model` through the account `accountId`. The
    answer comes once the call ends; one that has not come by
    `checkDeadlineMs` is given up, as if none came. */
export async function checkModel(to: Send, csrfToken: string, accountId: string, model: string): Promise<Answer<Checked>> {
  const stop = new AbortController()
  const deadline = setTimeout(() => { stop.abort() }, checkDeadlineMs)
  try {
    const response = await deliver(to, checkPath, {
      method: 'POST',
      headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
      body: JSON.stringify({ provider_account_id: accountId, model }),
      signal: stop.signal,
    })
    if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
    if (!response.ok) return { ok: false, problem: await problemOf(response) }
    const checked = readChecked(await bodyOf(response))
    return checked === null ? { ok: false, problem: { kind: 'unreadable' } } : { ok: true, value: checked }
  } finally {
    clearTimeout(deadline)
  }
}

/** A request the server refused, so no call was made of it: it answered with a status that says why. */
type Refused = Extract<Shown, { kind: 'refused' }>
/** No answer the page could read came: the server may have made the call. */
type Unanswered = Exclude<Shown, Refused>

/** The latest check of a model of one account. */
export type Check =
  | { readonly kind: 'checking'; readonly model: string }
  | { readonly kind: 'passed'; readonly model: string; readonly made: boolean }
  /** The server called the model, and the call did not pass. */
  | { readonly kind: 'failed'; readonly model: string; readonly failure: CheckFailure; readonly reason: string | null; readonly attempts: number }
  /** The server refused the request. */
  | { readonly kind: 'not_done'; readonly model: string; readonly problem: Refused; readonly attempts: number }
  /** No answer the page could read came. The server may have made the call
      and recorded a Runtime: the subscriptions are read again. */
  | { readonly kind: 'unknown'; readonly model: string; readonly problem: Unanswered; readonly attempts: number }
  /** The request found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving'; readonly model: string }

export interface ChecksDeps {
  readonly send: Send
  readonly leave: () => void
  /** The CSRF token of the session of the person the panel shows, or null before one. */
  readonly token: () => string | null
  /** Reads the person's subscriptions again. */
  readonly refresh: () => Promise<void>
}

export interface ChecksModel {
  /** The latest check of each account the person checked a model of, by the id of the account. */
  readonly checks: ReadonlySignal<ReadonlyMap<string, Check>>
  /** Checks `model` on the account `accountId`. The server calls one model
      of an account at a time, so a check of an account that runs, or any
      check once the session ended, does nothing. */
  readonly check: (accountId: string, model: string) => Promise<void>
  /** Forgets every check, for another person is shown now. An answer that
      comes later changes nothing. */
  readonly reset: () => void
}

/** How many checks of `model` on the account came to nothing in a row before this one. */
function failedBefore(before: Check | undefined, model: string): number {
  if (before === undefined || before.model !== model) return 0
  switch (before.kind) {
    case 'failed':
    case 'not_done':
    case 'unknown':
      return before.attempts
    case 'checking':
    case 'passed':
    case 'leaving':
      return 0
  }
}

export function createChecks({ send, leave, token, refresh }: ChecksDeps): ChecksModel {
  const checks = signal<ReadonlyMap<string, Check>>(new Map())
  /** Each reset makes a new round; an answer writes only while its round is the latest. */
  let round = 0
  let left = false

  const set = (accountId: string, check: Check): void => {
    const next = new Map(checks.peek())
    next.set(accountId, check)
    checks.value = next
  }

  const check = async (accountId: string, model: string): Promise<void> => {
    const before = checks.peek().get(accountId)
    const csrfToken = token()
    if (left || before?.kind === 'checking' || csrfToken === null) return
    const mine = round
    set(accountId, { kind: 'checking', model })
    const answer = await checkModel(send, csrfToken, accountId, model)
    if (mine !== round || left) return
    const attempts = failedBefore(before, model) + 1
    if (!answer.ok) {
      const problem = answer.problem
      switch (problem.kind) {
        case 'signed_out': {
          // Every check that runs is left behind with the page.
          left = true
          const next = new Map(checks.peek())
          for (const [id, one] of next) if (one.kind === 'checking') next.set(id, { kind: 'leaving', model: one.model })
          checks.value = next
          leave()
          return
        }
        case 'refused':
          set(accountId, { kind: 'not_done', model, problem, attempts })
          return
        case 'unreachable':
        case 'unreadable':
          set(accountId, { kind: 'unknown', model, problem, attempts })
          await refresh()
          return
      }
    }
    const checked = answer.value
    if (checked.kind === 'failed') {
      set(accountId, { kind: 'failed', model, failure: checked.failure, reason: checked.reason, attempts })
      return
    }
    set(accountId, { kind: 'passed', model, made: checked.made })
    await refresh()
  }

  const reset = (): void => {
    round += 1
    left = false
    checks.value = new Map()
  }

  return { checks, check, reset }
}
