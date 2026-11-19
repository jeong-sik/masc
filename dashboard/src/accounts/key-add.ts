// Connecting a subscription with an API key. The person gives a key of
// their own; the server records an account for it and stores the key in a
// file of that account (lib/server/server_key_account_registration.ml).
// Nothing of the key comes back in an answer.
//
// `createKeyAdds` holds the one add of the person the panel shows;
// `KeyArea` (key-area.ts) draws it. The request has no idempotency key: the
// same key sent twice makes two accounts. So the page never sends a key
// again by itself, and after an answer it could not read it asks the person
// to look at the list before they send it again (RFC, 3.3).

import { signal, type ReadonlySignal } from '@preact/signals'
import { isRecord } from '../lib/type-guards'
import { bodyOf, csrfHeader, deliver, serverFailure } from './wire'
import type { Send } from './wire'

/** The route that registers a key (lib/server/server_login_http.ml). */
export const addPath = '/api/v1/setup/accounts/key'

/** The codes of a key the server did not take, or took and could not keep
    (lib/server/server_key_account.ml, `register`). */
const refusalCodes = [
  'invalid_request', 'not_a_key', 'unknown_integration', 'integration_takes_no_key', 'registration_refused',
  'internal_error', 'configuration_unavailable', 'registration_not_recorded', 'key_not_stored', 'account_not_removed',
] as const

/** Why a key was not stored. A code this console does not know is kept
    apart, and so is an answer with none. */
export type AddRefusal = typeof refusalCodes[number] | 'unrecognised'

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)

/** What came of sending a key. */
export type Sent =
  /** The server recorded the account `accountId` and stored the key. */
  | { readonly kind: 'stored'; readonly accountId: string }
  | { readonly kind: 'signed_out' }
  /** `reason` is the server's own sentence. `accountId` is the account the
      server recorded and could not remove again (`account_not_removed`),
      else null. */
  | { readonly kind: 'refused'; readonly status: number; readonly code: AddRefusal; readonly reason: string | null; readonly accountId: string | null }
  /** No answer came: the server may have stored the key. */
  | { readonly kind: 'unreachable' }
  /** An answer came as if all was well, and it names no key account: it is
      not the answer of this route. */
  | { readonly kind: 'unreadable' }
  /** A failure with no code of this route. It is not the server's word that
      it stored nothing: what stands in front of the server answers so too,
      after the server stored the key. */
  | { readonly kind: 'server_failed' }

/** The account a body says the key was stored for
    (lib/server/server_key_account.ml, `register`), or null. */
function storedFor(json: unknown): string | null {
  return isRecord(json) && json.kind === 'key' ? text(json.provider_account_id) : null
}

/** Sends `key` for a new account of the subscription `integrationId`. The
    key is in the body of this one request and nowhere else. */
export async function addKey(to: Send, csrfToken: string, integrationId: string, key: string): Promise<Sent> {
  const response = await deliver(to, addPath, {
    method: 'POST',
    // A redirect would send the body, with the key, again to wherever it leads.
    redirect: 'error',
    headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify({ integration_id: integrationId, key }),
  })
  if (response === null) return { kind: 'unreachable' }
  if (response.status === 401) return { kind: 'signed_out' }
  const json = await bodyOf(response)
  if (response.ok) {
    const accountId = storedFor(json)
    return accountId === null ? { kind: 'unreadable' } : { kind: 'stored', accountId }
  }
  const code = isRecord(json) ? json.code : undefined
  const known = refusalCodes.find((one) => one === code)
  if (known === undefined && response.status >= serverFailure) return { kind: 'server_failed' }
  return {
    kind: 'refused',
    status: response.status,
    code: known ?? 'unrecognised',
    reason: isRecord(json) ? text(json.error) : null,
    accountId: isRecord(json) ? text(json.provider_account_id) : null,
  }
}

/** An add that came to nothing the page can show as done. */
export type AddFailure =
  /** The server did not store the key. */
  | { readonly kind: 'refused'; readonly status: number; readonly code: AddRefusal; readonly reason: string | null; readonly accountId: string | null; readonly attempts: number }
  /** The page has no word of the server on the key: no answer came, or one
      it could not read, or a failure with no code of this route. The server
      may have stored the key: the subscriptions are read again, and the
      person looks at them before they send the key again. */
  | { readonly kind: 'unknown'; readonly answer: 'none' | 'unreadable' | 'server_failed'; readonly attempts: number }

export type AddView =
  /** No key is being given. `stored` is the account the latest add made, or null. */
  | { readonly kind: 'closed'; readonly stored: string | null }
  /** The form is on the page. `failure` is what came of the latest add, if it came to nothing. */
  | { readonly kind: 'open'; readonly failure: AddFailure | null }
  /** A key is on its way. The form stays as it is. */
  | { readonly kind: 'sending'; readonly failure: AddFailure | null }
  /** The request found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving' }

/** What the form does with the key it holds once an add ended. */
export type Kept =
  /** The key was not stored, and the person may send it again as it is. */
  | 'kept'
  /** The key is stored, or may be: the form holds it no longer. */
  | 'dropped'

export interface KeyAddDeps {
  readonly send: Send
  readonly leave: () => void
  /** The CSRF token of the session of the person the panel shows, or null before one. */
  readonly token: () => string | null
  /** Reads the person's subscriptions again. */
  readonly refresh: () => Promise<void>
}

export interface KeyAddModel {
  readonly view: ReadonlySignal<AddView>
  readonly open: () => void
  /** Closes the form. While a key is on its way it does nothing. */
  readonly close: () => void
  /** Sends `key` for a new account of `integrationId`, once: an add that
      runs, or any add once the session ended, sends nothing and keeps the
      key. It ends when the page knows what the form does with the key, and
      does not wait for the subscriptions it has read again after an answer
      it has no word of the server on: until then the key would stay in a
      field with a button that sends it. */
  readonly add: (integrationId: string, key: string) => Promise<Kept>
  /** Leaves whatever runs behind and closes the form, for another person is
      shown now or the page goes away. An answer that comes later changes
      nothing. */
  readonly reset: () => void
}

/** How many adds came to nothing in a row before this one. */
const failedBefore = (failure: AddFailure | null): number => failure?.attempts ?? 0

/** Whether a refused add can have changed what the panel reads: the server
    recorded an account it could not remove again, or the page offered a
    subscription the server does not take a key for. */
function changedWhatIsRead(code: AddRefusal): boolean {
  switch (code) {
    case 'account_not_removed':
    case 'unknown_integration':
    case 'integration_takes_no_key':
      return true
    case 'invalid_request':
    case 'not_a_key':
    case 'registration_refused':
    case 'internal_error':
    case 'configuration_unavailable':
    case 'registration_not_recorded':
    case 'key_not_stored':
    case 'unrecognised':
      return false
  }
}

export function createKeyAdds({ send, leave, token, refresh }: KeyAddDeps): KeyAddModel {
  const view = signal<AddView>({ kind: 'closed', stored: null })
  /** Each reset makes a new round; an answer writes only while its round is the latest. */
  let round = 0

  const open = (): void => {
    if (view.peek().kind === 'closed') view.value = { kind: 'open', failure: null }
  }

  const close = (): void => {
    if (view.peek().kind === 'open') view.value = { kind: 'closed', stored: null }
  }

  const add = async (integrationId: string, key: string): Promise<Kept> => {
    const before = view.peek()
    const csrfToken = token()
    if (before.kind !== 'open' || csrfToken === null) return 'kept'
    const mine = round
    const attempts = failedBefore(before.failure) + 1
    view.value = { kind: 'sending', failure: before.failure }
    const sent = await addKey(send, csrfToken, integrationId, key)
    // The key went to the server for the person who gave it: whatever the
    // page shows now, the form of that person holds it no longer.
    if (mine !== round) return 'dropped'
    switch (sent.kind) {
      case 'signed_out':
        view.value = { kind: 'leaving' }
        leave()
        return 'dropped'
      case 'stored':
        view.value = { kind: 'closed', stored: sent.accountId }
        await refresh()
        return 'dropped'
      case 'unreachable':
      case 'unreadable':
      case 'server_failed':
        view.value = { kind: 'open', failure: { kind: 'unknown', answer: sent.kind === 'unreachable' ? 'none' : sent.kind, attempts } }
        void refresh()
        return 'dropped'
      case 'refused':
        view.value = { kind: 'open', failure: { kind: 'refused', status: sent.status, code: sent.code, reason: sent.reason, accountId: sent.accountId, attempts } }
        if (changedWhatIsRead(sent.code)) await refresh()
        return 'kept'
    }
  }

  const reset = (): void => {
    round += 1
    view.value = { kind: 'closed', stored: null }
  }

  return { view, open, close, add, reset }
}
