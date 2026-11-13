// The subscriptions of a signed-in person: the accounts they connected, the
// Runtimes made on them, and whether a Keeper may run on each here. A
// person learns before pressing anything what an account cannot do.
//
// `createSubscriptions` reads them for the person the console shows;
// `SubscriptionsPanel` draws whatever state it is given.

import { effect, signal, type ReadonlySignal } from '@preact/signals'
import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import type { View } from './console'
import { ProblemNote, Retry, idTail, slowAfterMs } from './notes'
import type { Failure, Next } from './notes'
import { integrations as readIntegrations, owned as readOwned } from './wire'
import type {
  CallRefusal, Integration, IntegrationUnread, ModelUnread, Owned, Problem, ProviderAccount, Runtime, Send,
} from './wire'

export type PanelView =
  /** No one is signed in yet. */
  | { readonly kind: 'waiting' }
  /** `slow` once the reading has lasted long enough that the panel says it is waiting. */
  | { readonly kind: 'reading'; readonly forUser: string; readonly slow: boolean }
  /** A reading found that the session had ended; the browser is on its way to the sign-in page. */
  | { readonly kind: 'leaving'; readonly forUser: string }
  | { readonly kind: 'failed'; readonly forUser: string; readonly failure: Failure; readonly next: Next }
  | { readonly kind: 'read'; readonly forUser: string; readonly integrations: readonly Integration[]; readonly owned: Owned }

export interface PanelDeps {
  readonly send: Send
  /** Takes the browser to the sign-in page, as the console does. */
  readonly leave: () => void
}

export interface SubscriptionsModel {
  readonly view: ReadonlySignal<PanelView>
  /** Reads what the person `userId` connected and what the server offers. A
      call for the person the panel already shows does nothing and settles at
      once, even after a failure: `retry` reads again. A call for another
      person starts over, and what was read for the first is dropped. */
  readonly load: (userId: string) => Promise<void>
  /** Reads again after a failure. Any other time it does nothing. */
  readonly retry: () => Promise<void>
}

type Found =
  | { readonly ok: true; readonly integrations: readonly Integration[]; readonly owned: Owned }
  | { readonly ok: false; readonly problem: Problem }

/** Of two problems, the one the panel acts on. A session that ended wins:
    nothing else can be read without one. */
const actedOn = (first: Problem, second: Problem): Problem => (second.kind === 'signed_out' ? second : first)

/** The two readings, side by side. */
async function readBoth(send: Send): Promise<Found> {
  const [offered, mine] = await Promise.all([readIntegrations(send), readOwned(send)])
  if (!offered.ok) return { ok: false, problem: mine.ok ? offered.problem : actedOn(offered.problem, mine.problem) }
  if (!mine.ok) return { ok: false, problem: mine.problem }
  return { ok: true, integrations: offered.value, owned: mine.value }
}

export function createSubscriptions({ send, leave }: PanelDeps): SubscriptionsModel {
  const view = signal<PanelView>({ kind: 'waiting' })
  /** The reading whose answer the panel takes. A later one, a retry or the
      reading for another person signed in meanwhile, replaces it. */
  let latest = 0

  const read = async (forUser: string, attemptsBefore: number): Promise<void> => {
    latest += 1
    const mine = latest
    const slow = setTimeout(() => {
      const now = view.peek()
      if (mine === latest && now.kind === 'reading') view.value = { ...now, slow: true }
    }, slowAfterMs)
    const found = await readBoth(send)
    clearTimeout(slow)
    if (mine !== latest) return
    if (found.ok) {
      view.value = { kind: 'read', forUser, integrations: found.integrations, owned: found.owned }
      return
    }
    if (found.problem.kind === 'signed_out') {
      // A retry keeps its button on the page while the browser leaves, so the
      // focus of the person who pressed it stays where it was (notes.ts, `Next`).
      const now = view.peek()
      view.value = now.kind === 'failed' ? { ...now, next: 'leaving' } : { kind: 'leaving', forUser }
      leave()
      return
    }
    view.value = { kind: 'failed', forUser, failure: { problem: found.problem, attempts: attemptsBefore + 1 }, next: 'idle' }
  }

  // The methods read the state with peek(): a caller inside an effect does
  // not come to depend on the panel's state.
  const load = (userId: string): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'waiting' && now.forUser === userId) return Promise.resolve()
    view.value = { kind: 'reading', forUser: userId, slow: false }
    return read(userId, 0)
  }

  const retry = (): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'failed' || now.next !== 'idle') return Promise.resolve()
    view.value = { ...now, next: 'reading' }
    return read(now.forUser, now.failure.attempts)
  }

  return { view, load, retry }
}

/** Reads the subscriptions of each person the console comes to show
    signed in. The returned function stops following. */
export function follow(frame: ReadonlySignal<View>, panel: SubscriptionsModel): () => void {
  return effect(() => {
    const now = frame.value
    if (now.kind === 'signed_in') void panel.load(now.session.userId)
  })
}

// ---- what the panel knows of each account ----

/** What the panel knows of one account before it says anything. */
export interface AccountFacts {
  readonly account: ProviderAccount
  /** The subscription the server offers for the account, or null when the
      account's subscription is not known or the server no longer offers it:
      nothing can be done with the account here. */
  readonly offered: Integration | null
  /** The Runtimes made on the account. */
  readonly runtimes: readonly Runtime[]
  /** A model was checked on the account and the server still finds it in its
      settings. A Runtime whose model it cannot read is not one a turn runs on. */
  readonly checked: boolean
  readonly keeper: KeeperOn
}

/** Whether a Keeper can run on an account here, or what stands in its way. */
export type KeeperOn =
  /** The server lets a Keeper run on the subscription, and a model was checked on the account. */
  | { readonly kind: 'can_run' }
  /** The server lets a Keeper run on the subscription; no model of the account is checked. */
  | { readonly kind: 'needs_model' }
  | { readonly kind: 'refused'; readonly refusal: CallRefusal }
  /** The account's subscription is not known, or the server no longer offers it. */
  | { readonly kind: 'not_offered' }

function keeperOn(offered: Integration | null, checked: boolean): KeeperOn {
  if (offered === null) return { kind: 'not_offered' }
  if (offered.calls.kind === 'refused') return { kind: 'refused', refusal: offered.calls.refusal }
  return checked ? { kind: 'can_run' } : { kind: 'needs_model' }
}

/** The subscriptions a Keeper may run on here. */
export const runnable = (integrations: readonly Integration[]): readonly Integration[] =>
  integrations.filter((one) => one.calls.kind === 'allowed')

/** The facts of each account, in the order the server lists the accounts.
    No Runtime is left out: an account is never unlinked
    (lib/auth/authz_provider_account.ml has only `link`), and a Runtime is
    made only on an account its maker owns (lib/auth/authz_runtime_state.ml
    refuses it with `Account_not_theirs`). */
export function accountFacts(integrations: readonly Integration[], owned: Owned): readonly AccountFacts[] {
  return owned.accounts.map((account) => {
    const integration = account.integration
    const runtimes = owned.runtimes.filter((runtime) => runtime.accountId === account.id)
    const offered = integration.read ? integrations.find((one) => one.id === integration.value) ?? null : null
    const checked = runtimes.some((runtime) => runtime.model.read)
    return { account, offered, runtimes, checked, keeper: keeperOn(offered, checked) }
  })
}

// ---- words ----

/** The name of the subscription of an account: the name the operator gave
    the provider, its id when the name is empty, or the id the login named
    when the server no longer offers it. */
function subscriptionName(account: ProviderAccount, offered: Integration | null): string {
  if (!account.integration.read) return '어떤 구독인지 알 수 없는 계정'
  return offered === null ? account.integration.value : integrationName(offered)
}

const integrationName = (integration: Integration): string =>
  integration.displayName === '' ? integration.id : integration.displayName

function integrationUnreadWords(unread: IntegrationUnread | 'unrecognised'): string {
  switch (unread) {
    case 'login_receipt_missing': return '이 계정의 로그인 기록이 없어요.'
    case 'login_receipt_unreadable': return '이 계정의 로그인 기록을 읽지 못했어요. 이 서버를 운영하는 사람에게 알려 주세요.'
    case 'unrecognised': return '서버가 이 계정의 구독을 알려 주지 않았어요.'
  }
}

/** Why a Keeper does not run on an account of the subscription `name` here. */
function refusedWords(refusal: CallRefusal, name: string): string {
  switch (refusal) {
    case 'native_tools_reach_other_homes':
      return `이 서버는 다른 사람의 폴더에 닿을 수 있는 도구를 막아요. 그래서 ${name} 구독으로는 Keeper를 실행할 수 없어요.`
    case 'native_tools_reach_person_homes':
      return `이 서버에는 다른 사람의 폴더가 있어서 그 폴더에 닿을 수 있는 도구를 막아요. 그래서 ${name} 구독으로는 Keeper를 실행할 수 없어요.`
    case 'native_unpublished':
      return `서버가 아직 도구를 허용할지 정하지 않았어요. 그래서 지금은 ${name} 구독으로 Keeper를 실행할 수 없어요.`
    case 'person_homes_unread':
      return `서버가 사람들의 폴더를 확인하지 못했어요. 그래서 지금은 ${name} 구독으로 Keeper를 실행할 수 없어요. 이 서버를 운영하는 사람에게 알려 주세요.`
    case 'unrecognised':
      return `이 서버는 ${name} 구독으로 Keeper를 실행하지 않아요.`
  }
}

/** Why the model of a Runtime is not known, or null when the row of its
    account already says it: the subscription is not known, or the server no
    longer declares it and so does not offer it. */
function modelUnreadWords(unread: ModelUnread | 'unrecognised'): string | null {
  switch (unread) {
    case 'account_integration_unread': return null
    case 'template_not_declared': return null
    case 'configuration_unavailable': return '서버 설정을 읽지 못해서 모델을 알 수 없어요.'
    case 'runtime_not_bound': return '서버 설정이 바뀌어서 이 구독으로 이 모델을 부를 수 없어요.'
    case 'unrecognised': return '서버가 이 모델을 알려 주지 않았어요.'
  }
}

// ---- the panel ----

/** What an account can do here, in words and a border, never in colour alone.
    Nothing is suggested for an account the server offers no subscription for:
    nothing can be done with it here. */
function Chips({ facts }: { readonly facts: AccountFacts }): VNode {
  const { keeper, checked } = facts
  if (keeper.kind === 'not_offered') return html`<p class="chips"><span class="chip chip-todo">여기서 쓸 수 없음</span></p>`
  return html`
    <p class="chips">
      <span class=${checked ? 'chip' : 'chip chip-todo'}>${checked ? '모델 확인됨' : '모델 확인 필요'}</span>
      ${keeper.kind === 'can_run' ? html`<span class="chip">Keeper 실행 가능</span>` : null}
      ${keeper.kind === 'refused' ? html`<span class="chip chip-todo">Keeper 실행 불가</span>` : null}
    </p>
  `
}

function UnreadModel({ unread }: { readonly unread: ModelUnread | 'unrecognised' }): VNode {
  const why = modelUnreadWords(unread)
  return why === null ? html`<span>알 수 없는 모델</span>` : html`<span>알 수 없는 모델</span> <span class="hint">${why}</span>`
}

function Models({ runtimes }: { readonly runtimes: readonly Runtime[] }): VNode {
  if (runtimes.length === 0) return html`<p class="hint">아직 확인한 모델이 없어요.</p>`
  return html`
    <ul class="models">
      ${runtimes.map((runtime) => html`
        <li key=${runtime.id}>
          ${runtime.model.read ? html`<span class="model">${runtime.model.value}</span>` : html`<${UnreadModel} unread=${runtime.model.unread} />`}
        </li>
      `)}
    </ul>
  `
}

function AccountRow({ facts }: { readonly facts: AccountFacts }): VNode {
  const { account, offered } = facts
  const name = subscriptionName(account, offered)
  return html`
    <li class="row">
      <h3 class="row-title">${name}</h3>
      <p class="hint">계정 <span class="mono">${idTail(account.id)}</span></p>
      <${Chips} facts=${facts} />
      ${account.integration.read
        ? (offered === null ? html`<p class="hint">이 서버는 이 구독을 더는 제공하지 않아요.</p>` : null)
        : html`<p class="hint">${integrationUnreadWords(account.integration.unread)}</p>`}
      ${facts.keeper.kind === 'refused' ? html`<p class="hint">${refusedWords(facts.keeper.refusal, name)}</p>` : null}
      <${Models} runtimes=${facts.runtimes} />
    </li>
  `
}

/** What the server lets a Keeper run on, said before anything is connected. */
function Offer({ integrations }: { readonly integrations: readonly Integration[] }): VNode {
  const names = runnable(integrations).map(integrationName)
  if (integrations.length === 0) return html`<p class="hint">이 서버에는 연결할 수 있는 구독이 없어요.</p>`
  if (names.length === 0) return html`<p class="hint">이 서버에서는 지금 어떤 구독으로도 Keeper를 실행할 수 없어요.</p>`
  return html`<p class="hint">이 서버에서 Keeper를 실행할 수 있는 구독: ${names.join(', ')}</p>`
}

function Read({ integrations, owned }: { readonly integrations: readonly Integration[]; readonly owned: Owned }): VNode {
  if (owned.accounts.length === 0) return html`<p>아직 연결한 구독이 없어요.</p>`
  return html`
    <ul class="rows">
      ${accountFacts(integrations, owned).map((facts) => html`<${AccountRow} key=${facts.account.id} facts=${facts} />`)}
    </ul>
  `
}

function PanelBody({ view, onRetry }: { readonly view: PanelView; readonly onRetry: () => void }): VNode {
  switch (view.kind) {
    case 'waiting':
      return html`<p class="hint" role="status"></p>`
    case 'reading':
      return html`<p class="hint" role="status">${view.slow ? '구독을 불러오고 있어요…' : ''}</p>`
    case 'leaving':
      return html`<p class="hint" role="status">세션이 끝났어요. 로그인 화면으로 이동해요…</p>`
    case 'failed':
      return html`
        <${ProblemNote} key=${view.failure.attempts} title="구독을 불러오지 못했어요" failure=${view.failure} />
        <${Retry} label="다시 시도" next=${view.next} onRetry=${onRetry} />
      `
    case 'read':
      return html`
        <${Offer} integrations=${view.integrations} />
        <${Read} integrations=${view.integrations} owned=${view.owned} />
        <p class="hint" role="status"></p>
      `
  }
}

export function SubscriptionsPanel({ model }: { readonly model: SubscriptionsModel }): VNode {
  const view = model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const shown = useRef(view.kind)
  // A retry that read takes the pressed button away. The focus then goes to
  // the heading of the panel, not to the body of the page; a focus the person
  // moved elsewhere meanwhile stays.
  useEffect(() => {
    const fell = document.activeElement === null || document.activeElement === document.body
    if (shown.current === 'failed' && view.kind === 'read' && fell) heading.current?.focus()
    shown.current = view.kind
  }, [view.kind])
  return html`
    <section aria-labelledby="subscriptions-heading">
      <h2 id="subscriptions-heading" ref=${heading} tabindex="-1">구독</h2>
      <p class="hint">내 Keeper는 내가 연결한 구독으로 일해요. 다른 구성원은 내 구독을 쓸 수 없어요.</p>
      <${PanelBody} view=${view} onRetry=${() => { void model.retry() }} />
    </section>
  `
}
