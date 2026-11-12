// @vitest-environment happy-dom
//
// The states of the console frame and how it moves between them, and that
// each state passes the accessibility rules. What a state says and where it
// puts things is not checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ConsoleFrame, createConsole } from './console'
import type { ConsoleModel, View } from './console'
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

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
const aSession = (): Response => json(200, { user_id: 'usr_0123456789', expires_at_ms: 1, csrf_token: 'token' })
const aWho = (role = 'worker'): Response => json(200, { principal: { kind: 'human', id: 'usr_0123456789' }, role, binding: { kind: 'session', id: 's' } })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })
const notReady = (): Response => json(503, { error: 'the files are being read again' })

function start(answers: readonly Scripted[]): { readonly model: ConsoleModel; readonly sent: Sent[]; readonly leave: ReturnType<typeof vi.fn> } {
  const { send, sent } = scripted(answers)
  const leave = vi.fn()
  return { model: createConsole({ send, leave }), sent, leave }
}

const kinds = (model: ConsoleModel): string => model.view.value.kind

/** The one element of `container` that `selector` names. */
function the(container: Element, selector: string): HTMLElement {
  const found = container.querySelectorAll<HTMLElement>(selector)
  const [first] = found
  if (first === undefined || found.length !== 1) throw new Error(`${found.length} elements match ${selector}`)
  return first
}

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
      session: { userId: 'usr_0123456789', csrfToken: 'token' },
      who: { id: 'usr_0123456789', role: 'admin' },
      signOut: { kind: 'idle' },
    })
    expect(sent.map((one) => one.path)).toEqual([paths.session, paths.who])
    expect(leave).not.toHaveBeenCalled()
  })

  it('leaves for the sign-in page when no session came, and asks nothing more', async () => {
    const { model, sent, leave } = start([noSession()])
    await model.load()
    expect(kinds(model)).toBe('leaving')
    expect(leave).toHaveBeenCalledTimes(1)
    expect(sent.map((one) => one.path)).toEqual([paths.session])
  })

  it('leaves when the session ended between the two requests', async () => {
    const { model, leave } = start([aSession(), noSession()])
    await model.load()
    expect(kinds(model)).toBe('leaving')
    expect(leave).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['a refusal', notReady(), { kind: 'refused', status: 503, reason: 'the files are being read again' }],
    ['no answer', 'no answer', { kind: 'unreachable' }],
    ['an answer of another shape', json(200, {}), { kind: 'unreadable' }],
  ] as const)('stays and shows the problem of %s', async (_name, answer, problem) => {
    const { model, leave } = start([answer])
    await model.load()
    expect(model.view.value).toEqual({ kind: 'failed', problem, retrying: false })
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

  it('joins a reading that is under way', async () => {
    const { model, sent } = start([aSession(), aWho()])
    await Promise.all([model.load(), model.load()])
    expect(sent.map((one) => one.path)).toEqual([paths.session, paths.who])
  })

  it('says it is waiting only once the wait is long', async () => {
    vi.useFakeTimers()
    let answer: (response: Response) => void = () => {}
    const later = new Promise<Response>((resolve) => { answer = resolve })
    const { model } = start([later, aWho()])
    const reading = model.load()
    // A tenth of a second passes before a person notices a wait.
    const unnoticedMs = 100
    const longMs = 1000
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
  it('sends the CSRF token of the session and leaves', async () => {
    const { model, sent, leave } = start([aSession(), aWho(), new Response(null, { status: 204 })])
    await model.load()
    await model.signOut()
    expect(kinds(model)).toBe('leaving')
    expect(leave).toHaveBeenCalledTimes(1)
    expect(sent.map((one) => [one.path, new Headers(one.init.headers).get(csrfHeader)])).toEqual([
      [paths.session, null],
      [paths.who, null],
      [paths.signOut, 'token'],
    ])
  })

  it('leaves when no session was left to end', async () => {
    const { model, leave } = start([aSession(), aWho(), noSession()])
    await model.load()
    await model.signOut()
    expect(leave).toHaveBeenCalledTimes(1)
  })

  it('stays signed in and shows the problem when the server refuses', async () => {
    const { model, leave } = start([aSession(), aWho(), notReady()])
    await model.load()
    await model.signOut()
    expect(model.view.value).toMatchObject({
      kind: 'signed_in',
      signOut: { kind: 'failed', problem: { kind: 'refused', status: 503 } },
    })
    expect(leave).not.toHaveBeenCalled()
  })

  it('sends once when it is asked twice', async () => {
    const { model, sent } = start([aSession(), aWho(), new Response(null, { status: 204 })])
    await model.load()
    await Promise.all([model.signOut(), model.signOut()])
    expect(sent.filter((one) => one.path === paths.signOut)).toHaveLength(1)
  })

  it('does nothing before anyone is signed in', async () => {
    const { model, sent } = start([])
    await model.signOut()
    expect(sent).toEqual([])
  })
})

it('keeps nothing of a session in web storage', async () => {
  const { model } = start([aSession(), aWho(), new Response(null, { status: 204 })])
  await model.load()
  await model.signOut()
  expect([localStorage.length, sessionStorage.length]).toEqual([0, 0])
})

describe('the frame', () => {
  const who = { id: 'usr_0123456789', role: 'member' } as const
  const session = { userId: 'usr_0123456789', csrfToken: 'token' } as const
  const refused = { kind: 'refused', status: 503, reason: 'the files are being read again' } as const
  const views: ReadonlyArray<readonly [string, View]> = [
    ['reading', { kind: 'reading', slow: false }],
    ['a long reading', { kind: 'reading', slow: true }],
    ['a reading that failed', { kind: 'failed', problem: refused, retrying: false }],
    ['a retry under way', { kind: 'failed', problem: { kind: 'unreachable' }, retrying: true }],
    ['signed in', { kind: 'signed_in', session, who, signOut: { kind: 'idle' } }],
    ['signing out', { kind: 'signed_in', session, who, signOut: { kind: 'sending' } }],
    ['a sign-out that failed', { kind: 'signed_in', session, who, signOut: { kind: 'failed', problem: refused } }],
    ['leaving', { kind: 'leaving' }],
  ]

  /** The frame of one state, over a model that only counts what it is asked. */
  const drawn = (view: View) => {
    const model = { view: signal(view), load: vi.fn(() => Promise.resolve()), signOut: vi.fn(() => Promise.resolve()) } satisfies ConsoleModel
    return { container: render(html`<${ConsoleFrame} model=${model} />`).container, model }
  }

  it.each(views)('passes the accessibility rules while %s', async (_name, view) => {
    expect(await axe(drawn(view).container)).toHaveNoViolations()
  })

  it.each(views)('has one main part and one top heading while %s', (_name, view) => {
    const { container } = drawn(view)
    expect([container.querySelectorAll('main').length, container.querySelectorAll('h1').length]).toEqual([1, 1])
  })

  it('offers the way out only to someone signed in', () => {
    const buttons = views.map(([name, view]) => [name, drawn(view).container.querySelectorAll('header button').length])
    expect(buttons).toEqual([
      ['reading', 0], ['a long reading', 0], ['a reading that failed', 0], ['a retry under way', 0],
      ['signed in', 1], ['signing out', 1], ['a sign-out that failed', 1], ['leaving', 0],
    ])
  })

  it('says a problem where a screen reader announces it', () => {
    const alerts = views.map(([name, view]) => [name, drawn(view).container.querySelectorAll('[role=alert]').length])
    expect(alerts.filter(([, count]) => count !== 0)).toEqual([['a reading that failed', 1], ['a retry under way', 1], ['a sign-out that failed', 1]])
  })

  it('asks the model to sign out and to read again', () => {
    const signedIn = drawn({ kind: 'signed_in', session, who, signOut: { kind: 'idle' } })
    fireEvent.click(the(signedIn.container, 'header button'))
    expect(signedIn.model.signOut).toHaveBeenCalledTimes(1)
    const failed = drawn({ kind: 'failed', problem: refused, retrying: false })
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
})
