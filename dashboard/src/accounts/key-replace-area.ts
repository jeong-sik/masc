// The part of the card of a key account where the person gives another key
// for the account: what `createReplacements` (key-replace.ts) holds of the
// account, in words, and what the person reads before they give the key.
//
// The key is in a field of the card until the server took it or may have
// taken it, and in the body of the one request. It is drawn nowhere else.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import type { ReplaceFailure, ReplacementStopped, ReplacementsModel, Replacing } from './key-replace'
import { Callout, ProblemNote, fell, keyGivenWords, notAKeyWords, operatorWords, sessionEndedWords } from './notes'

// ---- words ----

/** What replacing a key does not do: the server stops using its copy of the
    key before, and the vendor still takes that key (RFC of the key
    accounts, 3.8). */
const oldKeyStaysValidWords = '예전 key 는 발급한 곳에서 계속 유효해요. 못 쓰게 하려면 그곳에서 폐기해 주세요.'

/** What a person reads before they give another key for an account. */
const notes = [
  ...keyGivenWords,
  `바꾸면 이 서버는 예전 key 를 더 쓰지 않고 그 파일을 지워요. ${oldKeyStaysValidWords}`,
  '이 계정으로 확인한 모델은 그대로 남아요.',
] as const

/** Why the server did not replace the key of an account, and what the
    person does next. A refusal with no code of the route is said in the
    words every part of the console shares (notes.ts, `ProblemNote`). */
function refusedWords(code: Exclude<ReplacementStopped, 'unrecognised'>): string {
  switch (code) {
    case 'not_a_key': return notAKeyWords
    case 'invalid_request': return '서버가 이 요청을 읽지 못했어요. key 는 바뀌지 않았어요.'
    case 'account_call_running': return '이 계정으로 호출이 돌고 있어요. key 는 바뀌지 않았어요. 끝난 뒤 다시 보내 주세요.'
    case 'removal_left': return '없애기가 끝나지 않은 계정이라 key 를 바꿀 수 없어요. 이 계정을 먼저 없애 주세요.'
    case 'replacement_refused': return '내 계정이 지금 쓸 수 있는 상태가 아니라서 key 를 받지 않았어요. key 는 바뀌지 않았어요.'
    case 'internal_error': return '서버가 예상하지 못한 까닭으로 거절했어요. key 는 바뀌지 않았어요.'
    case 'files_not_reached': return `서버가 이 계정의 폴더를 쓰지 못해서 key 를 받지 않았어요. key 는 바뀌지 않았어요. 다시 보내도 답이 같으면 ${operatorWords}`
    case 'replacement_not_recorded': return '서버가 바꾸기를 기록하지 못했어요. 서버에 있는 key 는 그대로예요. key 를 다시 보내 주세요.'
    case 'key_not_stored':
      return '서버가 바꾸기를 기록했고, 새 key 파일은 놓지 못했어요. 예전 key 는 더 쓰이지 않아요. key 를 다시 보내 주세요.'
    case 'not_a_key_account': return '로그인으로 연결한 계정이라 key 를 바꿀 수 없어요.'
  }
}

/** What the page heard of a key it has no word of the server on. */
function unheardWords(answer: Extract<ReplaceFailure, { kind: 'unknown' }>['answer']): string {
  switch (answer) {
    case 'none': return '서버의 답을 받지 못했어요. 서버가 key 를 바꿨을 수도 있어요.'
    case 'unreadable': return '서버의 답을 읽지 못했어요. 서버가 key 를 바꿨을 수도 있어요.'
    case 'server_failed': return '서버 쪽이 오류로 답했고, 바꾸지 않았다고는 말하지 않았어요. 서버가 key 를 바꿨을 수도 있어요.'
  }
}

/** The alert of a replacement that came to nothing. A caller keys it by the
    count of attempts, so a second failure is announced as the first was. */
function FailureNote({ failure }: { readonly failure: ReplaceFailure }): VNode {
  switch (failure.kind) {
    case 'refused':
      if (failure.code === 'unrecognised') {
        return html`<${ProblemNote} title="key 를 바꾸지 못했어요" failure=${{ problem: { kind: 'refused', status: failure.status, reason: failure.reason }, attempts: failure.attempts }} />`
      }
      return html`<${Callout} title="key 를 바꾸지 못했어요" lines=${[refusedWords(failure.code)]} reason=${failure.reason} attempts=${failure.attempts} />`
    case 'unknown':
      return html`<${Callout} title="key 가 바뀌었는지 알 수 없어요" reason=${null} attempts=${failure.attempts}
        lines=${[
          unheardWords(failure.answer),
          '이 화면에서는 key 가 바뀌었는지 볼 수 없어요. 확실히 하려면 key 를 다시 넣어 보내 주세요. 같은 key 를 다시 보내도 계정은 그대로 하나예요.',
        ]} />`
  }
}

/** The line a screen reader reads out for each step. It is on the card in every step. */
function statusWords(replacing: Replacing | undefined): string {
  switch (replacing?.kind) {
    case undefined:
    case 'open':
      return ''
    case 'sending': return 'key 를 보내고 있어요…'
    case 'replaced':
      return replacing.oldKeysRemoved
        ? `key 를 바꿨어요. 예전 key 파일은 이 서버에서 지웠어요. ${oldKeyStaysValidWords}`
        : `key 를 바꿨어요. 예전 key 파일이 이 서버에 아직 남아 있어요. 서버가 다시 시작할 때나 다음에 key 를 바꿀 때 지워요. ${oldKeyStaysValidWords}`
    // On the page only when the list that was read again still has the account.
    case 'gone': return '서버에 이 계정이 없어요.'
    case 'leaving': return sessionEndedWords
  }
}

// ---- the field ----

/** The button that opens the field of a key for an account, the field, and
    what came of the latest replacement. The button is the same one before
    and after a replacement, so the focus of the person who pressed it has a
    place to come back to. The form stays the same form while a key is on
    its way. The field of the key has no name, and the form posts: a
    submission the page does not handle carries no key, and nothing of it is
    in an address. Every control is named with the card, so a list of the
    controls of the page tells the cards apart. */
export function ReplaceArea({ accountId, replacements, card, again }: {
  readonly accountId: string
  readonly replacements: ReplacementsModel
  /** The ids of what names the card: its title and its account line. */
  readonly card: string
  /** A replacement was left on the account: a key that is sent ends it. */
  readonly again: boolean
}): VNode {
  const replacing = replacements.replacing.value.get(accountId)
  const toggle = useRef<HTMLButtonElement>(null)
  const field = useRef<HTMLInputElement>(null)
  const open = replacing?.kind === 'open' || replacing?.kind === 'sending'
  const sending = replacing?.kind === 'sending'
  const held = sending || replacing?.kind === 'leaving'
  const wasOpen = useRef(open)
  // Opening the field puts the focus in it. A step that takes the field
  // away, with the control that was pressed in it, puts the focus back on
  // the button that opened it, never on the body of the page; a focus the
  // person moved elsewhere meanwhile stays.
  useEffect(() => {
    const before = wasOpen.current
    wasOpen.current = open
    if (before === open) return
    if (open) field.current?.focus()
    else if (fell()) toggle.current?.focus()
  }, [open])
  const press = (): void => {
    if (held) return
    if (open) replacements.close(accountId)
    else replacements.open(accountId)
  }
  const onSubmit = (event: Event): void => {
    event.preventDefault()
    const input = field.current
    if (sending || input === null || input.value === '') return
    const key = input.value
    // The key stays in the field until the server took it or may have.
    void replacements.replace(accountId, key).then((kept) => { if (kept === 'dropped') input.value = '' })
  }
  const id = `replace-${accountId}`
  const steps = `replace-steps-${accountId}`
  const label = `replace-label-${accountId}`
  const input = `replace-key-${accountId}`
  const noteList = `replace-notes-${accountId}`
  const send = `replace-send-${accountId}`
  const closeId = `replace-close-${accountId}`
  const failure = open ? replacing.failure : null
  return html`
    <p class="actions">
      <button ref=${toggle} id=${id} type="button" aria-expanded=${open} aria-controls=${steps} aria-disabled=${held}
        aria-labelledby=${`${id} ${card}`} onClick=${press}>${again ? 'key 다시 보내기' : 'key 바꾸기'}</button>
    </p>
    <div id=${steps}>
      ${open
        ? html`
          <form class="connect-form" method="post" onSubmit=${onSubmit}>
            <div class="field">
              <label id=${label} for=${input}>새 API key</label>
              <input ref=${field} id=${input} type="password" required autocomplete="off" spellcheck=${false}
                readonly=${sending} aria-labelledby=${`${label} ${card}`} aria-describedby=${noteList} />
              <ul id=${noteList} class="hint">
                ${notes.map((note) => html`<li key=${note}>${note}</li>`)}
              </ul>
            </div>
            <p class="actions">
              <button id=${send} type="submit" class="primary" aria-disabled=${sending} aria-labelledby=${`${send} ${card}`}>새 key 저장</button>
              <button id=${closeId} type="button" aria-disabled=${sending} aria-labelledby=${`${closeId} ${card}`}
                onClick=${() => { replacements.close(accountId) }}>닫기</button>
            </p>
          </form>
        `
        : null}
      <p class="hint" role="status">${statusWords(replacing)}</p>
      ${failure === null ? null : html`<${FailureNote} key=${failure.attempts} failure=${failure} />`}
    </div>
  `
}
