// The conversation of a person's Keeper that the console shows: one Keeper
// at a time, opened from its card (lib/server/server_preview_keeper_conversation.ml).
// The server records what the person asked and what the Keeper answered;
// the page reads it each time the conversation is opened, and again after
// each message sent or conversation started, so what it shows is the record.
//
// talk-wire.ts sends the requests and reads their answers; talk-area.ts and
// talk-say.ts draw the state `createTalk` holds.

import { signal, type ReadonlySignal } from '@preact/signals'
import { slowAfterMs } from './notes'
import type { Next } from './notes'
import { conversationOf, say, start, unsendable } from './talk-wire'
import type { Answered, Conversation, TalkAnswer, TalkShown, Unsendable } from './talk-wire'
import type { Send } from './wire'

/** A reading that failed, and how many times in a row it has. */
export interface TalkFailure {
  readonly problem: TalkShown
  readonly attempts: number
}

export type TalkView =
  /** No conversation is open. */
  | { readonly kind: 'closed' }
  /** `slow` once the reading has lasted long enough that the page says it is waiting. */
  | { readonly kind: 'reading'; readonly keeperId: string; readonly slow: boolean }
  /** The reading found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving'; readonly keeperId: string }
  | { readonly kind: 'failed'; readonly keeperId: string; readonly failure: TalkFailure; readonly next: Next }
  | { readonly kind: 'read'; readonly keeperId: string; readonly conversation: Conversation }

/** What the person asked of the open conversation: a message, or a new conversation. */
export type Step = 'say' | 'start'

/** A refusal the server answered with a status that says why. */
export type TalkRefused = Extract<TalkShown, { kind: 'refused' }>

/** The first status of a server that failed on its side. Such an answer
    with no code of the route did not come from the route but from what
    stands before it, so the page does not know whether the route ran. */
const serverFailure = 500

/** The latest thing the person asked of the open conversation. A failure
    says how many there were in a row, so a second one is announced again. */
export type Act =
  | { readonly kind: 'idle' }
  /** The page sent nothing: the server would have refused the message. */
  | { readonly kind: 'not_sent'; readonly why: Unsendable; readonly attempts: number }
  | { readonly kind: 'sending'; readonly message: string }
  | { readonly kind: 'starting' }
  | { readonly kind: 'answered'; readonly answer: Answered }
  | { readonly kind: 'started' }
  | { readonly kind: 'refused'; readonly step: Step; readonly problem: TalkRefused; readonly attempts: number }
  /** No answer came, it could not be read, or it came from something in
      front of the server: the server may have done it. */
  | { readonly kind: 'unknown'; readonly step: Step; readonly problem: TalkShown; readonly attempts: number }
  /** The request found that the session had ended. */
  | { readonly kind: 'leaving' }

export interface TalkDeps {
  readonly send: Send
  /** Takes the browser to the sign-in page, with whatever else runs on the page. */
  readonly leave: () => void
  /** Whether a request of the page found that the session had ended. */
  readonly left: () => boolean
  /** The CSRF token of the session shown, or null before one is read. */
  readonly token: () => string | null
}

export interface TalkModel {
  readonly view: ReadonlySignal<TalkView>
  readonly act: ReadonlySignal<Act>
  /** Opens the conversation of the Keeper `keeperId` and reads it, in place
      of any other one. A call while the conversation of that Keeper is read
      joins the reading; once the session ended it does nothing. */
  readonly open: (keeperId: string) => Promise<void>
  /** Closes the conversation. A reading or a request under way changes
      nothing after. Once the session ended it does nothing, so the page
      says it leaves. */
  readonly close: () => void
  /** Reads again after a failure. Any other time it does nothing. */
  readonly retry: () => Promise<void>
  /** Sends `message` to the Keeper of the conversation read, and reads the
      conversation again once the turn ends, however it ends. One request
      runs at a time. It settles with what the turn came to once that
      reading ended, or with null when nothing was asked or the conversation
      is no longer open. */
  readonly say: (message: string) => Promise<Act | null>
  /** Starts a new conversation of the Keeper of the open conversation, read
      or not, and reads it. One request runs at a time. */
  readonly start: () => Promise<void>
  /** Forgets the conversation, for another person is shown now. */
  readonly reset: () => void
}

/** How many requests of `step` came to nothing in a row before this one. */
function failedBefore(before: Act, step: Step): number {
  switch (before.kind) {
    case 'not_sent':
      return step === 'say' ? before.attempts : 0
    case 'refused':
    case 'unknown':
      return before.step === step ? before.attempts : 0
    case 'idle':
    case 'sending':
    case 'starting':
    case 'answered':
    case 'started':
    case 'leaving':
      return 0
  }
}

/** What a request of `step` came to, or null when it found that the session had ended. */
function outcomeOf<T>(step: Step, answer: TalkAnswer<T>, done: (value: T) => Act, attempts: number): Act | null {
  if (answer.ok) return done(answer.value)
  const { problem } = answer
  switch (problem.kind) {
    case 'signed_out':
      return null
    case 'refused':
      return problem.code === 'unrecognised' && problem.status >= serverFailure
        ? { kind: 'unknown', step, problem, attempts }
        : { kind: 'refused', step, problem, attempts }
    case 'unreachable':
    case 'unreadable':
      return { kind: 'unknown', step, problem, attempts }
  }
}

/** Whether a request runs, so another is not sent. */
const running = (now: Act): boolean => now.kind === 'sending' || now.kind === 'starting'

export function createTalk({ send, leave, left, token }: TalkDeps): TalkModel {
  const view = signal<TalkView>({ kind: 'closed' })
  const act = signal<Act>({ kind: 'idle' })
  /** The reading whose answer the page takes. Opening, closing, a reset and
      each reading after a request replace it. */
  let latest = 0
  /** Each conversation opened makes a new count; the answer of a request
      writes only while its conversation is still the one open. */
  let opened = 0
  let reading: Promise<void> | null = null

  const read = async (keeperId: string, attemptsBefore: number): Promise<void> => {
    latest += 1
    const mine = latest
    const slow = setTimeout(() => {
      const now = view.peek()
      if (mine === latest && now.kind === 'reading') view.value = { ...now, slow: true }
    }, slowAfterMs)
    const answer = await conversationOf(send, keeperId)
    clearTimeout(slow)
    if (mine !== latest || left()) return
    if (answer.ok) {
      view.value = { kind: 'read', keeperId, conversation: answer.value }
      return
    }
    const { problem } = answer
    if (problem.kind === 'signed_out') {
      // A retry keeps its button on the page while the browser leaves (notes.ts, `Next`).
      const now = view.peek()
      view.value = now.kind === 'failed' ? { ...now, next: 'leaving' } : { kind: 'leaving', keeperId }
      leave()
      return
    }
    view.value = { kind: 'failed', keeperId, failure: { problem, attempts: attemptsBefore + 1 }, next: 'idle' }
  }

  const follow = (keeperId: string, attemptsBefore: number): Promise<void> => {
    const run = read(keeperId, attemptsBefore).finally(() => { if (reading === run) reading = null })
    reading = run
    return run
  }

  /** Shows `next` in place of the conversation open: no reading or request of that one writes after. */
  const anew = (next: TalkView): void => {
    latest += 1
    opened += 1
    act.value = { kind: 'idle' }
    view.value = next
  }

  const open = (keeperId: string): Promise<void> => {
    const now = view.peek()
    if (left()) return Promise.resolve()
    if (now.kind === 'reading' && now.keeperId === keeperId && reading !== null) return reading
    anew({ kind: 'reading', keeperId, slow: false })
    return follow(keeperId, 0)
  }

  const close = (): void => {
    if (!left()) anew({ kind: 'closed' })
  }

  const retry = (): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'failed' || now.next !== 'idle') return Promise.resolve()
    view.value = { ...now, next: 'reading' }
    return follow(now.keeperId, now.failure.attempts)
  }

  /** Runs `request` for the Keeper of the conversation read, or of one that
      could not be read: a new conversation is the way past a record that
      cannot be read, and a message asks for one read first (`sayTo`). Then the
      conversation is read again, for the record holds the turn whatever the
      page heard of it, and only after that reading is what the request came
      to shown: its words speak of the conversation on the page. Until then
      the request runs, so nothing else is sent. */
  const ask = async <T>(
    step: Step,
    during: Act,
    request: (csrfToken: string, keeperId: string) => Promise<TalkAnswer<T>>,
    done: (value: T) => Act,
  ): Promise<Act | null> => {
    const now = view.peek()
    const csrfToken = token()
    const keeperId = now.kind === 'read' || now.kind === 'failed' ? now.keeperId : null
    if (left() || keeperId === null || running(act.peek()) || csrfToken === null) return null
    const mine = opened
    const attempts = failedBefore(act.peek(), step) + 1
    act.value = during
    const answer = await request(csrfToken, keeperId)
    if (mine !== opened || left()) return null
    const outcome = outcomeOf(step, answer, done, attempts)
    if (outcome === null) {
      act.value = { kind: 'leaving' }
      leave()
      return act.peek()
    }
    // A reading that failed before counts on, so the same failure again is announced again.
    const before = view.peek()
    await read(keeperId, before.kind === 'failed' ? before.failure.attempts : 0)
    if (mine !== opened) return null
    // A reading that found the session ended says so in the line of the conversation.
    act.value = left() ? { kind: 'idle' } : outcome
    return act.peek()
  }

  const sayTo = (message: string): Promise<Act | null> => {
    if (left() || view.peek().kind !== 'read' || running(act.peek())) return Promise.resolve(null)
    const why = unsendable(message)
    if (why !== null) {
      act.value = { kind: 'not_sent', why, attempts: failedBefore(act.peek(), 'say') + 1 }
      return Promise.resolve(act.peek())
    }
    return ask(
      'say',
      { kind: 'sending', message },
      (csrfToken, keeperId) => say(send, csrfToken, keeperId, message),
      (answer) => ({ kind: 'answered', answer }),
    )
  }

  const startOver = async (): Promise<void> => {
    await ask('start', { kind: 'starting' }, (csrfToken, keeperId) => start(send, csrfToken, keeperId), () => ({ kind: 'started' }))
  }

  const reset = (): void => {
    anew({ kind: 'closed' })
  }

  return { view, act, open, close, retry, say: sayTo, start: startOver, reset }
}
