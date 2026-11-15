// The people of the account server, as an Admin sees them: who they sign in
// as, their role, whether they can sign in, and a change the server holds
// (lib/auth/login_member_routes.mli). The panel only reads; member-rows.ts
// draws what `createMembers` holds.

import { effect, signal, type ReadonlySignal } from '@preact/signals'
import type { View } from './console'
import { slowAfterMs } from './notes'
import type { Failure, Next } from './notes'
import { list } from './members-wire'
import type { Member } from './members-wire'
import type { Send, Session } from './wire'

export type MembersView =
  /** No Admin is signed in. */
  | { readonly kind: 'waiting' }
  /** `slow` once the reading has lasted long enough that the panel says it is waiting. */
  | { readonly kind: 'reading'; readonly forUser: string; readonly slow: boolean }
  /** A reading found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving'; readonly forUser: string }
  | { readonly kind: 'failed'; readonly forUser: string; readonly failure: Failure; readonly next: Next }
  | { readonly kind: 'read'; readonly forUser: string; readonly members: readonly Member[] }

export interface MembersDeps {
  readonly send: Send
  /** Takes the browser to the sign-in page, as the console does. */
  readonly leave: () => void
}

export interface MembersModel {
  readonly view: ReadonlySignal<MembersView>
  /** Reads the people for the Admin of `session`. A call for the person the
      panel already shows does nothing; a call for another person starts
      over, and an answer for the first changes nothing. */
  readonly load: (session: Session) => Promise<void>
  /** Reads again after a failure. Any other time it does nothing. */
  readonly retry: () => Promise<void>
}

export function createMembers({ send, leave }: MembersDeps): MembersModel {
  const view = signal<MembersView>({ kind: 'waiting' })
  /** The reading whose answer the panel takes. */
  let latest = 0

  const read = async (forUser: string, attemptsBefore: number): Promise<void> => {
    latest += 1
    const mine = latest
    const slow = setTimeout(() => {
      const shown = view.peek()
      if (mine === latest && shown.kind === 'reading') view.value = { ...shown, slow: true }
    }, slowAfterMs)
    const found = await list(send)
    clearTimeout(slow)
    if (mine !== latest) return
    if (found.ok) {
      view.value = { kind: 'read', forUser, members: found.value }
      return
    }
    if (found.problem.kind === 'signed_out') {
      const shown = view.peek()
      view.value = shown.kind === 'failed' ? { ...shown, next: 'leaving' } : { kind: 'leaving', forUser }
      leave()
      return
    }
    view.value = { kind: 'failed', forUser, failure: { problem: found.problem, attempts: attemptsBefore + 1 }, next: 'idle' }
  }

  const load = (session: Session): Promise<void> => {
    const shown = view.peek()
    if (shown.kind !== 'waiting' && shown.forUser === session.userId) return Promise.resolve()
    view.value = { kind: 'reading', forUser: session.userId, slow: false }
    return read(session.userId, 0)
  }

  const retry = (): Promise<void> => {
    const shown = view.peek()
    if (shown.kind !== 'failed' || shown.next !== 'idle') return Promise.resolve()
    view.value = { ...shown, next: 'reading' }
    return read(shown.forUser, shown.failure.attempts)
  }

  return { view, load, retry }
}

/** Reads the people for each Admin the console comes to show signed in. A
    Member's session is never sent to the route. The returned function
    stops following. */
export function followMembers(frame: ReadonlySignal<View>, members: MembersModel): () => void {
  return effect(() => {
    const shown = frame.value
    if (shown.kind === 'signed_in' && shown.who.role === 'admin') void members.load(shown.session)
  })
}
