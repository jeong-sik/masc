// What a part of the console says when a request failed, and the button that
// reads again. The frame and the panels under it share them, so a failure
// reads the same wherever it happens.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { withheldReasons } from './wire'
import type { Problem, Withheld, WithheldReason } from './wire'

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
/** The answer of a request whose session may have been replaced by another tab (`ConsoleModel.send`). */
const forbidden = 403
/** How much of an id the console shows: enough to tell two apart. */
const idTailLength = 6

/** The end of an id, as the console shows it. */
export const idTail = (id: string): string => `…${id.slice(-idTailLength)}`

function problemWords(problem: Shown): string {
  switch (problem.kind) {
    case 'unreachable': return '서버에 닿지 못했어요. 연결을 확인한 뒤 다시 해 주세요.'
    case 'unreadable': return '서버의 답을 읽지 못했어요. 이 서버를 운영하는 사람에게 알려 주세요.'
    case 'refused':
      if (problem.status === serviceUnavailable) return '서버가 잠시 준비되지 않았어요. 잠시 뒤 다시 해 주세요.'
      // The console has read the session of now before this is shown, so
      // the next try carries its token.
      if (problem.status === forbidden) return '서버가 요청을 받아들이지 않았어요. 다른 탭에서 다시 로그인했다면 한 번 더 해 주세요.'
      return '서버가 요청을 받아들이지 않았어요.'
  }
}

/** What a page says while the browser leaves for the sign-in page because a
    request found that the session had ended. */
export const sessionEndedWords = '세션이 끝났어요. 로그인 화면으로 이동해요…'

export const operatorWords = '이 서버를 운영하는 사람에게 알려 주세요.'

/** What a person reads before they give a key, for a new account or for
    one they hold (RFC of the key accounts, 3.8). */
export const keyGivenWords = [
  'key 는 이 서버에 암호화하지 않은 파일로 저장돼요. 서버를 운영하는 사람은 그 파일을 읽을 수 있어요.',
  '저장한 뒤에는 이 화면에서 다시 보여 주지 않아요.',
  '이 key 로 쓴 만큼 key 를 발급한 조직에 요금이 나가요.',
] as const

/** What the server answers `not_a_key` for (lib/server/server_key_account.ml). */
export const notAKeyWords = 'key 로 읽을 수 없는 값이에요. key 하나만 넣어 주세요. 비어 있거나, 줄바꿈 같은 제어 문자가 있거나, JSON 문서면 받지 않아요.'

/** What removing a key account does not do, said where a key is given and
    where an account is removed: the server takes its own copy of the key
    away, and the vendor still takes the key (RFC of the key accounts, 3.8). */
export const keyStaysValidWords = '여기서 없애도 key 는 발급한 곳에서 계속 유효해요. 못 쓰게 하려면 그곳에서 폐기해 주세요.'

/** Why the models the operator bound are left out, a sentence for each reason. */
function withheldWords(reason: WithheldReason, models: readonly string[]): string {
  const names = models.join(', ')
  switch (reason) {
    case 'tools_not_declared': return `서버 설정에서 도구 호출을 켜지 않은 모델이에요: ${names}.`
    case 'model_undeclared': return `서버 설정에 정보가 없는 모델이에요: ${names}.`
    case 'unrecognised': return `이 화면이 모르는 까닭으로 빠진 모델이에요: ${names}.`
  }
}

/** Why a subscription has no model to check, for the person to pass on to the operator. */
export function noModelWords(withheld: readonly Withheld[]): string {
  if (withheld.length === 0) return `서버 설정에 이 구독의 모델이 하나도 적혀 있지 않아요. ${operatorWords}`
  const reasons = withheldReasons.flatMap((reason) => {
    const models = withheld.filter((one) => one.reason === reason).map((one) => one.model)
    return models.length === 0 ? [] : [withheldWords(reason, models)]
  })
  return `${reasons.join(' ')} ${operatorWords}`
}

/** What the status line under a button that reads again says. */
function nextWords(next: Next): string {
  switch (next) {
    case 'idle': return ''
    case 'reading': return '다시 불러오고 있어요…'
    case 'leaving': return sessionEndedWords
  }
}

/** Whether the focus is on nothing: the control that held it went away. */
export const fell = (): boolean => document.activeElement === null || document.activeElement === document.body

/** An alert with a title and lines, and the sentence of the server under
    them as it came. The sentence is English, so it says so. A failure after
    the first says how many there were. A caller that shows a failure again
    in the same place keys the alert by that count, so a screen reader says
    the second as it said the first. */
export function Callout({ title, lines, reason, attempts }: {
  readonly title: string
  readonly lines: readonly string[]
  readonly reason: string | null
  readonly attempts: number
}): VNode {
  return html`
    <div class="callout" role="alert">
      <p class="callout-title">${title}</p>
      ${lines.map((line) => html`<p>${line}</p>`)}
      ${reason === null ? null : html`<p class="hint">서버가 알려 준 이유: <span lang="en">${reason}</span></p>`}
      ${attempts > 1 ? html`<p class="hint">${attempts}번 시도했어요.</p>` : null}
    </div>
  `
}

/** What went wrong, in the words shared by every part of the console. */
export function ProblemNote({ title, failure }: { readonly title: string; readonly failure: Failure }): VNode {
  const { problem, attempts } = failure
  return html`<${Callout} title=${title} lines=${[problemWords(problem)]} reason=${problem.kind === 'refused' ? problem.reason : null} attempts=${attempts} />`
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
