// The area of the subscriptions panel where a person connects a subscription:
// the step `createConnect` (connect.ts) is at, in words, and the controls of
// that step. What a client printed is shown as text, never read as HTML.

import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import type { ConnectModel, ConnectView, Ended, Input } from './connect'
import { ProblemNote, sessionEndedWords } from './notes'
import { integrationName } from './wire'
import type { Integration } from './wire'

// ---- what a client printed ----

/** Removes what a terminal would act on rather than show: escape sequences
    and control characters other than tab and newline. */
export function printable(text: string): string {
  return text
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, '')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '')
}

const address = /https:\/\/[^\s<>"'`]+/g

/** How far from its end, in CSS pixels, a transcript still counts as read to
    its end. A browser may stop a scroll a fraction of a pixel short. */
const endSlackPx = 2

/** The transcript, with each address a link. Nothing printed is read as
    HTML. While the person has read it to its end, its end stays in view as
    it grows or as a narrower window wraps its lines again, as on a terminal;
    once they scroll back, it stays where they are. */
function Transcript({ text }: { readonly text: string }): VNode {
  const box = useRef<HTMLPreElement>(null)
  const atEnd = useRef(true)
  const shown = printable(text)
  useLayoutEffect(() => {
    const element = box.current
    if (element !== null && atEnd.current) element.scrollTop = element.scrollHeight
  }, [shown])
  useEffect(() => {
    const element = box.current
    if (element === null) return undefined
    const watching = new ResizeObserver(() => { if (atEnd.current) element.scrollTop = element.scrollHeight })
    watching.observe(element)
    return () => { watching.disconnect() }
  }, [])
  const onScroll = (event: Event): void => {
    const element = event.currentTarget as HTMLElement
    atEnd.current = element.scrollHeight - element.scrollTop - element.clientHeight <= endSlackPx
  }
  const parts: Array<string | VNode> = []
  let at = 0
  for (const match of shown.matchAll(address)) {
    parts.push(shown.slice(at, match.index), html`<a href=${match[0]} target="_blank" rel="noopener noreferrer">${match[0]}</a>`)
    at = match.index + match[0].length
  }
  parts.push(shown.slice(at))
  return html`
    <pre ref=${box} class="transcript" role="region" tabindex="0" aria-label="로그인 도구가 보낸 안내" onScroll=${onScroll}>${parts}</pre>
  `
}

// ---- words ----

function inputWords(input: Input): string {
  switch (input) {
    case 'not_asked': return '로그인 도구가 켜졌어요. 안내를 기다리고 있어요…'
    case 'asked': return '로그인 도구가 답을 기다려요. 안내에 나온 주소에서 로그인한 뒤, 받은 코드를 붙여 넣어 주세요.'
    case 'sending': return '보내고 있어요…'
    case 'not_taken': return '보내지 못했어요. 다시 보내 주세요.'
  }
}

function endedWords(ended: Ended): string {
  switch (ended) {
    case 'failed': return '로그인하지 못했어요. 처음부터 다시 해 주세요.'
    case 'cancelled': return '로그인을 취소했어요.'
    case 'interrupted': return '로그인이 중간에 멈췄어요. 처음부터 다시 해 주세요.'
    case 'unrecorded': return '로그인은 끝났지만 서버가 결과를 적지 못했어요. 이 서버를 운영하는 사람에게 알려 주세요.'
    case 'unknown': return '연결이 끊겨서 로그인이 어떻게 됐는지 알 수 없어요. 새 계정이 생겼다면 아래 목록에 나와요.'
  }
}

/** What a Keeper can do with an account of the subscription, said before it is picked. */
const callsWords = (integration: Integration): string =>
  integration.calls.kind === 'allowed'
    ? '연결하면 이 구독으로 Keeper를 실행할 수 있어요.'
    : '연결은 되지만 이 서버에서는 이 구독으로 Keeper를 실행할 수 없어요.'

const keys = [
  { key: 'enter', label: 'Enter' },
  { key: 'up', label: '↑ 위' },
  { key: 'down', label: '↓ 아래' },
  { key: 'tab', label: 'Tab' },
  { key: 'eof', label: '입력 끝(Ctrl-D)' },
] as const

// ---- the area ----

interface AreaProps {
  readonly model: ConnectModel
  readonly integrations: readonly Integration[]
}

function Choosing({ model, integrations }: AreaProps): VNode {
  const onSubmit = (event: Event): void => {
    event.preventDefault()
    const picked = new FormData(event.currentTarget as HTMLFormElement).get('integration')
    if (typeof picked === 'string') void model.start(picked)
  }
  return html`
    <form class="connect-form" onSubmit=${onSubmit}>
      <fieldset>
        <legend>연결할 구독</legend>
        <ul class="choices">
          ${integrations.map((integration) => html`
            <li key=${integration.id}>
              <label class="choice">
                <input type="radio" name="integration" value=${integration.id} required />
                <span><span class="choice-title">${integrationName(integration)}</span> <span class="hint">${callsWords(integration)}</span></span>
              </label>
            </li>
          `)}
        </ul>
      </fieldset>
      <p class="actions">
        <button type="submit" class="primary">로그인 시작</button>
        <button type="button" onClick=${model.close}>닫기</button>
      </p>
    </form>
  `
}

function Running({ model, view }: AreaProps & { readonly view: Extract<ConnectView, { kind: 'running' }> }): VNode {
  const ready = view.input === 'asked' || view.input === 'not_taken'
  const onSubmit = (event: Event): void => {
    event.preventDefault()
    const field = (event.currentTarget as HTMLFormElement).elements.namedItem('code')
    // A code typed while the client is not asking stays in the field.
    if (!ready || !(field instanceof HTMLInputElement) || field.value === '') return
    const text = field.value
    field.value = ''
    void model.reply({ kind: 'text', text })
  }
  return html`
    <${Transcript} text=${view.transcript} />
    <form class="reply" onSubmit=${onSubmit}>
      <label for="connect-code">로그인 코드</label>
      <input id="connect-code" name="code" type="password" autocomplete="off" spellcheck=${false} />
      <button type="submit" aria-disabled=${!ready}>코드 보내기</button>
    </form>
    <div class="actions" role="group" aria-label="로그인 도구에 보낼 키">
      ${keys.map(({ key, label }) => html`
        <button key=${key} type="button" aria-disabled=${!ready} onClick=${() => { if (ready) void model.reply({ kind: 'key', key }) }}>${label}</button>
      `)}
    </div>
    <p class="actions"><button type="button" onClick=${() => { void model.cancel() }}>로그인 취소</button></p>
  `
}

/** The line a screen reader reads out for each step. It is on the page in every step. */
function statusWords(view: ConnectView): string {
  switch (view.kind) {
    case 'closed': return view.linked ? '구독을 연결했어요. 새 계정이 아래 목록에 있어요.' : ''
    case 'choosing': return ''
    case 'starting': return '로그인 도구를 켜고 있어요…'
    case 'running': return view.cancelNotTaken ? '취소하지 못했어요. 다시 눌러 주세요.' : inputWords(view.input)
    case 'cancelling': return '로그인을 멈추고 있어요…'
    case 'checking': return '로그인이 어떻게 됐는지 확인하고 있어요…'
    case 'detached':
      return view.failure === null
        ? '이 화면과 로그인 도구의 연결이 끊겼지만 로그인 도구는 아직 돌고 있어요. 잠시 뒤 다시 확인하거나 로그인을 취소해 주세요.'
        : ''
    case 'ended': return view.ended === 'cancelled' ? endedWords(view.ended) : ''
    case 'failed': return ''
    case 'leaving': return sessionEndedWords
  }
}

function Step(props: AreaProps & { readonly view: ConnectView }): VNode | null {
  const { model, view } = props
  switch (view.kind) {
    case 'closed':
    case 'starting':
    case 'checking':
    case 'leaving':
      return null
    case 'choosing':
      return html`<${Choosing} ...${props} />`
    case 'running':
      return html`<${Running} ...${props} view=${view} />`
    case 'cancelling':
      return html`<${Transcript} text=${view.transcript} />`
    case 'detached':
      return html`
        ${view.failure === null ? null : html`<${ProblemNote} title="로그인이 어떻게 됐는지 확인하지 못했어요" failure=${view.failure} />`}
        <p class="actions">
          <button type="button" class="primary" onClick=${() => { void model.check() }}>다시 확인</button>
          <button type="button" onClick=${() => { void model.cancel() }}>로그인 취소</button>
        </p>
      `
    case 'ended':
      return html`
        ${view.ended === 'cancelled' ? null : html`<div class="callout" role="alert"><p>${endedWords(view.ended)}</p></div>`}
        <${Choosing} ...${props} />
      `
    case 'failed':
      return html`
        <${ProblemNote} title="로그인을 시작하지 못했어요" failure=${view.failure} />
        <${Choosing} ...${props} />
      `
  }
}

export function ConnectArea(props: AreaProps): VNode {
  const view = props.model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const toggle = useRef<HTMLButtonElement>(null)
  const before = useRef(view.kind)
  // A step that takes the pressed control away with the step before moves
  // the focus to the heading of the steps, or to the button that opens them
  // once they close, never to the body of the page. A focus the person moved
  // elsewhere meanwhile stays.
  useEffect(() => {
    const from = before.current
    before.current = view.kind
    const fell = document.activeElement === null || document.activeElement === document.body
    if (from === view.kind || !fell) return
    if (view.kind === 'closed') toggle.current?.focus()
    else heading.current?.focus()
  }, [view.kind])
  const open = view.kind !== 'closed'
  const closable = view.kind === 'choosing' || view.kind === 'ended' || view.kind === 'failed'
  return html`
    <div class="connect">
      <p>
        <button ref=${toggle} type="button" aria-expanded=${open} aria-controls="connect-steps"
          aria-disabled=${open && !closable} onClick=${open ? props.model.close : props.model.open}>구독 연결하기</button>
      </p>
      <div id="connect-steps" class="connect-steps">
        ${open ? html`<h3 ref=${heading} tabindex="-1">구독 연결</h3>` : null}
        <p role="status">${statusWords(view)}</p>
        <${Step} ...${props} view=${view} />
      </div>
    </div>
  `
}
