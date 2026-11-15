// The conversation of a Keeper in its card: the button that opens and closes
// it, and under it what the person said and what the Keeper answered, as the
// server recorded it. One conversation is open at a time (talk.ts).

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import { Callout, ProblemNote, fell, sessionEndedWords } from './notes'
import type { Next } from './notes'
import type { TalkFailure, TalkModel, TalkView } from './talk'
import { SayPart } from './talk-say'
import type { Conversation, Outcome, TalkRefusal, Turn, TurnFailure } from './talk-wire'

const clock = new Intl.DateTimeFormat('ko-KR', { dateStyle: 'medium', timeStyle: 'short' })

function When({ ms }: { readonly ms: number }): VNode {
  const at = new Date(ms)
  return html`<time datetime=${at.toISOString()}>${clock.format(at)}</time>`
}

// ---- words ----

const mayHaveReadWords = 'Keeper는 이 말을 읽었을 수 있어요. 다음 말에서 이 말을 아는 듯 답할 수 있어요.'

function failureWords(failure: TurnFailure): string {
  switch (failure) {
    case 'not_signed_in': return '이 모델의 구독 계정이 로그인돼 있지 않았어요.'
    case 'no_quota': return '구독에 남은 사용량이 없었어요.'
    case 'silent': return 'Keeper가 한동안 아무것도 보내지 않아서 멈췄어요.'
    case 'not_started': return 'Keeper를 시작하지 못했어요.'
    case 'configuration_refused': return 'Keeper가 이 모델의 설정을 받아들이지 않았어요.'
    case 'no_answer': return 'Keeper가 답을 남기지 않고 끝냈어요.'
    case 'unrecognised': return '이 화면이 모르는 이유로 답하지 못했어요.'
  }
}

/** What a refused reading of a conversation means, when the page can say
    more than that it was refused. The other codes come of a turn, or of a
    conversation named by its id, which this reading does not do. */
function refusalWords(code: TalkRefusal): string | null {
  switch (code) {
    case 'unknown_keeper': return '서버에 이 Keeper가 없어요. 페이지를 새로 고쳐 주세요.'
    case 'conversation_record_unavailable': return '서버가 대화 기록을 지금 읽지 못했어요. 잠시 뒤 다시 해 주세요.'
    case 'conversation_row_not_understood': return '대화 기록에 서버가 읽지 못하는 줄이 있어요. 이 서버를 운영하는 사람에게 알려 주세요.'
    case 'conversation_row_half_written':
      return '서버가 멈추면서 대화 기록의 마지막 줄을 다 쓰지 못했어요. 아래에서 새 대화를 시작하면 정리돼요.'
    case 'invalid_request':
    case 'message_too_long':
    case 'message_blank':
    case 'runtime_not_supported':
    case 'account_runtime_invalid':
    case 'turn_refused':
    case 'native_tools_refused':
    case 'unknown_conversation':
    case 'unknown_account':
    case 'keeper_has_no_runtime':
    case 'account_call_running':
    case 'conversation_on_other_subscription':
    case 'runtime_reassigned':
    case 'not_signed_in':
    case 'no_quota':
    case 'silent':
    case 'not_started':
    case 'configuration_refused':
    case 'no_answer':
    case 'answer_unrecorded':
    case 'server_unavailable':
    case 'internal_error':
    case 'unrecognised':
      return null
  }
}

const failedTitle = '대화를 불러오지 못했어요'

/** The alert of a reading that failed. The caller makes each one anew (its
    key is the count), so a screen reader says the second as it said the first. */
function ReadNote({ failure }: { readonly failure: TalkFailure }): VNode {
  const { problem, attempts } = failure
  const words = problem.kind === 'refused' ? refusalWords(problem.code) : null
  if (problem.kind !== 'refused' || words === null) return html`<${ProblemNote} title=${failedTitle} failure=${failure} />`
  return html`<${Callout} title=${failedTitle} lines=${[words]} reason=${problem.reason} attempts=${attempts} />`
}

/** What the line says under a reading that failed, as its retry goes. */
function againWords(next: Next): string {
  switch (next) {
    case 'idle': return ''
    case 'reading': return '대화를 다시 불러오고 있어요…'
    case 'leaving': return sessionEndedWords
  }
}

/** What the line a screen reader reads out in the conversation of a card says. */
function statusWords(view: TalkView): string {
  switch (view.kind) {
    case 'reading': return view.slow ? '대화를 불러오고 있어요…' : ''
    case 'leaving': return sessionEndedWords
    case 'read':
      return view.conversation.turns.length === 0 ? '아직 나눈 말이 없어요.' : `주고받은 말 ${view.conversation.turns.length}개를 불러왔어요.`
    case 'failed': return againWords(view.next)
    case 'closed': return ''
  }
}

// ---- a conversation ----

function OutcomeOf({ outcome }: { readonly outcome: Outcome }): VNode {
  switch (outcome.kind) {
    case 'answered':
      return html`
        <div class="turn-part">
          <p class="turn-head">Keeper의 답 · <span class="mono">${outcome.model}</span> · <${When} ms=${outcome.atMs} /></p>
          <p class="turn-text">${outcome.text}</p>
        </div>
      `
    case 'failed':
      return html`
        <div class="turn-part turn-missed">
          <p class="turn-head">답하지 못했어요 · <${When} ms=${outcome.atMs} /></p>
          <p>${failureWords(outcome.failure)}</p>
          ${outcome.modelMayHaveRead ? html`<p class="hint">${mayHaveReadWords}</p>` : null}
        </div>
      `
    case 'unrecorded':
      return html`
        <div class="turn-part turn-missed">
          <p class="turn-head">어떻게 끝났는지 기록되지 않았어요</p>
          <p>서버가 이 말을 처리하다가 멈췄어요.</p>
          ${outcome.modelMayHaveRead ? html`<p class="hint">${mayHaveReadWords}</p>` : null}
        </div>
      `
  }
}

function TurnItem({ turn }: { readonly turn: Turn }): VNode {
  return html`
    <li class="turn">
      <div class="turn-part turn-said">
        <p class="turn-head">내가 보낸 말 · <${When} ms=${turn.askedAtMs} /></p>
        <p class="turn-text">${turn.message}</p>
      </div>
      <${OutcomeOf} outcome=${turn.outcome} />
    </li>
  `
}

function Read({ conversation, said }: { readonly conversation: Conversation; readonly said: string }): VNode {
  return html`
    ${conversation.earlier > 0 ? html`<p class="hint">이전 대화 ${conversation.earlier}개는 아직 여기서 볼 수 없어요.</p>` : null}
    ${conversation.turns.length === 0
      ? null
      : html`<ol class="turns" aria-labelledby=${said}>${conversation.turns.map((turn, at) => html`<${TurnItem} key=${at} turn=${turn} />`)}</ol>`}
  `
}

/** The button of a card that opens the conversation of its Keeper, and the
    place under it where the conversation goes. The place and its line for a
    screen reader are on the page whether it is open or not, and the line is
    the same element in every state, so what fills it is read out, and the
    button always names a place that is there. */
export function TalkPart({ keeperId, card, talk }: { readonly keeperId: string; readonly card: string; readonly talk: TalkModel }): VNode {
  const now = talk.view.value
  const view: TalkView = now.kind !== 'closed' && now.keeperId === keeperId ? now : { kind: 'closed' }
  const open = view.kind !== 'closed'
  // No prefix of an id here is the start of another, nor of an id of the
  // card (keeper-rows.ts), so two Keeper names never make one id.
  const button = `keeper-open-${keeperId}`
  const place = `keeper-talk-${keeperId}`
  const said = `keeper-said-${keeperId}`
  const again = `keeper-again-${keeperId}`
  const toggle = useRef<HTMLButtonElement>(null)
  // A retry that read takes its button away. The focus then goes back to the
  // button of the card, not to the body of the page.
  const retrying = view.kind === 'failed'
  const wasRetrying = useRef(retrying)
  useEffect(() => {
    const before = wasRetrying.current
    wasRetrying.current = retrying
    if (before && !retrying && fell()) toggle.current?.focus()
  }, [retrying])
  return html`
    <p>
      <button ref=${toggle} id=${button} type="button" aria-expanded=${open} aria-controls=${place} aria-labelledby=${`${button} ${card}`}
        onClick=${() => { if (open) talk.close(); else void talk.open(keeperId) }}>대화 보기</button>
    </p>
    <div id=${place} class="talk">
      ${open ? html`<h4 id=${said} class="talk-title">지금 대화</h4>` : null}
      <p class="hint" role="status">${statusWords(view)}</p>
      ${view.kind === 'failed'
        ? html`
            <${ReadNote} key=${view.failure.attempts} failure=${view.failure} />
            <p>
              <button id=${again} type="button" class="primary" aria-disabled=${view.next !== 'idle'} aria-labelledby=${`${again} ${card}`}
                onClick=${() => { void talk.retry() }}>다시 불러오기</button>
            </p>
          `
        : null}
      ${view.kind === 'read' ? html`<${Read} conversation=${view.conversation} said=${said} />` : null}
      ${view.kind === 'closed' ? null : html`<${SayPart} talk=${talk} view=${view} card=${card} />`}
    </div>
  `
}
