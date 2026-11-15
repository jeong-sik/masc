// The tokens panel of the console: the tokens of the person and the button
// that revokes one (tokens.ts). The form that makes one is token-make.ts.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { ProblemNote, Retry, fell, idTail, sessionEndedWords } from './notes'
import { MadeArea, MakeForm, Outcome, useWords } from './token-make'
import type { ListView, Revoke, TokensModel } from './tokens'
import { useOf } from './tokens-wire'
import type { Pat, PatStatus, Reach } from './tokens-wire'

const headingId = 'tokens-heading'

const clock = new Intl.DateTimeFormat('ko-KR', { dateStyle: 'medium', timeStyle: 'short' })

function When({ ms }: { readonly ms: number }): VNode {
  const at = new Date(ms)
  return html`<time datetime=${at.toISOString()}>${clock.format(at)}</time>`
}

// ---- words ----

/** What a token's status says, and whether the token still works. */
function statusWords(status: PatStatus): readonly [string, boolean] {
  switch (status) {
    case 'open': return ['쓸 수 있음', true]
    case 'expired': return ['만료됨', false]
    case 'revoked': return ['폐기됨', false]
    case 'unknown': return ['서버가 상태를 모름', false]
    case 'unrecognised': return ['이 화면이 모르는 상태', false]
  }
}

const reachWords = (reach: Reach): string => (reach === 'all' ? '모두' : reach.join(', '))

/** What the line of a row says: what a second press does once the first
    one asked, else what came of the latest revoke. */
function rowWords(revoke: Revoke | undefined, sure: boolean): string {
  if (sure) return '한 번 더 누르면 이 토큰으로는 더 접속할 수 없어요. 되돌릴 수 없어요.'
  switch (revoke?.kind) {
    case undefined: return ''
    case 'sending': return '폐기하고 있어요…'
    // A 409 can answer an earlier revoke of this page whose end it did not hear, so it does not say who revoked it.
    case 'done': return revoke.already ? '이미 폐기된 토큰이에요.' : '폐기했어요. 이 토큰으로는 더 접속할 수 없어요.'
    case 'leaving': return sessionEndedWords
    case 'refused':
    case 'unknown':
      return ''
  }
}

// ---- a token ----

/** The button that revokes a token, which asks once more before it does.
    `sure` is held by the row, whose line says what the second press does. */
function RevokeArea({ pat, revoke, model, title, line, sure, setSure }: {
  readonly pat: Pat
  readonly revoke: Revoke | undefined
  readonly model: TokensModel
  /** The id of the title of the row, which names the buttons with it. */
  readonly title: string
  /** The id of the line of the row, which describes the revoke button. */
  readonly line: string
  readonly sure: boolean
  readonly setSure: (sure: boolean) => void
}): VNode {
  const button = useRef<HTMLButtonElement>(null)
  const busy = revoke?.kind === 'sending' || revoke?.kind === 'leaving' || revoke?.kind === 'done'
  const press = (): void => {
    if (busy) return
    if (!sure) {
      setSure(true)
      return
    }
    setSure(false)
    void model.revoke(pat.id)
  }
  const back = (): void => {
    setSure(false)
    button.current?.focus()
  }
  const id = `token-revoke-${pat.id}`
  const backId = `token-back-${pat.id}`
  return html`
    <p class="actions">
      <button ref=${button} id=${id} type="button" aria-disabled=${busy} aria-labelledby=${`${id} ${title}`} aria-describedby=${line} onClick=${press}>
        ${sure ? '정말 폐기' : '폐기'}
      </button>
      ${sure ? html`<button id=${backId} type="button" aria-labelledby=${`${backId} ${title}`} onClick=${back}>취소</button>` : null}
    </p>
  `
}

function TokenRow({ pat, model }: { readonly pat: Pat; readonly model: TokensModel }): VNode {
  const [status, works] = statusWords(pat.status)
  const use = useOf(pat.scope)
  const title = `token-title-${pat.id}`
  const line = `token-line-${pat.id}`
  const revoke = model.revoking.value.get(pat.id)
  const [sure, setSure] = useState(false)
  const heading = useRef<HTMLHeadingElement>(null)
  // A token revoked takes its buttons away. The focus then goes to the title
  // of its row, not to the body of the page.
  const wasOpen = useRef(works)
  useEffect(() => {
    const before = wasOpen.current
    wasOpen.current = works
    if (before && !works && fell()) heading.current?.focus()
  }, [works])
  return html`
    <li class="row">
      <h3 id=${title} ref=${heading} class="row-title" tabindex="-1">토큰 <span class="mono">${idTail(pat.id)}</span></h3>
      <p class="chips"><span class=${works ? 'chip' : 'chip chip-todo'}>${status}</span></p>
      ${use === null
        ? html`<p>직접 정한 범위: <span class="mono" lang="en">${reachWords(pat.scope.effects)}</span></p>`
        : html`<p>쓸 곳: ${useWords(use)[0]}</p>`}
      <p class="hint">
        <${When} ms=${pat.issuedAtMs} />에 만들었어요.
        ${pat.expiresAtMs === null ? ' 만료되지 않아요.' : html` <${When} ms=${pat.expiresAtMs} />에 만료돼요.`}
      </p>
      ${works ? html`<${RevokeArea} pat=${pat} revoke=${revoke} model=${model} title=${title} line=${line} sure=${sure} setSure=${setSure} />` : null}
      <p id=${line} class="hint" role="status">${rowWords(revoke, sure && works)}</p>
      ${works && (revoke?.kind === 'refused' || revoke?.kind === 'unknown')
        ? html`<${Outcome} key=${revoke.attempts} step="revoke" outcome=${revoke}
            title=${revoke.kind === 'refused' ? '토큰을 폐기하지 못했어요' : '토큰을 폐기했는지 알 수 없어요'} />`
        : null}
    </li>
  `
}

// ---- the panel ----

/** What the line under the heading says while the list is not on the page. */
function listWords(view: ListView): string {
  switch (view.kind) {
    case 'reading': return view.slow ? '토큰을 불러오고 있어요…' : ''
    case 'leaving': return sessionEndedWords
    case 'waiting':
    case 'failed':
    case 'read':
      return ''
  }
}

export function TokensPanel({ model }: { readonly model: TokensModel }): VNode {
  const view = model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const shown = useRef(view.kind)
  // A retry that read takes the pressed button away. The focus then goes to
  // the heading of the panel, not to the body of the page.
  useEffect(() => {
    const before = shown.current
    shown.current = view.kind
    if (before !== view.kind && (before === 'failed' || before === 'read') && fell()) heading.current?.focus()
  }, [view.kind])
  const pats = view.kind === 'read' ? [...view.pats].sort((a, b) => b.issuedAtMs - a.issuedAtMs) : []
  return html`
    <section aria-labelledby=${headingId}>
      <h2 id=${headingId} ref=${heading} tabindex="-1">토큰</h2>
      <p class="hint">스크립트나 MCP 클라이언트가 내 권한의 일부로 이 서버에 접속할 때 쓰는 열쇠예요.</p>
      <p class="hint" role="status">${listWords(view)}</p>
      ${view.kind === 'failed'
        ? html`
            <${ProblemNote} key=${view.failure.attempts} title="토큰을 불러오지 못했어요" failure=${view.failure} />
            <${Retry} label="다시 시도" next=${view.next} onRetry=${() => { void model.retry() }} />
          `
        : null}
      ${view.kind === 'read'
        ? html`
            ${pats.length === 0
              ? html`<p>아직 만든 토큰이 없어요.</p>`
              : html`<ul class="rows">${pats.map((pat) => html`<${TokenRow} key=${pat.id} pat=${pat} model=${model} />`)}</ul>`}
            <${MakeForm} model=${model} />
          `
        : null}
      <${MadeArea} model=${model} heading=${headingId} />
    </section>
  `
}
