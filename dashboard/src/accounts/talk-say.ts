// The part of an open conversation where the person writes to the Keeper:
// the field of a message, the button that sends it, the button that starts
// a new conversation, and what the latest of them came to (talk.ts, `Act`).
// One conversation is open at a time, so its ids are fixed.

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import { Callout, ProblemNote, sessionEndedWords } from './notes'
import type { Act, Step, TalkModel, TalkView } from './talk'
import { messageLimitBytes } from './talk-wire'
import type { TalkRefusal, TalkShown, Unsendable } from './talk-wire'

const fieldId = 'talk-message'
const fieldTipId = 'talk-message-tip'
const sendId = 'talk-send'
const startId = 'talk-start'
const startTipId = 'talk-start-tip'
/** The bytes of UTF-8 a Hangul syllable takes. */
const hangulBytes = 3

// ---- words ----

/** What a refused message or start means, by the code of the route, and
    whether the server had taken the message in when the refusal came: it
    writes the message in the conversation, then starts the Keeper with it
    (lib/server/server_preview_keeper_turn.ml, `call_claude`). */
interface Refusal {
  readonly words: string
  readonly sent: boolean
}

const before = (words: string): Refusal => ({ words, sent: false })
const after = (words: string): Refusal => ({ words, sent: true })

/** Null when the shared words of notes.ts say as much. */
export function refusalOf(code: TalkRefusal): Refusal | null {
  switch (code) {
    case 'message_too_long': return before(`말이 ${messageLimitBytes}바이트를 넘어요. 줄여서 보내 주세요.`)
    case 'message_blank': return before('보낼 말을 적어 주세요.')
    case 'runtime_not_supported': return before('이 Keeper의 모델로는 여기서 대화할 수 없어요. 카드에서 다른 모델을 골라 주세요.')
    case 'account_runtime_invalid': return before('서버가 이 모델의 설정을 읽지 못했어요. 이 서버를 운영하는 사람에게 알려 주세요.')
    case 'turn_refused': return before('서버가 이 Keeper의 대화를 허락하지 않았어요.')
    case 'native_tools_refused': return before('이 구독으로는 지금 Keeper가 일할 수 없어요. 카드에서 다른 모델을 골라 주세요.')
    case 'unknown_keeper': return before('서버에 이 Keeper가 없어요. 페이지를 새로 고쳐 주세요.')
    case 'unknown_account': return before('이 모델의 구독 계정을 서버에서 찾지 못했어요. 페이지를 새로 고쳐 주세요.')
    case 'keeper_has_no_runtime': return before('이 Keeper는 쓸 모델이 아직 없어요. 카드에서 모델을 먼저 정해 주세요.')
    case 'account_call_running': return before('이 구독 계정으로 다른 호출이 돌고 있어요. 끝나면 다시 해 주세요.')
    case 'conversation_on_other_subscription': return before('지금 대화는 다른 구독에서 시작했어요. 새 대화를 시작하면 보낼 수 있어요.')
    case 'runtime_reassigned': return before('보내는 사이에 이 Keeper의 모델이 바뀌었어요. 다시 보내 주세요.')
    case 'not_signed_in': return after('이 모델의 구독 계정이 로그인돼 있지 않아요. 위 구독 카드에서 다시 연결해 주세요.')
    case 'no_quota': return after('구독에 남은 사용량이 없어요. 사용량이 돌아온 뒤 다시 보내 주세요.')
    case 'silent': return after('Keeper가 한동안 아무것도 보내지 않아서 멈췄어요. 다시 보내 주세요.')
    case 'not_started': return after('Keeper를 시작하지 못했어요. 잠시 뒤 다시 보내 주세요.')
    case 'configuration_refused': return after('Keeper가 이 모델의 설정을 받아들이지 않았어요. 이 서버를 운영하는 사람에게 알려 주세요.')
    case 'no_answer': return after('Keeper가 답을 남기지 않고 끝냈어요. 계속 이러면 새 대화를 시작해 주세요.')
    case 'answer_unrecorded': return after('Keeper가 답했지만 서버가 그 답을 기록하지 못했어요. 그 답은 대화에 남지 않아요.')
    case 'conversation_record_unavailable': return before('서버가 대화 기록을 지금 읽거나 쓰지 못했어요. 잠시 뒤 다시 해 주세요.')
    case 'conversation_row_not_understood': return before('대화 기록에 서버가 읽지 못하는 줄이 있어요. 이 서버를 운영하는 사람에게 알려 주세요.')
    case 'conversation_row_half_written': return before('서버가 멈추면서 대화 기록의 마지막 줄을 다 쓰지 못했어요. 새 대화를 시작하면 정리돼요.')
    case 'invalid_request':
    case 'unknown_conversation':
    case 'server_unavailable':
    case 'internal_error':
    case 'unrecognised':
      return null
  }
}

/** What the page heard of a request whose end it does not know. */
function unheardWords(problem: TalkShown): string {
  switch (problem.kind) {
    case 'unreachable': return '답이 오기 전에 연결이 끊겼어요.'
    case 'unreadable': return '서버가 보낸 답을 읽지 못했어요.'
    case 'refused': return '서버가 이유를 알 수 없는 오류로 답했어요.'
  }
}

function notSentWords(why: Unsendable): readonly [string, string] {
  switch (why) {
    case 'blank': return ['보낼 말을 적어 주세요', '빈칸과 줄바꿈만으로는 보낼 수 없어요.']
    case 'too_long': return ['말이 너무 길어요', `${messageLimitBytes}바이트까지 보낼 수 있어요. 줄여서 보내 주세요.`]
  }
}

/** The title of a request that came to nothing: `sent` once the message was written, `known` unless the page does not know what the server did. */
function titleOf(step: Step, known: boolean, sent: boolean): string {
  switch (step) {
    case 'say': return !known ? '보냈는지 알 수 없어요' : sent ? '보냈지만 답을 받지 못했어요' : '보내지 못했어요'
    case 'start': return known ? '새 대화를 시작하지 못했어요' : '새 대화를 시작했는지 알 수 없어요'
  }
}

function actWords(act: Act): string {
  switch (act.kind) {
    case 'sending': return 'Keeper에게 보내고 답을 기다리고 있어요…'
    case 'starting': return '새 대화를 시작하고 있어요…'
    case 'answered':
      return act.answer.recorded ? 'Keeper가 답했어요.' : 'Keeper가 답했어요. 이 답은 대화 기록에 남지 않아서 여기에만 보여요.'
    case 'started': return '새 대화를 시작했어요.'
    case 'leaving': return sessionEndedWords
    case 'idle':
    case 'not_sent':
    case 'refused':
    case 'unknown':
      return ''
  }
}

/** A request that came to nothing. */
type Failed = Extract<Act, { kind: 'not_sent' | 'refused' | 'unknown' }>

const failed = (act: Act): act is Failed => act.kind === 'not_sent' || act.kind === 'refused' || act.kind === 'unknown'

/** The alert of a request that came to nothing. `read` is whether the
    conversation read again after it is on the page. */
function ActNote({ act, read }: { readonly act: Failed; readonly read: boolean }): VNode {
  switch (act.kind) {
    case 'not_sent': {
      const [title, line] = notSentWords(act.why)
      return html`<${Callout} title=${title} lines=${[line]} reason=${null} attempts=${act.attempts} />`
    }
    case 'refused': {
      const refusal = refusalOf(act.problem.code)
      const title = titleOf(act.step, true, refusal?.sent ?? false)
      if (refusal === null) return html`<${ProblemNote} title=${title} failure=${{ problem: act.problem, attempts: act.attempts }} />`
      return html`<${Callout} title=${title} lines=${[refusal.words]} reason=${act.problem.reason} attempts=${act.attempts} />`
    }
    case 'unknown': {
      const [may, look] = act.step === 'say'
        ? ['말이 Keeper에게 갔을 수도 있어요.', '보낸 말이 위 대화에 없으면 다시 보내 주세요.']
        : ['새 대화가 시작됐을 수도 있어요.', '위 대화가 새 대화인지 보고, 아니면 다시 해 주세요.']
      const next = read ? `대화를 다시 불러왔어요. ${look}` : '대화를 다시 불러온 뒤에 확인해 주세요.'
      return html`<${Callout} title=${titleOf(act.step, false, false)} reason=${act.problem.kind === 'refused' ? act.problem.reason : null}
        attempts=${act.attempts} lines=${[`${unheardWords(act.problem)} ${may}`, next]} />`
    }
  }
}

// ---- the form ----

/** The form under the conversation of `view`, which is open. A message
    goes once the conversation is read; a new conversation can start as
    soon as it is open, since that is the way past a record that cannot be
    read. Each says so before it is pressed. */
export function SayPart({ talk, view, card }: {
  readonly talk: TalkModel
  readonly view: Exclude<TalkView, { kind: 'closed' }>
  /** The id of the title of the card, which names the buttons with it. */
  readonly card: string
}): VNode {
  const act = talk.act.value
  const field = useRef<HTMLTextAreaElement>(null)
  const busy = act.kind === 'sending' || act.kind === 'starting' || act.kind === 'leaving' || view.kind === 'leaving'
  const canSay = view.kind === 'read' && !busy
  const canStart = (view.kind === 'read' || view.kind === 'failed') && !busy
  // The field is emptied only once the Keeper answered; a message refused,
  // or whose end is not known, stays to be sent again.
  const onSubmit = async (event: Event): Promise<void> => {
    event.preventDefault()
    const form = event.currentTarget as HTMLFormElement
    const typed = new FormData(form).get('message')
    if (!canSay || typeof typed !== 'string') return
    const outcome = await talk.say(typed)
    if (outcome?.kind === 'answered') form.reset()
    if (outcome?.kind === 'not_sent') field.current?.focus()
  }
  // Ctrl+Enter (⌘+Enter on a Mac) sends; Enter alone starts a new line, and
  // an Enter that ends the composing of a Hangul syllable is left to it.
  const onKeyDown = (event: KeyboardEvent): void => {
    if (event.key !== 'Enter' || !(event.ctrlKey || event.metaKey) || event.isComposing) return
    event.preventDefault()
    field.current?.form?.requestSubmit()
  }
  return html`
    ${act.kind === 'sending'
      ? html`
          <div class="turn-part turn-said">
            <p class="turn-head">보내는 말</p>
            <p class="turn-text">${act.message}</p>
          </div>
        `
      : null}
    ${act.kind === 'answered' && !act.answer.recorded
      ? html`
          <div class="turn-part">
            <p class="turn-head">Keeper의 답 · <span class="mono">${act.answer.model}</span></p>
            <p class="turn-text">${act.answer.text}</p>
          </div>
        `
      : null}
    <form class="field" aria-label="Keeper에게 말 보내기" onSubmit=${(event: Event) => { void onSubmit(event) }}>
      <label for=${fieldId}>보낼 말</label>
      <textarea ref=${field} id=${fieldId} name="message" rows="3" readonly=${busy} aria-describedby=${fieldTipId} onKeyDown=${onKeyDown}></textarea>
      <p id=${fieldTipId} class="hint">
        ${view.kind === 'read'
          ? `${messageLimitBytes}바이트까지 보낼 수 있어요(한글만 쓰면 ${Math.floor(messageLimitBytes / hangulBytes)}자). Ctrl+Enter로도 보내요.`
          : '대화를 불러온 뒤에 보낼 수 있어요.'}
      </p>
      <p class="actions">
        <button id=${sendId} type="submit" class="primary" aria-disabled=${!canSay} aria-labelledby=${`${sendId} ${card}`}>보내기</button>
        <button id=${startId} type="button" aria-disabled=${!canStart} aria-labelledby=${`${startId} ${card}`} aria-describedby=${startTipId}
          onClick=${() => { if (canStart) void talk.start() }}>새 대화 시작</button>
      </p>
      <p id=${startTipId} class="hint">새 대화에서 Keeper는 지금 대화를 이어 기억하지 않아요. 지금 대화는 기록에 남아요.</p>
    </form>
    <p class="hint" role="status">${actWords(act)}</p>
    ${failed(act) ? html`<${ActNote} key=${act.attempts} act=${act} read=${view.kind === 'read'} />` : null}
  `
}
