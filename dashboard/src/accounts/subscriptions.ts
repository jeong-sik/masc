// The subscriptions of a signed-in person: the accounts they connected, the
// Runtimes made on them, and whether a Keeper may run on each here. A
// person learns before pressing anything what an account cannot do.
//
// `createSubscriptions` reads them for the person the console shows and
// holds the person's connecting of a subscription (connect.ts) and checks of
// a model (check.ts);
// `SubscriptionsPanel` draws whatever state it is given, and
// account-rows.ts a card for each account.

import { effect, signal, type ReadonlySignal } from '@preact/signals'
import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { VNode } from 'preact'
import { createChecks } from './check'
import type { ChecksModel } from './check'
import { createConnect } from './connect'
import type { ConnectModel } from './connect'
import { ConnectArea } from './connect-area'
import type { View } from './console'
import { AccountList } from './account-rows'
import { ProblemNote, Retry, fell, idTail, sessionEndedWords, slowAfterMs } from './notes'
import type { Failure, Next } from './notes'
import { createKeyAdds } from './key-add'
import type { KeyAddModel } from './key-add'
import { KeyArea } from './key-area'
import { createRemovals } from './key-remove'
import type { Gone, RemovalsModel } from './key-remove'
import { checkable, integrationName, integrations as readIntegrations, owned as readOwned } from './wire'
import type { Integration, Owned, Problem, Send, Session } from './wire'

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
  /** Reads what the person of `session` connected and what the server
      offers. A call for the person the panel already shows only keeps their
      newest session and settles at once, even after a failure: `retry` reads
      again. A call after `stop` for the person the panel was for reads
      again and keeps their login and checks. A call for another person
      starts over: what was read for the first is dropped, and a login they
      started is left behind. */
  readonly load: (session: Session) => Promise<void>
  /** Reads again after a failure. Any other time it does nothing. */
  readonly retry: () => Promise<void>
  /** The connecting of a subscription by the person the panel shows. */
  readonly connecting: ConnectModel
  /** The checks of a model of an account by the person the panel shows. */
  readonly checking: ChecksModel
  /** The giving of an API key by the person the panel shows. */
  readonly adding: KeyAddModel
  /** The removals of a key account by the person the panel shows. */
  readonly removing: RemovalsModel
  /** Forgets what was read once the console shows no one signed in: the
      account changed, or the browser leaves. A reading still under way then
      changes nothing, and the next `load` reads again, for the same person
      too. A login and the checks stay the person's until another person is
      shown. */
  readonly stop: () => void
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
  /** The session of the person the panel shows. A login sends its token. */
  let session: Session | null = null
  /** The person whose login and checks the panel holds. `stop` keeps them. */
  let person: string | null = null
  /** How many logins and checks asked for the panel to be read again. A
      reading that began before the latest of them may not hold what it
      changed, and is read again. */
  let landed = 0

  const read = async (forUser: string, attemptsBefore: number): Promise<void> => {
    latest += 1
    const mine = latest
    const asOf = landed
    const slow = setTimeout(() => {
      const now = view.peek()
      if (mine === latest && now.kind === 'reading') view.value = { ...now, slow: true }
    }, slowAfterMs)
    const found = await readBoth(send)
    clearTimeout(slow)
    if (mine !== latest) return
    if (found.ok) {
      if (landed !== asOf) return read(forUser, attemptsBefore)
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

  /** Reads again what the panel shows, which stays on the page meanwhile. A
      reading or retry under way reads again once it ends. */
  const refresh = (): Promise<void> => {
    landed += 1
    const now = view.peek()
    return now.kind === 'read' ? read(now.forUser, 0) : Promise.resolve()
  }

  const token = (): string | null => session?.csrfToken ?? null
  const connecting = createConnect({ send, leave, token, refresh })
  const checking = createChecks({ send, leave, token, refresh })
  const adding = createKeyAdds({ send, leave, token, refresh })
  const removing = createRemovals({ send, leave, token, refresh })

  // The methods read the state with peek(): a caller inside an effect does
  // not come to depend on the panel's state.
  const load = (next: Session): Promise<void> => {
    const now = view.peek()
    session = next
    if (now.kind !== 'waiting' && now.forUser === next.userId) return Promise.resolve()
    if (next.userId !== person) {
      person = next.userId
      connecting.reset()
      checking.reset()
      adding.reset()
      removing.reset()
    }
    view.value = { kind: 'reading', forUser: next.userId, slow: false }
    return read(next.userId, 0)
  }

  const retry = (): Promise<void> => {
    const now = view.peek()
    if (now.kind !== 'failed' || now.next !== 'idle') return Promise.resolve()
    view.value = { ...now, next: 'reading' }
    return read(now.forUser, now.failure.attempts)
  }

  const stop = (): void => {
    if (view.peek().kind === 'waiting') return
    latest += 1
    view.value = { kind: 'waiting' }
  }

  return { view, load, retry, connecting, checking, adding, removing, stop }
}

/** Reads the subscriptions of each person the console comes to show
    signed in, and stops whenever it shows anything else, so the person
    shown again after another account was in the browser is read again. The
    returned function stops following. */
export function follow(frame: ReadonlySignal<View>, panel: SubscriptionsModel): () => void {
  return effect(() => {
    const now = frame.value
    if (now.kind === 'signed_in') void panel.load(now.session)
    else panel.stop()
  })
}

/** The subscriptions an account connected now comes to run a Keeper on, said
    before anything is connected: those with a model to check. An account
    checked earlier is not what this line is about; its card says what it
    can do. */
function Offer({ integrations }: { readonly integrations: readonly Integration[] }): VNode {
  const names = integrations.filter(checkable).map(integrationName)
  if (integrations.length === 0) return html`<p class="hint">이 서버에는 연결할 수 있는 구독이 없어요.</p>`
  if (names.length === 0) return html`<p class="hint">이 서버에는 지금 새로 연결해서 Keeper를 실행할 수 있는 구독이 없어요.</p>`
  return html`<p class="hint">지금 새로 연결해서 Keeper를 실행할 수 있는 구독: ${names.join(', ')}</p>`
}

/** What the line of the panel says of the account the latest removal took out of the list. */
function goneWords(gone: Gone | null): string {
  if (gone === null) return ''
  return gone.already ? `계정 ${idTail(gone.accountId)}은 이미 없는 계정이에요.` : `계정 ${idTail(gone.accountId)}을 없앴어요. 이 서버에 그 key 는 없어요.`
}

function PanelBody({ view, connecting, checking, adding, removing, onRetry }: {
  readonly view: PanelView
  readonly connecting: ConnectModel
  readonly checking: ChecksModel
  readonly adding: KeyAddModel
  readonly removing: RemovalsModel
  readonly onRetry: () => void
}): VNode {
  switch (view.kind) {
    case 'waiting':
      return html`<p class="hint" role="status"></p>`
    case 'reading':
      return html`<p class="hint" role="status">${view.slow ? '구독을 불러오고 있어요…' : ''}</p>`
    case 'leaving':
      return html`<p class="hint" role="status">${sessionEndedWords}</p>`
    case 'failed':
      return html`
        <${ProblemNote} key=${view.failure.attempts} title="구독을 불러오지 못했어요" failure=${view.failure} />
        <${Retry} label="다시 시도" next=${view.next} onRetry=${onRetry} />
      `
    case 'read': {
      const takingKey = view.integrations.filter((integration) => integration.takesKey)
      return html`
        <${Offer} integrations=${view.integrations} />
        ${view.integrations.length === 0 ? null : html`<${ConnectArea} model=${connecting} integrations=${view.integrations} />`}
        ${takingKey.length === 0 ? null : html`<${KeyArea} model=${adding} integrations=${takingKey} />`}
        <${AccountList} integrations=${view.integrations} owned=${view.owned} checks=${checking} removals=${removing} />
        <p class="hint" role="status">${goneWords(removing.gone.value)}</p>
      `
    }
  }
}

export function SubscriptionsPanel({ model }: { readonly model: SubscriptionsModel }): VNode {
  const view = model.view.value
  const heading = useRef<HTMLHeadingElement>(null)
  const shown = useRef(view.kind)
  // A retry that read takes the pressed button away, and a reading that
  // failed after a login takes the connect area away. The focus then goes to
  // the heading of the panel, not to the body of the page; a focus the person
  // moved elsewhere meanwhile stays. The first reading takes nothing away.
  useEffect(() => {
    const before = shown.current
    shown.current = view.kind
    const hadControls = before === 'failed' || before === 'read'
    if (before !== view.kind && hadControls && fell()) heading.current?.focus()
  }, [view.kind])
  // An account that was removed takes its card away, and the pressed button
  // with it. The focus goes to the heading of the panel in the same way.
  const gone = model.removing.gone.value
  useEffect(() => {
    if (gone !== null && fell()) heading.current?.focus()
  }, [gone])
  return html`
    <section aria-labelledby="subscriptions-heading">
      <h2 id="subscriptions-heading" ref=${heading} tabindex="-1">구독</h2>
      <p class="hint">내 Keeper는 내가 연결한 구독으로 일해요. 다른 구성원은 내 구독을 쓸 수 없어요.</p>
      <${PanelBody} view=${view} connecting=${model.connecting} checking=${model.checking} adding=${model.adding} removing=${model.removing} onRetry=${() => { void model.retry() }} />
    </section>
  `
}
