// The subscriptions of a signed-in person: the accounts they connected, the
// Runtimes made on them, and whether a Keeper may run on each here. A
// person learns before pressing anything what an account cannot do.
//
// `createSubscriptions` reads them for the person the console shows;
// `SubscriptionsPanel` draws whatever state it is given.

import { effect, signal, type ReadonlySignal } from '@preact/signals'
import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { View } from './console'
import { ProblemNote, Retry, idTail, slowAfterMs } from './notes'
import type { Failure, Next } from './notes'
import { integrations as readIntegrations, owned as readOwned } from './wire'
import type {
  Calls, Integration, IntegrationUnread, ModelUnread, Owned, Problem, ProviderAccount, Runtime, Send,
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
      call for the person the panel reads or has read joins or does nothing;
      a call for another person starts over, and what was read for the
      first is dropped. */
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
  let reading: { readonly forUser: string; readonly done: Promise<void> } | null = null

  const read = async (forUser: string, attemptsBefore: number): Promise<void> => {
    const slow = setTimeout(() => {
      const now = view.peek()
      if (now.kind === 'reading' && now.forUser === forUser) view.value = { ...now, slow: true }
    }, slowAfterMs)
    const found = await readBoth(send)
    clearTimeout(slow)
    // Another person was signed in while the panel read: what it read is not theirs.
    const now = view.peek()
    if (now.kind === 'waiting' || now.forUser !== forUser) return
    if (found.ok) {
      view.value = { kind: 'read', forUser, integrations: found.integrations, owned: found.owned }
      return
    }
    if (found.problem.kind === 'signed_out') {
      view.value = { kind: 'leaving', forUser }
      leave()
      return
    }
    view.value = { kind: 'failed', forUser, failure: { problem: found.problem, attempts: attemptsBefore + 1 }, next: 'idle' }
  }

  const start = (forUser: string, run: () => Promise<void>): Promise<void> => {
    const done = run().finally(() => { if (reading?.done === done) reading = null })
    reading = { forUser, done }
    return done
  }

  // The methods read the state with peek(): a caller inside an effect does
  // not come to depend on the panel's state.
  const load = (userId: string): Promise<void> => {
    if (reading !== null && reading.forUser === userId) return reading.done
    const now = view.peek()
    if (now.kind !== 'waiting' && now.forUser === userId) return Promise.resolve()
    view.value = { kind: 'reading', forUser: userId, slow: false }
    return start(userId, () => read(userId, 0))
  }

  const retry = (): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'failed' || now.next !== 'idle') return Promise.resolve()
    view.value = { ...now, next: 'reading' }
    return start(now.forUser, () => read(now.forUser, now.failure.attempts))
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

// ---- words ----

/** The name of the subscription of an account: the name the operator gave
    the provider, its id when the name is empty, or the id the login named
    when the server no longer offers it. */
function subscriptionName(account: ProviderAccount, offered: Integration | undefined): string {
  if (!account.integration.read) return '어떤 구독인지 알 수 없는 계정'
  if (offered === undefined) return account.integration.value
  return offered.displayName === '' ? offered.id : offered.displayName
}

function integrationUnreadWords(unread: IntegrationUnread | 'unrecognised'): string {
  switch (unread) {
    case 'login_receipt_missing': return '이 계정의 로그인 기록이 없어요.'
    case 'login_receipt_unreadable': return '이 계정의 로그인 기록을 읽지 못했어요. 이 서버를 운영하는 사람에게 알려 주세요.'
    case 'unrecognised': return '서버가 이 계정의 구독을 알려 주지 않았어요.'
  }
}

/** Why a Keeper does not run on an account of the subscription `name` here. */
function refusedWords(calls: Extract<Calls, { readonly kind: 'refused' }>, name: string): string {
  switch (calls.refusal) {
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
    case 'runtime_not_bound': return '서버 설정에 이 모델이 없어요.'
    case 'unrecognised': return '서버가 이 모델을 알려 주지 않았어요.'
  }
}

// ---- the panel ----

/** What an account can do here, in words and a border, never in colour alone.
    `calls` is null when the server does not offer the subscription of the
    account: nothing can be done with it here, so nothing is suggested. A
    model counts as checked while the server still finds it in its settings;
    a Runtime whose model it cannot read is not one a turn runs on. */
function Chips({ runtimes, calls }: { readonly runtimes: readonly Runtime[]; readonly calls: Calls | null }): VNode {
  if (calls === null) return html`<p class="chips"><span class="chip chip-todo">여기서 쓸 수 없음</span></p>`
  const checked = runtimes.some((runtime) => runtime.model.read)
  return html`
    <p class="chips">
      <span class=${checked ? 'chip' : 'chip chip-todo'}>${checked ? '모델 확인됨' : '모델 확인 필요'}</span>
      <span class=${calls.kind === 'allowed' ? 'chip' : 'chip chip-todo'}>${calls.kind === 'allowed' ? 'Keeper 실행 가능' : 'Keeper 실행 불가'}</span>
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

function AccountRow({ account, runtimes, offered }: {
  readonly account: ProviderAccount
  readonly runtimes: readonly Runtime[]
  readonly offered: readonly Integration[]
}): VNode {
  const integrationId = account.integration.read ? account.integration.value : null
  const integration = integrationId === null ? undefined : offered.find((one) => one.id === integrationId)
  const name = subscriptionName(account, integration)
  const calls = integration === undefined ? null : integration.calls
  return html`
    <li class="row">
      <h3 class="row-title">${name}</h3>
      <p class="hint">계정 <span class="mono">${idTail(account.id)}</span></p>
      <${Chips} runtimes=${runtimes} calls=${calls} />
      ${account.integration.read
        ? (integration === undefined ? html`<p class="hint">이 서버는 이 구독을 더는 제공하지 않아요.</p>` : null)
        : html`<p class="hint">${integrationUnreadWords(account.integration.unread)}</p>`}
      ${calls !== null && calls.kind === 'refused' ? html`<p class="hint">${refusedWords(calls, name)}</p>` : null}
      <${Models} runtimes=${runtimes} />
    </li>
  `
}

/** A row for each account, with the Runtimes made on it. No Runtime is left
    out: an account is never unlinked (lib/auth/authz_provider_account.ml has
    only `link`), and a Runtime is made only on an account its maker owns
    (lib/auth/authz_runtime_state.ml refuses it with `Account_not_theirs`). */
function Read({ integrations, owned }: { readonly integrations: readonly Integration[]; readonly owned: Owned }): VNode {
  if (owned.accounts.length === 0) return html`<p>아직 연결한 구독이 없어요.</p>`
  return html`
    <ul class="rows">
      ${owned.accounts.map((account) => html`
        <${AccountRow}
          key=${account.id}
          account=${account}
          runtimes=${owned.runtimes.filter((runtime) => runtime.accountId === account.id)}
          offered=${integrations} />
      `)}
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
        <${Read} integrations=${view.integrations} owned=${view.owned} />
        <p class="hint" role="status"></p>
      `
  }
}

export function SubscriptionsPanel({ model }: { readonly model: SubscriptionsModel }): VNode {
  return html`
    <section aria-labelledby="subscriptions-heading">
      <h2 id="subscriptions-heading">구독</h2>
      <p class="hint">내 구독을 연결하면 그 구독으로 내 Keeper가 일해요. 다른 구성원은 내 구독을 쓸 수 없어요.</p>
      <${PanelBody} view=${model.view.value} onRetry=${() => { void model.retry() }} />
    </section>
  `
}
