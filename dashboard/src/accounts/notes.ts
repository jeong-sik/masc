// What a part of the console says when a request failed, and the button that
// reads again. The frame and the panels under it share them, so a failure
// reads the same wherever it happens.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { Problem } from './wire'

/** A problem a page shows. A missing session is never shown: the console
    leaves for the sign-in page. */
export type Shown = Exclude<Problem, { readonly kind: 'signed_out' }>

/** A request that failed, and how many times in a row it has. */
export interface Failure {
  readonly problem: Shown
  readonly attempts: number
}

/** What a page with a button that reads again does: nothing yet, a reading,
    or the way to the sign-in page after a reading found no session. The
    button stays on the page while the browser leaves, so the focus of the
    person who pressed it stays where it was. */
export type Next = 'idle' | 'reading' | 'leaving'

/** A wait shorter than this is not announced: the words would flash by. */
export const slowAfterMs = 300

/** The answer of a server that cannot serve for now (its files are being read again). */
const serviceUnavailable = 503
/** How much of an id the console shows: enough to tell two apart. */
const idTailLength = 6

/** The end of an id, as the console shows it. */
export const idTail = (id: string): string => `…${id.slice(-idTailLength)}`

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

/** What a page says while the browser leaves for the sign-in page because a
    request found that the session had ended. */
export const sessionEndedWords = '세션이 끝났어요. 로그인 화면으로 이동해요…'

/** What the status line under a button that reads again says. */
function nextWords(next: Next): string {
  switch (next) {
    case 'idle': return ''
    case 'reading': return '다시 불러오고 있어요…'
    case 'leaving': return sessionEndedWords
  }
}

/** What went wrong, and the sentence of the server under it as it came. The
    sentence is English, so it says so. A failure after the first says how
    many there were, so a second failure for the same reason still changes
    what the page says. */
export function ProblemNote({ title, failure }: { readonly title: string; readonly failure: Failure }): VNode {
  const { problem, attempts } = failure
  const reason = problem.kind === 'refused' ? problem.reason : null
  return html`
    <div class="callout" role="alert">
      <p class="callout-title">${title}</p>
      <p>${problemWords(problem)}</p>
      ${reason === null ? null : html`<p class="hint">서버가 알려 준 이유: <span lang="en">${reason}</span></p>`}
      ${attempts > 1 ? html`<p class="hint">${attempts}번 시도했어요.</p>` : null}
    </div>
  `
}

/** A button that reads again, and the line that says what it does. Each
    line is on the page from the start of its state and fills when something
    happens, which is when a screen reader says it. */
export function Retry({ label, next, onRetry }: { readonly label: string; readonly next: Next; readonly onRetry: () => void }): VNode {
  return html`
    <p><button type="button" class="primary" aria-disabled=${next !== 'idle'} onClick=${onRetry}>${label}</button></p>
    <p class="hint" role="status">${nextWords(next)}</p>
  `
}
