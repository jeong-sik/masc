// The allowlist panel of the console, which only an Admin sees: the accounts
// that join as a Member when they sign in, with the button that takes one off
// the list, the form that puts one on it (allowlist-add.ts), and, behind a
// button, the entries that are closed (allowlist.ts).

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { Retry, fell, idTail, sessionEndedWords } from './notes'
import { AddArea, AddForm, Outcome } from './allowlist-add'
import type { AllowlistModel, ListView, Provider, Remove } from './allowlist'
import type { Entry, EntryStatus } from './allowlist-wire'
import { AdminListProblem } from './invite-rows'
import { identityWords } from './member-rows'

const headingId = 'allowlist-heading'
const closedId = 'allowlist-closed'
const defaultProvider: Provider = 'github'

// ---- words ----

/** What an entry's status says, and whether a person can still join
    through it or the removal of it is still to finish: the two the Admin
    may take off the list. */
function statusWords(status: EntryStatus['kind']): readonly [string, boolean] {
  switch (status) {
    case 'open': return ['기다리는 중', true]
    case 'removal_pending': return ['빼기 마무리 필요', true]
    case 'removed': return ['뺌', false]
    case 'consumed': return ['사용됨', false]
    case 'unrecognised': return ['이 화면이 모르는 상태', false]
  }
}

function StatusLine({ status }: { readonly status: EntryStatus }): VNode {
  switch (status.kind) {
    case 'open': return html`<p>이 계정으로 로그인하면 구성원으로 들어와요.</p>`
    case 'removal_pending': return html`<p>빼기가 기록되지 않았어요. 이 계정으로는 아무도 들어올 수 없어요. 한 번 더 빼면 마무리돼요.</p>`
    case 'removed': return html`<p>목록에서 뺀 계정이에요.</p>`
    case 'consumed': return html`<p>이 계정으로 들어온 사용자: <span class="mono">${idTail(status.joined)}</span></p>`
    case 'unrecognised': return html`<p>서버가 알려 준 상태를 이 화면은 몰라요.</p>`
  }
}

/** What the line of a row says: what a second press does once the first
    one asked, else what came of the latest removal. */
function rowWords(removal: Remove | undefined, sure: boolean, pending: boolean): string {
  if (sure) return pending ? '한 번 더 누르면 빼기를 마무리해요.' : '한 번 더 누르면 이 계정은 초대 링크 없이 들어올 수 없어요.'
  switch (removal?.kind) {
    case undefined: return ''
    case 'sending': return '목록에서 빼고 있어요…'
    // A 409 can answer an earlier removal of this page whose end it did not hear, so it does not say who closed it.
    case 'done': return removal.before ? '이미 닫힌 항목이에요. 빠졌거나 누군가 이 계정으로 들어왔어요.' : '뺐어요. 이 계정은 초대 링크 없이 들어올 수 없어요.'
    case 'leaving': return sessionEndedWords
    case 'refused':
    case 'unknown':
      return ''
  }
}

// ---- an entry ----

/** The button that takes an entry off the list, which asks once more
    before it does. `sure` is held by the row, whose line says what the
    second press does. */
function RemoveArea({ entry, removal, model, title, line, sure, setSure }: {
  readonly entry: Entry
  readonly removal: Remove | undefined
  readonly model: AllowlistModel
  /** The id of the title of the row, which names the buttons with it. */
  readonly title: string
  /** The id of the line of the row, which describes the remove button. */
  readonly line: string
  readonly sure: boolean
  readonly setSure: (sure: boolean) => void
}): VNode {
  const button = useRef<HTMLButtonElement>(null)
  const busy = removal?.kind === 'sending' || removal?.kind === 'leaving' || removal?.kind === 'done'
  const press = (): void => {
    if (busy) return
    if (!sure) {
      setSure(true)
      return
    }
    setSure(false)
    void model.remove(entry.id)
  }
  const back = (): void => {
    setSure(false)
    button.current?.focus()
  }
  const id = `allowlist-remove-${entry.id}`
  const backId = `allowlist-back-${entry.id}`
  const first = entry.status.kind === 'removal_pending' ? '빼기 마무리' : '목록에서 빼기'
  return html`
    <p class="actions">
      <button ref=${button} id=${id} type="button" aria-disabled=${busy} aria-labelledby=${`${id} ${title}`} aria-describedby=${line} onClick=${press}>
        ${sure ? '정말 빼기' : first}
      </button>
      ${sure ? html`<button id=${backId} type="button" aria-labelledby=${`${backId} ${title}`} onClick=${back}>그대로 두기</button>` : null}
    </p>
  `
}

function EntryRow({ entry, model, me }: { readonly entry: Entry; readonly model: AllowlistModel; readonly me: string }): VNode {
  const [status, removable] = statusWords(entry.status.kind)
  const title = `allowlist-title-${entry.id}`
  const line = `allowlist-line-${entry.id}`
  const removal = model.removing.value.get(entry.id)
  const [sure, setSure] = useState(false)
  const heading = useRef<HTMLHeadingElement>(null)
  // An entry taken off the list takes its buttons away. The focus then goes
  // to the title of its row, not to the body of the page.
  const wasRemovable = useRef(removable)
  useEffect(() => {
    const before = wasRemovable.current
    wasRemovable.current = removable
    if (before && !removable && fell()) heading.current?.focus()
  }, [removable])
  return html`
    <li class="row">
      <h3 id=${title} ref=${heading} class="row-title" tabindex="-1">${identityWords(entry.identity)}</h3>
      <p class="chips"><span class=${entry.status.kind === 'open' ? 'chip' : 'chip chip-todo'}>${status}</span></p>
      <${StatusLine} status=${entry.status} />
      <p class="hint">넣은 사람: ${entry.registrar === me ? '나' : html`관리자 <span class="mono">${idTail(entry.registrar)}</span>`}</p>
      ${removable ? html`<${RemoveArea} entry=${entry} removal=${removal} model=${model} title=${title} line=${line} sure=${sure} setSure=${setSure} />` : null}
      <p id=${line} class="hint" role="status">${rowWords(removal, sure && removable, entry.status.kind === 'removal_pending')}</p>
      ${removable && (removal?.kind === 'refused' || removal?.kind === 'unknown')
        ? html`<${Outcome} key=${removal.attempts} step="remove" outcome=${removal}
            title=${removal.kind === 'refused' ? '목록에서 빼지 못했어요' : '목록에서 뺐는지 알 수 없어요'} />`
        : null}
    </li>
  `
}

// ---- the panel ----

/** What the line under the heading says while the list is not on the page. */
function listWords(view: ListView): string {
  switch (view.kind) {
    case 'reading': return view.slow ? '허용 목록을 불러오고 있어요…' : ''
    case 'leaving': return sessionEndedWords
    case 'waiting':
    case 'failed':
    case 'read':
      return ''
  }
}

export function AllowlistPanel({ model }: { readonly model: AllowlistModel }): VNode {
  const view = model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const [showClosed, setShowClosed] = useState(false)
  // The way of signing in picked and what was typed are kept by the panel,
  // which stays while the form comes and goes with the list.
  const [provider, setProvider] = useState<Provider>(defaultProvider)
  const [typed, setTyped] = useState('')
  // The entries once shown with the open ones stay with them while the list
  // is on the page, so a row never moves to the closed list under the
  // focus: one taken off here, or that a person joined through meanwhile,
  // says so where it was.
  const keptOpen = useRef(new Set<string>())
  if (view.kind !== 'read') keptOpen.current.clear()
  // A control of the panel that goes away takes the focus with it: a row the
  // server no longer lists, the retry that read, the form when the list
  // could not be read again. The focus then goes to the heading of the
  // panel, not to the body of the page. The check waits for the effects of
  // the rows, which put it on the title of a row that stays.
  const lastFocus = useRef<Element | null>(null)
  useEffect(() => {
    const was = lastFocus.current
    if (was === null || was.isConnected) return
    queueMicrotask(() => { if (!was.isConnected && fell()) heading.current?.focus() })
  })
  const entries = view.kind === 'read' ? view.entries : []
  const current = entries.filter((one) => statusWords(one.status.kind)[1] || keptOpen.current.has(one.id))
  for (const one of current) keptOpen.current.add(one.id)
  const closed = entries.filter((one) => !current.includes(one))
  const me = view.kind === 'waiting' ? '' : view.forUser
  return html`
    <section aria-labelledby=${headingId} onFocusIn=${(event: FocusEvent) => { lastFocus.current = event.target instanceof Element ? event.target : null }}>
      <h2 id=${headingId} ref=${heading} tabindex="-1">허용 목록</h2>
      <p class="hint">관리자만 보는 칸이에요. 여기 넣은 계정은 초대 링크 없이, 로그인만 하면 구성원으로 들어와요.</p>
      <p class="hint" role="status">${listWords(view)}</p>
      ${view.kind === 'failed'
        ? html`
            <${AdminListProblem} key=${view.failure.attempts} title="허용 목록을 불러오지 못했어요" failure=${view.failure} />
            <${Retry} label="다시 시도" next=${view.next} onRetry=${() => { void model.retry() }} />
          `
        : null}
      ${view.kind === 'read'
        ? html`
            ${current.length === 0
              ? html`<p>지금 기다리는 계정이 없어요.</p>`
              : html`<ul class="rows">${current.map((one) => html`<${EntryRow} key=${one.id} entry=${one} model=${model} me=${me} />`)}</ul>`}
            <${AddForm} model=${model} provider=${provider} setProvider=${setProvider} typed=${typed} setTyped=${setTyped} />
          `
        : null}
      <${AddArea} model=${model} />
      ${view.kind === 'read' && closed.length > 0
        ? html`
            <p><button type="button" aria-expanded=${showClosed} aria-controls=${closedId} onClick=${() => { setShowClosed(!showClosed) }}>닫힌 항목 ${closed.length}개</button></p>
            <ul id=${closedId} class="rows" hidden=${!showClosed}>
              ${closed.map((one) => html`<${EntryRow} key=${one.id} entry=${one} model=${model} me=${me} />`)}
            </ul>
          `
        : null}
    </section>
  `
}
