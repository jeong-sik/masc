// The area of the subscriptions panel where a person connects a
// subscription with an API key: the form `createKeyAdds` (key-add.ts) is
// at, in words, and what the person reads before they give a key.
//
// The key is in a field of the form until the server took it or may have
// taken it, and in the body of the one request. It is drawn nowhere else.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import type { AddFailure, AddRefusal, AddView, KeyAddModel } from './key-add'
import { Callout, ProblemNote, fell, idTail, keyGivenWords, keyStaysValidWords, notAKeyWords, sessionEndedWords } from './notes'
import { integrationName } from './wire'
import type { Integration } from './wire'

// ---- words ----

/** What a person reads before they give a key for a new account (RFC, 3.8). */
const notes = [...keyGivenWords, keyStaysValidWords] as const

/** Why the server did not store a key, and what the person does next.
    `accountId` is the account the server left behind, if it left one. A
    refusal with no code of the route is said in the words every part of the
    console shares (notes.ts, `ProblemNote`). */
function refusedWords(code: Exclude<AddRefusal, 'unrecognised'>, accountId: string | null): string {
  switch (code) {
    case 'not_a_key': return notAKeyWords
    case 'invalid_request': return '서버가 이 요청을 읽지 못했어요. 저장된 것은 없어요.'
    case 'unknown_integration': return '서버에 이 구독이 없어요. 저장된 것은 없어요. 구독 목록을 다시 읽었어요.'
    case 'integration_takes_no_key': return '이 구독은 API key 를 받지 않아요. 저장된 것은 없어요. 구독 목록을 다시 읽었어요.'
    case 'registration_refused': return '내 계정이 지금 쓸 수 있는 상태가 아니라서 key 를 받지 않았어요. 저장된 것은 없어요.'
    case 'internal_error': return '서버가 예상하지 못한 까닭으로 거절했어요. 저장된 것은 없어요.'
    case 'configuration_unavailable': return '서버가 구독 설정을 읽지 못했어요. 저장된 것은 없어요. 잠시 뒤 다시 보내 주세요.'
    case 'registration_not_recorded': return '서버가 계정을 기록하지 못했어요. 저장된 것은 없어요. 다시 보내 주세요.'
    case 'key_not_stored': return '서버가 key 파일을 만들지 못했어요. 만들던 계정은 서버가 없앴고 key 는 남지 않았어요. 다시 보내 주세요.'
    case 'account_not_removed':
      return accountId === null
        ? '서버가 key 파일을 만들지 못했고, 만들던 계정도 다 없애지 못했어요. 아래 목록에서 그 계정을 없앤 뒤 다시 보내 주세요.'
        : `서버가 key 파일을 만들지 못했고, 만들던 계정도 다 없애지 못했어요. 아래 목록에서 계정 ${idTail(accountId)}을 없앤 뒤 다시 보내 주세요.`
  }
}

/** What the page heard of a key it has no word of the server on. */
function unheardWords(answer: Extract<AddFailure, { kind: 'unknown' }>['answer']): string {
  switch (answer) {
    case 'none': return '서버의 답을 받지 못했어요. 서버가 key 를 저장했을 수도 있어요.'
    case 'unreadable': return '서버의 답을 읽지 못했어요. 서버가 key 를 저장했을 수도 있어요.'
    case 'server_failed': return '서버 쪽이 오류로 답했고, 저장하지 않았다고는 말하지 않았어요. 서버가 key 를 저장했을 수도 있어요.'
  }
}

/** The alert of an add that came to nothing. A caller keys it by the count
    of attempts, so a second failure is announced as the first was. */
function FailureNote({ failure }: { readonly failure: AddFailure }): VNode {
  switch (failure.kind) {
    case 'refused':
      if (failure.code === 'unrecognised') {
        return html`<${ProblemNote} title="key 를 저장하지 못했어요" failure=${{ problem: { kind: 'refused', status: failure.status, reason: failure.reason }, attempts: failure.attempts }} />`
      }
      return html`<${Callout} title="key 를 저장하지 못했어요" lines=${[refusedWords(failure.code, failure.accountId)]}
        reason=${failure.reason} attempts=${failure.attempts} />`
    case 'unknown':
      return html`<${Callout} title="key 가 저장됐는지 알 수 없어요" reason=${null} attempts=${failure.attempts}
        lines=${[
          unheardWords(failure.answer),
          '아래 목록에 「API key 로 연결」 계정이 새로 생겼는지 봐 주세요. 생겼으면 다시 보내지 마세요. 같은 key 를 다시 보내면 계정이 하나 더 생겨요.',
          '새 계정이 없으면 key 를 다시 넣어 주세요.',
        ]} />`
  }
}

/** The line a screen reader reads out for each step. It is on the page in every step. */
function statusWords(view: AddView): string {
  switch (view.kind) {
    case 'closed':
      return view.stored === null ? '' : `key 를 저장했어요. 계정 ${idTail(view.stored)}이 생겼어요. 그 계정의 카드에서 모델을 확인해 주세요.`
    case 'open': return ''
    case 'sending': return 'key 를 보내고 있어요…'
    case 'leaving': return sessionEndedWords
  }
}

// ---- the form ----

interface AreaProps {
  readonly model: KeyAddModel
  /** The subscriptions that take a key. */
  readonly integrations: readonly Integration[]
}

/** The form stays the same form while a key is on its way, so what the
    person typed and the button they pressed stay where they are. The field
    of the key has no name, and the form posts: a submission the page does
    not handle carries no key, and nothing of it is in an address. */
function Form({ model, integrations, view }: AreaProps & { readonly view: Extract<AddView, { kind: 'open' | 'sending' }> }): VNode {
  const field = useRef<HTMLInputElement>(null)
  // The one subscription there is when the form opens is picked for the
  // person. A list that changes under the open form picks nothing: the
  // person chose among what they saw, and a subscription they did not choose
  // gets no key.
  const only = useRef(integrations.length === 1 ? integrations[0]?.id ?? null : null).current
  const sending = view.kind === 'sending'
  const onSubmit = (event: Event): void => {
    event.preventDefault()
    const picked = new FormData(event.currentTarget as HTMLFormElement).get('integration')
    const input = field.current
    if (sending || typeof picked !== 'string' || input === null || input.value === '') return
    const key = input.value
    // The key stays in the field until the server took it or may have.
    void model.add(picked, key).then((kept) => { if (kept === 'dropped' && input.value === key) input.value = '' })
  }
  const failure = view.failure === null ? null : html`<${FailureNote} key=${view.failure.attempts} failure=${view.failure} />`
  // No subscription takes a key any more: there is nothing to give one to,
  // and no field to hold one. What came of the key given before stays.
  if (integrations.length === 0) {
    return html`
      <p class="hint">지금 이 서버에는 API key 를 받는 구독이 없어요.</p>
      <p class="actions"><button type="button" aria-disabled=${sending} onClick=${model.close}>닫기</button></p>
      ${failure}
    `
  }
  return html`
    <form class="connect-form" method="post" onSubmit=${onSubmit}>
      <fieldset>
        <legend>key 를 넣을 구독</legend>
        <ul class="choices">
          ${integrations.map((integration) => html`
            <li key=${integration.id}>
              <label class="choice">
                <input type="radio" name="integration" value=${integration.id} required defaultChecked=${integration.id === only} />
                <span class="choice-title">${integrationName(integration)}</span>
              </label>
            </li>
          `)}
        </ul>
      </fieldset>
      <div class="field">
        <label for="key-value">API key</label>
        <input ref=${field} id="key-value" type="password" required autocomplete="off" spellcheck=${false}
          readonly=${sending} aria-describedby="key-notes" />
        <ul id="key-notes" class="hint">
          ${notes.map((note) => html`<li key=${note}>${note}</li>`)}
        </ul>
      </div>
      <p class="actions">
        <button type="submit" class="primary" aria-disabled=${sending}>key 저장</button>
        <button type="button" aria-disabled=${sending} onClick=${model.close}>닫기</button>
      </p>
    </form>
    ${failure}
  `
}

export function KeyArea(props: AreaProps): VNode {
  const view = props.model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const toggle = useRef<HTMLButtonElement>(null)
  const none = props.integrations.length === 0
  const before = useRef({ kind: view.kind, none })
  // A step that takes the pressed control away moves the focus to the
  // heading of the form, or to the button that opens it once it closed,
  // never to the body of the page. So does the last subscription that took
  // a key leaving the list, which takes the field and its button away. A
  // focus the person moved elsewhere meanwhile stays.
  useEffect(() => {
    const from = before.current
    before.current = { kind: view.kind, none }
    if ((from.kind === view.kind && from.none === none) || !fell()) return
    if (view.kind === 'closed') toggle.current?.focus()
    else heading.current?.focus()
  }, [view.kind, none])
  const open = view.kind !== 'closed'
  const closable = view.kind === 'open'
  return html`
    <div class="connect">
      <p>
        <button ref=${toggle} type="button" aria-expanded=${open} aria-controls="key-steps"
          aria-disabled=${open && !closable} onClick=${open ? props.model.close : props.model.open}>API key 로 연결하기</button>
      </p>
      <div id="key-steps" class="connect-steps">
        ${open ? html`<h3 ref=${heading} tabindex="-1">API key 로 연결</h3>` : null}
        <p role="status">${statusWords(view)}</p>
        ${view.kind === 'open' || view.kind === 'sending' ? html`<${Form} ...${props} view=${view} />` : null}
      </div>
    </div>
  `
}
