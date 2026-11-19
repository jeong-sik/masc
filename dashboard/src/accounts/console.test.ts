// @vitest-environment happy-dom
//
// The states of the console frame and how it moves between them, and that
// each state passes the accessibility rules. What a state says and where it
// puts things is not checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { createChecks } from './check'
import { createConnect } from './connect'
import { createKeyAdds } from './key-add'
import { createRemovals } from './key-remove'
import { createReplacements } from './key-replace'
import { ConsoleFrame, createConsole } from './console'
import type { ConsoleModel, Shown, View } from './console'
import { createSubscriptions, follow } from './subscriptions'
import type { PanelView, SubscriptionsModel } from './subscriptions'
import { createAllowlist } from './allowlist'
import type { AllowlistModel } from './allowlist'
import { createInvites, followInvites } from './invites'
import type { InvitesModel } from './invites'
import { createKeepers, followKeepers } from './keepers'
import { createMembers } from './members'
import type { MembersModel } from './members'
import type { KeepersModel } from './keepers'
import { createTokens, followTokens } from './tokens'
import type { TokensModel } from './tokens'
import { csrfHeader, paths } from './wire'
import type { Send } from './wire'

interface Sent { readonly path: string; readonly init: RequestInit }
type Scripted = Response | 'no answer' | Promise<Response>

/** Requests that came after the answers of a list ran out. The console reads
    a failed request as no answer, so a test would not see one; each test
    checks at its end that there was none. */
const unscripted: string[] = []
/** The answers of each list made in a test. Each test checks at its end that
    every one was asked for, so a test cannot pass with fewer requests than
    it scripts. */
const scriptedLists: Scripted[][] = []

/** A `send` that answers from a list, in order, and keeps what was sent. */
function scripted(answers: readonly Scripted[]): { readonly send: Send; readonly sent: Sent[] } {
  const sent: Sent[] = []
  const left = [...answers]
  scriptedLists.push(left)
  const send: Send = (path, init) => {
    sent.push({ path, init })
    const next = left.shift()
    if (next === undefined) {
      unscripted.push(path)
      return Promise.reject(new Error(`no answer was scripted for ${path}`))
    }
    return next === 'no answer' ? Promise.reject(new TypeError('fetch failed')) : Promise.resolve(next)
  }
  return { send, sent }
}

const person = 'usr_0123456789'
const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
const aSession = (csrf = 'token', user = person): Response => json(200, { user_id: user, expires_at_ms: 1, csrf_token: csrf })
const aWho = (role = 'worker', id = person): Response => json(200, { principal: { kind: 'human', id }, role, binding: { kind: 'session', id: 's' } })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })
const notReady = (): Response => json(503, { error: 'the files are being read again' })
const staleToken = (): Response => json(403, { error: 'the CSRF token is not the one of the session' })
const signedOut = (): Response => new Response(null, { status: 204 })

function start(answers: readonly Scripted[]): { readonly model: ConsoleModel; readonly sent: Sent[]; readonly leave: ReturnType<typeof vi.fn> } {
  const { send, sent } = scripted(answers)
  const leave = vi.fn()
  return { model: createConsole({ send, leave }), sent, leave }
}

const kinds = (model: ConsoleModel): string => model.view.value.kind
const sentPaths = (sent: readonly Sent[]): string[] => sent.map((one) => one.path)
const tokens = (sent: readonly Sent[]): Array<string | null> =>
  sent.filter((one) => one.path === paths.signOut).map((one) => new Headers(one.init.headers).get(csrfHeader))

/** The one element of `container` that `selector` names. */
function the(container: Element, selector: string): HTMLElement {
  const found = container.querySelectorAll<HTMLElement>(selector)
  const [first] = found
  if (first === undefined || found.length !== 1) throw new Error(`${found.length} elements match ${selector}`)
  return first
}

/** A subscriptions panel that waits for someone to be signed in. The panel
    has its own tests; here it only has to be there. */
const waitingPanel = (): SubscriptionsModel => ({
  view: signal<PanelView>({ kind: 'waiting' }),
  load: vi.fn(() => Promise.resolve()),
  retry: vi.fn(() => Promise.resolve()),
  connecting: createConnect({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() }),
  checking: createChecks({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() }),
  adding: createKeyAdds({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() }),
  removing: createRemovals({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() }),
  replacing: createReplacements({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() }),
  stop: vi.fn(),
})

/** A Keepers panel that waits for someone to be signed in. It has its own
    tests; here it only has to be there. */
const waitingKeepers = (): KeepersModel => createKeepers({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn() })
const waitingTokens = (): TokensModel => createTokens({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), now: () => 0 })
const waitingInvites = (): InvitesModel => createInvites({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn() })
const waitingAllowlist = (): AllowlistModel => createAllowlist({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn() })
const waitingMembers = (): MembersModel => createMembers({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn() })

/** Longer than any wait the console announces or times. */
const longMs = 1000

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  expect(unscripted.splice(0), 'requests that no answer was scripted for').toEqual([])
  const unused = scriptedLists.splice(0).reduce((count, left) => count + left.length, 0)
  expect(unused, 'answers scripted that no request asked for').toBe(0)
})

describe('reading the session', () => {
  it('ends signed in, after the session and then whose it is', async () => {
    const { model, sent, leave } = start([aSession(), aWho('admin')])
    expect(model.view.value).toEqual({ kind: 'reading', slow: false })
    await model.load()
    expect(model.view.value).toEqual({
      kind: 'signed_in',
      session: { userId: person, csrfToken: 'token' },
      who: { id: person, role: 'admin' },
      signOut: { kind: 'idle' },
    })
    expect(sentPaths(sent)).toEqual([paths.session, paths.who])
    expect(leave).not.toHaveBeenCalled()
  })

  it('leaves for the sign-in page when no session came, and asks nothing more', async () => {
    const { model, sent, leave } = start([noSession()])
    await model.load()
    expect(kinds(model)).toBe('leaving')
    expect(leave).toHaveBeenCalledTimes(1)
    expect(sentPaths(sent)).toEqual([paths.session])
  })

  it('leaves when the session ended between the two requests', async () => {
    const { model, leave } = start([aSession(), noSession()])
    await model.load()
    expect(kinds(model)).toBe('leaving')
    expect(leave).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['a refusal of the session', [notReady()], { kind: 'refused', status: 503, reason: 'the files are being read again' }],
    ['no answer', ['no answer'], { kind: 'unreachable' }],
    ['an answer of another shape', [json(200, {})], { kind: 'unreadable' }],
    ['a refusal of whose the session is', [aSession(), notReady()], { kind: 'refused', status: 503, reason: 'the files are being read again' }],
  ] as const)('stays and shows the problem of %s', async (_name, answers, problem) => {
    const { model, leave } = start(answers)
    await model.load()
    expect(model.view.value).toEqual({ kind: 'failed', failure: { problem, attempts: 1 }, next: 'idle' })
    expect(leave).not.toHaveBeenCalled()
  })

  it('says the account changed when the two answers name two people, and reads the one of now on a retry', async () => {
    const { model, sent, leave } = start([aSession(), aWho('worker', 'usr_someone_else'), aSession('t2', 'usr_someone_else'), aWho('worker', 'usr_someone_else')])
    await model.load()
    expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
    await model.load()
    expect(model.view.value).toMatchObject({ kind: 'signed_in', session: { userId: 'usr_someone_else' } })
    expect(sentPaths(sent)).toEqual([paths.session, paths.who, paths.session, paths.who])
    expect(leave).not.toHaveBeenCalled()
  })

  it('reads again on a retry, and says so while it does', async () => {
    let answer: (response: Response) => void = () => {}
    const later = new Promise<Response>((resolve) => { answer = resolve })
    const { model } = start([notReady(), later, aWho()])
    await model.load()
    const retry = model.load()
    expect(model.view.value).toMatchObject({ kind: 'failed', next: 'reading' })
    answer(aSession())
    await retry
    expect(kinds(model)).toBe('signed_in')
  })

  it('keeps the page of a failed reading while it leaves after a retry finds no session', async () => {
    const { model, leave } = start([notReady(), noSession()])
    await model.load()
    await model.load()
    expect(model.view.value).toMatchObject({ kind: 'failed', failure: { attempts: 1 }, next: 'leaving' })
    expect(leave).toHaveBeenCalledTimes(1)
    await model.load()
    expect(leave).toHaveBeenCalledTimes(1)
  })

  it('counts the readings that failed in a row', async () => {
    const { model } = start([notReady(), 'no answer'])
    await model.load()
    await model.load()
    expect(model.view.value).toEqual({ kind: 'failed', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'idle' })
  })

  it('reads nothing while someone is signed in', async () => {
    const { model, sent } = start([aSession(), aWho()])
    await model.load()
    const before = model.view.value
    await model.load()
    expect(model.view.value).toBe(before)
    expect(sentPaths(sent)).toEqual([paths.session, paths.who])
  })

  it('keeps what failed on the page while a long retry runs', async () => {
    vi.useFakeTimers()
    let answer: (response: Response) => void = () => {}
    const later = new Promise<Response>((resolve) => { answer = resolve })
    const { model } = start([notReady(), later, aWho()])
    await model.load()
    const retry = model.load()
    await vi.advanceTimersByTimeAsync(longMs)
    expect(model.view.value).toMatchObject({ kind: 'failed', next: 'reading' })
    answer(aSession())
    await retry
    expect(kinds(model)).toBe('signed_in')
  })

  it('joins a reading that is under way', async () => {
    const { model, sent } = start([aSession(), aWho()])
    await Promise.all([model.load(), model.load()])
    expect(sentPaths(sent)).toEqual([paths.session, paths.who])
  })

  it('says it is waiting only once the wait is long', async () => {
    vi.useFakeTimers()
    let answer: (response: Response) => void = () => {}
    const later = new Promise<Response>((resolve) => { answer = resolve })
    const { model } = start([later, aWho()])
    const reading = model.load()
    // A tenth of a second passes before a person notices a wait.
    const unnoticedMs = 100
    await vi.advanceTimersByTimeAsync(unnoticedMs)
    expect(model.view.value).toEqual({ kind: 'reading', slow: false })
    await vi.advanceTimersByTimeAsync(longMs)
    expect(model.view.value).toEqual({ kind: 'reading', slow: true })
    answer(aSession())
    await reading
    expect(kinds(model)).toBe('signed_in')
  })
})

describe('signing out', () => {
  /** A model that has read the session of `person` with the token `token`. */
  async function signedIn(after: readonly Scripted[]) {
    const started = start([aSession(), aWho(), ...after])
    await started.model.load()
    return started
  }

  it('sends the CSRF token of the session and leaves, with the page as it was', async () => {
    const { model, sent, leave } = await signedIn([signedOut()])
    await model.signOut()
    expect(leave).toHaveBeenCalledTimes(1)
    expect(model.view.value).toMatchObject({ kind: 'signed_in', session: { userId: person }, signOut: { kind: 'out' } })
    expect(sent.map((one) => [one.path, new Headers(one.init.headers).get(csrfHeader)])).toEqual([
      [paths.session, null],
      [paths.who, null],
      [paths.signOut, 'token'],
    ])
  })

  it('leaves when no session was left to end', async () => {
    const { model, leave } = await signedIn([noSession()])
    await model.signOut()
    expect(leave).toHaveBeenCalledTimes(1)
    expect(model.view.value).toMatchObject({ signOut: { kind: 'out' } })
  })

  it('sends nothing more once the person is out', async () => {
    const { model, sent, leave } = await signedIn([signedOut()])
    await model.signOut()
    await model.signOut()
    expect(tokens(sent)).toEqual(['token'])
    expect(leave).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['no answer, and none to the reading after it', ['no answer', 'no answer'], { kind: 'unreachable' }],
    ['an answer it cannot read', [json(200, { ended: true }), aSession()], { kind: 'unreadable' }],
  ] as const)('stays and shows the failure when the sign-out gets %s', async (_name, after, problem) => {
    const { model, leave } = await signedIn(after)
    await model.signOut()
    expect(model.view.value).toMatchObject({ kind: 'signed_in', signOut: { kind: 'failed', failure: { problem, attempts: 1 } } })
    expect(leave).not.toHaveBeenCalled()
  })

  it('stays signed in and shows the problem when the server refuses', async () => {
    const { model, sent, leave } = await signedIn([notReady(), aSession()])
    await model.signOut()
    expect(model.view.value).toMatchObject({
      kind: 'signed_in',
      signOut: { kind: 'failed', failure: { problem: { kind: 'refused', status: 503 }, attempts: 1 } },
    })
    expect(sentPaths(sent).slice(2)).toEqual([paths.signOut, paths.session])
    expect(leave).not.toHaveBeenCalled()
  })

  it('sends again, and counts the refusals', async () => {
    const { model, sent } = await signedIn([notReady(), aSession(), notReady(), aSession()])
    await model.signOut()
    await model.signOut()
    expect(model.view.value).toMatchObject({ signOut: { kind: 'failed', failure: { attempts: 2 } } })
    expect(tokens(sent)).toEqual(['token', 'token'])
  })

  it('sends the token of now when another tab signed in again', async () => {
    const { model, sent, leave } = await signedIn([staleToken(), aSession('token-of-now'), signedOut()])
    await model.signOut()
    expect(tokens(sent)).toEqual(['token', 'token-of-now'])
    expect(leave).toHaveBeenCalledTimes(1)
  })

  it('keeps the token of now for the next press when that one is refused too', async () => {
    const { model, sent } = await signedIn([staleToken(), aSession('token-of-now'), notReady(), notReady(), aSession('token-of-now')])
    await model.signOut()
    expect(model.view.value).toMatchObject({
      session: { csrfToken: 'token-of-now' },
      signOut: { kind: 'failed', failure: { problem: { status: 503 } } },
    })
    await model.signOut()
    expect(tokens(sent)).toEqual(['token', 'token-of-now', 'token-of-now'])
  })

  it('leaves when the server refuses and the session ended meanwhile', async () => {
    const { model, sent, leave } = await signedIn([staleToken(), noSession()])
    await model.signOut()
    expect(leave).toHaveBeenCalledTimes(1)
    expect(tokens(sent)).toEqual(['token'])
    expect(model.view.value).toMatchObject({ session: { userId: person }, signOut: { kind: 'out' } })
  })

  it('says the account changed, and ends no session, when another person signed in meanwhile', async () => {
    const { model, sent, leave } = await signedIn([staleToken(), aSession('token-of-them', 'usr_someone_else')])
    await model.signOut()
    expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
    expect(tokens(sent)).toEqual(['token'])
    expect(leave).not.toHaveBeenCalled()
  })

  it('shows the refusal when the session cannot be read again', async () => {
    const { model } = await signedIn([notReady(), 'no answer'])
    await model.signOut()
    expect(model.view.value).toMatchObject({
      session: { csrfToken: 'token' },
      signOut: { kind: 'failed', failure: { problem: { kind: 'refused', status: 503 } } },
    })
  })

  it('sends once when it is asked twice', async () => {
    const { model, sent } = await signedIn([signedOut()])
    await Promise.all([model.signOut(), model.signOut()])
    expect(tokens(sent)).toHaveLength(1)
  })

  it('does nothing before anyone is signed in', async () => {
    const { model, sent } = start([])
    await model.signOut()
    expect(sent).toEqual([])
  })
})

describe('a request of a panel that the server refused', () => {
  const other = 'usr_someone_else'
  const panelPath = '/api/v1/auth/tokens'
  const write = (token: string): RequestInit => ({ method: 'POST', headers: { accept: 'application/json', [csrfHeader]: token }, body: '{}' })
  const readOnly: RequestInit = { method: 'GET', headers: { accept: 'application/json' } }
  const notAllowed = (): Response => json(403, { error: 'the account may not do this' })
  const toPanel = (sent: readonly Sent[], path = panelPath): number => sent.filter((one) => one.path === path).length
  const readings = (sent: readonly Sent[]): number => sent.filter((one) => one.path === paths.session).length
  const them = (): Response[] => [aSession('token-of-them', other), aWho('worker', other)]
  /** An answer the test gives when it chooses. */
  function later(): { readonly answer: Promise<Response>; readonly give: (response: Response) => void } {
    let give: (response: Response) => void = () => undefined
    const answer = new Promise<Response>((resolve) => { give = resolve })
    return { answer, give }
  }

  /** A model that has read the session of `person` with the token `token`. */
  async function signedIn(after: readonly Scripted[]) {
    const started = start([aSession(), aWho(), ...after])
    await started.model.load()
    return started
  }

  it('reads the session before the panel gets the answer, and takes the token of the same person signed in again', async () => {
    const { model, sent, leave } = await signedIn([staleToken(), aSession('token-of-now'), aWho()])
    const answer = await model.send(panelPath, write('token'))
    expect(answer.status).toBe(403)
    expect(toPanel(sent)).toBe(1)
    expect(model.view.value).toMatchObject({ kind: 'signed_in', session: { userId: person, csrfToken: 'token-of-now' }, signOut: { kind: 'idle' } })
    expect(leave).not.toHaveBeenCalled()
  })

  it('says the account changed when another person signed in', async () => {
    const { model, sent } = await signedIn([staleToken(), ...them()])
    expect((await model.send(panelPath, write('token'))).status).toBe(403)
    expect(toPanel(sent)).toBe(1)
    expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
  })

  it('says the account changed when the two answers of the reading name two people', async () => {
    const { model } = await signedIn([staleToken(), aSession('token-of-now'), aWho('worker', other)])
    await model.send(panelPath, write('token'))
    expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
  })

  it('leaves for the sign-in page when no session is left', async () => {
    const { model, leave } = await signedIn([staleToken(), noSession()])
    expect((await model.send(panelPath, write('token'))).status).toBe(403)
    expect(leave).toHaveBeenCalledTimes(1)
    expect(model.view.value).toEqual({ kind: 'leaving' })
  })

  it('keeps the session when it still has the token sent: the account may not do it', async () => {
    const { model } = await signedIn([notAllowed(), aSession(), aWho()])
    expect((await model.send(panelPath, write('token'))).status).toBe(403)
    expect(model.view.value).toMatchObject({ kind: 'signed_in', session: { csrfToken: 'token' } })
  })

  it('keeps the page when the session cannot be read again', async () => {
    const { model, leave } = await signedIn([staleToken(), 'no answer'])
    expect((await model.send(panelPath, write('token'))).status).toBe(403)
    expect(model.view.value).toMatchObject({ kind: 'signed_in', session: { csrfToken: 'token' } })
    expect(leave).not.toHaveBeenCalled()
  })

  it('reads the session after a refused read too', async () => {
    const { model } = await signedIn([notAllowed(), aSession('token-of-now'), aWho()])
    expect((await model.send(panelPath, readOnly)).status).toBe(403)
    expect(model.view.value).toMatchObject({ kind: 'signed_in', session: { csrfToken: 'token-of-now' } })
  })

  it('reads the session once for refusals that come together', async () => {
    const { model, sent } = await signedIn([staleToken(), staleToken(), aSession('token-of-now'), aWho()])
    const answers = await Promise.all([model.send(panelPath, write('token')), model.send('/api/v1/auth/invites', write('token'))])
    expect(answers.map((one) => one.status)).toEqual([403, 403])
    expect(readings(sent)).toBe(2)
  })

  it('passes every other answer through and reads nothing', async () => {
    const { model, sent } = await signedIn([notReady()])
    expect((await model.send(panelPath, write('token'))).status).toBe(503)
    expect(sentPaths(sent).slice(2)).toEqual([panelPath])
  })

  it('sends nothing before anyone is signed in', async () => {
    const { model, sent } = start([])
    await expect(model.send(panelPath, readOnly)).rejects.toThrow()
    expect(sent).toEqual([])
  })

  it('sends nothing while the page says the account changed', async () => {
    const { model, sent } = await signedIn([staleToken(), ...them()])
    await model.send(panelPath, write('token'))
    await expect(model.send(panelPath, readOnly)).rejects.toThrow()
    expect(toPanel(sent)).toBe(1)
  })

  it('sends nothing once the person signed out', async () => {
    const { model, sent } = await signedIn([signedOut()])
    await model.signOut()
    await expect(model.send(panelPath, readOnly)).rejects.toThrow()
    expect(toPanel(sent)).toBe(0)
  })

  it('keeps the account that changed when a sign-out under way is refused and cannot read the session', async () => {
    const logout = later()
    const { model, leave } = await signedIn([logout.answer, staleToken(), ...them(), 'no answer'])
    const signingOut = model.signOut()
    await model.send(panelPath, write('token'))
    expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
    logout.give(staleToken())
    await signingOut
    expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
    expect(leave).not.toHaveBeenCalled()
  })

  it('sends no second sign-out once the page says the account changed, even when the person is back', async () => {
    const logout = later()
    const { model, sent } = await signedIn([logout.answer, staleToken(), ...them(), aSession('token-of-now')])
    const signingOut = model.signOut()
    await model.send(panelPath, write('token'))
    logout.give(staleToken())
    await signingOut
    expect(tokens(sent)).toEqual(['token'])
    expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
  })

  it('leaves once when a reading finds no session while a sign-out runs', async () => {
    const logout = later()
    const { model, leave } = await signedIn([logout.answer, staleToken(), noSession()])
    const signingOut = model.signOut()
    await model.send(panelPath, write('token'))
    logout.give(signedOut())
    await signingOut
    expect(leave).toHaveBeenCalledTimes(1)
    expect(model.view.value).toEqual({ kind: 'leaving' })
  })

  it('keeps the newer token a reading found when a sign-out under way cannot read the session', async () => {
    const logout = later()
    const { model, sent } = await signedIn([logout.answer, staleToken(), aSession('token-of-now'), aWho(), 'no answer', notReady()])
    const signingOut = model.signOut()
    await model.send(panelPath, write('token'))
    logout.give(notReady())
    await signingOut
    expect(model.view.value).toMatchObject({
      kind: 'signed_in',
      session: { csrfToken: 'token-of-now' },
      signOut: { kind: 'failed', failure: { problem: { status: 503 } } },
    })
    expect(tokens(sent)).toEqual(['token', 'token-of-now'])
  })

  it('keeps the token a reading found while the second sign-out request was under way', async () => {
    const secondLogout = later()
    const { model, sent } = await signedIn([staleToken(), aSession('token-of-now'), secondLogout.answer, staleToken(), aSession('token-newest'), aWho()])
    const signingOut = model.signOut()
    await waitFor(() => { expect(tokens(sent)).toEqual(['token', 'token-of-now']) })
    await model.send(panelPath, write('token-of-now'))
    expect(model.view.value).toMatchObject({ session: { csrfToken: 'token-newest' } })
    secondLogout.give(notReady())
    await signingOut
    expect(model.view.value).toMatchObject({ kind: 'signed_in', session: { csrfToken: 'token-newest' }, signOut: { kind: 'failed' } })
  })

  it('drops a reading that a sign-out moved the page past', async () => {
    const session = later()
    const { model, sent } = await signedIn([staleToken(), session.answer, notReady(), aSession(), aWho('worker', other)])
    const refused = model.send(panelPath, write('token'))
    // The reading after the refusal has asked for the session; the person
    // presses sign-out, which reads it again and finds the same person.
    await waitFor(() => { expect(readings(sent)).toBe(2) })
    await model.signOut()
    session.give(aSession('token-of-them', other))
    await refused
    expect(model.view.value).toMatchObject({ kind: 'signed_in', who: { id: person }, signOut: { kind: 'failed' } })
  })

  it('lets an Admin make an invitation on the next press after signing in again in another tab, with no new page', async () => {
    const invitesPath = '/api/v1/auth/invites'
    const { send, sent } = scripted([
      aSession(), aWho('admin'), json(200, { invites: [] }),
      staleToken(), aSession('token-of-now'), aWho('admin'), json(200, { invites: [] }),
      json(200, { invite_id: 'inv_1', role: 'member', expires_at_ms: 1, link: '/accounts/invite#secret' }), json(200, { invites: [] }),
    ])
    const model = createConsole({ send, leave: vi.fn() })
    const invites = createInvites({ send: model.send, leave: vi.fn() })
    const stop = followInvites(model.view, invites)
    await model.load()
    await waitFor(() => { expect(invites.view.value.kind).toBe('read') })
    await invites.make('member')
    expect(invites.making.value).toMatchObject({ kind: 'refused', problem: { status: 403 } })
    await waitFor(() => { expect(sent).toHaveLength(7) })
    await waitFor(() => { expect(invites.view.value.kind).toBe('read') })
    await invites.make('member')
    expect(invites.making.value).toMatchObject({ kind: 'issued', issued: { id: 'inv_1' } })
    const posted = sent.filter((one) => one.path === invitesPath && one.init.method === 'POST')
    expect(posted.map((one) => new Headers(one.init.headers).get(csrfHeader))).toEqual(['token', 'token-of-now'])
    await waitFor(() => { expect(sent).toHaveLength(9) })
    stop()
  })

  describe('a panel shown again to the same person after the account changed', () => {
    const readsOf = (sent: readonly Sent[], path: string): number =>
      sent.filter((one) => one.path === path && one.init.method !== 'POST').length
    const aPat = (id: string) =>
      ({ pat_id: id, scope: { runtimes: 'all', channels: ['direct'], allowed_effects: ['read_state'] }, expires_at_ms: null, issued_at_ms: 1, status: 'open' })
    /** The console over `answers`, before its first reading. */
    function shown(answers: readonly Scripted[]): { readonly model: ConsoleModel; readonly sent: Sent[] } {
      const { send, sent } = scripted(answers)
      return { model: createConsole({ send, leave: vi.fn() }), sent }
    }

    interface Following { readonly kind: () => string; readonly unfollow: () => void }
    const followers: ReadonlyArray<readonly [string, (send: Send, frame: ConsoleModel['view']) => Following, () => Response[]]> = [
      ['tokens', (send, frame) => {
        const panel = createTokens({ send, leave: vi.fn(), now: () => 0 })
        return { kind: () => panel.view.value.kind, unfollow: followTokens(frame, panel) }
      }, () => [json(200, { pats: [] })]],
      ['Keepers', (send, frame) => {
        const panel = createKeepers({ send, leave: vi.fn() })
        return { kind: () => panel.view.value.kind, unfollow: followKeepers(frame, panel) }
      }, () => [json(200, { keepers: [] })]],
      ['subscriptions', (send, frame) => {
        const panel = createSubscriptions({ send, leave: vi.fn() })
        return { kind: () => panel.view.value.kind, unfollow: follow(frame, panel) }
      }, () => [json(200, { integrations: [] }), json(200, { provider_accounts: [], runtimes: [] })]],
    ]

    // The reading went out while the console showed the person, and its
    // answer may be of the account the browser holds now. Kept, it would
    // stand for the person once they are back.
    it.each(followers)('drops a reading of the %s that was under way when the account changed', async (_name, panelOf, lists) => {
      const late = lists().map(() => later())
      const { model, sent } = shown([
        aSession(), aWho(), ...late.map((one) => one.answer),
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), ...lists(),
      ])
      const panel = panelOf(model.send, model.view)
      await model.load()
      await waitFor(() => { expect(sent).toHaveLength(2 + late.length) })
      await model.send(panelPath, write('token'))
      expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
      for (const one of late) one.give(notReady())
      await new Promise((resolve) => { setTimeout(resolve, 0) })
      expect(panel.kind()).toBe('waiting')
      await model.load()
      await waitFor(() => { expect(panel.kind()).toBe('read') })
      panel.unfollow()
    })

    it('reads the tokens again, not the failure of the reading that ran while no one was shown', async () => {
      const patsPath = '/api/v1/auth/pats'
      const { model, sent } = shown([
        aSession(), aWho(), json(200, { pats: [] }),
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), json(200, { pats: [] }),
      ])
      const panel = createTokens({ send: model.send, leave: vi.fn(), now: () => 0 })
      const stop = followTokens(model.view, panel)
      await model.load()
      await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
      await panel.make('read_only', 'days_7')
      expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
      // The list read after the refusal could not be sent; the panel forgot it.
      expect(panel.view.value).toEqual({ kind: 'waiting' })
      await model.load()
      await waitFor(() => { expect(readsOf(sent, patsPath)).toBe(2) })
      await waitFor(() => { expect(panel.view.value).toEqual({ kind: 'read', forUser: person, pats: [] }) })
      // The refusal is the person's, and stays with them.
      expect(panel.making.value).toMatchObject({ kind: 'refused', problem: { status: 403 } })
      stop()
    })

    it('keeps a token made for the person shown again, and drops it for another person', async () => {
      const issued = json(200, { pat_id: 'pat_1', token: 'masc_pat_pat_1_secret' })
      const backAgain = shown([
        aSession(), aWho(), json(200, { pats: [] }), issued.clone(), json(200, { pats: [aPat('pat_1')] }),
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), json(200, { pats: [aPat('pat_1')] }),
      ])
      const someoneElse = shown([
        aSession(), aWho(), json(200, { pats: [] }), issued.clone(), json(200, { pats: [aPat('pat_1')] }),
        staleToken(), ...them(),
        ...them(), json(200, { pats: [] }),
      ])
      const madeThen = async ({ model }: { readonly model: ConsoleModel }): Promise<TokensModel['making']['value']> => {
        const panel = createTokens({ send: model.send, leave: vi.fn(), now: () => 0 })
        const stop = followTokens(model.view, panel)
        await model.load()
        await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
        await panel.make('read_only', 'never')
        await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', pats: [{ id: 'pat_1' }] }) })
        await model.send(panelPath, write('token'))
        expect(panel.view.value).toEqual({ kind: 'waiting' })
        await model.load()
        await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
        stop()
        return panel.making.value
      }
      expect(await madeThen(backAgain)).toMatchObject({ kind: 'issued', issued: { id: 'pat_1', token: 'masc_pat_pat_1_secret' } })
      expect(await madeThen(someoneElse)).toEqual({ kind: 'idle' })
    })

    it('reads the tokens again when a token made before the change is answered after the person is back', async () => {
      const made = later()
      const { model, sent } = shown([
        aSession(), aWho(), json(200, { pats: [] }),
        made.answer,
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), json(200, { pats: [] }),
        json(200, { pats: [aPat('pat_1')] }),
      ])
      const panel = createTokens({ send: model.send, leave: vi.fn(), now: () => 0 })
      const stop = followTokens(model.view, panel)
      await model.load()
      await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
      const making = panel.make('read_only', 'never')
      await model.send(panelPath, write('token'))
      await model.load()
      await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', pats: [] }) })
      made.give(json(200, { pat_id: 'pat_1', token: 'masc_pat_pat_1_secret' }))
      await making
      await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', pats: [{ id: 'pat_1' }] }) })
      expect(panel.making.value).toMatchObject({ kind: 'issued', issued: { id: 'pat_1' } })
      expect(readsOf(sent, '/api/v1/auth/pats')).toBe(3)
      stop()
    })

    it('reads the Keepers again', async () => {
      const keepersPath = '/api/v1/auth/keepers'
      const { model, sent } = shown([
        aSession(), aWho(), json(200, { keepers: [] }),
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), json(200, { keepers: [] }),
      ])
      const panel = createKeepers({ send: model.send, leave: vi.fn() })
      const stop = followKeepers(model.view, panel)
      await model.load()
      await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
      expect(await panel.make('alpha', null)).toMatchObject({ kind: 'refused', problem: { status: 403 } })
      expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
      await model.load()
      await waitFor(() => { expect(readsOf(sent, keepersPath)).toBe(2) })
      await waitFor(() => { expect(panel.view.value).toEqual({ kind: 'read', forUser: person, keepers: [] }) })
      expect(panel.making.value).toMatchObject({ kind: 'refused', problem: { status: 403 } })
      stop()
    })

    it('reads the Keepers again when a Keeper made before the change is answered while the list is read', async () => {
      const keepersPath = '/api/v1/auth/keepers'
      const made = later()
      const list = later()
      const { model, sent } = shown([
        aSession(), aWho(), json(200, { keepers: [] }),
        made.answer,
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), list.answer,
        json(200, { keepers: [{ keeper_id: 'alpha', runtime_id: null }] }),
      ])
      const panel = createKeepers({ send: model.send, leave: vi.fn() })
      const stop = followKeepers(model.view, panel)
      await model.load()
      await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
      const making = panel.make('alpha', null)
      await model.send(panelPath, write('token'))
      await model.load()
      await waitFor(() => { expect(readsOf(sent, keepersPath)).toBe(2) })
      // The make is answered while the list is read: that reading may not hold it.
      made.give(json(200, { keeper_id: 'alpha', record: 'made' }))
      expect(await making).toMatchObject({ kind: 'made', name: 'alpha' })
      list.give(json(200, { keepers: [] }))
      await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', keepers: [{ id: 'alpha' }] }) })
      expect(readsOf(sent, keepersPath)).toBe(3)
      stop()
    })

    it('reads the Keepers again when a make before the change ends unknown while the list is read', async () => {
      const keepersPath = '/api/v1/auth/keepers'
      const made = later()
      const list = later()
      const { model, sent } = shown([
        aSession(), aWho(), json(200, { keepers: [] }),
        made.answer,
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), list.answer,
        json(200, { keepers: [{ keeper_id: 'alpha', runtime_id: null }] }),
      ])
      const panel = createKeepers({ send: model.send, leave: vi.fn() })
      const stop = followKeepers(model.view, panel)
      await model.load()
      await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
      const making = panel.make('alpha', null)
      await model.send(panelPath, write('token'))
      await model.load()
      await waitFor(() => { expect(readsOf(sent, keepersPath)).toBe(2) })
      // The server failed on its side: the Keeper may have been made.
      made.give(notReady())
      expect(await making).toMatchObject({ kind: 'unknown', name: 'alpha' })
      list.give(json(200, { keepers: [] }))
      await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', keepers: [{ id: 'alpha' }] }) })
      expect(readsOf(sent, keepersPath)).toBe(3)
      stop()
    })

    it('reads the subscriptions again', async () => {
      const offered = (): Response => json(200, { integrations: [] })
      const ownedNothing = (): Response => json(200, { provider_accounts: [], runtimes: [] })
      const { model, sent } = shown([
        aSession(), aWho(), offered(), ownedNothing(),
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), offered(), ownedNothing(),
      ])
      const panel = createSubscriptions({ send: model.send, leave: vi.fn() })
      const stop = follow(model.view, panel)
      await model.load()
      await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
      // Another panel's write meets the session of another person.
      await model.send(panelPath, write('token'))
      expect(model.view.value).toEqual({ kind: 'changed', next: 'idle' })
      await model.load()
      await waitFor(() => { expect(readsOf(sent, paths.integrations)).toBe(2) })
      await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', forUser: person }) })
      stop()
    })

    it('keeps a check of the person shown again, and reads again once it passes', async () => {
      const claude = { integration_id: 'claude_code', display_name: 'Claude Code', connect: ['login'], models: ['claude-sonnet-5'], withheld: [], calls: 'allowed' }
      const offered = (): Response => json(200, { integrations: [claude] })
      const account = { provider_account_id: 'acct_1', kind: 'login', integration_id: 'claude_code' }
      const runtime = { runtime_id: 'acct_1.claude-sonnet-5', provider_account_id: 'acct_1', model: 'claude-sonnet-5' }
      const owned = (...runtimes: readonly unknown[]): Response => json(200, { provider_accounts: [account], runtimes })
      const passed = json(200, {
        verification: {
          schema: 'masc.runtime_verification.v1', runtime_id: runtime.runtime_id, model: runtime.model, observed_model: null,
          status: 'verified', checks: { response: true, tool_called: true, tool_roundtrip: true }, failure: null,
        },
        runtime: { runtime_id: runtime.runtime_id, record: 'made' },
      })
      const checked = later()
      const { model, sent } = shown([
        aSession(), aWho(), offered(), owned(),
        checked.answer,
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), offered(), owned(),
        offered(), owned(runtime),
      ])
      const panel = createSubscriptions({ send: model.send, leave: vi.fn() })
      const stop = follow(model.view, panel)
      await model.load()
      await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
      const checking = panel.checking.check('acct_1', 'claude-sonnet-5')
      await model.send(panelPath, write('token'))
      await model.load()
      await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', owned: { runtimes: [] } }) })
      expect(panel.checking.checks.value.get('acct_1')).toMatchObject({ kind: 'checking' })
      checked.give(passed)
      await checking
      expect(panel.checking.checks.value.get('acct_1')).toMatchObject({ kind: 'passed' })
      await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', owned: { runtimes: [{ id: runtime.runtime_id }] } }) })
      expect(readsOf(sent, paths.owned)).toBe(3)
      stop()
    })

    it('reads the subscriptions again when a check passes while they are read', async () => {
      const claude = { integration_id: 'claude_code', display_name: 'Claude Code', connect: ['login'], models: ['claude-sonnet-5'], withheld: [], calls: 'allowed' }
      const offered = (): Response => json(200, { integrations: [claude] })
      const account = { provider_account_id: 'acct_1', kind: 'login', integration_id: 'claude_code' }
      const runtime = { runtime_id: 'acct_1.claude-sonnet-5', provider_account_id: 'acct_1', model: 'claude-sonnet-5' }
      const owned = (...runtimes: readonly unknown[]): Response => json(200, { provider_accounts: [account], runtimes })
      const passed = json(200, {
        verification: {
          schema: 'masc.runtime_verification.v1', runtime_id: runtime.runtime_id, model: runtime.model, observed_model: null,
          status: 'verified', checks: { response: true, tool_called: true, tool_roundtrip: true }, failure: null,
        },
        runtime: { runtime_id: runtime.runtime_id, record: 'made' },
      })
      const checked = later()
      const offeredLate = later()
      const { model, sent } = shown([
        aSession(), aWho(), offered(), owned(),
        checked.answer,
        staleToken(), ...them(),
        aSession('token-of-now'), aWho(), offeredLate.answer, owned(),
        offered(), owned(runtime),
      ])
      const panel = createSubscriptions({ send: model.send, leave: vi.fn() })
      const stop = follow(model.view, panel)
      await model.load()
      await waitFor(() => { expect(panel.view.value.kind).toBe('read') })
      const checking = panel.checking.check('acct_1', 'claude-sonnet-5')
      await model.send(panelPath, write('token'))
      await model.load()
      await waitFor(() => { expect(readsOf(sent, paths.owned)).toBe(2) })
      // The owned accounts were read before the check recorded its Runtime.
      checked.give(passed)
      await checking
      offeredLate.give(offered())
      await waitFor(() => { expect(panel.view.value).toMatchObject({ kind: 'read', owned: { runtimes: [{ id: runtime.runtime_id }] } }) })
      expect(readsOf(sent, paths.owned)).toBe(3)
      stop()
    })
  })
})

it('keeps nothing of a session in web storage', async () => {
  const { model } = start([aSession(), aWho(), signedOut()])
  await model.load()
  await model.signOut()
  expect([localStorage.length, sessionStorage.length]).toEqual([0, 0])
})

describe('the frame', () => {
  const who = { id: person, role: 'member' } as const
  const session = { userId: person, csrfToken: 'token' } as const
  const refused: Shown = { kind: 'refused', status: 503, reason: 'the files are being read again' }
  const views: ReadonlyArray<readonly [string, View]> = [
    ['reading', { kind: 'reading', slow: false }],
    ['a long reading', { kind: 'reading', slow: true }],
    ['leaving', { kind: 'leaving' }],
    ['a reading that failed', { kind: 'failed', failure: { problem: refused, attempts: 1 }, next: 'idle' }],
    ['a retry under way', { kind: 'failed', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'reading' }],
    ['a retry that found no session', { kind: 'failed', failure: { problem: refused, attempts: 1 }, next: 'leaving' }],
    ['an account that changed', { kind: 'changed', next: 'idle' }],
    ['a reading of the account of now', { kind: 'changed', next: 'reading' }],
    ['signed in', { kind: 'signed_in', session, who, signOut: { kind: 'idle' } }],
    ['signing out', { kind: 'signed_in', session, who, signOut: { kind: 'sending' } }],
    ['a sign-out that failed', { kind: 'signed_in', session, who, signOut: { kind: 'failed', failure: { problem: refused, attempts: 3 } } }],
    ['signed out', { kind: 'signed_in', session, who, signOut: { kind: 'out' } }],
  ]
  const named = (...names: string[]) => views.map(([name]) => [name, names.includes(name) ? 1 : 0])

  /** The frame of one state, over a model that only counts what it is asked. */
  const drawn = (view: View) => {
    const state = signal(view)
    const model = {
      view: state,
      load: vi.fn(() => Promise.resolve()),
      signOut: vi.fn(() => Promise.resolve()),
      send: () => Promise.reject(new Error('nothing is sent')),
    } satisfies ConsoleModel
    return { container: render(html`<${ConsoleFrame} model=${model} subscriptions=${waitingPanel()} keepers=${waitingKeepers()} tokens=${waitingTokens()} invites=${waitingInvites()} allowlist=${waitingAllowlist()} members=${waitingMembers()} />`).container, model, state }
  }
  const count = (selector: string) => views.map(([name, view]) => [name, drawn(view).container.querySelectorAll(selector).length])

  it.each(views)('passes the accessibility rules while %s', async (_name, view) => {
    expect(await axe(drawn(view).container)).toHaveNoViolations()
  })

  it.each(views)('has one main part and one top heading while %s', (_name, view) => {
    const { container } = drawn(view)
    expect([container.querySelectorAll('main').length, container.querySelectorAll('h1').length]).toEqual([1, 1])
  })

  it('draws the subscriptions panel only for someone signed in', () => {
    expect(count('section[aria-labelledby="subscriptions-heading"]')).toEqual(named('signed in', 'signing out', 'a sign-out that failed', 'signed out'))
  })

  it('draws the invitations, allowlist and members panels only for an Admin signed in', () => {
    const panel = ['invites-heading', 'allowlist-heading', 'members-heading'].map((id) => `section[aria-labelledby="${id}"]`).join(', ')
    const admin = drawn({ kind: 'signed_in', session, who: { id: person, role: 'admin' }, signOut: { kind: 'idle' } })
    expect([count(panel), admin.container.querySelectorAll(panel).length]).toEqual([named(), 3])
  })

  it('offers the way out only to someone signed in', () => {
    expect(count('header button')).toEqual(named('signed in', 'signing out', 'a sign-out that failed', 'signed out'))
  })

  it('says a problem where a screen reader announces it', () => {
    expect(count('[role=alert]')).toEqual(named(
      'a reading that failed', 'a retry under way', 'a retry that found no session',
      'an account that changed', 'a reading of the account of now', 'a sign-out that failed'))
  })

  // The panels under the frame have lines of their own; these are the frame's.
  it('has one line a screen reader reads out, which is filled while the page waits or moves', () => {
    expect(count('main > [role=status]')).toEqual(named(...views.map(([name]) => name)))
    const filled = views.map(([name, view]) => [name, the(drawn(view).container, 'main > [role=status]').textContent === '' ? 0 : 1])
    expect(filled).toEqual(named(
      'a long reading', 'leaving', 'a retry under way', 'a retry that found no session', 'a reading of the account of now', 'signed out'))
  })

  it('marks the button whose request runs, and no other', () => {
    expect(count('button[aria-disabled=true]')).toEqual(named(
      'a retry under way', 'a retry that found no session', 'a reading of the account of now', 'signing out', 'signed out'))
  })

  it('asks the model to sign out and to read again', () => {
    const signedIn = drawn({ kind: 'signed_in', session, who, signOut: { kind: 'idle' } })
    fireEvent.click(the(signedIn.container, 'header button'))
    expect(signedIn.model.signOut).toHaveBeenCalledTimes(1)
    for (const view of [
      { kind: 'failed', failure: { problem: refused, attempts: 1 }, next: 'idle' },
      { kind: 'changed', next: 'idle' },
    ] as const) {
      const shown = drawn(view)
      fireEvent.click(the(shown.container, 'main button'))
      expect(shown.model.load).toHaveBeenCalledTimes(1)
    }
  })

  /** The frame over a model that answers from a list. */
  const live = (answers: readonly Scripted[]) => {
    const { send } = scripted(answers)
    const model = createConsole({ send, leave: vi.fn() })
    return { model, container: render(html`<${ConsoleFrame} model=${model} subscriptions=${waitingPanel()} keepers=${waitingKeepers()} tokens=${waitingTokens()} invites=${waitingInvites()} allowlist=${waitingAllowlist()} members=${waitingMembers()} />`).container }
  }

  it('puts a new note on the page when a reading fails again', async () => {
    const { model, container } = live([notReady(), notReady()])
    await act(() => model.load())
    const first = the(container, '[role=alert]')
    await act(() => model.load())
    expect(the(container, '[role=alert]')).not.toBe(first)
  })

  it('puts a new note on the page when a sign-out fails again', async () => {
    const { model, container } = live([aSession(), aWho(), notReady(), aSession(), notReady(), aSession()])
    await act(() => model.load())
    await act(() => model.signOut())
    const first = the(container, '[role=alert]')
    await act(() => model.signOut())
    expect(the(container, '[role=alert]')).not.toBe(first)
  })

  it('keeps the focus on the sign-out button while the browser leaves', async () => {
    const { model, container } = live([aSession(), aWho(), signedOut()])
    await act(() => model.load())
    const button = the(container, 'header button')
    button.focus()
    await act(() => model.signOut())
    expect(document.activeElement).toBe(button)
  })

  it('moves the focus to the heading when a sign-out finds that the account changed', async () => {
    const { model, container } = live([aSession(), aWho(), staleToken(), aSession('token-of-them', 'usr_someone_else')])
    await act(() => model.load())
    the(container, 'header button').focus()
    await act(() => model.signOut())
    expect(container.querySelectorAll('header button')).toHaveLength(0)
    expect(document.activeElement).toBe(the(container, 'h1'))
  })

  it('keeps the focus on the button when a retry finds that the account changed', async () => {
    const { model, container } = live([notReady(), aSession(), aWho('worker', 'usr_someone_else')])
    await act(() => model.load())
    const button = the(container, 'main button')
    button.focus()
    await act(() => model.load())
    expect(model.view.value.kind).toBe('changed')
    expect(document.activeElement).toBe(button)
  })

  it('moves the focus to the heading after a retry that worked', async () => {
    const { model, container } = live([notReady(), aSession(), aWho()])
    await act(() => model.load())
    const retry = the(container, 'main button')
    retry.focus()
    expect(document.activeElement).toBe(retry)
    fireEvent.click(retry)
    await waitFor(() => {
      expect(document.activeElement).toBe(the(container, 'h1'))
    })
  })

  it('leaves the focus alone when the first reading ends', async () => {
    const { model, container } = live([aSession(), aWho()])
    // The frame moves the focus in an effect, which runs after the page is
    // drawn; `act` runs the effects of the reading before the focus is read.
    await act(() => model.load())
    expect(container.querySelectorAll('header button')).toHaveLength(1)
    expect(document.activeElement).toBe(document.body)
  })
})
