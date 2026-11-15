// The form of the invitations panel that makes a link for a role; what came
// of the make, with the link just made, which is shown once until the Admin
// says they took it; and the alert of a request about an invitation that
// came to nothing (invites.ts).

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { Callout, ProblemNote, fell, idTail, sessionEndedWords } from './notes'
import type { InvitesModel, Make, Revoke } from './invites'
import { addressOf, inviteRoles } from './invites-wire'
import type { InviteRole, Issued } from './invites-wire'
import { unknownWords } from './token-make'
import { When } from './token-rows'

export const formTitleId = 'invite-new-title'
const makeTipId = 'invite-make-tip'
const linkTitleId = 'invite-link-title'
const defaultRole: InviteRole = 'member'
/** The answers of a request about an invitation the page has words for (lib/auth/login_invite_routes.mli). */
const notFound = 404
const forbidden = 403

// ---- words ----

/** The name of a role, and what a person who joins with it can do. */
export function roleWords(role: InviteRole): readonly [string, string] {
  switch (role) {
    case 'member': return ['구성원', '자기 구독과 Keeper를 써요. 다른 사람을 들이지는 못해요.']
    case 'admin': return ['관리자', '구성원이 하는 일에 더해 다른 사람을 초대하고, 허용 목록에 계정을 넣고 빼요.']
  }
}

function makeWords(making: Make): string {
  switch (making.kind) {
    case 'sending': return '초대 링크를 만들고 있어요…'
    case 'issued': return '초대 링크를 만들었어요. 바로 아래에 한 번만 보여요.'
    case 'leaving': return sessionEndedWords
    case 'idle':
    case 'refused':
    case 'unknown':
      return ''
  }
}

/** The words of a refusal the page can say more of than that it was refused.
    A 403 comes of a session another tab replaced as well as of an account
    that is no longer an Admin, and its answer does not say which. */
function refusedWords(status: number, step: 'make' | 'revoke'): readonly string[] | null {
  if (status === forbidden) {
    return [
      '서버가 이 요청을 받지 않았어요.',
      '다른 탭에서 다시 로그인했다면 이 화면을 새로 고친 뒤 다시 해 주세요.',
      '그래도 안 되면 이 계정이 지금 관리자가 아닌 것이에요.',
    ]
  }
  if (status === notFound && step === 'revoke') return ['서버에서 이 초대를 찾지 못했어요. 목록을 다시 불러와요.']
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
      ? ['초대가 만들어졌을 수도 있지만, 그 링크는 다시 볼 수 없어요.', '열린 초대에 모르는 새 초대가 보이면 취소하고 다시 만들어 주세요.']
      : ['초대가 취소됐을 수도 있어요.', '이 초대의 상태를 보고, 아직 기다리는 중이면 다시 취소해 주세요.']
    return html`<${Callout} title=${title} attempts=${attempts} reason=${reason} lines=${[`${unknownWords(problem)} ${after[0]}`, after[1]]} />`
  }
  const words = refusedWords(outcome.problem.status, step)
  if (words === null) return html`<${ProblemNote} title=${title} failure=${{ problem: outcome.problem, attempts }} />`
  return html`<${Callout} title=${title} lines=${words} attempts=${attempts} reason=${reason} />`
}

// ---- a new link ----

/** The link just made, with a button that copies it. It is in a field, so
    it can also be picked and copied by hand. */
function LinkBox({ issued, onDone }: { readonly issued: Issued; readonly onDone: () => void }): VNode {
  const [copied, setCopied] = useState<'not_yet' | 'copied' | 'failed'>('not_yet')
  const address = addressOf(issued, location.origin)
  const copy = (): void => {
    // The clipboard is not there in a page served without TLS away from localhost.
    if (!('clipboard' in navigator)) {
      setCopied('failed')
      return
    }
    navigator.clipboard.writeText(address).then(() => { setCopied('copied') }, () => { setCopied('failed') })
  }
  const copiedWords = copied === 'copied' ? '복사했어요.' : copied === 'failed' ? '복사하지 못했어요. 칸의 글자를 골라 직접 복사해 주세요.' : ''
  return html`
    <div class="callout" aria-labelledby=${linkTitleId} role="group">
      <p id=${linkTitleId} class="callout-title">새 ${roleWords(issued.role)[0]} 초대 링크예요. 지금만 보여요</p>
      <p>이 화면을 떠나거나 「다 옮겼어요」를 누르면 다시 볼 수 없어요. 들어올 사람에게만 보내 주세요.</p>
      <p><${When} ms=${issued.expiresAtMs} />까지 한 사람이 한 번 쓸 수 있어요.</p>
      ${issued.role === 'admin' ? html`<p>이 링크로 들어온 사람은 관리자가 돼요.</p>` : null}
      <div class="field">
        <label for="invite-link">링크 <span class="mono">${idTail(issued.id)}</span></label>
        <textarea id="invite-link" readonly rows="3" spellcheck=${false} autocomplete="off" value=${address}
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

/** The form that makes a link. The role picked is kept here, so a form
    drawn again (a make refused, the list read again) still shows and sends
    what the Admin picked. */
export function MakeForm({ model }: { readonly model: InvitesModel }): VNode {
  const making = model.making.value
  const showing = making.kind === 'issued'
  const busy = making.kind === 'sending' || making.kind === 'leaving'
  const canMake = !busy && !showing
  const [role, setRole] = useState<InviteRole>(defaultRole)
  const onSubmit = (event: Event): void => {
    event.preventDefault()
    if (canMake) void model.make(role)
  }
  return html`
    <form class="keeper-form" aria-labelledby=${formTitleId} onSubmit=${onSubmit}>
      <h3 id=${formTitleId} tabindex="-1">새 초대 링크</h3>
      <fieldset>
        <legend>들어올 사람의 역할</legend>
        <ul class="choices">
          ${inviteRoles.map((one) => html`
            <li key=${one}>
              <label class="choice">
                <input type="radio" name="invite-role" value=${one} checked=${one === role} onChange=${() => { setRole(one) }} />
                <span><span class="choice-title">${roleWords(one)[0]}</span> <span class="hint">${roleWords(one)[1]}</span></span>
              </label>
            </li>
          `)}
        </ul>
      </fieldset>
      <p><button type="submit" class="primary" aria-disabled=${!canMake} aria-describedby=${makeTipId}>초대 링크 만들기</button></p>
      <p id=${makeTipId} class="hint">
        ${showing
          ? '아래 링크를 옮기고 「다 옮겼어요」를 누르면 또 만들 수 있어요.'
          : '링크는 만든 뒤 한 번만 보여요. 한 사람이 한 번 쓸 수 있고, 정해진 때가 지나면 만료돼요.'}
      </p>
    </form>
  `
}

/** What came of the latest make: a line a screen reader reads out, the
    alert of a make that came to nothing, and the link just made. It is
    drawn whatever the list shows, so a list that could not be read again
    does not take a link made off the page. `heading` names the heading of
    the panel, where the focus goes when the form is not on the page. */
export function MadeArea({ model, heading }: { readonly model: InvitesModel; readonly heading: string }): VNode {
  const making = model.making.value
  const showing = making.kind === 'issued'
  // The line under the heading says that the session ended, so this one does not say it again.
  const words = model.view.value.kind === 'leaving' ? '' : makeWords(making)
  // Saying the link was taken takes its box and buttons away. The focus
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
          title=${making.kind === 'refused' ? '초대 링크를 만들지 못했어요' : '초대 링크를 만들었는지 알 수 없어요'} />`
      : null}
    ${making.kind === 'issued' ? html`<${LinkBox} issued=${making.issued} onDone=${model.forget} />` : null}
  `
}
