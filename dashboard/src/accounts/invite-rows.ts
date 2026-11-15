// The invitations panel of the console, which only an Admin sees: the
// invitations a person can still join through, with the button that revokes
// one, the form that makes a link (invite-make.ts), and, behind a button,
// the invitations that are closed (invites.ts).

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { Callout, ProblemNote, Retry, fell, idTail, sessionEndedWords } from './notes'
import type { Failure } from './notes'
import { MadeArea, MakeForm, Outcome, defaultRole, roleWords } from './invite-make'
import type { InvitesModel, ListView, Revoke } from './invites'
import type { Invite, InviteRole, InviteStatus, Issuer } from './invites-wire'
import { When } from './token-rows'

const headingId = 'invites-heading'
const closedId = 'invites-closed'
const forbidden = 403

// ---- words ----

/** What an invitation's status says, and whether a person can still join
    through it or the revoke of it is still to finish: the two the Admin
    may revoke. */
function statusWords(status: InviteStatus['kind']): readonly [string, boolean] {
  switch (status) {
    case 'open': return ['기다리는 중', true]
    case 'revocation_pending': return ['취소 마무리 필요', true]
    case 'expired': return ['만료됨', false]
    case 'revoked': return ['취소됨', false]
    case 'consumed': return ['사용됨', false]
    case 'unrecognised': return ['이 화면이 모르는 상태', false]
  }
}

function StatusLine({ invite }: { readonly invite: Invite }): VNode {
  const { status } = invite
  switch (status.kind) {
    case 'open': return html`<p><${When} ms=${invite.expiresAtMs} />까지 한 사람이 이 링크로 들어올 수 있어요.</p>`
    case 'revocation_pending': return html`<p>취소가 기록되지 않았어요. 이 링크로는 아무도 들어올 수 없어요. 한 번 더 취소하면 마무리돼요.</p>`
    case 'expired': return html`<p><${When} ms=${invite.expiresAtMs} />에 만료됐어요.</p>`
    case 'revoked': return html`<p>취소한 초대예요.</p>`
    case 'consumed': return html`<p>이 링크로 들어온 사용자: <span class="mono">${idTail(status.joined)}</span></p>`
    case 'unrecognised': return html`<p>서버가 알려 준 상태를 이 화면은 몰라요.</p>`
  }
}

function IssuerLine({ issuer, me }: { readonly issuer: Issuer; readonly me: string }): VNode {
  switch (issuer.kind) {
    case 'local_operator': return html`<p class="hint">만든 사람: 서버 운영자(<span class="mono" lang="en">masc auth</span>)</p>`
    case 'admin':
      return issuer.userId === me
        ? html`<p class="hint">만든 사람: 나</p>`
        : html`<p class="hint">만든 사람: 관리자 <span class="mono">${idTail(issuer.userId)}</span></p>`
  }
}

/** What the line of a row says: what a second press does once the first
    one asked, else what came of the latest revoke. */
function rowWords(revoke: Revoke | undefined, sure: boolean, pending: boolean): string {
  if (sure) return pending ? '한 번 더 누르면 취소를 마무리해요.' : '한 번 더 누르면 이 링크로는 아무도 들어올 수 없어요. 되돌릴 수 없어요.'
  switch (revoke?.kind) {
    case undefined: return ''
    case 'sending': return '초대를 취소하고 있어요…'
    // A 409 can answer an earlier revoke of this page whose end it did not hear, so it does not say who closed it.
    case 'done': return revoke.before ? '이미 닫힌 초대예요. 취소됐거나 누군가 이 링크로 들어왔어요.' : '취소했어요. 이 링크로는 아무도 들어올 수 없어요.'
    case 'leaving': return sessionEndedWords
    case 'refused':
    case 'unknown':
      return ''
  }
}

// ---- an invitation ----

/** The button that revokes an invitation, which asks once more before it
    does. `sure` is held by the row, whose line says what the second press does. */
function RevokeArea({ invite, revoke, model, title, line, sure, setSure }: {
  readonly invite: Invite
  readonly revoke: Revoke | undefined
  readonly model: InvitesModel
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
    void model.revoke(invite.id)
  }
  const back = (): void => {
    setSure(false)
    button.current?.focus()
  }
  const id = `invite-revoke-${invite.id}`
  const backId = `invite-back-${invite.id}`
  const first = invite.status.kind === 'revocation_pending' ? '취소 마무리' : '초대 취소'
  return html`
    <p class="actions">
      <button ref=${button} id=${id} type="button" aria-disabled=${busy} aria-labelledby=${`${id} ${title}`} aria-describedby=${line} onClick=${press}>
        ${sure ? '정말 취소' : first}
      </button>
      ${sure ? html`<button id=${backId} type="button" aria-labelledby=${`${backId} ${title}`} onClick=${back}>그대로 두기</button>` : null}
    </p>
  `
}

function InviteRow({ invite, model, me }: { readonly invite: Invite; readonly model: InvitesModel; readonly me: string }): VNode {
  const [status, revocable] = statusWords(invite.status.kind)
  const title = `invite-title-${invite.id}`
  const line = `invite-line-${invite.id}`
  const revoke = model.revoking.value.get(invite.id)
  const [sure, setSure] = useState(false)
  const heading = useRef<HTMLHeadingElement>(null)
  // An invitation revoked takes its buttons away. The focus then goes to the
  // title of its row, not to the body of the page.
  const wasRevocable = useRef(revocable)
  useEffect(() => {
    const before = wasRevocable.current
    wasRevocable.current = revocable
    if (before && !revocable && fell()) heading.current?.focus()
  }, [revocable])
  return html`
    <li class="row">
      <h3 id=${title} ref=${heading} class="row-title" tabindex="-1">${roleWords(invite.role)[0]} 초대 <span class="mono">${idTail(invite.id)}</span></h3>
      <p class="chips"><span class=${invite.status.kind === 'open' ? 'chip' : 'chip chip-todo'}>${status}</span></p>
      <${StatusLine} invite=${invite} />
      <${IssuerLine} issuer=${invite.issuer} me=${me} />
      ${revocable ? html`<${RevokeArea} invite=${invite} revoke=${revoke} model=${model} title=${title} line=${line} sure=${sure} setSure=${setSure} />` : null}
      <p id=${line} class="hint" role="status">${rowWords(revoke, sure && revocable, invite.status.kind === 'revocation_pending')}</p>
      ${revocable && (revoke?.kind === 'refused' || revoke?.kind === 'unknown')
        ? html`<${Outcome} key=${revoke.attempts} step="revoke" outcome=${revoke}
            title=${revoke.kind === 'refused' ? '초대를 취소하지 못했어요' : '초대를 취소했는지 알 수 없어요'} />`
        : null}
    </li>
  `
}

// ---- the panel ----

/** What the line under the heading says while the list is not on the page. */
function listWords(view: ListView): string {
  switch (view.kind) {
    case 'reading': return view.slow ? '초대를 불러오고 있어요…' : ''
    case 'leaving': return sessionEndedWords
    case 'waiting':
    case 'failed':
    case 'read':
      return ''
  }
}

/** The alert of a list that could not be read. On a request from this page
    the list answers 403 only when the browser now holds the session of
    another account that is not an Admin: this build takes the role from no
    one, and a disabled account gets 401. */
function ListProblem({ failure }: { readonly failure: Failure }): VNode {
  const title = '초대를 불러오지 못했어요'
  const { problem, attempts } = failure
  if (problem.kind !== 'refused' || problem.status !== forbidden) return html`<${ProblemNote} title=${title} failure=${failure} />`
  return html`<${Callout} title=${title} attempts=${attempts} reason=${problem.reason}
    lines=${['이 브라우저에 지금 로그인한 계정은 관리자가 아니에요.', '다른 탭에서 다른 계정으로 로그인했다면, 이 화면을 새로 고치면 그 계정으로 보여요.']} />`
}

const byNewest = (a: Invite, b: Invite): number => b.expiresAtMs - a.expiresAtMs

export function InvitesPanel({ model }: { readonly model: InvitesModel }): VNode {
  const view = model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const shown = useRef(view.kind)
  const [showClosed, setShowClosed] = useState(false)
  // The role picked is kept by the panel, which stays while the form comes
  // and goes with the list, so a list read again does not change the pick.
  const [role, setRole] = useState<InviteRole>(defaultRole)
  // The invitations once shown with the open ones stay with them while the
  // list is on the page, so a row never moves to the closed list under the
  // focus: one revoked here, or that expired or was used meanwhile, says so
  // where it was.
  const keptOpen = useRef(new Set<string>())
  if (view.kind !== 'read') keptOpen.current.clear()
  // A row the server no longer lists goes away with its buttons. The focus
  // then goes to the heading of the panel, not to the body of the page. The
  // check waits for the effects of the rows, which put it on the title of a
  // row that stays.
  const lastFocus = useRef<Element | null>(null)
  useEffect(() => {
    const was = lastFocus.current
    if (was === null || was.isConnected) return
    queueMicrotask(() => { if (!was.isConnected && fell()) heading.current?.focus() })
  })
  // A retry that read takes the pressed button away. The focus then goes to
  // the heading of the panel, not to the body of the page.
  useEffect(() => {
    const before = shown.current
    shown.current = view.kind
    if (before !== view.kind && (before === 'failed' || before === 'read') && fell()) heading.current?.focus()
  }, [view.kind])
  const invites = view.kind === 'read' ? [...view.invites].sort(byNewest) : []
  const current = invites.filter((one) => statusWords(one.status.kind)[1] || keptOpen.current.has(one.id))
  for (const one of current) keptOpen.current.add(one.id)
  const closed = invites.filter((one) => !current.includes(one))
  const me = view.kind === 'waiting' ? '' : view.forUser
  return html`
    <section aria-labelledby=${headingId} onFocusIn=${(event: FocusEvent) => { lastFocus.current = event.target instanceof Element ? event.target : null }}>
      <h2 id=${headingId} ref=${heading} tabindex="-1">초대 링크</h2>
      <p class="hint">관리자만 보는 칸이에요. 링크를 받은 사람이 GitHub이나 Google로 로그인하면 이 서버에 들어와요.</p>
      <p class="hint" role="status">${listWords(view)}</p>
      ${view.kind === 'failed'
        ? html`
            <${ListProblem} key=${view.failure.attempts} failure=${view.failure} />
            <${Retry} label="다시 시도" next=${view.next} onRetry=${() => { void model.retry() }} />
          `
        : null}
      ${view.kind === 'read'
        ? html`
            ${current.length === 0
              ? html`<p>지금 열린 초대가 없어요.</p>`
              : html`<ul class="rows">${current.map((one) => html`<${InviteRow} key=${one.id} invite=${one} model=${model} me=${me} />`)}</ul>`}
            <${MakeForm} model=${model} role=${role} setRole=${setRole} />
          `
        : null}
      <${MadeArea} model=${model} heading=${headingId} />
      ${view.kind === 'read' && closed.length > 0
        ? html`
            <p><button type="button" aria-expanded=${showClosed} aria-controls=${closedId} onClick=${() => { setShowClosed(!showClosed) }}>닫힌 초대 ${closed.length}개</button></p>
            <ul id=${closedId} class="rows" hidden=${!showClosed}>
              ${closed.map((one) => html`<${InviteRow} key=${one.id} invite=${one} model=${model} me=${me} />`)}
            </ul>
          `
        : null}
    </section>
  `
}
