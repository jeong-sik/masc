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
import { checkPath, createChecks } from './check'
import type { ChecksModel } from './check'
import { createConnect } from './connect'
import type { ConnectModel } from './connect'
import { addPath, createKeyAdds } from './key-add'
import type { KeyAddModel } from './key-add'
import { createRemovals, removePath } from './key-remove'
import type { RemovalsModel } from './key-remove'
import { createReplacements, replacePath } from './key-replace'
import type { ReplacementsModel } from './key-replace'
import type { View } from './console'
import { loginPath } from './login'
import { slowAfterMs } from './notes'
import { accountFacts } from './account-rows'
import type { AccountFacts } from './account-rows'
import { SubscriptionsPanel, createSubscriptions, follow } from './subscriptions'
import type { PanelView, SubscriptionsModel } from './subscriptions'
import { checkable, csrfHeader, paths } from './wire'
import type { Integration, Send, Session } from './wire'

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
const sessionOf = (userId: string, csrfToken = `token of ${userId}`): Session => ({ userId, csrfToken })
const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

/** A connecting no test here drives: the frame and the panel only need one to be there. */
const idleConnect = (): ConnectModel =>
  createConnect({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() })
/** Checks no test here drives: the panel only needs them to be there. */
const idleChecks = (): ChecksModel =>
  createChecks({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() })

/** A giving of a key no test here drives: the panel only needs one to be there. */
const idleAdds = (): KeyAddModel =>
  createKeyAdds({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() })
/** Replacements no test here drives: the panel only needs them to be there. */
const idleReplacements = (): ReplacementsModel => createReplacements({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() })
/** Removals no test here drives: the panel only needs them to be there. */
const idleRemovals = (): RemovalsModel =>
  createRemovals({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() })

const loginId = 'a'.repeat(64)
const frame = (event: string, data: unknown): string => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
const receipt = (status: string, more: Readonly<Record<string, unknown>> = {}) =>
  ({ login_id: loginId, integration_id: 'claude_code', status, invocation_verified: false, ...more })
/** The whole stream of a login that links a new account. */
const linking = (): Response => new Response(
  frame('started', receipt('running')) + frame('complete', receipt('complete', { account: 'linked', authentication: 'login_completed' })),
  { status: 200, headers: { 'content-type': 'text/event-stream' } },
)

const claude = { integration_id: 'claude_code', display_name: 'Claude Code', connect: ['login'], models: ['claude-sonnet-5'], withheld: [], calls: 'allowed' }
const codex = { integration_id: 'codex', display_name: 'Codex', connect: ['login'], models: ['gpt-5.5'], withheld: [], calls: 'refused', refusal: 'native_tools_reach_other_homes' }
const offered = (): Response => json(200, { integrations: [claude, codex] })
/** The same subscriptions, the first of which takes an API key too. */
const offeredWithKey = (): Response => json(200, { integrations: [{ ...claude, connect: ['login', 'key'] }, codex] })
const keyStored = (): Response => json(200, { provider_account_id: 'acct_key', kind: 'key' })
const ownedNothing = (): Response => json(200, { provider_accounts: [], runtimes: [] })
const ownedOne = (): Response => json(200, {
  provider_accounts: [{ provider_account_id: 'acct_1', kind: 'login', integration_id: 'claude_code' }],
  runtimes: [{ runtime_id: 'acct_1.claude-sonnet-5', provider_account_id: 'acct_1', model: 'claude-sonnet-5' }],
})
const keyAccountRow = (removal?: string) =>
  ({ provider_account_id: 'acct_key', kind: 'key', key: 'readable', integration_id: 'claude_code', ...(removal === undefined ? {} : { removal }) })
/** A key account, with what a removal left on it if it left anything. */
const ownedKey = (removal?: string): Response => json(200, { provider_accounts: [keyAccountRow(removal)], runtimes: [] })
const keyRemoved = (): Response => json(200, { provider_account_id: 'acct_key', removed: true })
const keyStayed = (): Response => json(503, { error: 'The key of this account could not be removed from this server.', code: 'key_not_removed' })
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
    await panel.load(sessionOf(person))
    expect(panel.view.value).toEqual({
      kind: 'read',
      forUser: person,
      integrations: [
        { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], withheld: [], calls: { kind: 'allowed' }, takesKey: false },
        { id: 'codex', displayName: 'Codex', models: ['gpt-5.5'], withheld: [], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' }, takesKey: false },
      ],
      owned: {
        accounts: [{ id: 'acct_1', integration: 'claude_code', held: { kind: 'login' }, left: null }],
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
    await Promise.all([panel.load(sessionOf(person)), panel.load(sessionOf(person))])
    await panel.load(sessionOf(person))
    expect([kind(panel), sent.length]).toEqual([`read for ${person}`, 2])
  })

  it('drops what it read for a person who is no longer the one shown', async () => {
    const first = later()
    const { panel } = start({ [paths.integrations]: [first.answer, offered()], [paths.owned]: [ownedOne(), ownedNothing()] })
    const forPerson = panel.load(sessionOf(person))
    const forOther = panel.load(sessionOf(other))
    await forOther
    first.give(offered())
    await forPerson
    // No one waits for a reading that was replaced: its answer is taken in by now.
    await new Promise((resolve) => { setTimeout(resolve, 0) })
    const view = panel.view.value
    expect([kind(panel), view.kind === 'read' ? view.owned.accounts.length : null]).toEqual([`read for ${other}`, 0])
  })

  it('says a failure, counts the failures in a row, and reads again on a retry', async () => {
    const { panel } = start({ [paths.integrations]: [notReady(), 'no answer', offered()], [paths.owned]: [ownedNothing(), ownedNothing(), ownedNothing()] })
    await panel.load(sessionOf(person))
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
    await panel.load(sessionOf(person))
    await panel.retry()
    expect([kind(panel), sent.length]).toEqual([`read for ${person}`, 2])
  })

  it('reads once on a retry however often it is asked', async () => {
    const { panel, sent } = start({ [paths.integrations]: [notReady(), offered()], [paths.owned]: [ownedNothing(), ownedNothing()] })
    await panel.load(sessionOf(person))
    await Promise.all([panel.retry(), panel.retry()])
    expect([kind(panel), sent.length]).toEqual([`read for ${person}`, 4])
  })

  it('does nothing for a person whose reading failed: the retry reads again', async () => {
    const { panel, sent } = start({ [paths.integrations]: [notReady()], [paths.owned]: [ownedNothing()] })
    await panel.load(sessionOf(person))
    await panel.load(sessionOf(person))
    expect([kind(panel), sent.length]).toEqual([`failed for ${person}`, 2])
  })

  it('takes the answer of the newest reading, whatever an older one ends with', async () => {
    const first = later()
    const { panel } = start({ [paths.integrations]: [first.answer, offered(), offered()], [paths.owned]: [ownedOne(), ownedNothing(), ownedOne()] })
    const older = panel.load(sessionOf(person))
    await panel.load(sessionOf(other))
    await panel.load(sessionOf(person))
    first.give(notReady())
    await older
    await new Promise((resolve) => { setTimeout(resolve, 0) })
    expect(kind(panel)).toBe(`read for ${person}`)
  })

  it('lets go of whoever waits for a reading once it is stopped, though no answer came', async () => {
    const { panel } = start({ [paths.integrations]: [offered()], [paths.owned]: [later().answer] })
    let ended = false
    void panel.load(sessionOf(person)).then(() => { ended = true })
    panel.stop()
    await vi.waitFor(() => { expect(ended).toBe(true) })
    expect(kind(panel)).toBe('waiting')
  })

  it('keeps the page of a failed reading while it leaves after a retry finds no session', async () => {
    const { panel, leave } = start({ [paths.integrations]: [notReady(), offered()], [paths.owned]: [ownedNothing(), noSession()] })
    await panel.load(sessionOf(person))
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
    await panel.load(sessionOf(person))
    expect([kind(panel), leave.mock.calls.length]).toEqual([`leaving for ${person}`, 1])
  })

  it('says it is waiting only once a reading is slow', async () => {
    vi.useFakeTimers()
    const answer = later()
    const { panel } = start({ [paths.integrations]: [answer.answer], [paths.owned]: [ownedNothing()] })
    const done = panel.load(sessionOf(person))
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
    const older = panel.load(sessionOf(person))
    await vi.advanceTimersByTimeAsync(slowAfterMs - 1)
    const newer = panel.load(sessionOf(other))
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
  const session = sessionOf(person)
  const who = { id: person, role: 'member' } as const

  it('gives the panel the session of each person the console comes to show signed in, stops it whenever the console shows no one, and no more', () => {
    const frame = signal<View>({ kind: 'reading', slow: false })
    const panel = {
      view: signal<PanelView>({ kind: 'waiting' }),
      load: vi.fn((_session: Session) => Promise.resolve()),
      retry: vi.fn(() => Promise.resolve()),
      connecting: idleConnect(), checking: idleChecks(), adding: idleAdds(), removing: idleRemovals(), replacing: idleReplacements(),
      stop: vi.fn(),
    } satisfies SubscriptionsModel
    const stop = follow(frame, panel)
    frame.value = { kind: 'signed_in', session, who, signOut: { kind: 'idle' } }
    frame.value = { kind: 'signed_in', session, who, signOut: { kind: 'sending' } }
    frame.value = { kind: 'changed', next: 'idle' }
    frame.value = { kind: 'signed_in', session: sessionOf(other), who: { id: other, role: 'member' }, signOut: { kind: 'idle' } }
    stop()
    frame.value = { kind: 'signed_in', session, who, signOut: { kind: 'idle' } }
    expect(panel.load.mock.calls).toEqual([[session], [session], [sessionOf(other)]])
    // The first reading of the console, and the account that changed.
    expect(panel.stop).toHaveBeenCalledTimes(2)
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

describe('connecting a subscription from the panel', () => {
  const accounts = (panel: SubscriptionsModel): unknown => {
    const view = panel.view.value
    return view.kind === 'read' ? view.owned.accounts.length : view.kind
  }
  const loginTokens = (sent: readonly Sent[]): Array<string | null> =>
    sent.filter((one) => one.path === loginPath).map((one) => new Headers(one.init.headers).get(csrfHeader))

  it('reads the subscriptions again once a login links an account, and keeps the list on the page meanwhile', async () => {
    const again = later()
    const { panel, sent } = start({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedNothing(), again.answer],
      [loginPath]: [linking()],
    })
    await panel.load(sessionOf(person))
    panel.connecting.open()
    const login = panel.connecting.start('claude_code')
    await vi.waitFor(() => { expect(panel.connecting.view.value).toEqual({ kind: 'closed', linked: true }) })
    const meanwhile = accounts(panel)
    again.give(ownedOne())
    await login
    expect([meanwhile, accounts(panel), loginTokens(sent)]).toEqual([0, 1, [`token of ${person}`]])
  })

  it('sends the token of the newest session of the person it shows', async () => {
    const { panel, sent } = start({
      [paths.integrations]: [offered()],
      [paths.owned]: [ownedNothing()],
      [loginPath]: [json(503, { error: 'the files are being read again' })],
    })
    await panel.load(sessionOf(person, 'first'))
    await panel.load(sessionOf(person, 'second'))
    panel.connecting.open()
    await panel.connecting.start('claude_code')
    expect([loginTokens(sent), sent.length]).toEqual([['second'], 3])
  })

  it('starts no login before it shows anyone', async () => {
    const { panel, sent } = start({})
    panel.connecting.open()
    await panel.connecting.start('claude_code')
    expect([panel.connecting.view.value.kind, sent.length]).toEqual(['choosing', 0])
  })

  it('keeps a login for the same person, and leaves it behind for another', async () => {
    const stream = later()
    const { panel, sent } = start({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedNothing(), ownedNothing()],
      [loginPath]: [stream.answer],
    })
    await panel.load(sessionOf(person))
    panel.connecting.open()
    const login = panel.connecting.start('claude_code')
    await panel.load(sessionOf(person))
    const kept = panel.connecting.view.value.kind
    await panel.load(sessionOf(other))
    const left = panel.connecting.view.value
    stream.give(linking())
    await login
    expect([kept, left, kind(panel), sent.length]).toEqual(['starting', { kind: 'closed', linked: false }, `read for ${other}`, 5])
  })
})

describe('checking a model from the panel', () => {
  const passedCall = (): Response => json(200, {
    verification: { schema: 'masc.runtime_verification.v1', status: 'verified', failure: null },
    runtime: { runtime_id: 'acct_1.claude-sonnet-5', record: 'made' },
  })
  const checkTokens = (sent: readonly Sent[]): Array<string | null> =>
    sent.filter((one) => one.path === checkPath).map((one) => new Headers(one.init.headers).get(csrfHeader))

  it('checks with the token of the newest session, and reads the subscriptions again once the call passed', async () => {
    const { panel, sent } = start({
      [paths.integrations]: [offered(), offered(), offered()],
      [paths.owned]: [ownedNothing(), ownedOne(), ownedOne()],
      [checkPath]: [passedCall(), passedCall()],
    })
    await panel.load(sessionOf(person, 'first'))
    await panel.checking.check('acct_1', 'claude-sonnet-5')
    const view = panel.view.value
    await panel.load(sessionOf(person, 'second'))
    await panel.checking.check('acct_1', 'claude-sonnet-5')
    expect([checkTokens(sent), view.kind === 'read' ? view.owned.runtimes.length : view.kind]).toEqual([['first', 'second'], 1])
  })

  it('forgets the checks of one person once it shows another', async () => {
    const call = later()
    const { panel, sent } = start({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedOne(), ownedNothing()],
      [checkPath]: [call.answer],
    })
    await panel.load(sessionOf(person))
    const run = panel.checking.check('acct_1', 'claude-sonnet-5')
    await panel.load(sessionOf(other))
    call.give(passedCall())
    await run
    const ownedReadings = sent.filter((one) => one.path === paths.owned).length
    expect([panel.checking.checks.value.size, kind(panel), ownedReadings]).toEqual([0, `read for ${other}`, 2])
  })
})

describe('giving a key in the panel', () => {
  const addTokens = (sent: readonly Sent[]): Array<string | null> =>
    sent.filter((one) => one.path === addPath).map((one) => new Headers(one.init.headers).get(csrfHeader))
  const heldBy = (panel: SubscriptionsModel): readonly unknown[] => {
    const view = panel.view.value
    return view.kind === 'read' ? view.owned.accounts.map((account) => [account.id, account.held.kind]) : [view.kind]
  }

  it('sends a key with the token of the newest session, and reads the subscriptions again once it was stored', async () => {
    const { panel, sent } = start({
      [paths.integrations]: [offeredWithKey(), offeredWithKey()],
      [paths.owned]: [ownedNothing(), ownedKey()],
      [addPath]: [keyStored()],
    })
    await panel.load(sessionOf(person, 'first'))
    await panel.load(sessionOf(person, 'second'))
    panel.adding.open()
    const kept = await panel.adding.add('claude_code', 'made-up-key')
    expect([kept, addTokens(sent), heldBy(panel), panel.adding.view.value])
      .toEqual(['dropped', ['second'], [['acct_key', 'key']], { kind: 'closed', stored: 'acct_key' }])
  })

  it('forgets the add of one person once it shows another', async () => {
    const call = later()
    const { panel, sent } = start({
      [paths.integrations]: [offeredWithKey(), offeredWithKey()],
      [paths.owned]: [ownedNothing(), ownedNothing()],
      [addPath]: [call.answer],
    })
    await panel.load(sessionOf(person))
    panel.adding.open()
    const run = panel.adding.add('claude_code', 'made-up-key')
    await panel.load(sessionOf(other))
    call.give(keyStored())
    const kept = await run
    const ownedReadings = sent.filter((one) => one.path === paths.owned).length
    expect([kept, panel.adding.view.value, kind(panel), ownedReadings]).toEqual(['dropped', { kind: 'closed', stored: null }, `read for ${other}`, 2])
  })
})

describe('giving another key for an account in the panel', () => {
  const keyReplaced = (): Response => json(200, { provider_account_id: 'acct_key', old_keys_removed: true })
  const replaceTokens = (sent: readonly Sent[]): Array<string | null> =>
    sent.filter((one) => one.path === replacePath('acct_key')).map((one) => new Headers(one.init.headers).get(csrfHeader))
  const ownedReadings = (sent: readonly Sent[]): number => sent.filter((one) => one.path === paths.owned).length

  it('sends the key with the token of the newest session, and reads the subscriptions again', async () => {
    const { panel, sent } = start({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedKey()],
      [replacePath('acct_key')]: [keyReplaced()],
    })
    await panel.load(sessionOf(person, 'first'))
    await panel.load(sessionOf(person, 'second'))
    panel.replacing.open('acct_key')
    const kept = await panel.replacing.replace('acct_key', 'made-up-key')
    await vi.waitFor(() => { expect(panel.replacing.replacing.value.get('acct_key')).toEqual({ kind: 'replaced', oldKeysRemoved: true }) })
    expect([kept, replaceTokens(sent), ownedReadings(sent), kind(panel)]).toEqual(['dropped', ['second'], 2, `read for ${person}`])
  })

  it('says the key was replaced only once the list of the newest reading is on the page', async () => {
    const second = later()
    const third = later()
    const { panel, sent } = start({
      [paths.integrations]: [offeredWithKey(), second.answer, third.answer],
      [paths.owned]: [ownedKey(), ownedKey(), ownedKey()],
      [replacePath('acct_key')]: [keyReplaced()],
      [addPath]: [json(200, { provider_account_id: 'acct_other', kind: 'key' })],
    })
    await panel.load(sessionOf(person))
    panel.replacing.open('acct_key')
    const replaced = panel.replacing.replace('acct_key', 'made-up-key')
    await vi.waitFor(() => { expect(ownedReadings(sent)).toBe(2) })
    // Another card asks for the list while the reading of the replacement is on its way.
    panel.adding.open()
    const added = panel.adding.add('claude_code', 'another-made-up-key')
    await vi.waitFor(() => { expect(ownedReadings(sent)).toBe(3) })
    second.give(offeredWithKey())
    await new Promise((resolve) => { setTimeout(resolve, 0) })
    expect(panel.replacing.replacing.value.get('acct_key')?.kind).toBe('sending')
    third.give(offeredWithKey())
    await Promise.all([replaced, added])
    await vi.waitFor(() => { expect(panel.replacing.replacing.value.get('acct_key')).toEqual({ kind: 'replaced', oldKeysRemoved: true }) })
  })

  it('says the key was replaced once the newest list is on the page, though the readings before it have no answer', async () => {
    const { panel, sent } = start({
      [paths.integrations]: [offeredWithKey(), offeredWithKey(), offeredWithKey(), offeredWithKey()],
      [paths.owned]: [ownedKey(), later().answer, later().answer, ownedKey()],
      [replacePath('acct_key')]: [keyReplaced()],
      [addPath]: ['no answer', 'no answer'],
    })
    await panel.load(sessionOf(person))
    panel.replacing.open('acct_key')
    await panel.replacing.replace('acct_key', 'made-up-key')
    await vi.waitFor(() => { expect(ownedReadings(sent)).toBe(2) })
    // A key whose answer did not come asks for the list again, twice. Only
    // the last of the three readings gets an answer.
    panel.adding.open()
    await panel.adding.add('claude_code', 'another-made-up-key')
    const held = panel.replacing.replacing.value.get('acct_key')?.kind
    await panel.adding.add('claude_code', 'another-made-up-key')
    await vi.waitFor(() => { expect(panel.replacing.replacing.value.get('acct_key')).toEqual({ kind: 'replaced', oldKeysRemoved: true }) })
    expect([held, ownedReadings(sent), kind(panel)]).toEqual(['sending', 4, `read for ${person}`])
  })

  it('forgets the replacements of one person once it shows another', async () => {
    const call = later()
    const { panel } = start({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedNothing()],
      [replacePath('acct_key')]: [call.answer],
    })
    await panel.load(sessionOf(person))
    panel.replacing.open('acct_key')
    const run = panel.replacing.replace('acct_key', 'made-up-key')
    await panel.load(sessionOf(other))
    call.give(keyReplaced())
    expect([await run, panel.replacing.replacing.value.size, kind(panel)]).toEqual(['dropped', 0, `read for ${other}`])
  })
})

describe('removing a key account in the panel', () => {
  const removeTokens = (sent: readonly Sent[]): Array<string | null> =>
    sent.filter((one) => one.path === removePath('acct_key')).map((one) => new Headers(one.init.headers).get(csrfHeader))
  const accountsOf = (panel: SubscriptionsModel): readonly unknown[] => {
    const view = panel.view.value
    return view.kind === 'read' ? view.owned.accounts.map((account) => [account.id, account.left]) : [view.kind]
  }

  it('removes with the token of the newest session, and reads the subscriptions again once the server removed the account', async () => {
    const { panel, sent } = start({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedNothing()],
      [removePath('acct_key')]: [keyRemoved()],
    })
    await panel.load(sessionOf(person, 'first'))
    await panel.load(sessionOf(person, 'second'))
    await panel.removing.remove('acct_key')
    expect([removeTokens(sent), accountsOf(panel), panel.removing.removing.value.get('acct_key')]).toEqual([['second'], [], { kind: 'removed', already: false }])
  })

  it('shows what a removal that stopped left on the account', async () => {
    const { panel } = start({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedKey('key_not_removed')],
      [removePath('acct_key')]: [keyStayed()],
    })
    await panel.load(sessionOf(person))
    await panel.removing.remove('acct_key')
    expect([accountsOf(panel), panel.removing.removing.value.get('acct_key')?.kind]).toEqual([[['acct_key', { kind: 'removal', stage: 'key_not_removed' }]], 'refused'])
  })

  it('forgets the removals of one person once it shows another', async () => {
    const call = later()
    const { panel, sent } = start({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedNothing()],
      [removePath('acct_key')]: [call.answer],
    })
    await panel.load(sessionOf(person))
    const run = panel.removing.remove('acct_key')
    await panel.load(sessionOf(other))
    call.give(keyRemoved())
    await run
    const ownedReadings = sent.filter((one) => one.path === paths.owned).length
    expect([panel.removing.removing.value.size, kind(panel), ownedReadings]).toEqual([0, `read for ${other}`, 2])
  })
})

describe('what the panel knows of each account', () => {
  const integrations: readonly Integration[] = [
    { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], withheld: [], calls: { kind: 'allowed' }, takesKey: false },
    { id: 'codex', displayName: 'Codex', models: ['gpt-5.5'], withheld: [], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' }, takesKey: false },
  ]
  const facts = accountFacts(integrations, {
    accounts: [
      { id: 'acct_gone', integration: 'muse', held: { kind: 'login' }, left: null },
      { id: 'acct_claude', integration: 'claude_code', held: { kind: 'login' }, left: null },
      { id: 'acct_codex', integration: 'codex', held: { kind: 'login' }, left: null },
      { id: 'acct_new', integration: 'claude_code', held: { kind: 'login' }, left: null },
    ],
    runtimes: [
      { id: 'acct_codex.gpt-5.5', accountId: 'acct_codex', model: { read: true, value: 'gpt-5.5' } },
      { id: 'acct_claude.claude-opus-9', accountId: 'acct_claude', model: { read: false, unread: 'runtime_not_bound' } },
      { id: 'acct_gone.muse-1', accountId: 'acct_gone', model: { read: false, unread: 'template_not_declared' } },
      { id: 'acct_claude.claude-sonnet-5', accountId: 'acct_claude', model: { read: true, value: 'claude-sonnet-5' } },
    ],
  })
  const byAccount = <T>(pick: (one: AccountFacts) => T) => facts.map((one) => [one.account.id, pick(one)])

  it('keeps the order the server lists the accounts in', () => {
    expect(facts.map((one) => one.account.id)).toEqual(['acct_gone', 'acct_claude', 'acct_codex', 'acct_new'])
  })

  it('finds the subscription the server offers for an account, and none when it is no longer offered', () => {
    expect(byAccount((one) => (one.offered === null ? null : one.offered.id))).toEqual([
      ['acct_gone', null], ['acct_claude', 'claude_code'], ['acct_codex', 'codex'], ['acct_new', 'claude_code'],
    ])
  })

  it('gives an account only the Runtimes made on it', () => {
    expect(byAccount((one) => one.runtimes.map((runtime) => runtime.id))).toEqual([
      ['acct_gone', ['acct_gone.muse-1']],
      ['acct_claude', ['acct_claude.claude-opus-9', 'acct_claude.claude-sonnet-5']],
      ['acct_codex', ['acct_codex.gpt-5.5']],
      ['acct_new', []],
    ])
  })

  it('says whether a Keeper can run on an account, or what stands in its way', () => {
    expect(byAccount((one) => one.keeper)).toEqual([
      ['acct_gone', { kind: 'not_offered' }],
      ['acct_claude', { kind: 'can_run' }],
      ['acct_codex', { kind: 'refused', refusal: 'native_tools_reach_other_homes' }],
      ['acct_new', { kind: 'needs_model' }],
    ])
  })

  it('finds a model to check only on a subscription the server calls and offers a model of', () => {
    const bare = integrations.map((one) => ({ ...one, models: [] }))
    expect([...integrations, ...bare].map((one) => [one.id, one.calls.kind, one.models.length, checkable(one)])).toEqual([
      ['claude_code', 'allowed', 1, true], ['codex', 'refused', 1, false], ['claude_code', 'allowed', 0, false], ['codex', 'refused', 0, false],
    ])
  })

  it('tells an account that has a model to check from one whose subscription offers none', () => {
    const owned = {
      accounts: [
        { id: 'acct_checked', integration: 'claude_code', held: { kind: 'login' }, left: null },
        { id: 'acct_new', integration: 'claude_code', held: { kind: 'login' }, left: null },
      ],
      runtimes: [{ id: 'acct_checked.claude-sonnet-5', accountId: 'acct_checked', model: { read: true, value: 'claude-sonnet-5' } }],
    } as const
    const kinds = (offered: readonly Integration[]) => accountFacts(offered, owned).map((one) => [one.account.id, one.keeper.kind])
    expect(kinds(integrations)).toEqual([['acct_checked', 'can_run'], ['acct_new', 'needs_model']])
    expect(kinds(integrations.map((one) => ({ ...one, models: [] })))).toEqual([['acct_checked', 'can_run'], ['acct_new', 'no_model']])
  })

  it('says a removal or a key replacement that was left on an account before anything else of it', () => {
    const kinds = accountFacts(integrations, {
      accounts: [
        { id: 'acct_left', integration: 'claude_code', held: { kind: 'key', key: 'readable' }, left: { kind: 'removal', stage: 'key_not_removed' } },
        { id: 'acct_left_gone', integration: 'muse', held: { kind: 'key', key: 'key_missing' }, left: { kind: 'removal', stage: 'start_given_up' } },
        { id: 'acct_left_refused', integration: 'codex', held: { kind: 'key', key: 'readable' }, left: { kind: 'removal', stage: 'home_not_removed' } },
        { id: 'acct_blocked', integration: 'claude_code', held: { kind: 'key', key: 'readable' }, left: { kind: 'replacement', stage: 'start_given_up' } },
        { id: 'acct_key', integration: 'claude_code', held: { kind: 'key', key: 'key_missing' }, left: null },
      ],
      runtimes: [],
    }).map((one) => [one.account.id, one.keeper.kind])
    expect(kinds).toEqual([
      ['acct_left', 'removal_left'], ['acct_left_gone', 'removal_left'], ['acct_left_refused', 'removal_left'],
      ['acct_blocked', 'replacement_left'], ['acct_key', 'needs_model'],
    ])
  })

  it('says a Keeper can run on a key account with a checked model only while the server read its key', () => {
    const states = ['readable', 'key_missing', 'key_unreadable', 'not_looked_at', 'unrecognised'] as const
    const accounts = states.map((key) => ({ id: `acct_${key}`, integration: 'claude_code', held: { kind: 'key', key }, left: null }) as const)
    const runtimes = accounts.map((account) => ({ id: `${account.id}.claude-sonnet-5`, accountId: account.id, model: { read: true, value: 'claude-sonnet-5' } }) as const)
    expect(accountFacts(integrations, { accounts, runtimes }).map((one) => one.keeper.kind))
      .toEqual(['can_run', 'key_not_readable', 'key_not_readable', 'key_not_readable', 'key_not_readable'])
  })

  it('counts a model as checked only while the server still finds it in its settings', () => {
    expect(byAccount((one) => one.checked)).toEqual([
      ['acct_gone', false], ['acct_claude', true], ['acct_codex', true], ['acct_new', false],
    ])
  })
})

describe('the panel', () => {
  const refused = { kind: 'refused', status: 503, reason: 'the files are being read again' } as const
  const read = (owned: Extract<PanelView, { kind: 'read' }>['owned'], takesKey = false): PanelView => ({
    kind: 'read',
    forUser: person,
    integrations: [
      { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], withheld: [], calls: { kind: 'allowed' }, takesKey },
      { id: 'codex', displayName: '', models: ['gpt-5.5'], withheld: [], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' }, takesKey: false },
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
    ['nothing offered', { kind: 'read', forUser: person, integrations: [], owned: { accounts: [], runtimes: [] } }],
    ['nothing connected', read({ accounts: [], runtimes: [] })],
    ['accounts of each kind', read({
      accounts: [
        { id: 'acct_claude', integration: 'claude_code', held: { kind: 'login' }, left: null },
        { id: 'acct_codex', integration: 'codex', held: { kind: 'login' }, left: null },
        { id: 'acct_gone', integration: 'muse', held: { kind: 'login' }, left: null },
      ],
      runtimes: [
        { id: 'acct_claude.claude-sonnet-5', accountId: 'acct_claude', model: { read: true, value: 'claude-sonnet-5' } },
        { id: 'acct_claude.claude-opus-9', accountId: 'acct_claude', model: { read: false, unread: 'runtime_not_bound' } },
        { id: 'acct_gone.muse-1', accountId: 'acct_gone', model: { read: false, unread: 'template_not_declared' } },
        { id: 'acct_gone.odd', accountId: 'acct_gone', model: { read: false, unread: 'unrecognised' } },
      ],
    })],
    // The first holds a key the server did not find, and the second has a removal left on it.
    // Their subscription takes a key.
    ['key accounts', read({
      accounts: [
        { id: 'acct_key', integration: 'claude_code', held: { kind: 'key', key: 'key_missing' }, left: null },
        { id: 'acct_left', integration: 'claude_code', held: { kind: 'key', key: 'readable' }, left: { kind: 'removal', stage: 'key_not_removed' } },
      ],
      runtimes: [],
    }, true)],
  ]
  const named = (...names: string[]) => views.map(([name]) => [name, names.includes(name) ? 1 : 0])
  /** The states with a subscription to connect. */
  const connectable = ['nothing connected', 'accounts of each kind', 'key accounts']

  /** The panel of one state, over a model that only counts what it is asked. */
  const drawn = (view: PanelView) => {
    const model = {
      view: signal(view), load: vi.fn(() => Promise.resolve()), retry: vi.fn(() => Promise.resolve()), connecting: idleConnect(), checking: idleChecks(), adding: idleAdds(), removing: idleRemovals(), replacing: idleReplacements(), stop: vi.fn(),
    } satisfies SubscriptionsModel
    return { container: render(html`<${SubscriptionsPanel} model=${model} />`).container, model }
  }
  const count = (selector: string) => views.map(([name, view]) => [name, drawn(view).container.querySelectorAll(selector).length])

  it.each(views)('passes the accessibility rules while %s', async (_name, view) => {
    expect(await axe(drawn(view).container)).toHaveNoViolations()
  })

  it('has one line a screen reader reads out in each state, and one more for each way to connect a subscription', () => {
    expect(count('section > [role=status]')).toEqual(named(...views.map(([name]) => name)))
    expect(count('#connect-steps > [role=status]')).toEqual(named(...connectable))
    expect(count('#key-steps > [role=status]')).toEqual(named('key accounts'))
  })

  it('says a problem where a screen reader announces it only when a reading failed', () => {
    expect(count('[role=alert]')).toEqual(named('a reading that failed', 'a retry under way', 'a retry that found no session'))
  })

  it('offers a retry only when a reading failed, and marks it while it runs', () => {
    expect(count('section > p > button')).toEqual(named('a reading that failed', 'a retry under way', 'a retry that found no session'))
    expect(count('button[aria-disabled=true]')).toEqual(named('a retry under way', 'a retry that found no session'))
  })

  it('offers to connect a subscription only once it read some the server offers', () => {
    expect(count('button[aria-controls=connect-steps]')).toEqual(named(...connectable))
    // The other buttons are counted below: the check and the removal in the card of an account, and the one that opens the form of a key.
    const own = count('.check button, .row .actions button, button[aria-controls=key-steps]')
    expect(count('button').map(([name, all], at) => [name, Number(all) - Number(own[at]?.[1])])).toEqual(named('a reading that failed', 'a retry under way', 'a retry that found no session', ...connectable))
  })

  it('offers to check a model only on an account of a subscription with a model to check', () => {
    expect(count('.check button')).toEqual(named('accounts of each kind', 'key accounts'))
    expect(count('.check select')).toEqual(named('accounts of each kind', 'key accounts'))
  })

  it('offers a check on a key account whose key the server did not find, and none on an account a removal was left on', () => {
    const view = views.find(([name]) => name === 'key accounts')?.[1]
    if (view === undefined) throw new Error('no view of the key accounts')
    const rows = [...drawn(view).container.querySelectorAll('li.row')]
    expect(rows.map((row) => [row.querySelectorAll('.check button').length, row.querySelectorAll('.models, .check').length > 0])).toEqual([[1, true], [0, false]])
  })

  it('offers to give a key only while a subscription of the server takes one', () => {
    expect(count('button[aria-controls=key-steps]')).toEqual(named('key accounts'))
  })

  it('offers the removal on each key account, with or without a removal left on it', () => {
    const removeButtons = (name: string): number[] => {
      const view = views.find(([one]) => one === name)?.[1]
      if (view === undefined) throw new Error(`no view ${name}`)
      return [...drawn(view).container.querySelectorAll('li.row')].map((row) => row.querySelectorAll('button[id^="remove-"]').length)
    }
    expect([removeButtons('key accounts'), removeButtons('accounts of each kind').every((buttons) => buttons === 0)]).toEqual([[1, 1], true])
  })

  it('offers another key on a key account, and none on an account a removal was left on', () => {
    const replaceButtons = (name: string): number[] => {
      const view = views.find(([one]) => one === name)?.[1]
      if (view === undefined) throw new Error(`no view ${name}`)
      return [...drawn(view).container.querySelectorAll('li.row')].map((row) => row.querySelectorAll('button[id^="replace-"]').length)
    }
    expect([replaceButtons('key accounts'), replaceButtons('accounts of each kind').every((buttons) => buttons === 0)]).toEqual([[1, 0], true])
  })

  it('names, before anything is connected, only the subscriptions with a model to check', () => {
    const called = { kind: 'allowed' } as const
    const { container } = drawn({
      kind: 'read',
      forUser: person,
      integrations: [
        { id: 'with_model', displayName: 'Has-A-Model', models: ['m'], withheld: [], calls: called, takesKey: false },
        { id: 'no_model', displayName: 'Has-No-Model', models: [], withheld: [{ model: 'w', reason: 'tools_not_declared' }], calls: called, takesKey: false },
        { id: 'refused', displayName: 'Is-Refused', models: ['m'], withheld: [], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' }, takesKey: false },
      ],
      owned: { accounts: [], runtimes: [] },
    })
    // The line that follows the lead of the panel: the three names are also in the choices below it.
    const offer = container.querySelectorAll('section > p.hint')[1]?.textContent ?? ''
    expect(['Has-A-Model', 'Has-No-Model', 'Is-Refused'].map((name) => offer.includes(name))).toEqual([true, false, false])
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
    const { panel, sent } = start(byPath)
    return { panel, sent, container: render(html`<${SubscriptionsPanel} model=${panel} />`).container }
  }

  /** How many accounts the list the panel shows has, or null while it shows none. */
  const listed = (panel: SubscriptionsModel): number | null => {
    const view = panel.view.value
    return view.kind === 'read' ? view.owned.accounts.length : null
  }

  it('puts a new note on the page when a reading fails again', async () => {
    const { panel, container } = live({ [paths.integrations]: [notReady(), notReady()], [paths.owned]: [ownedNothing(), ownedNothing()] })
    await act(() => panel.load(sessionOf(person)))
    const first = container.querySelector('[role=alert]')
    await act(() => panel.retry())
    const second = container.querySelector('[role=alert]')
    expect([first === null, second === null, second === first]).toEqual([false, false, false])
  })

  it('keeps the focus on the check button through the reading after a check passed', async () => {
    const call = later()
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedOne(), ownedOne()],
      [checkPath]: [call.answer],
    })
    await act(() => panel.load(sessionOf(person)))
    const button = container.querySelector<HTMLButtonElement>('.check button')
    const form = container.querySelector('form.check')
    if (button === null || form === null) throw new Error('no check in the card')
    button.focus()
    const before = panel.view.value
    await act(() => { fireEvent.submit(form) })
    await act(async () => {
      call.give(json(200, {
        verification: { schema: 'masc.runtime_verification.v1', status: 'verified', failure: null },
        runtime: { runtime_id: 'acct_1.claude-sonnet-5', record: 'existing' },
      }))
      // The panel reads the subscriptions again once the check passed.
      await vi.waitFor(() => { expect(panel.view.value).not.toBe(before) })
    })
    expect([panel.checking.checks.value.get('acct_1')?.kind, container.querySelector('.check button') === button, document.activeElement === button])
      .toEqual(['passed', true, true])
  })

  it('lists, in the form of a key, only the subscriptions that take one', async () => {
    const { panel, container } = live({ [paths.integrations]: [offeredWithKey()], [paths.owned]: [ownedNothing()] })
    await act(() => panel.load(sessionOf(person)))
    await act(() => { panel.adding.open() })
    const offeredToLogin = [...container.querySelectorAll('#connect-steps input[type=radio]')].length
    await act(() => { panel.connecting.open() })
    const radios = (steps: string): string[] => [...container.querySelectorAll<HTMLInputElement>(`#${steps} input[type=radio]`)].map((radio) => radio.value)
    expect([offeredToLogin, radios('connect-steps'), radios('key-steps')]).toEqual([0, ['claude_code', 'codex'], ['claude_code']])
  })

  it('shows the card of the account a key was stored for, with the focus on the button that opened the form', async () => {
    const { panel, container } = live({
      [paths.integrations]: [offeredWithKey(), offeredWithKey()],
      [paths.owned]: [ownedNothing(), ownedKey()],
      [addPath]: [keyStored()],
    })
    await act(() => panel.load(sessionOf(person)))
    await act(() => { panel.adding.open() })
    const field = container.querySelector<HTMLInputElement>('#key-value')
    const form = container.querySelector('#key-steps form')
    const submit = container.querySelector<HTMLButtonElement>('#key-steps button[type=submit]')
    if (field === null || form === null || submit === null) throw new Error('no form of a key')
    field.value = 'made-up-key'
    submit.focus()
    const before = panel.view.value
    await act(async () => {
      fireEvent.submit(form)
      await vi.waitFor(() => { expect(panel.view.value).not.toBe(before) })
    })
    expect([
      container.querySelectorAll('li.row').length, container.querySelector('#key-value'), container.innerHTML.includes('made-up-key'),
      document.activeElement === container.querySelector('button[aria-controls=key-steps]'),
    ]).toEqual([1, null, false, true])
  })

  it('keeps what the form of a key says once no subscription takes a key any more, and moves the focus to the heading when the area leaves', async () => {
    const { panel, container } = live({
      [paths.integrations]: [offeredWithKey(), offered()],
      [paths.owned]: [ownedNothing(), ownedNothing()],
      [addPath]: [json(400, { error: 'The subscription takes no key.', code: 'integration_takes_no_key' })],
    })
    await act(() => panel.load(sessionOf(person)))
    await act(() => { panel.adding.open() })
    const field = container.querySelector<HTMLInputElement>('#key-value')
    const form = container.querySelector('#key-steps form')
    const submit = container.querySelector<HTMLButtonElement>('#key-steps button[type=submit]')
    if (field === null || form === null || submit === null) throw new Error('no form of a key')
    field.value = 'made-up-key'
    submit.focus()
    await act(async () => {
      fireEvent.submit(form)
      await vi.waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', integrations: [{ takesKey: false }, { takesKey: false }] }) })
    })
    const said = [
      container.querySelectorAll('#key-steps [role=alert]').length, container.querySelector('#key-value'),
      document.activeElement === container.querySelector('#key-steps h3'),
    ]
    const close = container.querySelector<HTMLButtonElement>('#key-steps button')
    if (close === null) throw new Error('no button that closes the form')
    close.focus()
    await act(() => { close.click() })
    expect([said, container.querySelector('#key-steps'), document.activeElement === container.querySelector('h2')]).toEqual([[1, null, true], null, true])
  })

  /** What the line of the panel says of the accounts that left its list. */
  const lineOf = (container: Element): string => [...container.querySelectorAll('section > [role=status]')].map((one) => one.textContent ?? '').join('')

  /** Presses the remove button of the key account twice: it asks once more before it removes. */
  const pressRemove = async (container: Element): Promise<HTMLButtonElement> => {
    const button = container.querySelector<HTMLButtonElement>('#remove-acct_key')
    if (button === null) throw new Error('no remove button in the card')
    button.focus()
    await act(() => { fireEvent.click(button) })
    await act(() => { fireEvent.click(button) })
    return button
  }

  it('moves the focus to the heading of the panel once an account was removed, and says so in its line', async () => {
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedNothing()],
      [removePath('acct_key')]: [keyRemoved()],
    })
    await act(() => panel.load(sessionOf(person)))
    const before = lineOf(container)
    await pressRemove(container)
    await act(async () => { await vi.waitFor(() => { expect(panel.removing.removing.value.get('acct_key')?.kind).toBe('removed') }) })
    expect([before, lineOf(container) === '', container.querySelectorAll('li.row').length, document.activeElement === container.querySelector('h2')])
      .toEqual(['', false, 0, true])
  })

  it('says that an account it sent a key for was not there, once its card is off the page', async () => {
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedNothing()],
      [replacePath('acct_key')]: [json(404, { error: 'No such account.', code: 'unknown_account' })],
    })
    await act(() => panel.load(sessionOf(person)))
    const before = lineOf(container)
    panel.replacing.open('acct_key')
    await act(async () => { await panel.replacing.replace('acct_key', 'made-up-key') })
    // The page is drawn again when `act` ends, so the wait is for what the panel holds.
    await act(async () => { await vi.waitFor(() => { expect(panel.replacing.replacing.value.get('acct_key')?.kind).toBe('gone') }) })
    expect([before, lineOf(container) === '', container.querySelectorAll('li.row').length]).toEqual(['', false, 0])
  })

  it('does not say that account went while a list that has it is on the page', async () => {
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedKey()],
      [replacePath('acct_key')]: [json(404, { error: 'No such account.', code: 'unknown_account' })],
    })
    await act(() => panel.load(sessionOf(person)))
    panel.replacing.open('acct_key')
    await act(async () => { await panel.replacing.replace('acct_key', 'made-up-key') })
    await act(async () => { await vi.waitFor(() => { expect(panel.replacing.replacing.value.get('acct_key')?.kind).toBe('gone') }) })
    expect([lineOf(container), container.querySelectorAll('li.row').length]).toEqual(['', 1])
  })

  it('says an account went only once its card is off the page, however the readings overlap', async () => {
    const asked = later()
    const newer = later()
    const { panel, sent, container } = live({
      [paths.integrations]: [offered(), offered(), offered()],
      [paths.owned]: [ownedKey(), asked.answer, newer.answer],
      [removePath('acct_key')]: [keyRemoved()],
      [addPath]: ['no answer'],
    })
    await act(() => panel.load(sessionOf(person)))
    await pressRemove(container)
    await act(async () => { await vi.waitFor(() => { expect(sent.filter((one) => one.path === paths.owned).length).toBe(2) }) })
    // A key whose answer did not come asks for a reading too, which replaces
    // the one the removal asked for.
    panel.adding.open()
    await act(async () => { await panel.adding.add('claude_code', 'made-up-key') })
    await act(async () => {
      asked.give(ownedNothing())
      await new Promise((resolve) => { setTimeout(resolve, 0) })
    })
    // The card stays held: the list on the page is not the one of the newest reading.
    const replaced = [panel.removing.removing.value.get('acct_key')?.kind, container.querySelectorAll('li.row').length, lineOf(container)]
    await act(async () => {
      newer.give(ownedNothing())
      await vi.waitFor(() => { expect(panel.removing.removing.value.get('acct_key')?.kind).toBe('removed') })
    })
    expect([replaced, listed(panel), container.querySelectorAll('li.row').length, lineOf(container) === '', document.activeElement === container.querySelector('h2')])
      .toEqual([['sending', 1, ''], 0, 0, false, true])
  })

  it('does not say an account it removed went while a list that has it is on the page', async () => {
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedKey()],
      [removePath('acct_key')]: [keyRemoved()],
    })
    await act(() => panel.load(sessionOf(person)))
    await pressRemove(container)
    await act(async () => { await vi.waitFor(() => { expect(panel.removing.removing.value.get('acct_key')?.kind).toBe('removed') }) })
    expect([lineOf(container), container.querySelectorAll('li.row').length]).toEqual(['', 1])
  })

  it.each([
    ['no answer came', 'no answer' as const],
    ['the server could not record its end', json(503, { error: 'The removal could not be recorded.', code: 'removal_not_recorded' })],
    ['what stands in front of the server failed', new Response('Bad Gateway', { status: 502 })],
  ])('says what it knows of an account that left the list after %s, with the focus on the heading', async (_name, answer) => {
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedNothing()],
      [removePath('acct_key')]: [answer],
    })
    await act(() => panel.load(sessionOf(person)))
    await pressRemove(container)
    await act(async () => { await vi.waitFor(() => { expect(listed(panel)).toBe(0) }) })
    expect([container.querySelectorAll('li.row').length, lineOf(container) === '', document.activeElement === container.querySelector('h2')])
      .toEqual([0, false, true])
  })

  it('moves a focus that was in the card of an account another page removed to the heading', async () => {
    // The reading a key with no answer asks for is the one that finds the
    // account gone. Its answer comes after the step of the key was drawn, as
    // an answer of a server does.
    const reading = later()
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), reading.answer],
      [addPath]: ['no answer'],
    })
    await act(() => panel.load(sessionOf(person)))
    container.querySelector<HTMLButtonElement>('#remove-acct_key')?.focus()
    panel.adding.open()
    await act(async () => { await panel.adding.add('claude_code', 'made-up-key') })
    await act(async () => {
      reading.give(ownedNothing())
      await vi.waitFor(() => { expect(listed(panel)).toBe(0) })
    })
    expect([container.querySelectorAll('li.row').length, lineOf(container), document.activeElement === container.querySelector('h2')]).toEqual([0, '', true])
  })

  it('leaves a focus the person moved elsewhere during a removal where it is', async () => {
    const call = later()
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedNothing()],
      [removePath('acct_key')]: [call.answer],
    })
    await act(() => panel.load(sessionOf(person)))
    await pressRemove(container)
    const elsewhere = document.createElement('button')
    document.body.append(elsewhere)
    elsewhere.focus()
    await act(async () => {
      call.give(keyRemoved())
      await vi.waitFor(() => { expect(panel.removing.removing.value.get('acct_key')?.kind).toBe('removed') })
    })
    const kept = document.activeElement === elsewhere
    elsewhere.remove()
    expect(kept).toBe(true)
  })

  it('keeps the focus on the remove button when the removal stopped and left the account in the list', async () => {
    const { panel, container } = live({
      [paths.integrations]: [offered(), offered()],
      [paths.owned]: [ownedKey(), ownedKey('key_not_removed')],
      [removePath('acct_key')]: [keyStayed()],
    })
    await act(() => panel.load(sessionOf(person)))
    const before = panel.view.value
    const button = await pressRemove(container)
    await act(async () => { await vi.waitFor(() => { expect(panel.view.value).not.toBe(before) }) })
    expect([container.querySelector('#remove-acct_key') === button, document.activeElement === button, container.querySelectorAll('.row [role=alert]').length])
      .toEqual([true, true, 1])
  })

  it('moves the focus to the heading of the panel when a retry reads', async () => {
    const { panel, container } = live({ [paths.integrations]: [notReady(), offered()], [paths.owned]: [ownedNothing(), ownedOne()] })
    await act(() => panel.load(sessionOf(person)))
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
      await act(() => panel.load(sessionOf(person)))
      elsewhere.focus()
      await act(() => panel.retry())
      expect([document.activeElement === elsewhere, container.querySelectorAll('li.row').length]).toEqual([true, 1])
    } finally {
      elsewhere.remove()
    }
  })

  it('moves the focus to the heading of the panel when a reading after a login fails and takes the steps away', async () => {
    const { panel, container } = live({
      [paths.integrations]: [offered(), notReady()],
      [paths.owned]: [ownedNothing(), ownedNothing()],
      [loginPath]: [linking()],
    })
    await act(() => panel.load(sessionOf(person)))
    const toggle = container.querySelector<HTMLButtonElement>('button[aria-controls=connect-steps]')
    if (toggle === null) throw new Error('no button opens the steps')
    toggle.focus()
    await act(() => { panel.connecting.open() })
    await act(() => panel.connecting.start('claude_code'))
    expect([kind(panel), document.activeElement === container.querySelector('h2')]).toEqual([`failed for ${person}`, true])
  })

  it('leaves the focus alone when the first reading reads', async () => {
    const { panel } = live({ [paths.integrations]: [offered()], [paths.owned]: [ownedOne()] })
    await act(() => panel.load(sessionOf(person)))
    expect(document.activeElement).toBe(document.body)
  })

  it('draws what the model reads', async () => {
    const { panel } = start({ [paths.integrations]: [offered()], [paths.owned]: [ownedOne()] })
    const { container } = render(html`<${SubscriptionsPanel} model=${panel} />`)
    await act(() => panel.load(sessionOf(person)))
    expect(container.querySelectorAll('li.row').length).toBe(1)
  })
})
