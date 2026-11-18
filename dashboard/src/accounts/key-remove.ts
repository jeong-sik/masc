// Removing a key account: an account that holds an API key the person
// registered. The server takes the key of the account off its disk and then
// the home of the account, inside the call of the account
// (lib/server/server_key_account_purge.ml, `remove`).
//
// `createRemovals` holds the latest removal of each account; account-rows.ts
// draws it in the card of the account. After an answer that can have changed
// the account, the panel reads the subscriptions again: an account that was
// removed is not in the list, and one whose removal stopped has what the
// removal left on it.

import { signal, type ReadonlySignal } from '@preact/signals'
import { isRecord } from '../lib/type-guards'
import { bodyOf, csrfHeader, deliver } from './wire'
import type { Send } from './wire'

/** The route that removes the key account `accountId` (lib/server/server_login_http.ml). */
export const removePath = (accountId: string): string => `/api/v1/setup/accounts/key/${encodeURIComponent(accountId)}`

/** The codes of a removal the server did not do or did not finish
    (lib/server/server_key_account.ml, `removal_error`). */
const refusalCodes = [
  'unknown_account', 'not_a_key_account', 'account_call_running', 'removal_refused',
  'removal_not_recorded', 'key_not_removed', 'home_not_removed',
] as const

/** Why an account was not removed. A code this console does not know is
    kept apart, and so is an answer with none. */
export type RemovalRefusal = typeof refusalCodes[number] | 'unrecognised'

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)

/** What came of asking the server to remove an account. */
export type Asked =
  | { readonly kind: 'removed' }
  | { readonly kind: 'signed_out' }
  /** `reason` is the server's own sentence. */
  | { readonly kind: 'refused'; readonly status: number; readonly code: RemovalRefusal; readonly reason: string | null }
  /** No answer came: the server may have removed the account. */
  | { readonly kind: 'unreachable' }
  /** An answer came as if all was well, and it does not say the account was
      removed: it is not the answer of this route. */
  | { readonly kind: 'unreadable' }

/** Whether a body is what the route answers once the account is removed
    (lib/server/server_key_account.ml, `remove`). */
const saysRemoved = (json: unknown): boolean => isRecord(json) && json.removed === true

/** Asks the server to remove the key account `accountId`. The request has no
    body: the path names the account. */
export async function removeAccount(to: Send, csrfToken: string, accountId: string): Promise<Asked> {
  const response = await deliver(to, removePath(accountId), { method: 'DELETE', headers: { accept: 'application/json', [csrfHeader]: csrfToken } })
  if (response === null) return { kind: 'unreachable' }
  if (response.status === 401) return { kind: 'signed_out' }
  const json = await bodyOf(response)
  if (response.ok) return saysRemoved(json) ? { kind: 'removed' } : { kind: 'unreadable' }
  const code = isRecord(json) ? json.code : undefined
  return {
    kind: 'refused',
    status: response.status,
    code: refusalCodes.find((known) => known === code) ?? 'unrecognised',
    reason: isRecord(json) ? text(json.error) : null,
  }
}

/** The latest removal of one account. An account that was removed has none:
    it is not in the list any more. */
export type Removing =
  | { readonly kind: 'sending' }
  /** The server did not remove the account, or did not finish. */
  | { readonly kind: 'refused'; readonly status: number; readonly code: RemovalRefusal; readonly reason: string | null; readonly attempts: number }
  /** No answer the page could read came. The server may have removed the
      account: the subscriptions are read again. */
  | { readonly kind: 'unknown'; readonly answer: 'none' | 'unreadable'; readonly attempts: number }
  /** The request found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving' }

/** An account the list no longer shows after this page asked for its
    removal. `already` when the server said it had no such account: another
    page removed it first. */
export interface Gone {
  readonly accountId: string
  readonly already: boolean
}

export interface RemovalsDeps {
  readonly send: Send
  readonly leave: () => void
  /** The CSRF token of the session of the person the panel shows, or null before one. */
  readonly token: () => string | null
  /** Reads the person's subscriptions again. */
  readonly refresh: () => Promise<void>
}

export interface RemovalsModel {
  /** The latest removal of each account the person asked to remove, by the id of the account. */
  readonly removing: ReadonlySignal<ReadonlyMap<string, Removing>>
  /** The account the latest removal took out of the list, set once the list
      was read again, or null before any. */
  readonly gone: ReadonlySignal<Gone | null>
  /** Removes the key account `accountId`. A removal of an account that
      runs, or any removal once the session ended, does nothing. */
  readonly remove: (accountId: string) => Promise<void>
  /** Forgets every removal, for another person is shown now. An answer that
      comes later changes nothing. */
  readonly reset: () => void
}

/** How many removals of the account came to nothing in a row before this one. */
function failedBefore(before: Removing | undefined): number {
  switch (before?.kind) {
    case 'refused':
    case 'unknown':
      return before.attempts
    case undefined:
    case 'sending':
    case 'leaving':
      return 0
  }
}

/** Whether a refused removal can have changed what the list says of the
    account: the server recorded how far it got, or could not say whether
    its record went in. */
function changedTheAccount(code: RemovalRefusal): boolean {
  switch (code) {
    case 'key_not_removed':
    case 'home_not_removed':
    case 'removal_not_recorded':
      return true
    case 'unknown_account':
    case 'not_a_key_account':
    case 'account_call_running':
    case 'removal_refused':
    case 'unrecognised':
      return false
  }
}

export function createRemovals({ send, leave, token, refresh }: RemovalsDeps): RemovalsModel {
  const removing = signal<ReadonlyMap<string, Removing>>(new Map())
  const gone = signal<Gone | null>(null)
  /** Each reset makes a new round; an answer writes only while its round is the latest. */
  let round = 0
  let left = false

  const set = (accountId: string, next: Removing | null): void => {
    const all = new Map(removing.peek())
    if (next === null) all.delete(accountId)
    else all.set(accountId, next)
    removing.value = all
  }

  /** The list is read again first, so the card of the account is off the
      page when the panel says it went. */
  const went = async (mine: number, accountId: string, already: boolean): Promise<void> => {
    await refresh()
    if (mine !== round) return
    set(accountId, null)
    gone.value = { accountId, already }
  }

  const remove = async (accountId: string): Promise<void> => {
    const before = removing.peek().get(accountId)
    const csrfToken = token()
    if (left || before?.kind === 'sending' || csrfToken === null) return
    const mine = round
    const attempts = failedBefore(before) + 1
    set(accountId, { kind: 'sending' })
    const asked = await removeAccount(send, csrfToken, accountId)
    if (mine !== round || left) return
    switch (asked.kind) {
      case 'signed_out': {
        // Every removal that runs is left behind with the page.
        left = true
        const all = new Map(removing.peek())
        for (const [id, one] of all) if (one.kind === 'sending') all.set(id, { kind: 'leaving' })
        removing.value = all
        leave()
        return
      }
      case 'unreachable':
      case 'unreadable':
        set(accountId, { kind: 'unknown', answer: asked.kind === 'unreachable' ? 'none' : 'unreadable', attempts })
        await refresh()
        return
      case 'removed':
        await went(mine, accountId, false)
        return
      case 'refused':
        if (asked.code === 'unknown_account') {
          await went(mine, accountId, true)
          return
        }
        set(accountId, { kind: 'refused', status: asked.status, code: asked.code, reason: asked.reason, attempts })
        if (changedTheAccount(asked.code)) await refresh()
        return
    }
  }

  const reset = (): void => {
    round += 1
    left = false
    removing.value = new Map()
    gone.value = null
  }

  return { removing, gone, remove, reset }
}
