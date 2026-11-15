// The Keepers of a signed-in person: their names and the Runtime each runs
// on, a new Keeper, and the Runtime a Keeper is given
// (lib/auth_preview_keeper.ml, `list`, `make` and `assign`).
//
// keepers-wire.ts sends the requests and reads their answers.
// `createKeepers` reads the Keepers for the person the console shows and
// holds what the person asked of them; keeper-rows.ts draws it. A make or an
// assignment that the server answered changes the list by its answer, which
// names the Keeper and its Runtime. One whose answer did not come, or that
// the server answered with a failure of its own, reads the list again: the
// server may have done it (lib/auth/authz_zone.mli, a commit whose append
// returned is in the log though the caller hears that it was not written).

import { effect, signal, type ReadonlySignal } from '@preact/signals'
import type { View } from './console'
import { assign, make, readList } from './keepers-wire'
import type { Keeper } from './keepers-wire'
import { slowAfterMs } from './notes'
import type { Failure, Next, Shown } from './notes'
import type { Problem, Send, Session } from './wire'

export type { Keeper } from './keepers-wire'

/** A request the server refused: it did nothing, and said why with a status below `serverFailure`. */
export type Refused = Extract<Shown, { kind: 'refused' }>

/** The first status of a server that failed on its side, which it can do after it wrote. */
const serverFailure = 500

export type ListView =
  /** No one is signed in yet. */
  | { readonly kind: 'waiting' }
  /** `slow` once the reading has lasted long enough that the panel says it is waiting. */
  | { readonly kind: 'reading'; readonly forUser: string; readonly slow: boolean }
  /** A reading found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving'; readonly forUser: string }
  | { readonly kind: 'failed'; readonly forUser: string; readonly failure: Failure; readonly next: Next }
  | { readonly kind: 'read'; readonly forUser: string; readonly keepers: readonly Keeper[] }

/** The latest new Keeper the person asked for. */
export type Make =
  | { readonly kind: 'idle' }
  /** The page sent nothing: the name is empty, or one of the person's Keepers has it. */
  | { readonly kind: 'not_sent'; readonly why: 'blank' | 'taken'; readonly name: string; readonly attempts: number }
  | { readonly kind: 'sending'; readonly name: string }
  /** `existing` when another page of the person made it first. */
  | { readonly kind: 'made'; readonly name: string; readonly existing: boolean }
  | { readonly kind: 'refused'; readonly name: string; readonly problem: Refused; readonly attempts: number }
  /** No answer came, it could not be read, or the server failed on its side.
      The list is read again: the Keeper may have been made. */
  | { readonly kind: 'unknown'; readonly name: string; readonly problem: Shown; readonly attempts: number }
  | { readonly kind: 'leaving' }

/** The latest Runtime the person gave a Keeper. */
export type Assign =
  | { readonly kind: 'sending'; readonly runtimeId: string }
  /** `existing` when the Keeper already ran on it. */
  | { readonly kind: 'done'; readonly runtimeId: string; readonly existing: boolean }
  | { readonly kind: 'refused'; readonly runtimeId: string; readonly problem: Refused; readonly attempts: number }
  /** As for a make: the list is read again, since the Keeper may run on it now. */
  | { readonly kind: 'unknown'; readonly runtimeId: string; readonly problem: Shown; readonly attempts: number }
  | { readonly kind: 'leaving' }

export interface KeepersDeps {
  readonly send: Send
  /** Takes the browser to the sign-in page, as the console does. */
  readonly leave: () => void
}

export interface KeepersModel {
  readonly view: ReadonlySignal<ListView>
  readonly making: ReadonlySignal<Make>
  /** The latest assignment of each Keeper the person gave a Runtime, by its name. */
  readonly assigning: ReadonlySignal<ReadonlyMap<string, Assign>>
  /** Reads the Keepers of the person of `session`. A call for the person the
      panel already shows only keeps their newest session; a call for another
      person starts over, and an answer for the first changes nothing. */
  readonly load: (session: Session) => Promise<void>
  /** Reads again after a failure. Any other time it does nothing. */
  readonly retry: () => Promise<void>
  /** Makes a Keeper named `name`, and gives it `runtimeId` when that is not
      null. A make runs one at a time, and only once the Keepers are read.
      It settles with what this make came to as soon as the server answered
      it, while the assignment it starts goes on; or with null when nothing
      was asked, or the answer came for a person no longer shown. */
  readonly make: (name: string, runtimeId: string | null) => Promise<Make | null>
  /** Gives the Keeper `name` the Runtime `runtimeId`. A Keeper whose
      assignment runs is left as it is. */
  readonly assign: (name: string, runtimeId: string) => Promise<void>
}

/** How many tries of the same thing came to nothing in a row before this one. */
function failedBefore(before: Make | Assign | undefined, same: boolean): number {
  if (before === undefined || !same) return 0
  switch (before.kind) {
    case 'not_sent':
    case 'refused':
    case 'unknown':
      return before.attempts
    case 'idle':
    case 'sending':
    case 'made':
    case 'done':
    case 'leaving':
      return 0
  }
}

export function createKeepers({ send, leave }: KeepersDeps): KeepersModel {
  const view = signal<ListView>({ kind: 'waiting' })
  const making = signal<Make>({ kind: 'idle' })
  const assigning = signal<ReadonlyMap<string, Assign>>(new Map())
  let session: Session | null = null
  /** The reading whose answer the panel takes. */
  let latest = 0
  /** Each person shown makes a new round; an answer writes only while its round is the latest. */
  let round = 0
  let left = false
  /** How many answers of a make or an assignment the list took. A reading
      that began before one of them may not hold it, and is read again. */
  let puts = 0

  /** The browser leaves, with whatever runs left behind. */
  const leaveAll = (): void => {
    left = true
    if (making.peek().kind === 'sending') making.value = { kind: 'leaving' }
    const next = new Map(assigning.peek())
    for (const [name, one] of next) if (one.kind === 'sending') next.set(name, { kind: 'leaving' })
    assigning.value = next
    leave()
  }

  const read = async (forUser: string, attemptsBefore: number): Promise<void> => {
    latest += 1
    const mine = latest
    const putsBefore = puts
    const slow = setTimeout(() => {
      const now = view.peek()
      if (mine === latest && now.kind === 'reading') view.value = { ...now, slow: true }
    }, slowAfterMs)
    const found = await readList(send)
    clearTimeout(slow)
    if (mine !== latest || left) return
    if (found.ok && puts !== putsBefore) return read(forUser, attemptsBefore)
    if (found.ok) {
      view.value = { kind: 'read', forUser, keepers: found.value }
      return
    }
    if (found.problem.kind === 'signed_out') {
      const now = view.peek()
      view.value = now.kind === 'failed' ? { ...now, next: 'leaving' } : { kind: 'leaving', forUser }
      leaveAll()
      return
    }
    view.value = { kind: 'failed', forUser, failure: { problem: found.problem, attempts: attemptsBefore + 1 }, next: 'idle' }
  }

  /** Reads the list again while it shows one, which stays on the page meanwhile. */
  const refresh = (): Promise<void> => {
    const now = view.peek()
    return now.kind === 'read' ? read(now.forUser, 0) : Promise.resolve()
  }

  /** Puts the Keeper an answer named into the list the panel shows. */
  const put = (keeper: Keeper): void => {
    const now = view.peek()
    if (now.kind !== 'read') return
    const listed = now.keepers.some((one) => one.id === keeper.id)
    const keepers = listed ? now.keepers.map((one) => (one.id === keeper.id ? keeper : one)) : [...now.keepers, keeper]
    puts += 1
    view.value = { ...now, keepers }
  }

  const setAssign = (name: string, one: Assign): void => {
    const next = new Map(assigning.peek())
    next.set(name, one)
    assigning.value = next
  }

  /** What an answer that is not a value does: the browser leaves, or the
      page says the refusal, or it says it does not know and reads the list
      again. */
  const failed = (problem: Problem, refused: (problem: Refused) => void, unknown: (problem: Shown) => void): void => {
    switch (problem.kind) {
      case 'signed_out':
        leaveAll()
        return
      case 'refused':
        if (problem.status < serverFailure) {
          refused(problem)
          return
        }
        break
      case 'unreachable':
      case 'unreadable':
        break
    }
    unknown(problem)
    void refresh()
  }

  const assignKeeper = async (name: string, runtimeId: string): Promise<void> => {
    const before = assigning.peek().get(name)
    const csrfToken = session?.csrfToken ?? null
    if (left || before?.kind === 'sending' || csrfToken === null) return
    const mine = round
    setAssign(name, { kind: 'sending', runtimeId })
    const answer = await assign(send, csrfToken, name, runtimeId)
    if (mine !== round || left) return
    const attempts = failedBefore(before, before !== undefined && before.kind !== 'leaving' && before.runtimeId === runtimeId) + 1
    if (!answer.ok) {
      failed(
        answer.problem,
        (problem) => { setAssign(name, { kind: 'refused', runtimeId, problem, attempts }) },
        (problem) => { setAssign(name, { kind: 'unknown', runtimeId, problem, attempts }) },
      )
      return
    }
    setAssign(name, { kind: 'done', runtimeId: answer.value.runtimeId, existing: answer.value.existing })
    put({ id: answer.value.id, runtimeId: answer.value.runtimeId })
  }

  const makeKeeper = async (typed: string, runtimeId: string | null): Promise<Make | null> => {
    const before = making.peek()
    const now = view.peek()
    const csrfToken = session?.csrfToken ?? null
    if (left || before.kind === 'sending' || now.kind !== 'read' || csrfToken === null) return null
    const name = typed.trim()
    const sameName = before.kind !== 'idle' && before.kind !== 'leaving' && before.name === name
    const attempts = failedBefore(before, sameName) + 1
    if (name === '' || now.keepers.some((one) => one.id === name)) {
      making.value = { kind: 'not_sent', why: name === '' ? 'blank' : 'taken', name, attempts }
      return making.peek()
    }
    const mine = round
    making.value = { kind: 'sending', name }
    const answer = await make(send, csrfToken, name)
    if (mine !== round || left) return null
    if (!answer.ok) {
      failed(
        answer.problem,
        (problem) => { making.value = { kind: 'refused', name, problem, attempts } },
        (problem) => { making.value = { kind: 'unknown', name, problem, attempts } },
      )
      return making.peek()
    }
    making.value = { kind: 'made', name: answer.value.id, existing: answer.value.existing }
    // A Keeper another page made keeps the Runtime it has: the list is read
    // for it, and nothing is given to it here.
    if (answer.value.existing) {
      void refresh()
      return making.peek()
    }
    put({ id: answer.value.id, runtimeId: null })
    if (runtimeId !== null) void assignKeeper(answer.value.id, runtimeId)
    return making.peek()
  }

  const load = (next: Session): Promise<void> => {
    const now = view.peek()
    session = next
    if (now.kind !== 'waiting' && now.forUser === next.userId) return Promise.resolve()
    round += 1
    left = false
    making.value = { kind: 'idle' }
    assigning.value = new Map()
    view.value = { kind: 'reading', forUser: next.userId, slow: false }
    return read(next.userId, 0)
  }

  const retry = (): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'failed' || now.next !== 'idle') return Promise.resolve()
    view.value = { ...now, next: 'reading' }
    return read(now.forUser, now.failure.attempts)
  }

  return { view, making, assigning, load, retry, make: makeKeeper, assign: assignKeeper }
}

/** Reads the Keepers of each person the console comes to show signed in.
    The returned function stops following. */
export function followKeepers(frame: ReadonlySignal<View>, keepers: KeepersModel): () => void {
  return effect(() => {
    const now = frame.value
    if (now.kind === 'signed_in') void keepers.load(now.session)
  })
}
