// The invitations of the account server, as an Admin sees them: the link a
// person joins through, made and shown once, the invitations made before,
// and the revoke of one (lib/auth/login_invite_routes.mli).
//
// invites-wire.ts sends the requests and reads their answers; invite-rows.ts
// draws what `createInvites` holds. The list is read again after each
// invitation made or revoked, however the request ended: the server may have
// written it though the page did not hear so (lib/auth/authz_zone.mli).

import { effect, signal, type ReadonlySignal } from '@preact/signals'
import type { View } from './console'
import { slowAfterMs } from './notes'
import type { Failure, Next, Shown } from './notes'
import { issue, list, revoke } from './invites-wire'
import type { Invite, InviteRole, Issued } from './invites-wire'
import type { Problem, Send, Session } from './wire'

/** A request the server refused: it did nothing, and said why with a status below `serverFailure`. */
export type Refused = Extract<Shown, { kind: 'refused' }>

/** The first status of a server that failed on its side, which it can do after it wrote. */
const serverFailure = 500

/** The answer of a revoke of an invitation that was revoked before, or that a person joined through. */
const closedBefore = 409

export type ListView =
  /** No Admin is signed in. */
  | { readonly kind: 'waiting' }
  /** `slow` once the reading has lasted long enough that the panel says it is waiting. */
  | { readonly kind: 'reading'; readonly forUser: string; readonly slow: boolean }
  /** A reading found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving'; readonly forUser: string }
  | { readonly kind: 'failed'; readonly forUser: string; readonly failure: Failure; readonly next: Next }
  | { readonly kind: 'read'; readonly forUser: string; readonly invites: readonly Invite[] }

/** The latest invitation the Admin asked for. A failure says how many there
    were in a row, so a second one is announced again. */
export type Make =
  | { readonly kind: 'idle' }
  | { readonly kind: 'sending'; readonly role: InviteRole }
  /** The invitation, whose link the page shows until the Admin says they took it. */
  | { readonly kind: 'issued'; readonly issued: Issued }
  | { readonly kind: 'refused'; readonly role: InviteRole; readonly problem: Refused; readonly attempts: number }
  /** No answer came, it could not be read, or the server failed on its side:
      the invitation may have been made, and its link is not on the page. */
  | { readonly kind: 'unknown'; readonly role: InviteRole; readonly problem: Shown; readonly attempts: number }
  | { readonly kind: 'leaving' }

/** The latest revoke of an invitation. */
export type Revoke =
  | { readonly kind: 'sending' }
  /** `before` when the server had closed it already: revoked by another
      page or an earlier press, or used by a person who joined. */
  | { readonly kind: 'done'; readonly before: boolean }
  | { readonly kind: 'refused'; readonly problem: Refused; readonly attempts: number }
  | { readonly kind: 'unknown'; readonly problem: Shown; readonly attempts: number }
  | { readonly kind: 'leaving' }

export interface InvitesDeps {
  readonly send: Send
  /** Takes the browser to the sign-in page, as the console does. */
  readonly leave: () => void
}

export interface InvitesModel {
  readonly view: ReadonlySignal<ListView>
  readonly making: ReadonlySignal<Make>
  /** The latest revoke of each invitation the Admin revoked, by its id. */
  readonly revoking: ReadonlySignal<ReadonlyMap<string, Revoke>>
  /** Reads the invitations for the Admin of `session`. A call for the person
      the panel already shows only keeps their newest session; a call for
      another person starts over, and an answer for the first changes nothing. */
  readonly load: (session: Session) => Promise<void>
  /** Reads again after a failure. Any other time it does nothing. */
  readonly retry: () => Promise<void>
  /** Makes an invitation for `role`. One runs at a time, once the list is
      read, and not while the link of one made before is still shown. */
  readonly make: (role: InviteRole) => Promise<void>
  /** Takes the link made away from the page, once the Admin has it. */
  readonly forget: () => void
  /** Revokes the invitation `id`. One whose revoke runs is left as it is. */
  readonly revoke: (id: string) => Promise<void>
}

/** How many tries came to nothing in a row before this one. */
function failedBefore(before: Make | Revoke | undefined): number {
  if (before === undefined) return 0
  switch (before.kind) {
    case 'refused':
    case 'unknown':
      return before.attempts
    case 'idle':
    case 'sending':
    case 'issued':
    case 'done':
    case 'leaving':
      return 0
  }
}

export function createInvites({ send, leave }: InvitesDeps): InvitesModel {
  const view = signal<ListView>({ kind: 'waiting' })
  const making = signal<Make>({ kind: 'idle' })
  const revoking = signal<ReadonlyMap<string, Revoke>>(new Map())
  let session: Session | null = null
  /** The reading whose answer the panel takes. */
  let latest = 0
  /** Each person shown makes a new round; an answer writes only while its round is the latest. */
  let round = 0
  /** How many makes and revokes have had their answer. A list read before
      the latest of them may not hold what it did, so it is read again. */
  let landed = 0
  let left = false

  /** The browser leaves, with whatever runs left behind. A link made is
      taken off the page with it. */
  const leaveAll = (): void => {
    left = true
    const before = making.peek()
    if (before.kind === 'sending' || before.kind === 'issued') making.value = { kind: 'leaving' }
    const next = new Map(revoking.peek())
    for (const [id, one] of next) if (one.kind === 'sending') next.set(id, { kind: 'leaving' })
    revoking.value = next
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
      view.value = { kind: 'read', forUser, invites: found.value }
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

  const makeInvite = async (role: InviteRole): Promise<void> => {
    const before = making.peek()
    const csrfToken = session?.csrfToken ?? null
    const busy = before.kind === 'sending' || before.kind === 'issued'
    if (left || busy || view.peek().kind !== 'read' || csrfToken === null) return
    const mine = round
    const attempts = failedBefore(before) + 1
    making.value = { kind: 'sending', role }
    const answer = await issue(send, csrfToken, role)
    if (mine !== round || left) return
    if (!answer.ok) {
      failed(
        answer.problem,
        (problem) => { making.value = { kind: 'refused', role, problem, attempts } },
        (problem) => { making.value = { kind: 'unknown', role, problem, attempts } },
      )
      return
    }
    making.value = { kind: 'issued', issued: answer.value }
    refresh()
  }

  const forget = (): void => {
    if (making.peek().kind === 'issued') making.value = { kind: 'idle' }
  }

  const setRevoke = (id: string, one: Revoke): void => {
    const next = new Map(revoking.peek())
    next.set(id, one)
    revoking.value = next
  }

  const revokeInvite = async (id: string): Promise<void> => {
    const before = revoking.peek().get(id)
    const csrfToken = session?.csrfToken ?? null
    if (left || before?.kind === 'sending' || csrfToken === null) return
    const mine = round
    const attempts = failedBefore(before) + 1
    setRevoke(id, { kind: 'sending' })
    const answer = await revoke(send, csrfToken, id)
    if (mine !== round || left) return
    if (answer.ok) {
      setRevoke(id, { kind: 'done', before: false })
      refresh()
      return
    }
    const { problem } = answer
    if (problem.kind === 'refused' && problem.status === closedBefore) {
      setRevoke(id, { kind: 'done', before: true })
      refresh()
      return
    }
    failed(
      problem,
      (refused) => { setRevoke(id, { kind: 'refused', problem: refused, attempts }) },
      (unknown) => { setRevoke(id, { kind: 'unknown', problem: unknown, attempts }) },
    )
  }

  const load = (next: Session): Promise<void> => {
    const shown = view.peek()
    session = next
    if (shown.kind !== 'waiting' && shown.forUser === next.userId) return Promise.resolve()
    round += 1
    left = false
    making.value = { kind: 'idle' }
    revoking.value = new Map()
    view.value = { kind: 'reading', forUser: next.userId, slow: false }
    return read(next.userId, 0)
  }

  const retry = (): Promise<void> => {
    const shown = view.peek()
    if (shown.kind !== 'failed' || shown.next !== 'idle') return Promise.resolve()
    view.value = { ...shown, next: 'reading' }
    return read(shown.forUser, shown.failure.attempts)
  }

  return { view, making, revoking, load, retry, make: makeInvite, forget, revoke: revokeInvite }
}

/** Reads the invitations for each Admin the console comes to show signed in.
    A Member's session is never sent to the route. The returned function
    stops following. */
export function followInvites(frame: ReadonlySignal<View>, invites: InvitesModel): () => void {
  return effect(() => {
    const shown = frame.value
    if (shown.kind === 'signed_in' && shown.who.role === 'admin') void invites.load(shown.session)
  })
}
