// The conversation of a person's Keeper that the console shows: one Keeper
// at a time, opened from its card (lib/server/server_preview_keeper_conversation.ml).
// The server records what the person asked and what the Keeper answered;
// the page reads it each time the conversation is opened.
//
// talk-wire.ts sends the request and reads its answer; talk-area.ts draws
// the state `createTalk` holds.

import { signal, type ReadonlySignal } from '@preact/signals'
import { slowAfterMs } from './notes'
import type { Next } from './notes'
import { conversationOf } from './talk-wire'
import type { Conversation, TalkShown } from './talk-wire'
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

export interface TalkDeps {
  readonly send: Send
  /** Takes the browser to the sign-in page, with whatever else runs on the page. */
  readonly leave: () => void
  /** Whether a request of the page found that the session had ended. */
  readonly left: () => boolean
}

export interface TalkModel {
  readonly view: ReadonlySignal<TalkView>
  /** Opens the conversation of the Keeper `keeperId` and reads it, in place
      of any other one. A call while the conversation of that Keeper is read
      joins the reading; once the session ended it does nothing. */
  readonly open: (keeperId: string) => Promise<void>
  /** Closes the conversation. A reading under way changes nothing after.
      Once the session ended it does nothing, so the page says it leaves. */
  readonly close: () => void
  /** Reads again after a failure. Any other time it does nothing. */
  readonly retry: () => Promise<void>
  /** Forgets the conversation, for another person is shown now. */
  readonly reset: () => void
}

export function createTalk({ send, leave, left }: TalkDeps): TalkModel {
  const view = signal<TalkView>({ kind: 'closed' })
  /** The reading whose answer the page takes. Opening, closing and a reset replace it. */
  let latest = 0
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

  const open = (keeperId: string): Promise<void> => {
    const now = view.peek()
    if (left()) return Promise.resolve()
    if (now.kind === 'reading' && now.keeperId === keeperId && reading !== null) return reading
    view.value = { kind: 'reading', keeperId, slow: false }
    return follow(keeperId, 0)
  }

  const close = (): void => {
    if (left()) return
    latest += 1
    view.value = { kind: 'closed' }
  }

  const retry = (): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'failed' || now.next !== 'idle') return Promise.resolve()
    view.value = { ...now, next: 'reading' }
    return follow(now.keeperId, now.failure.attempts)
  }

  const reset = (): void => {
    latest += 1
    view.value = { kind: 'closed' }
  }

  return { view, open, close, retry, reset }
}
