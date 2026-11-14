// @vitest-environment happy-dom
//
// The tokens of a person: what the server's answers read as, what a token
// made and revoked sends, how the list and the requests move, and the panel
// in each step. What a step says and where it puts things is not checked
// here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { TokensPanel } from './token-rows'
import { createTokens, expiresAtOf } from './tokens'
import type { ListView, Make, Revoke, TokensModel } from './tokens'
import { issue, list, patsPath, readIssued, readPats, readScope, revoke, scopeOf, useOf } from './tokens-wire'
import type { Pat } from './tokens-wire'
import { csrfHeader } from './wire'
import type { Send, Session } from './wire'

interface Sent { readonly path: string; readonly init: RequestInit }
type Scripted = Response | 'no answer' | Promise<Response>

/** A `send` that gives the scripted answers in order, and keeps what was sent. */
function answering(answers: readonly Scripted[]): { readonly send: Send; readonly sent: Sent[] } {
  const sent: Sent[] = []
  const left = [...answers]
  const send: Send = (path, init) => {
    sent.push({ path, init })
    const next = left.shift()
    if (next === undefined) return Promise.reject(new Error(`no answer was scripted for ${path}`))
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

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

const day = 86_400_000
const issuedAt = 1_763_000_000_000
const readOnlyBody = { runtimes: 'all', channels: ['direct'], allowed_effects: ['read_state'] }
const mcpBody = { runtimes: 'all', channels: ['direct'], allowed_effects: ['invoke_model', 'manage_own_keeper', 'manage_own_provider', 'read_state', 'use_tool'] }
const patJson = (id: string, extra: Record<string, unknown> = {}) =>
  ({ pat_id: id, scope: readOnlyBody, expires_at_ms: issuedAt + 30 * day, issued_at_ms: issuedAt, status: 'open', ...extra })
const listed = (...pats: readonly unknown[]): Response => json(200, { pats })
const issuedAnswer = (id: string): Response => json(200, { pat_id: id, token: `masc_pat_${id}_secret` })
const revoked = (): Response => new Response(null, { status: 204 })

const first: Session = { userId: 'usr_first', csrfToken: 'token-1' }
const second: Session = { userId: 'usr_second', csrfToken: 'token-2' }

const methods = (sent: readonly Sent[]): string[] => sent.map((one) => `${String(one.init.method)} ${one.path}`)
const patsOf = (model: TokensModel): readonly Pat[] | null => {
  const now = model.view.value
  return now.kind === 'read' ? now.pats : null
}

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('reading the answers about tokens', () => {
  it('reads a scope of each use, and knows the use by its scope', () => {
    expect([readScope(readOnlyBody), readScope(mcpBody)]).toEqual([scopeOf('read_only'), scopeOf('mcp')])
    expect([useOf(scopeOf('read_only')), useOf(scopeOf('mcp'))]).toEqual(['read_only', 'mcp'])
    const custom = readScope({ runtimes: ['rt_1'], channels: 'all', allowed_effects: ['read_state'] })
    expect([custom, custom === null ? 'unread' : useOf(custom)]).toEqual([{ runtimes: ['rt_1'], channels: 'all', effects: ['read_state'] }, null])
  })

  it('does not read a scope the server would not have written', () => {
    expect([
      readScope({ channels: ['direct'], runtimes: 'all', allowed_effects: ['read_state'] }),
      readScope({ ...readOnlyBody, allowed_effects: ['use_tool', 'read_state'] }),
      readScope({ ...readOnlyBody, allowed_effects: ['read_state', 'read_state'] }),
      readScope({ ...readOnlyBody, allowed_effects: ['read_everything'] }),
      readScope({ ...readOnlyBody, channels: ['email'] }),
      readScope({ ...readOnlyBody, runtimes: [''] }),
      readScope({ ...readOnlyBody, allowed_effects: 'some' }),
      readScope({ ...readOnlyBody, extra: true }),
      readScope('all'),
    ]).toEqual([null, null, null, null, null, null, null, null, null])
  })

  it('reads the tokens of the person, with a status it does not know kept apart', () => {
    expect(readPats({ pats: [patJson('pat_1'), patJson('pat_2', { expires_at_ms: null, status: 'paused' })] })).toEqual([
      { id: 'pat_1', scope: scopeOf('read_only'), expiresAtMs: issuedAt + 30 * day, issuedAtMs: issuedAt, status: 'open' },
      { id: 'pat_2', scope: scopeOf('read_only'), expiresAtMs: null, issuedAtMs: issuedAt, status: 'unrecognised' },
    ])
  })

  it('does not read a list with a token that is not what the route promises', () => {
    const bad = [
      { pats: [patJson('pat_1'), patJson('pat_1')] },
      { pats: [patJson('')] },
      { pats: [patJson('pat_1', { scope: { ...readOnlyBody, allowed_effects: ['x'] } })] },
      { pats: [patJson('pat_1', { issued_at_ms: -1 })] },
      { pats: [patJson('pat_1', { expires_at_ms: 1.5 })] },
      { pats: [patJson('pat_1', { status: 1 })] },
      { pats: 'none' },
    ]
    expect(bad.map(readPats)).toEqual(bad.map(() => null))
  })

  it('reads a token made, and nothing that lacks its id or its secret', () => {
    expect([readIssued({ pat_id: 'pat_1', token: 't' }), readIssued({ pat_id: 'pat_1' }), readIssued({ pat_id: 'pat_1', token: '' }), readIssued({ token: 't' })]).toEqual([{ id: 'pat_1', token: 't' }, null, null, null])
  })

  it('counts an expiry from the time given, or none', () => {
    expect(['days_7', 'days_30', 'days_90', 'never'].map((one) => expiresAtOf(one as 'days_7', 1000))).toEqual([1000 + 7 * day, 1000 + 30 * day, 1000 + 90 * day, null])
  })
})

describe('sending about tokens', () => {
  it('lists, makes and revokes with the cookie of the session, and the CSRF token on each write', async () => {
    const { send, sent } = answering([listed(), issuedAnswer('pat_1'), revoked()])
    await list(send)
    await issue(send, 'token-1', scopeOf('mcp'), issuedAt)
    await revoke(send, 'token-1', 'pat_1/x')
    expect(sent.map(({ path, init }) => {
      const headers = new Headers(init.headers)
      return [path, init.method, init.credentials, headers.get(csrfHeader), headers.has('authorization'), init.body ?? null]
    })).toEqual([
      [patsPath, 'GET', 'same-origin', null, false, null],
      [patsPath, 'POST', 'same-origin', 'token-1', false, JSON.stringify({ scope: mcpBody, expires_at_ms: issuedAt })],
      [`${patsPath}/pat_1%2Fx`, 'DELETE', 'same-origin', 'token-1', false, null],
    ])
  })

  it('takes a revoke only from a 204', async () => {
    const { send } = answering([json(200, {}), json(409, { error: 'revoked already' })])
    expect([await revoke(send, 't', 'pat_1'), await revoke(send, 't', 'pat_1')]).toEqual([
      { ok: false, problem: { kind: 'unreadable' } },
      { ok: false, problem: { kind: 'refused', status: 409, reason: 'revoked already' } },
    ])
  })
})

describe('the tokens of a person', () => {
  const loaded = async (answers: readonly Scripted[], now = () => issuedAt) => {
    const { send, sent } = answering([listed(patJson('pat_1')), ...answers])
    const leave = vi.fn()
    const model = createTokens({ send, leave, now })
    await model.load(first)
    return { model, sent, leave }
  }
  const settled = async (sent: readonly Sent[], gets: number) => {
    await vi.waitFor(() => { expect(sent.filter((one) => one.init.method === 'GET').length).toBe(gets) })
  }

  it('reads the tokens, says when it waits, and reads again after a failure', async () => {
    vi.useFakeTimers()
    const wait = later()
    const { send } = answering([wait.answer, json(503, { error: 'not now' }), listed(patJson('pat_1'))])
    const model = createTokens({ send, leave: vi.fn(), now: () => issuedAt })
    const run = model.load(first)
    await vi.advanceTimersByTimeAsync(1000)
    const slow = model.view.value
    wait.give(json(503, { error: 'not now' }))
    await run
    await model.retry()
    const failed = model.view.value
    await model.retry()
    expect([slow, failed.kind === 'failed' ? failed.failure.attempts : null, patsOf(model)?.length]).toEqual([{ kind: 'reading', forUser: 'usr_first', slow: true }, 2, 1])
  })

  it('makes a token of the scope of its use, shows it until the person took it, and reads the list again', async () => {
    const { model, sent } = await loaded([issuedAnswer('pat_2'), listed(patJson('pat_1'), patJson('pat_2'))])
    await model.make('mcp', 'days_7')
    await vi.waitFor(() => { expect(patsOf(model)?.length).toBe(2) })
    const shown = model.making.value
    await model.make('read_only', 'never')
    model.forget()
    expect([shown, methods(sent).filter((one) => one.startsWith('POST')).length, model.making.value, patsOf(model)?.length]).toEqual([
      { kind: 'issued', use: 'mcp', issued: { id: 'pat_2', token: 'masc_pat_pat_2_secret' } }, 1, { kind: 'idle' }, 2,
    ])
    expect(JSON.parse(String(sent[1]?.init.body))).toEqual({ scope: mcpBody, expires_at_ms: issuedAt + 7 * day })
  })

  it('keeps the token made out of the storage of the browser', async () => {
    const { model, sent } = await loaded([issuedAnswer('pat_2'), listed()])
    await model.make('mcp', 'days_30')
    await settled(sent, 2)
    expect([localStorage.length, sessionStorage.length]).toEqual([0, 0])
  })

  it('counts the refusals of a make, and does not know what came of one the server failed', async () => {
    const { model, sent } = await loaded([json(403, { error: 'disabled' }), listed(), json(403, { error: 'disabled' }), listed(), json(503, { error: 'uncertain' }), listed(), 'no answer', listed()])
    const kinds = []
    for (let n = 0; n < 4; n += 1) {
      await model.make('read_only', 'days_30')
      await settled(sent, n + 2)
      const now = model.making.value
      kinds.push(now.kind === 'refused' || now.kind === 'unknown' ? [now.kind, now.attempts] : null)
    }
    expect(kinds).toEqual([['refused', 1], ['refused', 2], ['unknown', 3], ['unknown', 4]])
  })

  it('makes one token at a time, and none before the list is read', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed()])
    const run = model.make('mcp', 'days_30')
    await model.make('mcp', 'days_30')
    wait.give(issuedAnswer('pat_2'))
    await run
    const reading = createTokens({ send: answering([]).send, leave: vi.fn(), now: () => issuedAt })
    await reading.make('mcp', 'days_30')
    const unread = answering([json(503, { error: 'not now' })])
    const failing = createTokens({ send: unread.send, leave: vi.fn(), now: () => issuedAt })
    await failing.load(first)
    await failing.make('mcp', 'days_30')
    expect([methods(sent).filter((one) => one.startsWith('POST')).length, reading.making.value, methods(unread.sent)]).toEqual([1, { kind: 'idle' }, [`GET ${patsPath}`]])
  })

  it('drops a make that answers after another person is shown', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed()])
    const making = model.make('mcp', 'days_30')
    await model.load(second)
    wait.give(issuedAnswer('pat_2'))
    await making
    expect([model.making.value, methods(sent).filter((one) => one.startsWith('GET')).length]).toEqual([{ kind: 'idle' }, 2])
  })

  it('keeps the newest session of the person shown, and does not read the list again for it', async () => {
    const { model, sent } = await loaded([revoked(), listed()])
    await model.load({ userId: 'usr_first', csrfToken: 'token-1b' })
    await model.revoke('pat_1')
    await settled(sent, 2)
    expect([methods(sent), new Headers(sent[1]?.init.headers).get(csrfHeader)]).toEqual([
      [`GET ${patsPath}`, `DELETE ${patsPath}/pat_1`, `GET ${patsPath}`], 'token-1b',
    ])
  })

  it('takes the latest reading of the list, not one that answers after it', async () => {
    const wait = later()
    const { model } = await loaded([issuedAnswer('pat_2'), wait.answer, revoked(), listed(patJson('pat_1', { status: 'revoked' }), patJson('pat_2'))])
    await model.make('mcp', 'days_30')
    await model.revoke('pat_1')
    await vi.waitFor(() => { expect(patsOf(model)?.length).toBe(2) })
    wait.give(listed(patJson('pat_1')))
    await new Promise((resolve) => { setTimeout(resolve, 20) })
    expect(patsOf(model)?.map((one) => one.status)).toEqual(['revoked', 'open'])
  })

  it('reads the list again when a revoke answers while the list is read', async () => {
    const slowRevoke = later()
    const slowRead = later()
    const { model, sent } = await loaded([slowRevoke.answer, json(404, { error: 'no PAT' }), json(503, { error: 'not now' }), slowRead.answer, listed(patJson('pat_1', { status: 'revoked' }))])
    const revoking = model.revoke('pat_1')
    await model.revoke('pat_2')
    await vi.waitFor(() => { expect(model.view.value.kind).toBe('failed') })
    const retried = model.retry()
    slowRevoke.give(revoked())
    await revoking
    slowRead.give(listed(patJson('pat_1')))
    await retried
    expect([patsOf(model)?.map((one) => one.status), sent.filter((one) => one.init.method === 'GET').length]).toEqual([['revoked'], 4])
  })

  it('leaves once when two requests find that the session ended, and marks the revoke under way', async () => {
    const wait = later()
    const { model, leave } = await loaded([wait.answer, noSession()])
    const revoking = model.revoke('pat_1')
    await model.make('mcp', 'days_30')
    const marked = model.revoking.value.get('pat_1')
    wait.give(noSession())
    await revoking
    expect([model.making.value, marked, model.revoking.value.get('pat_1'), leave.mock.calls.length]).toEqual([{ kind: 'leaving' }, { kind: 'leaving' }, { kind: 'leaving' }, 1])
  })

  it('forgets the token made and drops a late answer when another person is shown', async () => {
    const wait = later()
    const { model, sent } = await loaded([issuedAnswer('pat_2'), listed(), wait.answer, listed()])
    await model.make('mcp', 'days_30')
    await settled(sent, 2)
    const revoking = model.revoke('pat_1')
    await model.load(second)
    wait.give(revoked())
    await revoking
    expect([model.making.value, model.revoking.value.size, model.view.value.kind === 'read' ? model.view.value.forUser : null]).toEqual([{ kind: 'idle' }, 0, 'usr_second'])
    expect(new Headers(sent[3]?.init.headers).get(csrfHeader)).toBe('token-1')
  })

  it('leaves once when a request finds that the session ended, and takes the token made off the page', async () => {
    const { model, leave } = await loaded([issuedAnswer('pat_2'), noSession()])
    await model.make('mcp', 'days_30')
    await vi.waitFor(() => { expect(leave).toHaveBeenCalled() })
    await model.make('mcp', 'days_30')
    expect([model.making.value, model.view.value.kind, leave.mock.calls.length]).toEqual([{ kind: 'leaving' }, 'leaving', 1])
  })

  it('revokes a token and reads the list again, and takes one revoked elsewhere as revoked', async () => {
    const { model, sent } = await loaded([revoked(), listed(patJson('pat_1', { status: 'revoked' })), json(409, { error: 'revoked already' }), listed()])
    await model.revoke('pat_1')
    await settled(sent, 2)
    const done = model.revoking.value.get('pat_1')
    await model.revoke('pat_1')
    await settled(sent, 3)
    expect([done, model.revoking.value.get('pat_1')]).toEqual([{ kind: 'done', already: false }, { kind: 'done', already: true }])
  })

  it('counts the refusals of a revoke, and does not know what came of one the server failed', async () => {
    const { model, sent } = await loaded([json(404, { error: 'no PAT' }), listed(), json(500, { error: 'bug' }), listed()])
    await model.revoke('pat_1')
    await settled(sent, 2)
    await model.revoke('pat_1')
    await settled(sent, 3)
    const now = model.revoking.value.get('pat_1')
    expect(now?.kind === 'unknown' ? now.attempts : null).toBe(2)
  })

  it('revokes a token once at a time', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed()])
    const run = model.revoke('pat_1')
    await model.revoke('pat_1')
    wait.give(revoked())
    await run
    expect(methods(sent).filter((one) => one.startsWith('DELETE')).length).toBe(1)
  })
})

// ---- the panel ----

const pat = (id: string, extra: Partial<Pat> = {}): Pat =>
  ({ id, scope: scopeOf('read_only'), expiresAtMs: issuedAt + 30 * day, issuedAtMs: issuedAt, status: 'open', ...extra })
const readView = (pats: readonly Pat[]): ListView => ({ kind: 'read', forUser: 'usr_first', pats })
const showing = (view: ListView, making: Make = { kind: 'idle' }, revoking: ReadonlyMap<string, Revoke> = new Map()): TokensModel => ({
  view: signal(view),
  making: signal(making),
  revoking: signal(revoking),
  load: vi.fn(() => Promise.resolve()),
  retry: vi.fn(() => Promise.resolve()),
  make: vi.fn(() => Promise.resolve()),
  forget: vi.fn(),
  revoke: vi.fn(() => Promise.resolve()),
})
const panelOf = (model: TokensModel) =>
  render(html`<main><h1>내 계정</h1><${TokensPanel} model=${model} /></main>`).container

describe('the tokens panel', () => {
  const many = [
    pat('pat_open'),
    pat('pat_mcp', { scope: scopeOf('mcp'), expiresAtMs: null, issuedAtMs: issuedAt + day }),
    pat('pat_expired', { status: 'expired' }),
    pat('pat_revoked', { status: 'revoked' }),
    pat('pat_lost', { status: 'unknown' }),
    pat('pat_new_word', { status: 'unrecognised', scope: { runtimes: ['rt_1'], channels: 'all', effects: 'all' } }),
  ]
  const forbiddenProblem = { kind: 'refused', status: 403, reason: 'disabled' } as const
  const unreadList: ListView = { kind: 'failed', forUser: 'usr_first', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'idle' }
  const madeNow: Make = { kind: 'issued', use: 'mcp', issued: { id: 'pat_new', token: 'masc_pat_secret' } }
  const steps: ReadonlyArray<readonly [string, TokensModel]> = [
    ['while the list is read', showing({ kind: 'reading', forUser: 'usr_first', slow: true })],
    ['when the list could not be read', showing(unreadList)],
    ['with a token just made and a list that could not be read again', showing(unreadList, madeNow)],
    ['with no token', showing(readView([]))],
    ['with a token in each status', showing(readView(many))],
    ['while a token is made', showing(readView([]), { kind: 'sending', use: 'mcp' })],
    ['with a token just made', showing(readView([]), { kind: 'issued', use: 'mcp', issued: { id: 'pat_new', token: 'masc_pat_secret_with_no_place_to_break_it' } })],
    ['with a make refused', showing(readView([]), { kind: 'refused', use: 'mcp', problem: forbiddenProblem, attempts: 2 })],
    ['with a make whose end it does not know', showing(readView([]), { kind: 'unknown', use: 'mcp', problem: { kind: 'unreadable' }, attempts: 1 })],
    ['while a token is revoked', showing(readView([pat('pat_1')]), { kind: 'idle' }, new Map([['pat_1', { kind: 'sending' }]]))],
    ['with a revoke refused', showing(readView([pat('pat_1')]), { kind: 'idle' }, new Map([['pat_1', { kind: 'refused', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 }]]))],
    ['with a revoke whose end it does not know', showing(readView([pat('pat_1')]), { kind: 'idle' }, new Map([['pat_1', { kind: 'unknown', problem: { kind: 'unreachable' }, attempts: 1 }]]))],
    ['while the browser leaves', showing({ kind: 'leaving', forUser: 'usr_first' }, { kind: 'leaving' })],
  ]
  const each = <T>(look: (container: Element) => T) => steps.map(([name, model]) => {
    const found = look(panelOf(model))
    cleanup()
    return [name, found]
  })
  const named = (values: Readonly<Record<string, unknown>>, otherwise: unknown) => steps.map(([name]) => [name, name in values ? values[name] : otherwise])

  it.each(steps)('passes the accessibility rules %s', async (_name, model) => {
    expect(await axe(panelOf(model))).toHaveNoViolations()
  })

  it('says each request that came to nothing where a screen reader announces it', () => {
    expect(each((container) => container.querySelectorAll('[role=alert]').length)).toEqual(named({
      'when the list could not be read': 1,
      'with a token just made and a list that could not be read again': 1,
      'with a make refused': 1,
      'with a make whose end it does not know': 1,
      'with a revoke refused': 1,
      'with a revoke whose end it does not know': 1,
    }, 0))
  })

  it('marks the button that makes a token while one is made or shown, or the browser leaves', () => {
    expect(each((container) => container.querySelector('form button[type=submit]')?.getAttribute('aria-disabled') ?? 'none')).toEqual(named({
      'while the list is read': 'none',
      'when the list could not be read': 'none',
      'with a token just made and a list that could not be read again': 'none',
      'while a token is made': 'true',
      'with a token just made': 'true',
      'while the browser leaves': 'none',
    }, 'false'))
  })

  it('lists the newest token first, with a revoke button only for one that still works', () => {
    const container = panelOf(showing(readView(many)))
    const rows = [...container.querySelectorAll('.rows > li')]
    expect(rows.map((row) => [row.querySelector('h3')?.id, row.querySelector('button') !== null])).toEqual([
      ['token-title-pat_mcp', true], ['token-title-pat_open', true], ['token-title-pat_expired', false],
      ['token-title-pat_revoked', false], ['token-title-pat_lost', false], ['token-title-pat_new_word', false],
    ])
  })

  it('names every button with what it does and the token it is for, and says what a press does', () => {
    const container = panelOf(showing(readView([pat('pat_1')])))
    const button = container.querySelector<HTMLButtonElement>('#token-revoke-pat_1')
    const line = () => document.getElementById(button?.getAttribute('aria-describedby') ?? '')?.textContent?.trim() ?? null
    const before = line()
    if (button !== null) fireEvent.click(button)
    const submit = container.querySelector('form button[type=submit]')
    const tip = document.getElementById(submit?.getAttribute('aria-describedby') ?? '')?.textContent?.trim() ?? ''
    expect([
      button?.getAttribute('aria-labelledby'), container.querySelector('#token-back-pat_1')?.getAttribute('aria-labelledby'), before, line() !== '', tip !== '',
    ]).toEqual(['token-revoke-pat_1 token-title-pat_1', 'token-back-pat_1 token-title-pat_1', '', true, true])
  })

  it('marks the revoke button while its revoke runs or is done, or the browser leaves', () => {
    const revokes: ReadonlyArray<Revoke | undefined> = [
      undefined, { kind: 'sending' }, { kind: 'done', already: false }, { kind: 'leaving' },
      { kind: 'refused', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 }, { kind: 'unknown', problem: { kind: 'unreachable' }, attempts: 1 },
    ]
    expect(revokes.map((one) => {
      const container = panelOf(showing(readView([pat('pat_1')]), { kind: 'idle' }, one === undefined ? new Map() : new Map([['pat_1', one]])))
      const marked = container.querySelector('#token-revoke-pat_1')?.getAttribute('aria-disabled')
      cleanup()
      return marked
    })).toEqual(['false', 'true', 'true', 'true', 'false', 'false'])
  })

  it('makes a new alert for each failure in a row, so a screen reader says the second one too', async () => {
    const failure = (attempts: number): ListView => ({ ...unreadList, failure: { problem: { kind: 'unreachable' }, attempts } })
    const refused = (attempts: number): Make => ({ kind: 'refused', use: 'mcp', problem: forbiddenProblem, attempts })
    const unknown = (attempts: number): Revoke => ({ kind: 'unknown', problem: { kind: 'unreachable' }, attempts })
    const view = signal(failure(1))
    const making = signal(refused(1))
    const alerts = (container: Element) => [...container.querySelectorAll('[role=alert]')]
    const listed = panelOf({ ...showing(readView([])), view, making })
    const firstAlerts = alerts(listed)
    await act(() => { view.value = failure(2); making.value = refused(2) })
    const secondAlerts = alerts(listed)
    cleanup()
    const revoking = signal<ReadonlyMap<string, Revoke>>(new Map([['pat_1', unknown(1)]]))
    const row = panelOf({ ...showing(readView([pat('pat_1')])), revoking })
    const firstRevoke = alerts(row)
    await act(() => { revoking.value = new Map([['pat_1', unknown(2)]]) })
    const secondRevoke = alerts(row)
    expect([firstAlerts.length, secondAlerts.filter((one) => firstAlerts.includes(one)).length, firstRevoke.length, secondRevoke.filter((one) => firstRevoke.includes(one)).length]).toEqual([2, 0, 1, 0])
  })

  it('keeps the use and the expiry picked when the form is drawn again', async () => {
    const making = signal<Make>({ kind: 'idle' })
    const model = { ...showing(readView([])), making }
    const container = panelOf(model)
    const select = container.querySelector<HTMLSelectElement>('#token-expiry')
    const before = select?.value
    const mcp = container.querySelector<HTMLInputElement>('input[value=mcp]')
    if (mcp !== null) fireEvent.click(mcp)
    if (select !== null) fireEvent.change(select, { target: { value: 'never' } })
    await act(() => { making.value = { kind: 'sending', use: 'mcp' } })
    await act(() => { making.value = { kind: 'refused', use: 'mcp', problem: forbiddenProblem, attempts: 1 } })
    const form = container.querySelector('form')
    if (form !== null) fireEvent.submit(form)
    expect([before, mcp?.checked, select?.value, vi.mocked(model.make).mock.calls]).toEqual(['days_30', true, 'never', [['mcp', 'never']]])
  })

  it('revokes only on a second press, and a cancel puts the focus back on the button', async () => {
    const model = showing(readView([pat('pat_1')]))
    const container = panelOf(model)
    const button = container.querySelector<HTMLButtonElement>('#token-revoke-pat_1')
    if (button === null) throw new Error('no revoke button')
    fireEvent.click(button)
    const asked = vi.mocked(model.revoke).mock.calls.length
    const back = container.querySelector<HTMLButtonElement>('#token-back-pat_1')
    back?.focus()
    if (back !== null) fireEvent.click(back)
    await act(() => undefined)
    const focus = document.activeElement
    fireEvent.click(button)
    fireEvent.click(button)
    expect([asked, focus === button, container.querySelector('#token-back-pat_1'), vi.mocked(model.revoke).mock.calls]).toEqual([0, true, null, [['pat_1']]])
  })

  it('asks for nothing on a press of a button that is marked', () => {
    const model = showing(readView([pat('pat_1')]), { kind: 'sending', use: 'mcp' }, new Map([['pat_1', { kind: 'sending' }]]))
    const container = panelOf(model)
    const revokeButton = container.querySelector<HTMLButtonElement>('#token-revoke-pat_1')
    if (revokeButton !== null) {
      fireEvent.click(revokeButton)
      fireEvent.click(revokeButton)
    }
    const form = container.querySelector('form')
    if (form !== null) fireEvent.submit(form)
    expect([vi.mocked(model.revoke).mock.calls.length, vi.mocked(model.make).mock.calls.length]).toEqual([0, 0])
  })

  it('makes a token of the use and the expiry picked', () => {
    const model = showing(readView([]))
    const container = panelOf(model)
    const mcp = container.querySelector<HTMLInputElement>('input[value=mcp]')
    if (mcp !== null) fireEvent.click(mcp)
    const select = container.querySelector<HTMLSelectElement>('#token-expiry')
    if (select !== null) fireEvent.change(select, { target: { value: 'never' } })
    const form = container.querySelector('form')
    if (form !== null) fireEvent.submit(form)
    expect(vi.mocked(model.make).mock.calls).toEqual([['mcp', 'never']])
  })

  // happy-dom has no `spellcheck` property, so the field's spelling check is read in a browser.
  it('shows a token made in a field it can be copied from', async () => {
    const writeText = vi.fn(() => Promise.resolve())
    vi.stubGlobal('navigator', { ...navigator, clipboard: { writeText } })
    const model = showing(readView([]), { kind: 'issued', use: 'mcp', issued: { id: 'pat_new', token: 'masc_pat_secret' } })
    const container = panelOf(model)
    const field = container.querySelector<HTMLTextAreaElement>('#token-secret')
    if (field !== null) fireEvent.focus(field)
    const copy = [...container.querySelectorAll('button')].find((one) => one.textContent === '복사')
    if (copy !== undefined) fireEvent.click(copy)
    await vi.waitFor(() => { expect(writeText).toHaveBeenCalled() })
    vi.unstubAllGlobals()
    expect([field?.value, field?.readOnly, field?.getAttribute('autocomplete'), [field?.selectionStart, field?.selectionEnd], writeText.mock.calls]).toEqual([
      'masc_pat_secret', true, 'off', [0, 'masc_pat_secret'.length], [['masc_pat_secret']],
    ])
  })

  it('says so when the token could not be copied, on the same line each time', async () => {
    const said = []
    for (const clipboard of [{ writeText: vi.fn(() => Promise.reject(new Error('not allowed'))) }, null]) {
      vi.stubGlobal('navigator', clipboard === null ? {} : { clipboard })
      const container = panelOf(showing(readView([]), madeNow))
      const line = container.querySelector('[role=group] [role=status]')
      const copy = [...container.querySelectorAll('button')].find((one) => one.textContent === '복사')
      if (copy !== undefined) fireEvent.click(copy)
      await vi.waitFor(() => { expect(container.querySelector('[role=group] [role=status]')?.textContent).not.toBe('') })
      said.push(container.querySelector('[role=group] [role=status]') === line)
      vi.unstubAllGlobals()
      cleanup()
    }
    expect(said).toEqual([true, true])
  })

  it('keeps a token made on the page when the list could not be read again, and puts the focus on the heading once it was taken', async () => {
    const making = signal<Make>(madeNow)
    const model = { ...showing(unreadList), making, forget: vi.fn(() => { making.value = { kind: 'idle' } }) }
    const container = panelOf(model)
    const field = container.querySelector('#token-secret')
    const done = [...container.querySelectorAll<HTMLButtonElement>('button')].find((one) => one.textContent === '다 옮겼어요')
    done?.focus()
    if (done !== undefined) fireEvent.click(done)
    await act(() => undefined)
    expect([field !== null, document.activeElement?.id]).toEqual([true, 'tokens-heading'])
  })

  it('puts the focus on the heading once a retry read the list', async () => {
    const view = signal<ListView>(unreadList)
    const container = panelOf({ ...showing(readView([])), view })
    const retry = [...container.querySelectorAll<HTMLButtonElement>('button')].find((one) => one.textContent === '다시 시도')
    retry?.focus()
    await act(() => { view.value = readView([]) })
    expect([retry !== undefined, document.activeElement?.id]).toEqual([true, 'tokens-heading'])
  })

  it('puts the focus on the title of the form once the person took the token', async () => {
    const making = signal<Make>({ kind: 'issued', use: 'mcp', issued: { id: 'pat_new', token: 'masc_pat_secret' } })
    const model = { ...showing(readView([])), making, forget: vi.fn(() => { making.value = { kind: 'idle' } }) }
    const container = panelOf(model)
    const done = [...container.querySelectorAll<HTMLButtonElement>('button')].find((one) => one.textContent === '다 옮겼어요')
    done?.focus()
    if (done !== undefined) fireEvent.click(done)
    await act(() => undefined)
    expect([model.forget.mock.calls.length, document.activeElement?.id]).toEqual([1, 'token-new-title'])
  })

  it('puts the focus on the title of a token once it no longer works', async () => {
    const view = signal<ListView>(readView([pat('pat_1')]))
    const container = panelOf({ ...showing(readView([])), view })
    container.querySelector<HTMLButtonElement>('#token-revoke-pat_1')?.focus()
    await act(() => { view.value = readView([pat('pat_1', { status: 'revoked' })]) })
    expect(document.activeElement?.id).toBe('token-title-pat_1')
  })

  it('keeps the line a screen reader reads out under the heading as one element in every step', async () => {
    const view = signal<ListView>({ kind: 'reading', forUser: 'usr_first', slow: true })
    const container = panelOf({ ...showing(readView([])), view })
    const line = () => container.querySelector('#tokens-heading ~ [role=status]')
    const first = line()
    const same = []
    for (const next of steps.map(([, model]) => model.view.peek())) {
      await act(() => { view.value = next })
      same.push(line() === first)
    }
    expect([first !== null, same.every(Boolean)]).toEqual([true, true])
  })

  it('says that the session ended on one line only', () => {
    const container = panelOf(showing({ kind: 'leaving', forUser: 'usr_first' }, { kind: 'leaving' }))
    const said = [...container.querySelectorAll('[role=status]')].filter((one) => (one.textContent ?? '').trim() !== '')
    expect(said.length).toBe(1)
  })

  it('stops saying what a second press does once the token no longer works', async () => {
    const view = signal<ListView>(readView([pat('pat_1')]))
    const container = panelOf({ ...showing(readView([])), view })
    const button = container.querySelector<HTMLButtonElement>('#token-revoke-pat_1')
    if (button !== null) fireEvent.click(button)
    const armed = container.querySelector('#token-line-pat_1')?.textContent ?? ''
    await act(() => { view.value = readView([pat('pat_1', { status: 'revoked' })]) })
    expect([armed !== '', container.querySelector('#token-line-pat_1')?.textContent]).toEqual([true, ''])
  })

  it('keeps the line of a make and the line of a token as one element in every step, a token that stopped working included', async () => {
    const making = signal<Make>({ kind: 'idle' })
    const revoking = signal<ReadonlyMap<string, Revoke>>(new Map())
    const view = signal<ListView>(readView([pat('pat_1')]))
    const container = panelOf({ ...showing(readView([])), view, making, revoking })
    const makeLine = () => container.querySelectorAll('section > [role=status]')[1]
    const rowLine = () => container.querySelector('#token-line-pat_1')
    const firstMake = makeLine()
    const firstRow = rowLine()
    const same = []
    const makes: readonly Make[] = [
      { kind: 'sending', use: 'mcp' }, madeNow, { kind: 'refused', use: 'mcp', problem: forbiddenProblem, attempts: 1 },
      { kind: 'unknown', use: 'mcp', problem: { kind: 'unreadable' }, attempts: 1 }, { kind: 'leaving' }, { kind: 'idle' },
    ]
    for (const next of makes) {
      await act(() => { making.value = next })
      same.push(makeLine() === firstMake)
    }
    const revokes: readonly Revoke[] = [
      { kind: 'sending' }, { kind: 'refused', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 },
      { kind: 'unknown', problem: { kind: 'unreachable' }, attempts: 1 }, { kind: 'leaving' }, { kind: 'done', already: false },
    ]
    for (const next of revokes) {
      await act(() => { revoking.value = new Map([['pat_1', next]]) })
      same.push(rowLine() === firstRow)
    }
    await act(() => { view.value = readView([pat('pat_1', { status: 'revoked' })]) })
    expect([firstMake !== undefined, firstRow !== null, same, rowLine() === firstRow, rowLine()?.textContent !== '']).toEqual([
      true, true, makes.map(() => true).concat(revokes.map(() => true)), true, true,
    ])
  })
})
