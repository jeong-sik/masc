// The frame of the console of a signed-in person: who is signed in, the way
// out, and what the page says while it reads the session or cannot.
//
// `createConsole` holds the state and makes the requests; `ConsoleFrame`
// draws whatever state it is given. The state is one value of a closed
// shape, so the frame has a branch for each thing that can be on the page
// and for nothing else.

import { signal, type ReadonlySignal } from '@preact/signals'
import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import { Callout, ProblemNote, Retry, idTail, slowAfterMs } from './notes'
import type { Failure, Next, Shown } from './notes'
import { KeepersPanel } from './keeper-rows'
import type { KeepersModel } from './keepers'
import { SubscriptionsPanel } from './subscriptions'
import type { SubscriptionsModel } from './subscriptions'
import { session as readSession, signOut as endSession, who as readWho } from './wire'
import type { Answer, Problem, Role, Send, Session, Who } from './wire'

export type { Failure, Next, Shown } from './notes'

export type SignOut =
  | { readonly kind: 'idle' }
  | { readonly kind: 'sending' }
  | { readonly kind: 'failed'; readonly failure: Failure }
  /** The person is out: the session ended, or none was left to end. The
      browser leaves, and the page stays as it was while it does. */
  | { readonly kind: 'out' }

export type View =
  /** The first reading of the session. `slow` once it has lasted long
      enough that the page says it is waiting. */
  | { readonly kind: 'reading'; readonly slow: boolean }
  /** The first reading found no session, and the browser is on its way to
      the sign-in page. */
  | { readonly kind: 'leaving' }
  /** The session could not be read. */
  | { readonly kind: 'failed'; readonly failure: Failure; readonly next: Next }
  /** The browser holds the session of another person than the one the page
      read or showed: another tab signed in. The page shows neither, and
      sends nothing for the person it showed. */
  | { readonly kind: 'changed'; readonly next: Next }
  | { readonly kind: 'signed_in'; readonly session: Session; readonly who: Who; readonly signOut: SignOut }

export interface Deps {
  readonly send: Send
  /** Takes the browser to the sign-in page. The console calls it only when
      the browser holds no session. */
  readonly leave: () => void
}

export interface ConsoleModel {
  readonly view: ReadonlySignal<View>
  /** Reads the session and whose it is. A call during a reading joins it. A
      call while someone is signed in, or after a reading found no session,
      does nothing. */
  readonly load: () => Promise<void>
  readonly signOut: () => Promise<void>
}

interface SignedIn {
  readonly session: Session
  readonly who: Who
}

/** What a reading found: the session and whose it is, two people, or a
    problem. The two come from two requests, and another tab that signs in
    between them makes them name two people. */
type Found =
  | { readonly kind: 'signed_in'; readonly value: SignedIn }
  | { readonly kind: 'changed' }
  | { readonly kind: 'problem'; readonly problem: Problem }

async function readSignedIn(send: Send): Promise<Found> {
  const session = await readSession(send)
  if (!session.ok) return { kind: 'problem', problem: session.problem }
  const who = await readWho(send)
  if (!who.ok) return { kind: 'problem', problem: who.problem }
  if (who.value.id !== session.value.userId) return { kind: 'changed' }
  return { kind: 'signed_in', value: { session: session.value, who: who.value } }
}

/** What a sign-out came to: the person is out (the session ended, or none
    was left to end), or the server refused. */
type Ended = { readonly kind: 'out' } | { readonly kind: 'refused'; readonly problem: Shown }

const ended = (answer: Answer<null>): Ended =>
  answer.ok || answer.problem.kind === 'signed_out' ? { kind: 'out' } : { kind: 'refused', problem: answer.problem }

export function createConsole({ send, leave }: Deps): ConsoleModel {
  const view = signal<View>({ kind: 'reading', slow: false })

  const read = async (): Promise<void> => {
    const before = view.value
    // Someone is signed in, or the browser leaves: there is nothing to read.
    if (before.kind === 'signed_in' || before.kind === 'leaving') return
    if (before.kind !== 'reading' && before.next === 'leaving') return
    const failedBefore = before.kind === 'failed' ? before.failure.attempts : 0
    if (before.kind !== 'reading') view.value = { ...before, next: 'reading' }
    const slow = setTimeout(() => {
      if (view.value.kind === 'reading') view.value = { kind: 'reading', slow: true }
    }, slowAfterMs)
    const found = await readSignedIn(send)
    clearTimeout(slow)
    switch (found.kind) {
      case 'signed_in':
        view.value = { kind: 'signed_in', ...found.value, signOut: { kind: 'idle' } }
        return
      case 'changed':
        view.value = { kind: 'changed', next: 'idle' }
        return
      case 'problem':
        if (found.problem.kind === 'signed_out') {
          view.value = before.kind === 'reading' ? { kind: 'leaving' } : { ...before, next: 'leaving' }
          leave()
          return
        }
        view.value = { kind: 'failed', failure: { problem: found.problem, attempts: failedBefore + 1 }, next: 'idle' }
    }
  }

  let reading: Promise<void> | null = null
  const load = (): Promise<void> => {
    reading ??= read().finally(() => { reading = null })
    return reading
  }

  const signOut = async (): Promise<void> => {
    const before = view.value
    if (before.kind !== 'signed_in' || before.signOut.kind === 'sending' || before.signOut.kind === 'out') return
    const refusedBefore = before.signOut.kind === 'failed' ? before.signOut.failure.attempts : 0
    view.value = { ...before, signOut: { kind: 'sending' } }
    const out = (): void => {
      view.value = { ...before, signOut: { kind: 'out' } }
      leave()
    }
    const first = ended(await endSession(send, before.session.csrfToken))
    if (first.kind === 'out') return out()
    // The server refuses a token that is not the one of the session, which
    // is what a page holds when another tab signed in. The session is read
    // again. A session that ended leaves the person out. Another person's
    // session is not ended: the page says the account changed. A token of
    // the same person that changed is sent once more.
    const now = await readSession(send)
    if (!now.ok && now.problem.kind === 'signed_out') return out()
    if (now.ok && now.value.userId !== before.session.userId) {
      view.value = { kind: 'changed', next: 'idle' }
      return
    }
    const session = now.ok ? now.value : before.session
    const last = session.csrfToken === before.session.csrfToken
      ? first
      : ended(await endSession(send, session.csrfToken))
    if (last.kind === 'out') return out()
    view.value = { ...before, session, signOut: { kind: 'failed', failure: { problem: last.problem, attempts: refusedBefore + 1 } } }
  }

  return { view, load, signOut }
}

// ---- words ----

function roleWords(role: Role): string {
  switch (role) {
    case 'admin': return '관리자'
    case 'member': return '구성원'
    case 'unrecognised': return ''
  }
}

// ---- the frame ----

function Account({ who, signOut, onSignOut }: { readonly who: Who; readonly signOut: SignOut; readonly onSignOut: () => void }): VNode {
  // The button stays focusable while the request runs, so the focus of a
  // person who pressed it with a key stays on it.
  return html`
    <div class="account">
      <span class="hint">${roleWords(who.role)} ${idTail(who.id)}</span>
      <button type="button" aria-disabled=${signOut.kind === 'sending' || signOut.kind === 'out'} onClick=${onSignOut}>로그아웃</button>
    </div>
  `
}

/** What is under the heading of the page in one state. A note of a failure
    is made anew for each failure (its key is the count), so a screen reader
    says the second one as it said the first. */
function Body({ view, subscriptions, keepers, onRetry }: {
  readonly view: View
  readonly subscriptions: SubscriptionsModel
  readonly keepers: KeepersModel
  readonly onRetry: () => void
}): VNode {
  switch (view.kind) {
    case 'reading':
      return html`<p class="hint" role="status">${view.slow ? '내 계정을 불러오고 있어요…' : ''}</p>`
    case 'leaving':
      return html`<p class="hint" role="status">로그인 화면으로 이동해요…</p>`
    case 'failed':
      return html`
        <${ProblemNote} key=${view.failure.attempts} title="내 계정을 불러오지 못했어요" failure=${view.failure} />
        <${Retry} label="다시 시도" next=${view.next} onRetry=${onRetry} />
      `
    case 'changed':
      return html`
        <${Callout} title="다른 탭에서 계정이 바뀌었어요" reason=${null} attempts=${1}
          lines=${['이 브라우저에는 지금 다른 계정이 로그인되어 있어요. 이 화면은 그 계정을 불러오기 전에는 아무것도 보내지 않아요.']} />
        <${Retry} label="지금 계정 불러오기" next=${view.next} onRetry=${onRetry} />
      `
    case 'signed_in':
      return html`
        ${view.signOut.kind === 'failed'
          ? html`<${ProblemNote} key=${view.signOut.failure.attempts} title="로그아웃하지 못했어요" failure=${view.signOut.failure} />`
          : null}
        <${SubscriptionsPanel} model=${subscriptions} />
        <${KeepersPanel} model=${keepers} subscriptions=${subscriptions} />
        <p>토큰은 아직 처음 화면에서 만들어요.</p>
        <p><a class="button" href="/">처음 화면으로</a></p>
        <p class="hint" role="status">${view.signOut.kind === 'out' ? '로그아웃했어요. 로그인 화면으로 이동해요…' : ''}</p>
      `
  }
}

/** Whether a move from one state to another takes away the button the person
    pressed: the retry of a failed or changed page when the session is read,
    and the sign-out when the page finds that the account changed. */
const takesThePressedButton = (from: View['kind'], to: View['kind']): boolean =>
  ((from === 'failed' || from === 'changed') && to === 'signed_in') || (from === 'signed_in' && to === 'changed')

export function ConsoleFrame({ model, subscriptions, keepers }: {
  readonly model: ConsoleModel
  readonly subscriptions: SubscriptionsModel
  readonly keepers: KeepersModel
}): VNode {
  const view = model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const shown = useRef(view.kind)
  // The focus goes to the heading of the page when the pressed button goes
  // away, not to nothing.
  useEffect(() => {
    if (takesThePressedButton(shown.current, view.kind)) heading.current?.focus()
    shown.current = view.kind
  }, [view.kind])
  return html`
    <header class="site-header">
      <span class="brand">MASC</span><span class="brand-sub">계정</span>
      ${view.kind === 'signed_in'
        ? html`<${Account} who=${view.who} signOut=${view.signOut} onSignOut=${() => { void model.signOut() }} />`
        : null}
    </header>
    <main>
      <h1 ref=${heading} tabindex="-1">내 계정</h1>
      <${Body} view=${view} subscriptions=${subscriptions} keepers=${keepers} onRetry=${() => { void model.load() }} />
    </main>
  `
}
