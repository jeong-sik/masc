// The form of the tokens panel that makes a token for a use; what came of
// the make, with the token just made, which is shown once until the person
// says they took it; and the alert of a request about a token that came to
// nothing (tokens.ts).

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { Callout, ProblemNote, fell, idTail, sessionEndedWords } from './notes'
import type { Shown } from './notes'
import { expiries } from './tokens'
import type { Expiry, Make, Revoke, TokensModel } from './tokens'
import { uses } from './tokens-wire'
import type { Issued, Use } from './tokens-wire'

const formTitleId = 'token-new-title'
const makeTipId = 'token-make-tip'
const secretTitleId = 'token-secret-title'
const defaultUse: Use = 'read_only'
const defaultExpiry: Expiry = 'days_30'
/** The answers of a request about a token the page has words for (lib/auth/login_pat_routes.mli). */
const notFound = 404
const forbidden = 403

// ---- words ----

/** The name of a use, and what a token made for it can do. */
export function useWords(use: Use): readonly [string, string] {
  switch (use) {
    case 'read_only': return ['읽기 전용', '내가 누구로 접속했는지만 확인할 수 있어요.']
    case 'mcp': return ['MCP 클라이언트', '구독을 보고, 연결하고, 모델을 확인할 수 있어요. Keeper를 보고, 만들고, 모델을 정하고, 대화할 수 있어요. 모델 확인과 대화는 내 구독으로 모델을 불러요.']
  }
}

function expiryWords(expiry: Expiry): string {
  switch (expiry) {
    case 'days_7': return '7일 뒤'
    case 'days_30': return '30일 뒤'
    case 'days_90': return '90일 뒤'
    case 'never': return '만료 없음'
  }
}

/** What the page heard of a request whose end it does not know. */
function unknownWords(problem: Shown): string {
  switch (problem.kind) {
    case 'unreachable': return '서버의 답을 받지 못했어요.'
    case 'unreadable': return '서버의 답을 읽지 못했어요.'
    case 'refused': return '서버가 오류로 답했어요.'
  }
}

function makeWords(making: Make): string {
  switch (making.kind) {
    case 'sending': return '토큰을 만들고 있어요…'
    case 'issued': return '토큰을 만들었어요. 바로 아래에 한 번만 보여요.'
    case 'leaving': return sessionEndedWords
    case 'idle':
    case 'refused':
    case 'unknown':
      return ''
  }
}

/** The words of a refusal the page can say more of than that it was refused.
    A 403 comes of a session another tab replaced as well as of an account
    the server does not let act, and its answer does not say which. */
function refusedWords(status: number, step: 'make' | 'revoke'): readonly string[] | null {
  if (status === forbidden) {
    return [
      '서버가 이 요청을 받지 않았어요.',
      '다른 탭에서 다시 로그인했다면 이 화면을 새로 고친 뒤 다시 해 주세요.',
      `그래도 안 되면 이 계정이 지금 토큰을 ${step === 'make' ? '만들' : '폐기할'} 수 없는 것이에요. 이 서버를 운영하는 사람에게 물어봐 주세요.`,
    ]
  }
  if (status === notFound && step === 'revoke') return ['서버에서 이 토큰을 찾지 못했어요. 목록을 다시 불러와요.']
  return null
}

/** The alert of a request that came to nothing. The caller makes each one
    anew (its key is the count), so a screen reader says the second as it
    said the first. */
export function Outcome({ title, step, outcome }: {
  readonly title: string
  readonly step: 'make' | 'revoke'
  readonly outcome: Extract<Make | Revoke, { kind: 'refused' | 'unknown' }>
}): VNode {
  const { problem, attempts } = outcome
  const reason = problem.kind === 'refused' ? problem.reason : null
  if (outcome.kind === 'unknown') {
    const after = step === 'make'
      ? ['토큰이 만들어졌을 수도 있지만, 그 토큰은 다시 볼 수 없어요.', '목록에 모르는 새 토큰이 보이면 폐기하고 다시 만들어 주세요.']
      : ['토큰이 폐기됐을 수도 있어요.', '목록에서 이 토큰의 상태를 보고, 아직 쓸 수 있으면 다시 폐기해 주세요.']
    return html`<${Callout} title=${title} attempts=${attempts} reason=${reason} lines=${[`${unknownWords(problem)} ${after[0]}`, after[1]]} />`
  }
  const words = refusedWords(outcome.problem.status, step)
  if (words === null) return html`<${ProblemNote} title=${title} failure=${{ problem: outcome.problem, attempts }} />`
  return html`<${Callout} title=${title} lines=${words} attempts=${attempts} reason=${reason} />`
}

// ---- a new token ----

/** The token just made, with a button that copies it. It is in a field, so
    it can also be picked and copied by hand. A token is one word of about
    a hundred letters, which takes five lines of the field at 320 CSS px. */
function SecretBox({ issued, onDone }: { readonly issued: Issued; readonly onDone: () => void }): VNode {
  const [copied, setCopied] = useState<'not_yet' | 'copied' | 'failed'>('not_yet')
  const copy = (): void => {
    // The clipboard is not there in a page served without TLS away from localhost.
    if (!('clipboard' in navigator)) {
      setCopied('failed')
      return
    }
    navigator.clipboard.writeText(issued.token).then(() => { setCopied('copied') }, () => { setCopied('failed') })
  }
  const copiedWords = copied === 'copied' ? '복사했어요.' : copied === 'failed' ? '복사하지 못했어요. 칸의 글자를 골라 직접 복사해 주세요.' : ''
  return html`
    <div class="callout" aria-labelledby=${secretTitleId} role="group">
      <p id=${secretTitleId} class="callout-title">새 토큰이에요. 지금만 보여요</p>
      <p>이 화면을 떠나거나 「다 옮겼어요」를 누르면 다시 볼 수 없어요. 지금 복사해서 안전한 곳에 두세요.</p>
      <div class="field">
        <label for="token-secret">토큰 <span class="mono">${idTail(issued.id)}</span></label>
        <textarea id="token-secret" readonly rows="5" spellcheck=${false} autocomplete="off" value=${issued.token}
          onFocus=${(event: FocusEvent) => { (event.currentTarget as HTMLTextAreaElement).select() }}></textarea>
      </div>
      <p class="actions">
        <button type="button" class="primary" onClick=${copy}>복사</button>
        <button type="button" onClick=${onDone}>다 옮겼어요</button>
      </p>
      <p class="hint" role="status">${copiedWords}</p>
    </div>
  `
}

/** The form that makes a token. The use and the expiry picked are kept
    here, so a form drawn again (a make refused, the list read again) still
    shows and sends what the person picked. */
export function MakeForm({ model }: { readonly model: TokensModel }): VNode {
  const making = model.making.value
  const showing = making.kind === 'issued'
  const busy = making.kind === 'sending' || making.kind === 'leaving'
  const canMake = !busy && !showing
  const [use, setUse] = useState<Use>(defaultUse)
  const [expiry, setExpiry] = useState<Expiry>(defaultExpiry)
  const onSubmit = (event: Event): void => {
    event.preventDefault()
    if (canMake) void model.make(use, expiry)
  }
  const onExpiry = (event: Event): void => {
    const picked = expiries.find((one) => one === (event.currentTarget as HTMLSelectElement).value)
    if (picked !== undefined) setExpiry(picked)
  }
  return html`
    <form class="keeper-form" aria-labelledby=${formTitleId} onSubmit=${onSubmit}>
      <h3 id=${formTitleId} tabindex="-1">새 토큰</h3>
      <fieldset>
        <legend>쓸 곳</legend>
        <ul class="choices">
          ${uses.map((one) => html`
            <li key=${one}>
              <label class="choice">
                <input type="radio" name="use" value=${one} checked=${one === use} onChange=${() => { setUse(one) }} />
                <span><span class="choice-title">${useWords(one)[0]}</span> <span class="hint">${useWords(one)[1]}</span></span>
              </label>
            </li>
          `)}
        </ul>
      </fieldset>
      <div class="field">
        <label for="token-expiry">만료</label>
        <select id="token-expiry" name="expiry" value=${expiry} onChange=${onExpiry}>
          ${expiries.map((one) => html`<option key=${one} value=${one}>${expiryWords(one)}</option>`)}
        </select>
      </div>
      <p><button type="submit" class="primary" aria-disabled=${!canMake} aria-describedby=${makeTipId}>토큰 만들기</button></p>
      <p id=${makeTipId} class="hint">
        ${showing
          ? '아래 토큰을 옮기고 「다 옮겼어요」를 누르면 또 만들 수 있어요.'
          : '토큰은 만든 뒤 한 번만 보여요. 토큰을 가진 쪽은 고른 범위 안에서 나로 접속해요.'}
      </p>
    </form>
  `
}

/** What came of the latest make: a line a screen reader reads out, the
    alert of a make that came to nothing, and the token just made. It is
    drawn whatever the list shows, so a list that could not be read again
    does not take a token made off the page. `heading` names the heading
    of the panel, where the focus goes when the form is not on the page. */
export function MadeArea({ model, heading }: { readonly model: TokensModel; readonly heading: string }): VNode {
  const making = model.making.value
  const showing = making.kind === 'issued'
  // The line under the heading says that the session ended, so this one does not say it again.
  const words = model.view.value.kind === 'leaving' ? '' : makeWords(making)
  // Saying the token was taken takes its box and buttons away. The focus
  // then goes to the title of the form, not to the body of the page.
  const wasShowing = useRef(showing)
  useEffect(() => {
    const before = wasShowing.current
    wasShowing.current = showing
    if (before && !showing && fell()) (document.getElementById(formTitleId) ?? document.getElementById(heading))?.focus()
  }, [showing, heading])
  return html`
    <p class="hint" role="status">${words}</p>
    ${making.kind === 'refused' || making.kind === 'unknown'
      ? html`<${Outcome} key=${making.attempts} step="make" outcome=${making}
          title=${making.kind === 'refused' ? '토큰을 만들지 못했어요' : '토큰을 만들었는지 알 수 없어요'} />`
      : null}
    ${making.kind === 'issued' ? html`<${SecretBox} issued=${making.issued} onDone=${model.forget} />` : null}
  `
}
