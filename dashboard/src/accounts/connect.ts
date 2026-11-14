// Connecting a subscription. The person picks one the server offers; its
// official client runs a login on the server, and what the client prints
// shows here. The person replies with a code or a key, or cancels. Once the
// login links the new account, the panel reads the subscriptions again.
//
// `createConnect` moves between the steps; `ConnectArea` (connect-area.ts)
// draws the step it is given. Each continuation of a login writes only while
// the view still shows that login: a login the person left behind changes
// nothing. The server stops a login once it finds its stream closed
// (lib/runtime/runtime_setup_login_session.ml, `monitor`).

import { signal, type ReadonlySignal } from '@preact/signals'
import { cancel as cancelLogin, connect, reply as replyLogin, standingOf } from './login'
import type { LoginEnd, LoginOutcome, Reply } from './login'
import type { Failure, Shown } from './notes'
import type { Problem, Send } from './wire'

/** Where a login is with the person's replies. The server holds one reply
    at a time, and takes the next once the client took the last
    (lib/runtime/runtime_setup_login_session.ml, `enqueue`). */
export type Input =
  /** No reply waits at the server: the person can send one. */
  | 'ready'
  | 'sending'
  /** The server took the last reply; the client has not taken it yet. */
  | 'pending'
  /** The server did not say it took the last reply. */
  | 'not_taken'

/** A login whose stream the page reads. */
interface Following {
  readonly integrationId: string
  readonly loginId: string
  /** What the client printed, as it came, its newest part kept. */
  readonly transcript: string
  readonly input: Input
}

/** What the page knows of a login whose stream it no longer reads. */
export type Known =
  /** Its receipt says its client still runs. */
  | { readonly kind: 'runs' }
  /** Its receipt could not be read: why, and how many readings failed in a row. */
  | { readonly kind: 'unread'; readonly failure: Failure }
  /** The server took a cancel of it; how it stopped is not read yet. */
  | { readonly kind: 'cancel_taken' }
  /** The server did not take a cancel of it, and its receipt does not say it stopped. */
  | { readonly kind: 'cancel_not_taken'; readonly problem: Shown }

export type ConnectView =
  /** Nothing is being connected. `linked` once a login linked an account. */
  | { readonly kind: 'closed'; readonly linked: boolean }
  | { readonly kind: 'choosing' }
  | { readonly kind: 'starting'; readonly integrationId: string }
  /** `cancelNotTaken`: the server did not take the person's last cancel. */
  | ({ readonly kind: 'running'; readonly cancelNotTaken: boolean } & Following)
  /** A cancel is on its way or was taken; the stream has not said yet that the login stopped. */
  | ({ readonly kind: 'cancelling' } & Following)
  /** The page no longer reads the stream; the receipt of the login is being read. */
  | { readonly kind: 'checking'; readonly integrationId: string; readonly loginId: string }
  /** The page no longer reads the stream of a login, which runs on as far as it knows. */
  | { readonly kind: 'detached'; readonly integrationId: string; readonly loginId: string; readonly known: Known }
  | { readonly kind: 'ended'; readonly integrationId: string; readonly ended: LoginEnd }
  /** A login that did not start, or whose stream stopped before it named the login. */
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
  /** Sends a reply; true once the server took it. */
  readonly reply: (input: Reply) => Promise<boolean>
  readonly cancel: () => Promise<void>
  /** Reads again how a detached login stands. */
  readonly check: () => Promise<void>
  /** Leaves whatever runs behind, for another person is shown now. */
  readonly reset: () => void
}

/** How much of what a client printed stays: the newest part, as on a terminal. */
export const transcriptLimit = 65_536

/** The second halves of UTF-16 surrogate pairs. */
const lowSurrogates = { first: 0xdc00, last: 0xdfff }

/** The newest part of `text`, from a whole character on. */
function kept(text: string): string {
  const tail = text.slice(-transcriptLimit)
  const head = tail.charCodeAt(0)
  return head >= lowSurrogates.first && head <= lowSurrogates.last ? tail.slice(1) : tail
}

export function createConnect({ send, leave, token, refresh }: ConnectDeps): ConnectModel {
  const view = signal<ConnectView>({ kind: 'closed', linked: false })

  /** Each login started, and each step that leaves one behind, makes a new
      run; a continuation writes only while its run is the latest. */
  let run = 0
  const own = (mine: number): boolean => mine === run
  /** Only the answer to the latest reply moves `input`. */
  let replies = 0
  /** Closes the stream of the latest login. */
  let reading: AbortController | null = null

  const leaveBehind = (): void => {
    run += 1
    reading?.abort()
    reading = null
  }

  const signedOut = (): void => {
    leaveBehind()
    view.value = { kind: 'leaving' }
    leave()
  }
  const failed = (integrationId: string, problem: Problem): void => {
    if (problem.kind === 'signed_out') signedOut()
    else view.value = { kind: 'failed', integrationId, failure: { problem, attempts: 1 } }
  }
  /** A login that stopped without linking an account, as far as it said.
      The server links a person's account before it writes the receipt that
      says so, and a login whose receipt could not be written may have linked
      one: the subscriptions are read again whichever way it stopped. */
  const ended = async (integrationId: string, end: LoginEnd): Promise<void> => {
    view.value = { kind: 'ended', integrationId, ended: end }
    await refresh()
  }

  const settle = async (mine: number, integrationId: string, outcome: LoginOutcome): Promise<void> => {
    if (!own(mine)) return
    switch (outcome.kind) {
      case 'linked':
        view.value = { kind: 'closed', linked: true }
        await refresh()
        return
      case 'ended':
        await ended(integrationId, outcome.end)
        return
      case 'problem': {
        // The page stops reading at a frame it cannot read, which closes the
        // stream; until the server finds it closed, the receipt says the
        // login runs.
        const at = view.peek()
        if (at.kind === 'running' || at.kind === 'cancelling') await recheck(mine, integrationId, at.loginId, 0)
        else failed(integrationId, outcome.problem)
        return
      }
      case 'cut':
        // A stream cut before it named the login leaves nothing to follow,
        // and the server stops the login it closed on.
        if (outcome.loginId === null) failed(integrationId, { kind: 'unreachable' })
        else await recheck(mine, integrationId, outcome.loginId, 0)
    }
  }

  /** Reads the receipt of the login `loginId`, and says meanwhile that it
      does. `attemptsBefore` readings of it failed in a row before this one. */
  const recheck = async (mine: number, integrationId: string, loginId: string, attemptsBefore: number): Promise<void> => {
    view.value = { kind: 'checking', integrationId, loginId }
    await stand(mine, integrationId, loginId, (problem) =>
      problem === null ? { kind: 'runs' } : { kind: 'unread', failure: { problem, attempts: attemptsBefore + 1 } })
  }

  /** Reads the receipt of the login `loginId` and goes to the step of a
      login that stopped. Of one that runs on as far as the page knows,
      `known` says what the page knows, from the problem of the reading or
      null when the receipt says the client still runs. */
  const stand = async (mine: number, integrationId: string, loginId: string, known: (problem: Shown | null) => Known): Promise<void> => {
    const standing = await standingOf(send, loginId, integrationId)
    if (!own(mine)) return
    if (!standing.ok) {
      const problem = standing.problem
      if (problem.kind === 'signed_out') signedOut()
      else view.value = { kind: 'detached', integrationId, loginId, known: known(problem) }
      return
    }
    switch (standing.value.kind) {
      case 'running':
        view.value = { kind: 'detached', integrationId, loginId, known: known(null) }
        return
      case 'linked':
        await settle(mine, integrationId, { kind: 'linked' })
        return
      case 'ended':
        await ended(integrationId, standing.value.end)
    }
  }

  const open = (): void => {
    if (view.peek().kind === 'closed') view.value = { kind: 'choosing' }
  }

  /** Closes the steps where the page reads no stream. A detached login runs
      on as far as the page knows; closing leaves it behind. */
  const close = (): void => {
    const now = view.peek()
    if (now.kind === 'choosing' || now.kind === 'ended' || now.kind === 'failed' || now.kind === 'detached') {
      leaveBehind()
      view.value = { kind: 'closed', linked: false }
    }
  }

  const reset = (): void => {
    leaveBehind()
    view.value = { kind: 'closed', linked: false }
  }

  const start = async (integrationId: string): Promise<void> => {
    const now = view.peek()
    const csrfToken = token()
    if ((now.kind !== 'choosing' && now.kind !== 'ended' && now.kind !== 'failed') || csrfToken === null) return
    leaveBehind()
    const mine = run
    const stream = new AbortController()
    reading = stream
    view.value = { kind: 'starting', integrationId }
    const outcome = await connect(send, csrfToken, integrationId, stream.signal, (progress) => {
      const at = view.peek()
      if (!own(mine)) return
      switch (progress.kind) {
        case 'started':
          if (at.kind === 'starting') {
            view.value = { kind: 'running', integrationId, loginId: progress.loginId, transcript: '', input: 'ready', cancelNotTaken: false }
          }
          return
        case 'output':
          if (at.kind === 'running' || at.kind === 'cancelling') view.value = { ...at, transcript: kept(at.transcript + progress.text) }
          return
        case 'input_ready':
          if (at.kind === 'running' || at.kind === 'cancelling') view.value = { ...at, input: 'ready' }
      }
    })
    if (reading === stream) reading = null
    await settle(mine, integrationId, outcome)
  }

  const reply = async (input: Reply): Promise<boolean> => {
    const now = view.peek()
    const csrfToken = token()
    if (now.kind !== 'running' || (now.input !== 'ready' && now.input !== 'not_taken') || csrfToken === null) return false
    const mine = run
    replies += 1
    const sent = replies
    view.value = { ...now, input: 'sending', cancelNotTaken: false }
    const answer = await replyLogin(send, csrfToken, now.loginId, input)
    if (!own(mine)) return answer.ok
    if (!answer.ok && answer.problem.kind === 'signed_out') {
      signedOut()
      return false
    }
    const at = view.peek()
    if (sent !== replies || (at.kind !== 'running' && at.kind !== 'cancelling')) return answer.ok
    // The client may take a reply before its answer comes back: then the
    // input is ready already.
    if (!answer.ok) view.value = { ...at, input: 'not_taken' }
    else if (at.input === 'sending') view.value = { ...at, input: 'pending' }
    return answer.ok
  }

  const cancel = async (): Promise<void> => {
    const now = view.peek()
    const csrfToken = token()
    if ((now.kind !== 'running' && now.kind !== 'detached') || csrfToken === null) return
    const mine = run
    if (now.kind === 'running') {
      view.value = { kind: 'cancelling', integrationId: now.integrationId, loginId: now.loginId, transcript: now.transcript, input: now.input }
    } else view.value = { kind: 'checking', integrationId: now.integrationId, loginId: now.loginId }
    const answer = await cancelLogin(send, csrfToken, now.loginId)
    if (!own(mine)) return
    const problem = answer.ok ? null : answer.problem
    if (problem?.kind === 'signed_out') {
      signedOut()
      return
    }
    if (now.kind === 'detached') {
      // No stream will say how the login stopped. The server stops it soon
      // after it takes a cancel, sooner than its receipt says so.
      if (problem === null) view.value = { kind: 'detached', integrationId: now.integrationId, loginId: now.loginId, known: { kind: 'cancel_taken' } }
      else await stand(mine, now.integrationId, now.loginId, () => ({ kind: 'cancel_not_taken', problem }))
      return
    }
    // The stream says how the login stopped. A cancel the server did not take
    // leaves the login running.
    const at = view.peek()
    if (problem !== null && at.kind === 'cancelling') view.value = { ...at, kind: 'running', cancelNotTaken: true }
  }

  const check = async (): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'detached') return
    await recheck(run, now.integrationId, now.loginId, now.known.kind === 'unread' ? now.known.failure.attempts : 0)
  }

  return { view, open, close, start, reply, cancel, check, reset }
}
