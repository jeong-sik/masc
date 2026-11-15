// The allowlist of the account server, as an Admin sees it: the accounts that
// join as a Member when they sign in at `/`, with no link, and the removal of
// one (lib/auth/login_allowlist_routes.mli).
//
// allowlist-wire.ts sends the requests and reads their answers;
// allowlist-rows.ts draws what `createAllowlist` holds. The list is read
// again after each registration and removal, however the request ended: the
// server may have written it though the page did not hear so
// (lib/auth/authz_zone.mli). The state of a list and its writes follows the
// invitations (invites.ts), whose list is of the server as this one is.

import { effect, signal, type ReadonlySignal } from '@preact/signals'
import type { View } from './console'
import { slowAfterMs } from './notes'
import type { Failure, Next, Shown } from './notes'
import { list, register, remove } from './allowlist-wire'
import type { Entry, Registered, Registrable } from './allowlist-wire'
import { googleSub } from './members-wire'
import type { Problem, Send, Session } from './wire'

/** A request the server refused: it did nothing, and said why with a status below `serverFailure`. */
export type Refused = Extract<Shown, { kind: 'refused' }>

/** The first status of a server that failed on its side, which it can do after it wrote. */
const serverFailure = 500

/** The answer of a removal of an entry that was removed before, or that a person joined through. */
const closedBefore = 409

/** The way of signing in an Admin types an account for. */
export type Provider = Registrable['provider']

export const providers: readonly Provider[] = ['github', 'google']

/** What the Admin typed, read as an account, or why it is not one. */
export type Typed =
  | { readonly ok: true; readonly identity: Registrable }
  | { readonly ok: false; readonly why: 'empty' | 'not_a_number' | 'not_a_sub' }

/** Reads what the Admin typed for `provider` as the server takes it
    (lib/auth/authz_external_identity.ml): a GitHub account is its user id,
    a positive whole number no larger than 2^53 - 1, and a Google account
    its sub, 1 to 255 visible ASCII characters. Spaces at either end are
    not part of it. */
export function readTyped(provider: Provider, typed: string): Typed {
  const value = typed.trim()
  if (value === '') return { ok: false, why: 'empty' }
  switch (provider) {
    case 'github': {
      const userId = /^[0-9]+$/.test(value) ? Number(value) : Number.NaN
      return Number.isSafeInteger(userId) && userId > 0 ? { ok: true, identity: { provider, userId } } : { ok: false, why: 'not_a_number' }
    }
    case 'google':
      return googleSub.test(value) ? { ok: true, identity: { provider, sub: value } } : { ok: false, why: 'not_a_sub' }
  }
}

export type ListView =
  /** No Admin is signed in. */
  | { readonly kind: 'waiting' }
  /** `slow` once the reading has lasted long enough that the panel says it is waiting. */
  | { readonly kind: 'reading'; readonly forUser: string; readonly slow: boolean }
  /** A reading found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving'; readonly forUser: string }
  | { readonly kind: 'failed'; readonly forUser: string; readonly failure: Failure; readonly next: Next }
  | { readonly kind: 'read'; readonly forUser: string; readonly entries: readonly Entry[] }

/** The latest registration the Admin asked for. A failure says how many
    there were in a row, so a second one is announced again. */
export type Add =
  | { readonly kind: 'idle' }
  | { readonly kind: 'sending'; readonly identity: Registrable }
  | { readonly kind: 'done'; readonly identity: Registrable; readonly registered: Registered }
  | { readonly kind: 'refused'; readonly identity: Registrable; readonly problem: Refused; readonly attempts: number }
  /** No answer came, it could not be read, or the server failed on its side:
      the entry may have been written. */
  | { readonly kind: 'unknown'; readonly identity: Registrable; readonly problem: Shown; readonly attempts: number }
  | { readonly kind: 'leaving' }

/** The latest removal of an entry. */
export type Remove =
  | { readonly kind: 'sending' }
  /** `before` when the server had closed it already: removed by another
      page or an earlier press, or used by a person who joined. */
  | { readonly kind: 'done'; readonly before: boolean }
  | { readonly kind: 'refused'; readonly problem: Refused; readonly attempts: number }
  | { readonly kind: 'unknown'; readonly problem: Shown; readonly attempts: number }
  | { readonly kind: 'leaving' }

export interface AllowlistDeps {
  readonly send: Send
  /** Takes the browser to the sign-in page, as the console does. */
  readonly leave: () => void
}

export interface AllowlistModel {
  readonly view: ReadonlySignal<ListView>
  readonly adding: ReadonlySignal<Add>
  /** The latest removal of each entry the Admin removed, by its id. */
  readonly removing: ReadonlySignal<ReadonlyMap<string, Remove>>
  /** Reads the entries for the Admin of `session`. A call for the person the
      panel already shows only keeps their newest session; a call for
      another person starts over, and an answer for the first changes nothing. */
  readonly load: (session: Session) => Promise<void>
  /** Reads again after a failure. Any other time it does nothing. */
  readonly retry: () => Promise<void>
  /** Registers `identity`. One runs at a time, once the list is read. */
  readonly add: (identity: Registrable) => Promise<void>
  /** Removes the entry `id`. One whose removal runs is left as it is. */
  readonly remove: (id: string) => Promise<void>
  /** Forgets the list once the console shows no Admin: another person, or
      no one. An answer still under way then changes nothing on the page
      and reads nothing. */
  readonly stop: () => void
}

/** How many tries came to nothing in a row before this one. */
function failedBefore(before: Add | Remove | undefined): number {
  if (before === undefined) return 0
  switch (before.kind) {
    case 'refused':
    case 'unknown':
      return before.attempts
    case 'idle':
    case 'sending':
    case 'done':
    case 'leaving':
      return 0
  }
}

export function createAllowlist({ send, leave }: AllowlistDeps): AllowlistModel {
  const view = signal<ListView>({ kind: 'waiting' })
  const adding = signal<Add>({ kind: 'idle' })
  const removing = signal<ReadonlyMap<string, Remove>>(new Map())
  let session: Session | null = null
  /** The reading whose answer the panel takes. */
  let latest = 0
  /** Each person shown makes a new round; an answer writes only while its round is the latest. */
  let round = 0
  /** How many registrations and removals have had their answer. A list read
      before the latest of them may not hold what it did, so it is read again. */
  let landed = 0
  let left = false

  /** The browser leaves, with whatever runs left behind. */
  const leaveAll = (): void => {
    left = true
    if (adding.peek().kind === 'sending') adding.value = { kind: 'leaving' }
    const next = new Map(removing.peek())
    for (const [id, one] of next) if (one.kind === 'sending') next.set(id, { kind: 'leaving' })
    removing.value = next
    leave()
  }

  const read = async (forUser: string, attemptsBefore: number): Promise<void> => {
    latest += 1
    const mine = latest
    const asOf = landed
    const slow = setTimeout(() => {
      const shown = view.peek()
      if (mine === latest && shown.kind === 'reading') view.value = { ...shown, slow: true }
    }, slowAfterMs)
    const found = await list(send)
    clearTimeout(slow)
    if (mine !== latest || left) return
    if (found.ok) {
      if (landed !== asOf) return read(forUser, attemptsBefore)
      view.value = { kind: 'read', forUser, entries: found.value }
      return
    }
    if (found.problem.kind === 'signed_out') {
      const shown = view.peek()
      view.value = shown.kind === 'failed' ? { ...shown, next: 'leaving' } : { kind: 'leaving', forUser }
      leaveAll()
      return
    }
    view.value = { kind: 'failed', forUser, failure: { problem: found.problem, attempts: attemptsBefore + 1 }, next: 'idle' }
  }

  /** Reads the list again while it shows one, which stays on the page
      meanwhile. A reading already under way reads again once it ends. */
  const refresh = (): void => {
    landed += 1
    const shown = view.peek()
    if (shown.kind === 'read') void read(shown.forUser, 0)
  }

  /** What an answer that is not a value does: the browser leaves, or the
      page says the refusal, or it says it does not know. The list is read
      again unless the browser leaves. */
  const failed = (problem: Problem, refused: (problem: Refused) => void, unknown: (problem: Shown) => void): void => {
    switch (problem.kind) {
      case 'signed_out':
        leaveAll()
        return
      case 'refused':
        if (problem.status < serverFailure) refused(problem)
        else unknown(problem)
        break
      case 'unreachable':
      case 'unreadable':
        unknown(problem)
        break
    }
    refresh()
  }

  const addEntry = async (identity: Registrable): Promise<void> => {
    const before = adding.peek()
    const csrfToken = session?.csrfToken ?? null
    if (left || before.kind === 'sending' || view.peek().kind !== 'read' || csrfToken === null) return
    const mine = round
    const attempts = failedBefore(before) + 1
    adding.value = { kind: 'sending', identity }
    const answer = await register(send, csrfToken, identity)
    if (left) return
    // The allowlist is that of the server, not of the person: another Admin
    // shown since then reads a list that may lack this entry.
    if (mine !== round) {
      refresh()
      return
    }
    if (!answer.ok) {
      failed(
        answer.problem,
        (problem) => { adding.value = { kind: 'refused', identity, problem, attempts } },
        (problem) => { adding.value = { kind: 'unknown', identity, problem, attempts } },
      )
      return
    }
    adding.value = { kind: 'done', identity, registered: answer.value }
    refresh()
  }

  const setRemove = (id: string, one: Remove): void => {
    const next = new Map(removing.peek())
    next.set(id, one)
    removing.value = next
  }

  const removeEntry = async (id: string): Promise<void> => {
    const before = removing.peek().get(id)
    const csrfToken = session?.csrfToken ?? null
    if (left || before?.kind === 'sending' || csrfToken === null) return
    const mine = round
    const attempts = failedBefore(before) + 1
    setRemove(id, { kind: 'sending' })
    const answer = await remove(send, csrfToken, id)
    if (left) return
    if (mine !== round) {
      refresh()
      return
    }
    if (answer.ok) {
      setRemove(id, { kind: 'done', before: false })
      refresh()
      return
    }
    const { problem } = answer
    if (problem.kind === 'refused' && problem.status === closedBefore) {
      setRemove(id, { kind: 'done', before: true })
      refresh()
      return
    }
    failed(
      problem,
      (refused) => { setRemove(id, { kind: 'refused', problem: refused, attempts }) },
      (unknown) => { setRemove(id, { kind: 'unknown', problem: unknown, attempts }) },
    )
  }

  const load = (next: Session): Promise<void> => {
    const shown = view.peek()
    session = next
    if (shown.kind !== 'waiting' && shown.forUser === next.userId) return Promise.resolve()
    round += 1
    left = false
    adding.value = { kind: 'idle' }
    removing.value = new Map()
    view.value = { kind: 'reading', forUser: next.userId, slow: false }
    return read(next.userId, 0)
  }

  const retry = (): Promise<void> => {
    const shown = view.peek()
    if (shown.kind !== 'failed' || shown.next !== 'idle') return Promise.resolve()
    view.value = { ...shown, next: 'reading' }
    return read(shown.forUser, shown.failure.attempts)
  }

  const stop = (): void => {
    if (view.peek().kind === 'waiting') return
    round += 1
    latest += 1
    session = null
    adding.value = { kind: 'idle' }
    removing.value = new Map()
    view.value = { kind: 'waiting' }
  }

  return { view, adding, removing, load, retry, add: addEntry, remove: removeEntry, stop }
}

/** Reads the allowlist for each Admin the console comes to show signed in,
    and stops whenever it shows anything else, so a Member's session is not
    sent to the route. The returned function stops following. */
export function followAllowlist(frame: ReadonlySignal<View>, allowlist: AllowlistModel): () => void {
  return effect(() => {
    const shown = frame.value
    if (shown.kind === 'signed_in' && shown.who.role === 'admin') void allowlist.load(shown.session)
    else allowlist.stop()
  })
}
