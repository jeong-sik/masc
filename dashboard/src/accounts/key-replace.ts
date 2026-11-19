// Replacing the key of a key account: the person gives another key for an
// account they hold. The server records the replacement, puts the new key
// in place and takes the key before off its disk, inside the call of the
// account (lib/server/server_key_account_replacement.ml, `replace`). Nothing
// of the key comes back in an answer.
//
// `createReplacements` holds the latest replacement of each account;
// key-replace-area.ts draws it in the card of the account. The request has
// no idempotency key: the same key sent twice raises the generation of the
// account twice and leaves the same key in place (RFC, 3.7). The page still
// never sends a key again by itself.

import { signal, type ReadonlySignal } from '@preact/signals'
import { isRecord } from '../lib/type-guards'
import type { Kept } from './key-add'
import { removePath } from './key-remove'
import { bodyOf, csrfHeader, deliver, serverFailure } from './wire'
import type { Send } from './wire'

/** The route of the key account `accountId`: a PUT replaces its key, and a
    DELETE removes it (lib/server/server_login_http.ml). */
export const replacePath = removePath

/** The codes of a replacement the server did not do or did not finish
    (lib/server/server_key_account.ml, `replace`). */
const refusalCodes = [
  'unknown_account', 'not_a_key_account', 'invalid_request', 'not_a_key', 'account_call_running', 'removal_left',
  'replacement_refused', 'internal_error', 'files_not_reached', 'replacement_not_recorded', 'key_not_stored',
] as const

/** Why the key of an account was not replaced. A code this console does not
    know is kept apart, and so is a refusal with none. */
export type ReplacementRefusal = typeof refusalCodes[number] | 'unrecognised'

/** Why the replacement of the key of an account the server has did not go
    through. `unknown_account` is not one: that account is gone. */
export type ReplacementStopped = Exclude<ReplacementRefusal, 'unknown_account'>

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)

/** What came of sending a key for an account. */
export type Asked =
  /** The new key is in place. `oldKeysRemoved` is false when a file of a key
      before stays on the disk of the server. */
  | { readonly kind: 'replaced'; readonly oldKeysRemoved: boolean }
  | { readonly kind: 'signed_out' }
  /** `reason` is the server's own sentence. */
  | { readonly kind: 'refused'; readonly status: number; readonly code: ReplacementRefusal; readonly reason: string | null }
  /** No answer came: the server may have replaced the key. */
  | { readonly kind: 'unreachable' }
  /** An answer came as if all was well, and it does not say the key of this
      account was replaced: it is not the answer of this route. */
  | { readonly kind: 'unreadable' }
  /** A failure with no code of this route. It is not the server's word that
      it changed nothing: what stands in front of the server answers so too,
      after the server replaced the key. */
  | { readonly kind: 'server_failed' }

/** Whether the files of the keys before went, when a body is what the route
    answers once the key of `accountId` is replaced
    (lib/server/server_key_account.ml, `replace`); else null. */
function replacedFor(json: unknown, accountId: string): boolean | null {
  if (!isRecord(json) || json.provider_account_id !== accountId) return null
  return typeof json.old_keys_removed === 'boolean' ? json.old_keys_removed : null
}

/** Sends `key` as the key of the account `accountId`. The key is in the
    body of this one request and nowhere else: a redirect is not followed,
    for it would send the body again to wherever it leads. */
export async function replaceKey(to: Send, csrfToken: string, accountId: string, key: string): Promise<Asked> {
  const response = await deliver(to, replacePath(accountId), {
    method: 'PUT',
    redirect: 'error',
    headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify({ key }),
  })
  if (response === null) return { kind: 'unreachable' }
  if (response.status === 401) return { kind: 'signed_out' }
  const json = await bodyOf(response)
  if (response.ok) {
    const oldKeysRemoved = replacedFor(json, accountId)
    return oldKeysRemoved === null ? { kind: 'unreadable' } : { kind: 'replaced', oldKeysRemoved }
  }
  const code = isRecord(json) ? json.code : undefined
  const known = refusalCodes.find((one) => one === code)
  if (known === undefined && response.status >= serverFailure) return { kind: 'server_failed' }
  return { kind: 'refused', status: response.status, code: known ?? 'unrecognised', reason: isRecord(json) ? text(json.error) : null }
}

/** A replacement that came to nothing the page can show as done. */
export type ReplaceFailure =
  /** The server did not replace the key, or did not finish. */
  | { readonly kind: 'refused'; readonly status: number; readonly code: ReplacementStopped; readonly reason: string | null; readonly attempts: number }
  /** The page has no word of the server on the key: no answer came, or one
      it could not read, or a failure with no code of this route. The server
      may have replaced the key: the subscriptions are read again. */
  | { readonly kind: 'unknown'; readonly answer: 'none' | 'unreadable' | 'server_failed'; readonly attempts: number }

/** The latest replacement of the key of one account. An account with none
    has no field on its card. */
export type Replacing =
  /** The field is on the card. `failure` is what came of the latest replacement, if it came to nothing. */
  | { readonly kind: 'open'; readonly failure: ReplaceFailure | null }
  /** A key is on its way, or the server answered that it took the key or
      has no such account and the subscriptions are read again. The field
      stays as it is. */
  | { readonly kind: 'sending'; readonly failure: ReplaceFailure | null }
  /** The server said the new key is in place. The subscriptions were read again. */
  | { readonly kind: 'replaced'; readonly oldKeysRemoved: boolean }
  /** The server has no such account: another page removed it. The
      subscriptions were read again. */
  | { readonly kind: 'gone' }
  /** A request found that the session had ended; the browser is on its way
      to the sign-in page. Every field that was open went with it. */
  | { readonly kind: 'leaving' }

export interface ReplacementsDeps {
  readonly send: Send
  readonly leave: () => void
  /** The CSRF token of the session of the person the panel shows, or null before one. */
  readonly token: () => string | null
  /** Reads the person's subscriptions again. */
  readonly refresh: () => Promise<void>
}

export interface ReplacementsModel {
  /** The latest replacement of each account the person opened a field for,
      by the id of the account. */
  readonly replacing: ReadonlySignal<ReadonlyMap<string, Replacing>>
  /** Puts the field on the card of `accountId`. While a key of the account
      is on its way, or once the session ended, it does nothing. */
  readonly open: (accountId: string) => void
  /** Takes the field off the card. While a key is on its way it does nothing. */
  readonly close: (accountId: string) => void
  /** Sends `key` as the key of `accountId`, once: with no open field it
      sends nothing and keeps the key. It ends when the answer is read, and
      does not wait for the subscriptions it asks for again: until they
      came, a key the server took would stay in the field. What the card
      says of that key changes once they came. */
  readonly replace: (accountId: string, key: string) => Promise<Kept>
  /** Forgets every replacement: another person is shown now, or the
      browser leaves the page. An answer that comes later changes nothing. */
  readonly reset: () => void
}

/** Whether a refused replacement can have changed what the list says of the
    account: the server recorded the replacement and left the account with
    no key, wrote the intent of one and gave it up, or found a removal left
    on the account. */
function changedTheAccount(code: ReplacementStopped): boolean {
  switch (code) {
    case 'replacement_not_recorded':
    case 'key_not_stored':
    case 'removal_left':
      return true
    case 'not_a_key_account':
    case 'invalid_request':
    case 'not_a_key':
    case 'account_call_running':
    case 'replacement_refused':
    case 'internal_error':
    case 'files_not_reached':
    case 'unrecognised':
      return false
  }
}

export function createReplacements({ send, leave, token, refresh }: ReplacementsDeps): ReplacementsModel {
  const replacing = signal<ReadonlyMap<string, Replacing>>(new Map())
  /** Each reset makes a new round; an answer writes only while its round is the latest. */
  let round = 0
  let left = false

  const set = (accountId: string, next: Replacing): void => {
    replacing.value = new Map(replacing.peek()).set(accountId, next)
  }

  const open = (accountId: string): void => {
    if (left) return
    switch (replacing.peek().get(accountId)?.kind) {
      case undefined:
      case 'replaced':
      case 'gone':
        set(accountId, { kind: 'open', failure: null })
        return
      case 'open':
      case 'sending':
      case 'leaving':
        return
    }
  }

  const close = (accountId: string): void => {
    if (replacing.peek().get(accountId)?.kind !== 'open') return
    const all = new Map(replacing.peek())
    all.delete(accountId)
    replacing.value = all
  }

  /** Shows what the server said of the account once the subscriptions were
      read again. Before that, the card would say it beside what an older
      list says of the account. The button of the account stays held until
      then, as after a removal (key-remove.ts, `went`). */
  const settled = async (mine: number, accountId: string, next: Replacing): Promise<void> => {
    await refresh()
    if (mine === round && !left) set(accountId, next)
  }

  const replace = async (accountId: string, key: string): Promise<Kept> => {
    const before = replacing.peek().get(accountId)
    const csrfToken = token()
    if (before?.kind !== 'open' || csrfToken === null) return 'kept'
    const mine = round
    const attempts = (before.failure?.attempts ?? 0) + 1
    set(accountId, { kind: 'sending', failure: before.failure })
    const asked = await replaceKey(send, csrfToken, accountId, key)
    // The key went to the server for the person who gave it: whatever the
    // page shows now, the field of that person holds it no longer.
    if (mine !== round || left) return 'dropped'
    switch (asked.kind) {
      case 'signed_out': {
        // Every field goes with the page, with what was typed into it,
        // and every replacement that runs is left behind.
        left = true
        const all = new Map(replacing.peek())
        for (const [id, one] of all) if (one.kind === 'open' || one.kind === 'sending') all.set(id, { kind: 'leaving' })
        replacing.value = all
        leave()
        return 'dropped'
      }
      // No branch below waits for the subscriptions it asks for again.
      case 'replaced':
        void settled(mine, accountId, { kind: 'replaced', oldKeysRemoved: asked.oldKeysRemoved })
        return 'dropped'
      case 'unreachable':
      case 'unreadable':
      case 'server_failed':
        set(accountId, { kind: 'open', failure: { kind: 'unknown', answer: asked.kind === 'unreachable' ? 'none' : asked.kind, attempts } })
        void refresh()
        return 'dropped'
      case 'refused':
        if (asked.code === 'unknown_account') {
          void settled(mine, accountId, { kind: 'gone' })
          return 'dropped'
        }
        set(accountId, { kind: 'open', failure: { kind: 'refused', status: asked.status, code: asked.code, reason: asked.reason, attempts } })
        if (changedTheAccount(asked.code)) void refresh()
        return 'kept'
    }
  }

  const reset = (): void => {
    round += 1
    left = false
    replacing.value = new Map()
  }

  return { replacing, open, close, replace, reset }
}
