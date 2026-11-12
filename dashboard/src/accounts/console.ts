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
import { session as readSession, signOut as endSession, who as readWho } from './wire'
import type { Problem, Role, Send, Session, Who } from './wire'

/** A problem the frame shows. A missing session is never shown: the console
    leaves for the sign-in page. */
export type Shown = Exclude<Problem, { readonly kind: 'signed_out' }>

export type SignOut =
  | { readonly kind: 'idle' }
  | { readonly kind: 'sending' }
  | { readonly kind: 'failed'; readonly problem: Shown }

export type View =
  /** The first reading of the session. `slow` once it has lasted long
      enough that the page says it is waiting. */
  | { readonly kind: 'reading'; readonly slow: boolean }
  /** The session could not be read. `retrying` while another reading runs. */
  | { readonly kind: 'failed'; readonly problem: Shown; readonly retrying: boolean }
  | { readonly kind: 'signed_in'; readonly session: Session; readonly who: Who; readonly signOut: SignOut }
  /** The browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving' }

export interface Deps {
  readonly send: Send
  /** Takes the browser to the sign-in page. */
  readonly leave: () => void
}

export interface ConsoleModel {
  readonly view: ReadonlySignal<View>
  /** Reads the session and whose it is. A call during a reading joins it. */
  readonly load: () => Promise<void>
  readonly signOut: () => Promise<void>
}

/** A wait shorter than this is not announced: the words would flash by. */
const slowAfterMs = 300

export function createConsole({ send, leave }: Deps): ConsoleModel {
  const view = signal<View>({ kind: 'reading', slow: false })

  const goToSignIn = (): void => {
    view.value = { kind: 'leaving' }
    leave()
  }
  const fail = (problem: Problem): void => {
    if (problem.kind === 'signed_out') goToSignIn()
    else view.value = { kind: 'failed', problem, retrying: false }
  }

  const read = async (): Promise<void> => {
    const before = view.value
    if (before.kind === 'failed') view.value = { ...before, retrying: true }
    const slow = setTimeout(() => {
      if (view.value.kind === 'reading') view.value = { kind: 'reading', slow: true }
    }, slowAfterMs)
    const session = await readSession(send)
    const who = session.ok ? await readWho(send) : session
    clearTimeout(slow)
    if (!session.ok) fail(session.problem)
    else if (!who.ok) fail(who.problem)
    else view.value = { kind: 'signed_in', session: session.value, who: who.value, signOut: { kind: 'idle' } }
  }

  let reading: Promise<void> | null = null
  const load = (): Promise<void> => {
    reading ??= read().finally(() => { reading = null })
    return reading
  }

  const signOut = async (): Promise<void> => {
    const before = view.value
    if (before.kind !== 'signed_in' || before.signOut.kind === 'sending') return
    view.value = { ...before, signOut: { kind: 'sending' } }
    const answer = await endSession(send, before.session.csrfToken)
    // The session ended, or none was left to end: either way the person is out.
    if (answer.ok || answer.problem.kind === 'signed_out') goToSignIn()
    else view.value = { ...before, signOut: { kind: 'failed', problem: answer.problem } }
  }

  return { view, load, signOut }
}

// ---- words ----

/** The answer of a server that cannot serve for now (its files are being read again). */
const serviceUnavailable = 503
/** How much of an id the frame shows: enough to tell two accounts apart. */
const idTailLength = 6

function problemWords(problem: Shown): string {
  switch (problem.kind) {
    case 'unreachable': return '서버에 닿지 못했어요. 연결을 확인한 뒤 다시 해 주세요.'
    case 'unreadable': return '서버의 답을 읽지 못했어요. 이 서버를 운영하는 사람에게 알려 주세요.'
    case 'refused':
      return problem.status === serviceUnavailable
        ? '서버가 잠시 준비되지 않았어요. 잠시 뒤 다시 해 주세요.'
        : '서버가 요청을 받아들이지 않았어요.'
  }
}

function roleWords(role: Role): string {
  switch (role) {
    case 'admin': return '관리자'
    case 'member': return '구성원'
    case 'unrecognised': return ''
  }
}

// ---- the frame ----

/** What went wrong, and the sentence of the server under it as it came. The
    sentence is English, so it says so. */
function ProblemNote({ title, problem }: { readonly title: string; readonly problem: Shown }): VNode {
  const reason = problem.kind === 'refused' ? problem.reason : null
  return html`
    <div class="callout" role="alert">
      <p class="callout-title">${title}</p>
      <p>${problemWords(problem)}</p>
      ${reason === null ? null : html`<p class="hint">서버가 알려 준 이유: <span lang="en">${reason}</span></p>`}
    </div>
  `
}

function Account({ who, signOut, onSignOut }: { readonly who: Who; readonly signOut: SignOut; readonly onSignOut: () => void }): VNode {
  // The button stays focusable while the request runs, so the focus of a
  // person who pressed it with a key stays on it.
  return html`
    <div class="account">
      <span class="hint">${roleWords(who.role)} …${who.id.slice(-idTailLength)}</span>
      <button type="button" aria-disabled=${signOut.kind === 'sending'} onClick=${onSignOut}>로그아웃</button>
    </div>
  `
}

/** What is under the heading of the page in one state. */
function Body({ view, onRetry }: { readonly view: View; readonly onRetry: () => void }): VNode {
  switch (view.kind) {
    case 'reading':
      // The line is on the page from the start and fills when the wait is
      // long, which is when a screen reader says it.
      return html`<p class="hint" role="status">${view.slow ? '내 계정을 불러오고 있어요…' : ''}</p>`
    case 'leaving':
      return html`<p class="hint" role="status">로그인 화면으로 이동해요…</p>`
    case 'failed':
      return html`
        <${ProblemNote} title="내 계정을 불러오지 못했어요" problem=${view.problem} />
        <p>
          <button type="button" class="primary" aria-disabled=${view.retrying} onClick=${onRetry}>
            ${view.retrying ? '다시 불러오는 중…' : '다시 시도'}
          </button>
        </p>
      `
    case 'signed_in':
      return html`
        ${view.signOut.kind === 'failed' ? html`<${ProblemNote} title="로그아웃하지 못했어요" problem=${view.signOut.problem} />` : null}
        <p>구독, Keeper, 토큰은 아직 <a href="/">처음 화면</a>에서 다뤄요.</p>
      `
  }
}

export function ConsoleFrame({ model }: { readonly model: ConsoleModel }): VNode {
  const view = model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const shown = useRef(view.kind)
  // A retry that worked takes away the button the person pressed. The focus
  // goes to the heading of the page, not to nothing.
  useEffect(() => {
    if (shown.current === 'failed' && view.kind === 'signed_in') heading.current?.focus()
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
      <${Body} view=${view} onRetry=${() => { void model.load() }} />
    </main>
  `
}
