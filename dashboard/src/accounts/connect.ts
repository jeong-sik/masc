// Connecting a subscription. The person picks one the server offers; its
// official client runs a login on the server, and what the client prints and
// asks shows here. The person replies with a code or a key, or cancels. Once
// the login links the new account, the panel reads the subscriptions again.
//
// `createConnect` moves between the steps; `ConnectArea` (connect-area.ts)
// draws the step it is given. Each continuation of a login writes only while
// the view still shows that login: a login the person left behind changes
// nothing.

import { signal, type ReadonlySignal } from '@preact/signals'
import { cancel as cancelLogin, connect, reply as replyLogin, standingOf } from './login'
import type { LoginEnd, LoginOutcome, Reply } from './login'
import type { Failure } from './notes'
import type { Problem, Send } from './wire'

/** Where a running login is with the person's replies. */
export type Input =
  /** The client has not asked for anything since the last reply. */
  | 'not_asked'
  /** The client waits for a reply. */
  | 'asked'
  | 'sending'
  /** The server did not take the last reply; the client still waits. */
  | 'not_taken'

/** How a login ended without linking an account: as it said, or not known
    because the stream was cut before it named the login. */
export type Ended = LoginEnd | 'unknown'

export type ConnectView =
  /** Nothing is being connected. `linked` once a login linked an account. */
  | { readonly kind: 'closed'; readonly linked: boolean }
  | { readonly kind: 'choosing' }
  | { readonly kind: 'starting'; readonly integrationId: string }
  | {
    readonly kind: 'running'
    readonly integrationId: string
    readonly loginId: string
    /** What the client printed, as it came, its newest part kept. */
    readonly transcript: string
    readonly input: Input
    /** A cancel the server did not take. */
    readonly cancelNotTaken: boolean
  }
  /** A cancel was taken; the login has not said it stopped yet. */
  | { readonly kind: 'cancelling'; readonly integrationId: string; readonly loginId: string; readonly transcript: string }
  /** The page no longer reads the stream; the receipt of the login is being read. */
  | { readonly kind: 'checking'; readonly integrationId: string; readonly loginId: string }
  /** The page no longer reads the stream of a login, which runs on as far as
      it knows: its receipt says the client still runs, or `failure` says why
      the receipt could not be read. */
  | { readonly kind: 'detached'; readonly integrationId: string; readonly loginId: string; readonly failure: Failure | null }
  | { readonly kind: 'ended'; readonly integrationId: string; readonly ended: Ended }
  /** A login that did not start, or whose stream named no login before it failed. */
  | { readonly kind: 'failed'; readonly integrationId: string; readonly failure: Failure }
  /** A request found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving' }

export interface ConnectDeps {
  readonly send: Send
  readonly leave: () => void
  /** The CSRF token of the session of the person the panel shows, or null before one. */
  readonly token: () => string | null
  /** Reads the person's subscriptions again. */
  readonly refresh: () => Promise<void>
}

export interface ConnectModel {
  readonly view: ReadonlySignal<ConnectView>
  readonly open: () => void
  readonly close: () => void
  /** Starts a login of `integrationId` and follows it to its end. */
  readonly start: (integrationId: string) => Promise<void>
  readonly reply: (input: Reply) => Promise<void>
  readonly cancel: () => Promise<void>
  /** Reads again how a detached login stands. */
  readonly check: () => Promise<void>
  /** Leaves whatever runs behind, for another person is shown now. */
  readonly reset: () => void
}

/** How much of what a client printed stays: the newest part, as on a terminal. */
export const transcriptLimit = 65_536

export function createConnect({ send, leave, token, refresh }: ConnectDeps): ConnectModel {
  const view = signal<ConnectView>({ kind: 'closed', linked: false })

  /** The view, when it still shows the login `loginId` of the run `run`. */
  let run = 0
  const own = (mine: number): boolean => mine === run

  const signedOut = (): void => {
    view.value = { kind: 'leaving' }
    leave()
  }
  const failed = (integrationId: string, problem: Problem): void => {
    if (problem.kind === 'signed_out') signedOut()
    else view.value = { kind: 'failed', integrationId, failure: { problem, attempts: 1 } }
  }

  const settle = async (mine: number, integrationId: string, outcome: LoginOutcome): Promise<void> => {
    if (!own(mine)) return
    switch (outcome.kind) {
      case 'linked':
        view.value = { kind: 'closed', linked: true }
        await refresh()
        return
      case 'ended':
        view.value = { kind: 'ended', integrationId, ended: outcome.end }
        return
      case 'problem': {
        // A frame the page cannot read ends the reading, not the login the
        // stream named: its receipt says how it stands.
        const at = view.peek()
        if (at.kind === 'running' || at.kind === 'cancelling') await recheck(mine, integrationId, at.loginId, 0)
        else failed(integrationId, outcome.problem)
        return
      }
      case 'cut':
        if (outcome.loginId === null) {
          view.value = { kind: 'ended', integrationId, ended: 'unknown' }
          await refresh()
          return
        }
        await recheck(mine, integrationId, outcome.loginId, 0)
    }
  }

  /** Reads the receipt of the login `loginId`, and says meanwhile that it
      does. `attemptsBefore` readings of it failed in a row before this one. */
  const recheck = async (mine: number, integrationId: string, loginId: string, attemptsBefore: number): Promise<void> => {
    view.value = { kind: 'checking', integrationId, loginId }
    await stand(mine, integrationId, loginId, attemptsBefore)
  }

  const stand = async (mine: number, integrationId: string, loginId: string, attemptsBefore: number): Promise<void> => {
    const standing = await standingOf(send, loginId, integrationId)
    if (!own(mine)) return
    if (!standing.ok) {
      const problem = standing.problem
      if (problem.kind === 'signed_out') signedOut()
      else view.value = { kind: 'detached', integrationId, loginId, failure: { problem, attempts: attemptsBefore + 1 } }
      return
    }
    switch (standing.value.kind) {
      case 'running':
        view.value = { kind: 'detached', integrationId, loginId, failure: null }
        return
      case 'linked':
        await settle(mine, integrationId, { kind: 'linked' })
        return
      case 'ended':
        view.value = { kind: 'ended', integrationId, ended: standing.value.end }
    }
  }

  const open = (): void => {
    if (view.peek().kind === 'closed') view.value = { kind: 'choosing' }
  }

  const close = (): void => {
    const now = view.peek()
    if (now.kind === 'choosing' || now.kind === 'ended' || now.kind === 'failed') {
      run += 1
      view.value = { kind: 'closed', linked: false }
    }
  }

  const reset = (): void => {
    run += 1
    view.value = { kind: 'closed', linked: false }
  }

  const start = async (integrationId: string): Promise<void> => {
    const now = view.peek()
    const csrfToken = token()
    if ((now.kind !== 'choosing' && now.kind !== 'ended' && now.kind !== 'failed') || csrfToken === null) return
    run += 1
    const mine = run
    view.value = { kind: 'starting', integrationId }
    const outcome = await connect(send, csrfToken, integrationId, (progress) => {
      const at = view.peek()
      if (!own(mine)) return
      switch (progress.kind) {
        case 'started':
          if (at.kind === 'starting') {
            view.value = { kind: 'running', integrationId, loginId: progress.loginId, transcript: '', input: 'not_asked', cancelNotTaken: false }
          }
          return
        case 'output':
          if (at.kind === 'running' || at.kind === 'cancelling') {
            view.value = { ...at, transcript: (at.transcript + progress.text).slice(-transcriptLimit) }
          }
          return
        case 'input_ready':
          if (at.kind === 'running') view.value = { ...at, input: 'asked' }
      }
    })
    await settle(mine, integrationId, outcome)
  }

  const reply = async (input: Reply): Promise<void> => {
    const now = view.peek()
    const csrfToken = token()
    if (now.kind !== 'running' || (now.input !== 'asked' && now.input !== 'not_taken') || csrfToken === null) return
    const mine = run
    view.value = { ...now, input: 'sending', cancelNotTaken: false }
    const answer = await replyLogin(send, csrfToken, now.loginId, input)
    const at = view.peek()
    if (!own(mine) || at.kind !== 'running' || at.input !== 'sending') return
    if (answer.ok) view.value = { ...at, input: 'not_asked' }
    else if (answer.problem.kind === 'signed_out') signedOut()
    else view.value = { ...at, input: 'not_taken' }
  }

  const cancel = async (): Promise<void> => {
    const now = view.peek()
    const csrfToken = token()
    if ((now.kind !== 'running' && now.kind !== 'detached') || csrfToken === null) return
    const mine = run
    if (now.kind === 'running') view.value = { kind: 'cancelling', integrationId: now.integrationId, loginId: now.loginId, transcript: now.transcript }
    else view.value = { kind: 'checking', integrationId: now.integrationId, loginId: now.loginId }
    const answer = await cancelLogin(send, csrfToken, now.loginId)
    if (!own(mine)) return
    if (!answer.ok && answer.problem.kind === 'signed_out') {
      signedOut()
      return
    }
    if (now.kind === 'detached') {
      // No stream will say how it stopped: its receipt does.
      await stand(mine, now.integrationId, now.loginId, 0)
      return
    }
    // The stream says how the login stopped. A cancel the server did not take
    // leaves the login running.
    const at = view.peek()
    if (!answer.ok && at.kind === 'cancelling') view.value = { ...now, transcript: at.transcript, cancelNotTaken: true }
  }

  const check = async (): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'detached') return
    await recheck(run, now.integrationId, now.loginId, now.failure === null ? 0 : now.failure.attempts)
  }

  return { view, open, close, start, reply, cancel, check, reset }
}
