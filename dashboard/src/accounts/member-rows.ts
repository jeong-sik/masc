// The members panel of the console, which only an Admin sees: each person of
// the server, the account they sign in with, their role, and whether they can
// sign in now (members.ts). The panel only reads: this build has no route
// that changes a person.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import { Retry, fell, idTail, sessionEndedWords } from './notes'
import { AdminListProblem } from './invite-rows'
import type { MembersModel, MembersView } from './members'
import type { HeldChange, Identity, Member, MemberRole, MemberStatus } from './members-wire'

const headingId = 'members-heading'

// ---- words ----

/** The account a person signs in with, as the title of their row. */
export function identityWords(identity: Identity): string {
  switch (identity.provider) {
    case 'github': return `GitHub 사용자 번호 ${String(identity.userId)}`
    case 'google': return `Google 계정 ${identity.sub}`
    case 'unrecognised': return '이 화면이 모르는 로그인 방법'
  }
}

function roleWords(role: MemberRole): string {
  switch (role) {
    case 'admin': return '관리자'
    case 'member': return '구성원'
  }
}

/** The chip of a status that keeps a person out, or null for one who can sign in. */
function statusChip(status: MemberStatus): string | null {
  switch (status) {
    case 'active': return null
    case 'disabled': return '비활성'
    case 'unrecognised': return '이 화면이 모르는 상태'
  }
}

function heldWords(change: HeldChange): string {
  switch (change) {
    case 'revoke': return '관리자 해제'
    case 'disable': return '비활성화'
    case 'delete': return '삭제'
    case 'unrecognised': return '이 화면이 모르는 변경'
  }
}

function listWords(view: MembersView): string {
  switch (view.kind) {
    case 'reading': return view.slow ? '구성원을 불러오고 있어요…' : ''
    case 'leaving': return sessionEndedWords
    case 'waiting':
    case 'failed':
    case 'read':
      return ''
  }
}

// ---- a person ----

function MemberRow({ member, me }: { readonly member: Member; readonly me: boolean }): VNode {
  const chip = statusChip(member.status)
  const held = member.held.length > 0
  return html`
    <li class="row">
      <h3 class="row-title">${identityWords(member.identity)}</h3>
      <p class="chips">
        <span class="chip">${roleWords(member.role)}</span>
        ${me ? html`<span class="chip">나</span>` : null}
        ${chip === null ? null : html`<span class="chip chip-todo">${chip}</span>`}
        ${held ? html`<span class="chip chip-todo">끝나지 않은 변경</span>` : null}
      </p>
      <p class="hint">사용자 <span class="mono">${idTail(member.userId)}</span></p>
      ${member.status === 'disabled' ? html`<p>이 계정으로는 로그인할 수 없어요.</p>` : null}
      ${held
        ? html`
            <p>기록되지 않은 변경이 있어요: ${member.held.map(heldWords).join(', ')}.</p>
            <p>그동안 이 사람은 로그인할 수도, 이 서버에서 무엇을 할 수도 없어요. 같은 변경을 한 번 더 하면 끝나지만, 이 화면에는 아직 그 단추가 없어요.</p>
          `
        : null}
    </li>
  `
}

/** People who can sign in first (active, with no change held), and Admins
    before Members; otherwise the order of the server. */
const rank = (member: Member): number =>
  (member.status === 'active' && member.held.length === 0 ? 0 : 2) + (member.role === 'admin' ? 0 : 1)

// ---- the panel ----

export function MembersPanel({ model }: { readonly model: MembersModel }): VNode {
  const view = model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const shown = useRef(view.kind)
  // A retry that read takes the pressed button away. The focus then goes to
  // the heading of the panel, not to the body of the page.
  useEffect(() => {
    const before = shown.current
    shown.current = view.kind
    if (before === 'failed' && view.kind !== 'failed' && fell()) heading.current?.focus()
  }, [view.kind])
  const members = view.kind === 'read' ? [...view.members].sort((a, b) => rank(a) - rank(b)) : []
  return html`
    <section aria-labelledby=${headingId}>
      <h2 id=${headingId} ref=${heading} tabindex="-1">구성원</h2>
      <p class="hint">관리자만 보는 칸이에요. 이 서버에 들어온 사람과 그 역할이에요.</p>
      <p class="hint" role="status">${listWords(view)}</p>
      ${view.kind === 'failed'
        ? html`
            <${AdminListProblem} key=${view.failure.attempts} title="구성원을 불러오지 못했어요" failure=${view.failure} />
            <${Retry} label="다시 시도" next=${view.next} onRetry=${() => { void model.retry() }} />
          `
        : null}
      ${view.kind === 'read'
        ? members.length === 0
          ? html`<p>아직 아무도 없어요.</p>`
          : html`<ul class="rows">${members.map((one) => html`<${MemberRow} key=${one.userId} member=${one} me=${one.userId === view.forUser} />`)}</ul>`
        : null}
    </section>
  `
}
