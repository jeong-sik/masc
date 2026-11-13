// @vitest-environment happy-dom
//
// The subscriptions panel: what it reads for whom, how it moves between its
// states, and that each state passes the accessibility rules. What a state
// says and where it puts things is not checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import type { View } from './console'
import { slowAfterMs } from './notes'
import { SubscriptionsPanel, accountFacts, createSubscriptions, follow, runnable } from './subscriptions'
import type { AccountFacts, PanelView, SubscriptionsModel } from './subscriptions'
import { paths } from './wire'
import type { Integration, Send } from './wire'

interface Sent { readonly path: string; readonly init: RequestInit }
type Scripted = Response | 'no answer' | Promise<Response>

/** Requests no answer was scripted for; each test checks at its end that there was none. */
const unscripted: string[] = []

/** A `send` that answers each path from its own list, in order, and keeps what was sent. */
function answering(byPath: Readonly<Record<string, readonly Scripted[]>>): { readonly send: Send; readonly sent: Sent[] } {
  const sent: Sent[] = []
  const left = new Map(Object.entries(byPath).map(([path, answers]) => [path, [...answers]]))
  const send: Send = (path, init) => {
    sent.push({ path, init })
    const next = left.get(path)?.shift()
    if (next === undefined) {
      unscripted.push(path)
      return Promise.reject(new Error(`no answer was scripted for ${path}`))
    }
    return next === 'no answer' ? Promise.reject(new TypeError('fetch failed')) : Promise.resolve(next)
  }
  return { send, sent }
}

/** An answer that comes when the test says so. */
function later(): { readonly answer: Promise<Response>; readonly give: (response: Response) => void } {
  let give: (response: Response) => void = () => { throw new Error('the answer was given before it was asked for') }
  const answer = new Promise<Response>((resolve) => { give = resolve })
  return { answer, give: (response) => { give(response) } }
}

const person = 'usr_0123456789'
const other = 'usr_9876543210'
const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

const claude = { integration_id: 'claude_code', display_name: 'Claude Code', models: ['claude-sonnet-5'], calls: 'allowed' }
const codex = { integration_id: 'codex', display_name: 'Codex', models: ['gpt-5.5'], calls: 'refused', refusal: 'native_tools_reach_other_homes' }
const offered = (): Response => json(200, { integrations: [claude, codex] })
const ownedNothing = (): Response => json(200, { provider_accounts: [], runtimes: [] })
const ownedOne = (): Response => json(200, {
  provider_accounts: [{ provider_account_id: 'acct_1', integration_id: 'claude_code' }],
  runtimes: [{ runtime_id: 'acct_1.claude-sonnet-5', provider_account_id: 'acct_1', model: 'claude-sonnet-5' }],
})
const notReady = (): Response => json(503, { error: 'the files are being read again' })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

function start(byPath: Readonly<Record<string, readonly Scripted[]>>) {
  const { send, sent } = answering(byPath)
  const leave = vi.fn()
  return { panel: createSubscriptions({ send, leave }), sent, leave }
}

const kind = (panel: SubscriptionsModel): string => {
  const view = panel.view.value
  return view.kind === 'waiting' ? 'waiting' : `${view.kind} for ${view.forUser}`
}

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  expect(unscripted.splice(0), 'requests that no answer was scripted for').toEqual([])
})

describe('reading the subscriptions', () => {
  it('reads what the person connected and what the server offers, with the cookie and no bearer token', async () => {
    const { panel, sent } = start({ [paths.integrations]: [offered()], [paths.owned]: [ownedOne()] })
    await panel.load(person)
    expect(panel.view.value).toEqual({
      kind: 'read',
      forUser: person,
      integrations: [
        { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], calls: { kind: 'allowed' } },
        { id: 'codex', displayName: 'Codex', models: ['gpt-5.5'], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' } },
      ],
      owned: {
        accounts: [{ id: 'acct_1', integration: { read: true, value: 'claude_code' } }],
        runtimes: [{ id: 'acct_1.claude-sonnet-5', accountId: 'acct_1', model: { read: true, value: 'claude-sonnet-5' } }],
      },
    })
    expect(sent.map((one) => [one.path, one.init.method, one.init.credentials]).sort()).toEqual([
      [paths.owned, 'GET', 'same-origin'],
      [paths.integrations, 'GET', 'same-origin'],
    ].sort())
    expect(sent.map((one) => new Headers(one.init.headers).has('authorization'))).toEqual([false, false])
  })

  it('reads once for a person however often it is asked', async () => {
    const { panel, sent } = start({ [paths.integrations]: [offered()], [paths.owned]: [ownedNothing()] })
    await Promise.all([panel.load(person), panel.load(person)])
    await panel.load(person)
    expect([kind(panel), sent.length]).toEqual([`read for ${person}`, 2])
  })

  it('drops what it read for a person who is no longer the one shown', async () => {
    const first = later()
    const { panel } = start({ [paths.integrations]: [first.answer, offered()], [paths.owned]: [ownedOne(), ownedNothing()] })
    const forPerson = panel.load(person)
    const forOther = panel.load(other)
    await forOther
    first.give(offered())
    await forPerson
    const view = panel.view.value
    expect([kind(panel), view.kind === 'read' ? view.owned.accounts.length : null]).toEqual([`read for ${other}`, 0])
  })

  it('says a failure, counts the failures in a row, and reads again on a retry', async () => {
    const { panel } = start({ [paths.integrations]: [notReady(), 'no answer', offered()], [paths.owned]: [ownedNothing(), ownedNothing(), ownedNothing()] })
    await panel.load(person)
    const failed = (): unknown => {
      const view = panel.view.value
      return view.kind === 'failed' ? [view.failure.problem.kind, view.failure.attempts, view.next] : view.kind
    }
    expect(failed()).toEqual(['refused', 1, 'idle'])
    const retried = panel.retry()
    expect(failed()).toEqual(['refused', 1, 'reading'])
    await retried
    expect(failed()).toEqual(['unreachable', 2, 'idle'])
    await panel.retry()
    expect(kind(panel)).toBe(`read for ${person}`)
  })

  it('reads again only after a failure', async () => {
    const { panel, sent } = start({ [paths.integrations]: [offered()], [paths.owned]: [ownedNothing()] })
    await panel.retry()
    await panel.load(person)
    await panel.retry()
    expect([kind(panel), sent.length]).toEqual([`read for ${person}`, 2])
  })

  it('reads once on a retry however often it is asked', async () => {
    const { panel, sent } = start({ [paths.integrations]: [notReady(), offered()], [paths.owned]: [ownedNothing(), ownedNothing()] })
    await panel.load(person)
    await Promise.all([panel.retry(), panel.retry()])
    expect([kind(panel), sent.length]).toEqual([`read for ${person}`, 4])
  })

  it('does nothing for a person whose reading failed: the retry reads again', async () => {
    const { panel, sent } = start({ [paths.integrations]: [notReady()], [paths.owned]: [ownedNothing()] })
    await panel.load(person)
    await panel.load(person)
    expect([kind(panel), sent.length]).toEqual([`failed for ${person}`, 2])
  })

  it('takes the answer of the newest reading, whatever an older one ends with', async () => {
    const first = later()
    const { panel } = start({ [paths.integrations]: [first.answer, offered(), offered()], [paths.owned]: [ownedOne(), ownedNothing(), ownedOne()] })
    const older = panel.load(person)
    await panel.load(other)
    await panel.load(person)
    first.give(notReady())
    await older
    expect(kind(panel)).toBe(`read for ${person}`)
  })

  it('keeps the page of a failed reading while it leaves after a retry finds no session', async () => {
    const { panel, leave } = start({ [paths.integrations]: [notReady(), offered()], [paths.owned]: [ownedNothing(), noSession()] })
    await panel.load(person)
    await panel.retry()
    const view = panel.view.value
    expect([view.kind, view.kind === 'failed' ? view.next : null, leave.mock.calls.length]).toEqual(['failed', 'leaving', 1])
  })

  it.each([
    ['the subscriptions', { [paths.integrations]: [offered()], [paths.owned]: [noSession()] }],
    ['the offer, while the other reading failed', { [paths.integrations]: [noSession()], [paths.owned]: [notReady()] }],
    ['the subscriptions, while the offer failed', { [paths.integrations]: [notReady()], [paths.owned]: [noSession()] }],
  ])('leaves for the sign-in page when a reading of %s finds no session', async (_name, byPath) => {
    const { panel, leave } = start(byPath)
    await panel.load(person)
    expect([kind(panel), leave.mock.calls.length]).toEqual([`leaving for ${person}`, 1])
  })

  it('says it is waiting only once a reading is slow', async () => {
    vi.useFakeTimers()
    const answer = later()
    const { panel } = start({ [paths.integrations]: [answer.answer], [paths.owned]: [ownedNothing()] })
    const done = panel.load(person)
    const slow = (): unknown => (panel.view.value.kind === 'reading' ? panel.view.value.slow : panel.view.value.kind)
    await vi.advanceTimersByTimeAsync(slowAfterMs - 1)
    expect(slow()).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    expect(slow()).toBe(true)
    answer.give(offered())
    await done
    expect(kind(panel)).toBe(`read for ${person}`)
  })

  it('says a reading is slow only once it has lasted long enough itself', async () => {
    vi.useFakeTimers()
    const first = later()
    const second = later()
    const { panel } = start({ [paths.integrations]: [first.answer, second.answer], [paths.owned]: [ownedNothing(), ownedNothing()] })
    const slow = (): unknown => (panel.view.value.kind === 'reading' ? panel.view.value.slow : panel.view.value.kind)
    const older = panel.load(person)
    await vi.advanceTimersByTimeAsync(slowAfterMs - 1)
    const newer = panel.load(other)
    await vi.advanceTimersByTimeAsync(1)
    const whenTheOlderWouldBeSlow = slow()
    await vi.advanceTimersByTimeAsync(slowAfterMs - 1)
    expect([whenTheOlderWouldBeSlow, slow()]).toEqual([false, true])
    first.give(offered())
    second.give(offered())
    await Promise.all([older, newer])
    expect(kind(panel)).toBe(`read for ${other}`)
  })
})

describe('following the console', () => {
  const session = { userId: person, csrfToken: 'token' }
  const who = { id: person, role: 'member' } as const

  it('reads for each person the console comes to show signed in, and no more', () => {
    const frame = signal<View>({ kind: 'reading', slow: false })
    const panel = { view: signal<PanelView>({ kind: 'waiting' }), load: vi.fn(() => Promise.resolve()), retry: vi.fn(() => Promise.resolve()) }
    const stop = follow(frame, panel)
    frame.value = { kind: 'signed_in', session, who, signOut: { kind: 'idle' } }
    frame.value = { kind: 'signed_in', session, who, signOut: { kind: 'sending' } }
    frame.value = { kind: 'changed', next: 'idle' }
    frame.value = { kind: 'signed_in', session: { userId: other, csrfToken: 'other' }, who: { id: other, role: 'member' }, signOut: { kind: 'idle' } }
    stop()
    frame.value = { kind: 'signed_in', session, who, signOut: { kind: 'idle' } }
    expect(panel.load.mock.calls).toEqual([[person], [person], [other]])
  })

  it('reads once for a person whose console moves between states', async () => {
    const frame = signal<View>({ kind: 'reading', slow: false })
    const { panel, sent } = start({ [paths.integrations]: [offered()], [paths.owned]: [ownedNothing()] })
    const stop = follow(frame, panel)
    frame.value = { kind: 'signed_in', session, who, signOut: { kind: 'idle' } }
    frame.value = { kind: 'signed_in', session, who, signOut: { kind: 'sending' } }
    await vi.waitFor(() => { expect(kind(panel)).toBe(`read for ${person}`) })
    stop()
    expect(sent.length).toBe(2)
  })
})

describe('what the panel knows of each account', () => {
  const integrations: readonly Integration[] = [
    { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], calls: { kind: 'allowed' } },
    { id: 'codex', displayName: 'Codex', models: ['gpt-5.5'], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' } },
  ]
  const facts = accountFacts(integrations, {
    accounts: [
      { id: 'acct_gone', integration: { read: true, value: 'muse' } },
      { id: 'acct_claude', integration: { read: true, value: 'claude_code' } },
      { id: 'acct_codex', integration: { read: true, value: 'codex' } },
      { id: 'acct_unknown', integration: { read: false, unread: 'login_receipt_missing' } },
      { id: 'acct_new', integration: { read: true, value: 'claude_code' } },
    ],
    runtimes: [
      { id: 'acct_codex.gpt-5.5', accountId: 'acct_codex', model: { read: true, value: 'gpt-5.5' } },
      { id: 'acct_claude.claude-opus-9', accountId: 'acct_claude', model: { read: false, unread: 'runtime_not_bound' } },
      { id: 'acct_gone.muse-1', accountId: 'acct_gone', model: { read: false, unread: 'template_not_declared' } },
      { id: 'acct_claude.claude-sonnet-5', accountId: 'acct_claude', model: { read: true, value: 'claude-sonnet-5' } },
      { id: 'acct_unknown.x', accountId: 'acct_unknown', model: { read: false, unread: 'account_integration_unread' } },
    ],
  })
  const byAccount = <T>(pick: (one: AccountFacts) => T) => facts.map((one) => [one.account.id, pick(one)])

  it('keeps the order the server lists the accounts in', () => {
    expect(facts.map((one) => one.account.id)).toEqual(['acct_gone', 'acct_claude', 'acct_codex', 'acct_unknown', 'acct_new'])
  })

  it('finds the subscription the server offers for an account, and none when it is not known or no longer offered', () => {
    expect(byAccount((one) => (one.offered === null ? null : one.offered.id))).toEqual([
      ['acct_gone', null], ['acct_claude', 'claude_code'], ['acct_codex', 'codex'], ['acct_unknown', null], ['acct_new', 'claude_code'],
    ])
  })

  it('gives an account only the Runtimes made on it', () => {
    expect(byAccount((one) => one.runtimes.map((runtime) => runtime.id))).toEqual([
      ['acct_gone', ['acct_gone.muse-1']],
      ['acct_claude', ['acct_claude.claude-opus-9', 'acct_claude.claude-sonnet-5']],
      ['acct_codex', ['acct_codex.gpt-5.5']],
      ['acct_unknown', ['acct_unknown.x']],
      ['acct_new', []],
    ])
  })

  it('says whether a Keeper can run on an account, or what stands in its way', () => {
    expect(byAccount((one) => one.keeper)).toEqual([
      ['acct_gone', { kind: 'not_offered' }],
      ['acct_claude', { kind: 'can_run' }],
      ['acct_codex', { kind: 'refused', refusal: 'native_tools_reach_other_homes' }],
      ['acct_unknown', { kind: 'not_offered' }],
      ['acct_new', { kind: 'needs_model' }],
    ])
  })

  it('names the subscriptions a Keeper may run on here', () => {
    expect(runnable(integrations).map((one) => one.id)).toEqual(['claude_code'])
  })

  it('counts a model as checked only while the server still finds it in its settings', () => {
    expect(byAccount((one) => one.checked)).toEqual([
      ['acct_gone', false], ['acct_claude', true], ['acct_codex', true], ['acct_unknown', false], ['acct_new', false],
    ])
  })
})

describe('the panel', () => {
  const refused = { kind: 'refused', status: 503, reason: 'the files are being read again' } as const
  const read = (owned: Extract<PanelView, { kind: 'read' }>['owned']): PanelView => ({
    kind: 'read',
    forUser: person,
    integrations: [
      { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], calls: { kind: 'allowed' } },
      { id: 'codex', displayName: '', models: ['gpt-5.5'], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' } },
    ],
    owned,
  })
  const views: ReadonlyArray<readonly [string, PanelView]> = [
    ['waiting', { kind: 'waiting' }],
    ['a short reading', { kind: 'reading', forUser: person, slow: false }],
    ['a long reading', { kind: 'reading', forUser: person, slow: true }],
    ['leaving', { kind: 'leaving', forUser: person }],
    ['a reading that failed', { kind: 'failed', forUser: person, failure: { problem: refused, attempts: 1 }, next: 'idle' }],
    ['a retry under way', { kind: 'failed', forUser: person, failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'reading' }],
    ['a retry that found no session', { kind: 'failed', forUser: person, failure: { problem: refused, attempts: 1 }, next: 'leaving' }],
    ['nothing connected', read({ accounts: [], runtimes: [] })],
    ['accounts of each kind', read({
      accounts: [
        { id: 'acct_claude', integration: { read: true, value: 'claude_code' } },
        { id: 'acct_codex', integration: { read: true, value: 'codex' } },
        { id: 'acct_gone', integration: { read: true, value: 'muse' } },
        { id: 'acct_unknown', integration: { read: false, unread: 'login_receipt_missing' } },
        { id: 'acct_odd', integration: { read: false, unread: 'unrecognised' } },
      ],
      runtimes: [
        { id: 'acct_claude.claude-sonnet-5', accountId: 'acct_claude', model: { read: true, value: 'claude-sonnet-5' } },
        { id: 'acct_claude.claude-opus-9', accountId: 'acct_claude', model: { read: false, unread: 'runtime_not_bound' } },
        { id: 'acct_gone.muse-1', accountId: 'acct_gone', model: { read: false, unread: 'template_not_declared' } },
        { id: 'acct_unknown.x', accountId: 'acct_unknown', model: { read: false, unread: 'account_integration_unread' } },
        { id: 'acct_odd.y', accountId: 'acct_odd', model: { read: false, unread: 'unrecognised' } },
      ],
    })],
  ]
  const named = (...names: string[]) => views.map(([name]) => [name, names.includes(name) ? 1 : 0])

  /** The panel of one state, over a model that only counts what it is asked. */
  const drawn = (view: PanelView) => {
    const model = { view: signal(view), load: vi.fn(() => Promise.resolve()), retry: vi.fn(() => Promise.resolve()) } satisfies SubscriptionsModel
    return { container: render(html`<${SubscriptionsPanel} model=${model} />`).container, model }
  }
  const count = (selector: string) => views.map(([name, view]) => [name, drawn(view).container.querySelectorAll(selector).length])

  it.each(views)('passes the accessibility rules while %s', async (_name, view) => {
    expect(await axe(drawn(view).container)).toHaveNoViolations()
  })

  it('has one line a screen reader reads out in each state', () => {
    expect(count('[role=status]')).toEqual(named(...views.map(([name]) => name)))
  })

  it('says a problem where a screen reader announces it only when a reading failed', () => {
    expect(count('[role=alert]')).toEqual(named('a reading that failed', 'a retry under way', 'a retry that found no session'))
  })

  it('offers a retry only when a reading failed, and marks it while it runs', () => {
    expect(count('button')).toEqual(named('a reading that failed', 'a retry under way', 'a retry that found no session'))
    expect(count('button[aria-disabled=true]')).toEqual(named('a retry under way', 'a retry that found no session'))
  })

  it('has a row for each account', () => {
    expect(count('li.row')).toEqual(views.map(([name, view]) => [name, view.kind === 'read' ? view.owned.accounts.length : 0]))
  })

  it('asks the model to read again', () => {
    const { container, model } = drawn({ kind: 'failed', forUser: person, failure: { problem: refused, attempts: 1 }, next: 'idle' })
    const button = container.querySelector('button')
    if (button === null) throw new Error('no retry button')
    fireEvent.click(button)
    expect(model.retry).toHaveBeenCalledTimes(1)
  })

  /** The panel over a model that answers from lists. */
  const live = (byPath: Readonly<Record<string, readonly Scripted[]>>) => {
    const { panel } = start(byPath)
    return { panel, container: render(html`<${SubscriptionsPanel} model=${panel} />`).container }
  }

  it('puts a new note on the page when a reading fails again', async () => {
    const { panel, container } = live({ [paths.integrations]: [notReady(), notReady()], [paths.owned]: [ownedNothing(), ownedNothing()] })
    await act(() => panel.load(person))
    const first = container.querySelector('[role=alert]')
    await act(() => panel.retry())
    const second = container.querySelector('[role=alert]')
    expect([first === null, second === null, second === first]).toEqual([false, false, false])
  })

  it('moves the focus to the heading of the panel when a retry reads', async () => {
    const { panel, container } = live({ [paths.integrations]: [notReady(), offered()], [paths.owned]: [ownedNothing(), ownedOne()] })
    await act(() => panel.load(person))
    const button = container.querySelector('button')
    if (button === null) throw new Error('no retry button')
    button.focus()
    await act(() => panel.retry())
    expect(document.activeElement).toBe(container.querySelector('h2'))
  })

  it('leaves a focus the person moved elsewhere during a retry where it is', async () => {
    const { panel, container } = live({ [paths.integrations]: [notReady(), offered()], [paths.owned]: [ownedNothing(), ownedOne()] })
    const elsewhere = document.body.appendChild(document.createElement('button'))
    try {
      await act(() => panel.load(person))
      elsewhere.focus()
      await act(() => panel.retry())
      expect([document.activeElement === elsewhere, container.querySelectorAll('li.row').length]).toEqual([true, 1])
    } finally {
      elsewhere.remove()
    }
  })

  it('leaves the focus alone when the first reading reads', async () => {
    const { panel } = live({ [paths.integrations]: [offered()], [paths.owned]: [ownedOne()] })
    await act(() => panel.load(person))
    expect(document.activeElement).toBe(document.body)
  })

  it('draws what the model reads', async () => {
    const { panel } = start({ [paths.integrations]: [offered()], [paths.owned]: [ownedOne()] })
    const { container } = render(html`<${SubscriptionsPanel} model=${panel} />`)
    await act(() => panel.load(person))
    expect(container.querySelectorAll('li.row').length).toBe(1)
  })
})
