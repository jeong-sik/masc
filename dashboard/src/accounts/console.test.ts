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
import { ConsoleFrame, createConsole } from './console'
import type { ConsoleModel, Shown, View } from './console'
import { csrfHeader, paths } from './wire'
import type { Send } from './wire'

interface Sent { readonly path: string; readonly init: RequestInit }
type Scripted = Response | 'no answer' | Promise<Response>

/** A `send` that answers from a list, in order, and keeps what was sent. */
function scripted(answers: readonly Scripted[]): { readonly send: Send; readonly sent: Sent[] } {
  const sent: Sent[] = []
  const left = [...answers]
  const send: Send = (path, init) => {
    sent.push({ path, init })
    const next = left.shift()
    if (next === undefined) throw new Error(`no answer was scripted for ${path}`)
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

/** Longer than any wait the console announces or times. */
const longMs = 1000

afterEach(() => {
  cleanup()
  vi.useRealTimers()
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
    ['two answers that name two people', [aSession(), aWho('worker', 'usr_someone_else')], { kind: 'unreadable' }],
  ] as const)('stays and shows the problem of %s', async (_name, answers, problem) => {
    const { model, leave } = start(answers)
    await model.load()
    expect(model.view.value).toEqual({ kind: 'failed', failure: { problem, attempts: 1 }, retrying: false })
    expect(leave).not.toHaveBeenCalled()
  })

  it('reads again on a retry, and says so while it does', async () => {
    let answer: (response: Response) => void = () => {}
    const later = new Promise<Response>((resolve) => { answer = resolve })
    const { model } = start([notReady(), later, aWho()])
    await model.load()
    const retry = model.load()
    expect(model.view.value).toMatchObject({ kind: 'failed', retrying: true })
    answer(aSession())
    await retry
    expect(kinds(model)).toBe('signed_in')
  })

  it('counts the readings that failed in a row', async () => {
    const { model } = start([notReady(), 'no answer'])
    await model.load()
    await model.load()
    expect(model.view.value).toEqual({ kind: 'failed', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, retrying: false })
  })

  it('keeps what failed on the page while a long retry runs', async () => {
    vi.useFakeTimers()
    let answer: (response: Response) => void = () => {}
    const later = new Promise<Response>((resolve) => { answer = resolve })
    const { model } = start([notReady(), later, aWho()])
    await model.load()
    const retry = model.load()
    await vi.advanceTimersByTimeAsync(longMs)
    expect(model.view.value).toMatchObject({ kind: 'failed', retrying: true })
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
    expect(model.view.value).toMatchObject({ kind: 'signed_in', signOut: { kind: 'sending' } })
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

  it.each([
    ['the session ended', noSession()],
    ['another person signed in', aSession('token-of-them', 'usr_someone_else')],
  ] as const)('leaves when the server refuses and %s meanwhile', async (_name, now) => {
    const { model, sent, leave } = await signedIn([staleToken(), now])
    await model.signOut()
    expect(leave).toHaveBeenCalledTimes(1)
    expect(tokens(sent)).toEqual(['token'])
    expect(model.view.value).toMatchObject({ session: { userId: person } })
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
    ['a reading that failed', { kind: 'failed', failure: { problem: refused, attempts: 1 }, retrying: false }],
    ['a retry under way', { kind: 'failed', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, retrying: true }],
    ['signed in', { kind: 'signed_in', session, who, signOut: { kind: 'idle' } }],
    ['signing out', { kind: 'signed_in', session, who, signOut: { kind: 'sending' } }],
    ['a sign-out that failed', { kind: 'signed_in', session, who, signOut: { kind: 'failed', failure: { problem: refused, attempts: 3 } } }],
    ['leaving', { kind: 'leaving' }],
  ]

  /** The frame of one state, over a model that only counts what it is asked. */
  const drawn = (view: View) => {
    const state = signal(view)
    const model = { view: state, load: vi.fn(() => Promise.resolve()), signOut: vi.fn(() => Promise.resolve()) } satisfies ConsoleModel
    return { container: render(html`<${ConsoleFrame} model=${model} />`).container, model, state }
  }
  const count = (selector: string) => views.map(([name, view]) => [name, drawn(view).container.querySelectorAll(selector).length])

  it.each(views)('passes the accessibility rules while %s', async (_name, view) => {
    expect(await axe(drawn(view).container)).toHaveNoViolations()
  })

  it.each(views)('has one main part and one top heading while %s', (_name, view) => {
    const { container } = drawn(view)
    expect([container.querySelectorAll('main').length, container.querySelectorAll('h1').length]).toEqual([1, 1])
  })

  it('offers the way out only to someone signed in', () => {
    expect(count('header button')).toEqual([
      ['reading', 0], ['a long reading', 0], ['a reading that failed', 0], ['a retry under way', 0],
      ['signed in', 1], ['signing out', 1], ['a sign-out that failed', 1], ['leaving', 0],
    ])
  })

  it('says a problem where a screen reader announces it', () => {
    expect(count('[role=alert]').filter(([, found]) => found !== 0)).toEqual([
      ['a reading that failed', 1], ['a retry under way', 1], ['a sign-out that failed', 1],
    ])
  })

  it('has a line a screen reader reads out while the page waits or moves', () => {
    expect(count('[role=status]').filter(([, found]) => found !== 0)).toEqual([
      ['reading', 1], ['a long reading', 1], ['a reading that failed', 1], ['a retry under way', 1], ['leaving', 1],
    ])
  })

  it('marks the button whose request runs, and no other', () => {
    expect(count('button[aria-disabled=true]').filter(([, found]) => found !== 0)).toEqual([
      ['a retry under way', 1], ['signing out', 1],
    ])
  })

  const failedTwice: ReadonlyArray<readonly [string, View, View]> = [
    ['a reading',
      { kind: 'failed', failure: { problem: refused, attempts: 1 }, retrying: false },
      { kind: 'failed', failure: { problem: refused, attempts: 2 }, retrying: false }],
    ['a sign-out',
      { kind: 'signed_in', session, who, signOut: { kind: 'failed', failure: { problem: refused, attempts: 1 } } },
      { kind: 'signed_in', session, who, signOut: { kind: 'failed', failure: { problem: refused, attempts: 2 } } }],
  ]

  it.each(failedTwice)('puts a new note on the page when %s fails again', async (_name, once, twice) => {
    const { container, state } = drawn(once)
    const first = the(container, '[role=alert]')
    state.value = twice
    await waitFor(() => {
      expect(the(container, '[role=alert]')).not.toBe(first)
    })
  })

  it('asks the model to sign out and to read again', () => {
    const signedIn = drawn({ kind: 'signed_in', session, who, signOut: { kind: 'idle' } })
    fireEvent.click(the(signedIn.container, 'header button'))
    expect(signedIn.model.signOut).toHaveBeenCalledTimes(1)
    const failed = drawn({ kind: 'failed', failure: { problem: refused, attempts: 1 }, retrying: false })
    fireEvent.click(the(failed.container, 'main button'))
    expect(failed.model.load).toHaveBeenCalledTimes(1)
  })

  it('moves the focus to the heading after a retry that worked', async () => {
    const { send } = scripted([notReady(), aSession(), aWho()])
    const model = createConsole({ send, leave: vi.fn() })
    await model.load()
    const { container } = render(html`<${ConsoleFrame} model=${model} />`)
    const retry = the(container, 'main button')
    retry.focus()
    expect(document.activeElement).toBe(retry)
    fireEvent.click(retry)
    await waitFor(() => {
      expect(document.activeElement).toBe(the(container, 'h1'))
    })
  })

  it('leaves the focus alone when the first reading ends', async () => {
    const { send } = scripted([aSession(), aWho()])
    const model = createConsole({ send, leave: vi.fn() })
    const { container } = render(html`<${ConsoleFrame} model=${model} />`)
    // The frame moves the focus in an effect, which runs after the page is
    // drawn; `act` runs the effects of the reading before the focus is read.
    await act(() => model.load())
    expect(container.querySelectorAll('header button')).toHaveLength(1)
    expect(document.activeElement).toBe(document.body)
  })
})
