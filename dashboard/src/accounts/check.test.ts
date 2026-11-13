// @vitest-environment happy-dom
//
// Checking a model of an account: what the server's answer reads as, what a
// check sends, how the check of each account moves, and the card of an
// account in each step. What a step says and where it puts things is not
// checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AccountList } from './account-rows'
import { checkModel, checkPath, createChecks, readChecked } from './check'
import type { Check, ChecksModel } from './check'
import { csrfHeader } from './wire'
import type { Integration, Owned, Send } from './wire'

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

const schema = 'masc.runtime_verification.v1'
const verification = (status: string, failure: unknown) => ({
  schema, runtime_id: 'acct_1.claude-sonnet-5', model: 'claude-sonnet-5', observed_model: null, status,
  checks: { response: false, tool_called: false, tool_roundtrip: false }, failure,
})
const passedBody = (record = 'made') =>
  ({ verification: verification('verified', null), runtime: { runtime_id: 'acct_1.claude-sonnet-5', record } })
const failedBody = (code = 'rate_limited', status = 'failed', message: unknown = 'The provider is rate limiting this account.') =>
  ({ verification: verification(status, { code, message, detail: null }), runtime: null })

const passed = (record?: string): Response => json(200, passedBody(record))
const failed = (code?: string): Response => json(200, failedBody(code))
const busy = (): Response => json(409, { error: 'A call of this account is running.' })
const notReady = (): Response => json(503, { error: 'The private login recovery record could not be saved.' })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('reading the answer of a check', () => {
  it('reads a call that passed, and whether it made the Runtime', () => {
    expect([readChecked(passedBody('made')), readChecked(passedBody('existing'))]).toEqual([
      { kind: 'passed', made: true },
      { kind: 'passed', made: false },
    ])
  })

  it.each([
    ['rate_limited', 'failed'],
    ['timed_out', 'failed'],
    ['tool_result_not_consumed', 'failed'],
    ['client_not_authenticated', 'unavailable'],
    ['account_not_authorized', 'unavailable'],
  ])('reads a call that did not pass, %s', (code, status) => {
    expect(readChecked(failedBody(code, status))).toEqual({ kind: 'failed', failure: code, reason: 'The provider is rate limiting this account.' })
  })

  it('keeps a code it does not know apart', () => {
    expect(readChecked(failedBody('a_code_of_tomorrow'))).toEqual({ kind: 'failed', failure: 'unrecognised', reason: 'The provider is rate limiting this account.' })
  })

  it.each([['an empty sentence', ''], ['no sentence', null]])('reads a failure with %s as one without a reason', (_name, message) => {
    expect(readChecked(failedBody('rate_limited', 'failed', message))).toEqual({ kind: 'failed', failure: 'rate_limited', reason: null })
  })

  it.each([
    ['no object', 'verified'],
    ['no verification', { runtime: null }],
    ['another schema', { ...passedBody(), verification: { ...verification('verified', null), schema: 'masc.runtime_verification.v2' } }],
    ['a pass with a failure', { ...passedBody(), verification: verification('verified', { code: 'timed_out', message: 'late' }) }],
    ['a pass with no Runtime', { ...passedBody(), runtime: null }],
    ['a pass whose Runtime has no id', { ...passedBody(), runtime: { runtime_id: '', record: 'made' } }],
    ['a pass whose Runtime was recorded in a way not known', { ...passedBody(), runtime: { runtime_id: 'acct_1.claude-sonnet-5', record: 'moved' } }],
    ['a failure with a Runtime', { ...failedBody(), runtime: { runtime_id: 'acct_1.claude-sonnet-5', record: 'made' } }],
    ['a failure with no failure', { ...failedBody(), verification: verification('failed', null) }],
    ['a failure whose code is not text', { ...failedBody(), verification: verification('failed', { code: 7, message: 'seven' }) }],
    ['a status not known', { ...passedBody(), verification: verification('skipped', null) }],
  ])('refuses an answer with %s', (_name, body) => {
    expect(readChecked(body)).toBeNull()
  })
})

describe('sending a check', () => {
  it('asks for the account and the model, with the token of the session and no other credential', async () => {
    const { send, sent } = answering([passed()])
    expect(await checkModel(send, 'token-1', 'acct_1', 'claude-sonnet-5')).toEqual({ ok: true, value: { kind: 'passed', made: true } })
    expect(sent.map(({ path }) => path)).toEqual([checkPath])
    const init: RequestInit = sent[0]?.init ?? {}
    const headers = new Headers(init.headers)
    expect([init.method, init.credentials, headers.get(csrfHeader), headers.has('authorization')]).toEqual(['POST', 'same-origin', 'token-1', false])
    expect(JSON.parse(String(init.body))).toEqual({ provider_account_id: 'acct_1', model: 'claude-sonnet-5' })
  })

  it.each([
    ['a session that ended', noSession(), { kind: 'signed_out' }],
    ['a call of the account that runs', busy(), { kind: 'refused', status: 409, reason: 'A call of this account is running.' }],
    ['no answer', 'no answer' as const, { kind: 'unreachable' }],
    ['an answer it cannot read', json(200, { verification: null }), { kind: 'unreadable' }],
  ])('gives a problem for %s', async (_name, answer, problem) => {
    const { send } = answering([answer])
    expect(await checkModel(send, 'token-1', 'acct_1', 'claude-sonnet-5')).toEqual({ ok: false, problem })
  })
})

/** Checks over scripted answers, with the token `token` gives. */
function checking(answers: readonly Scripted[], token: () => string | null = () => 'token-1') {
  const { send, sent } = answering(answers)
  const leave = vi.fn()
  const refresh = vi.fn(() => Promise.resolve())
  const model = createChecks({ send, leave, token, refresh })
  const of = (accountId: string): Check | undefined => model.checks.value.get(accountId)
  return { model, sent, leave, refresh, of }
}

describe('the checks of a person', () => {
  it('says a check runs until its call passed, then reads the subscriptions again', async () => {
    const answer = later()
    const { model, refresh, of } = checking([answer.answer])
    const run = model.check('acct_1', 'claude-sonnet-5')
    expect([of('acct_1'), refresh.mock.calls.length]).toEqual([{ kind: 'checking', model: 'claude-sonnet-5' }, 0])
    answer.give(passed('existing'))
    await run
    expect([of('acct_1'), refresh.mock.calls.length]).toEqual([{ kind: 'passed', model: 'claude-sonnet-5', made: false }, 1])
  })

  it('counts the checks of an account that came to nothing in a row, and starts again after a pass', async () => {
    const { model, refresh, of } = checking([failed('timed_out'), notReady(), failed('rate_limited'), passed(), failed('timed_out')])
    const attempts = (): unknown => { const now = of('acct_1'); return now?.kind === 'failed' || now?.kind === 'not_done' ? [now.kind, now.attempts] : now?.kind }
    const seen: unknown[] = []
    for (let step = 0; step < 5; step += 1) {
      await model.check('acct_1', 'claude-sonnet-5')
      seen.push(attempts())
    }
    expect(seen).toEqual([['failed', 1], ['not_done', 2], ['failed', 3], 'passed', ['failed', 1]])
    expect(refresh).toHaveBeenCalledTimes(1)
  })

  it('keeps the reason of a call that did not pass, and why a request gave no call', async () => {
    const { model, of } = checking([failed('quota_exhausted'), busy()])
    await model.check('acct_1', 'claude-sonnet-5')
    const first = of('acct_1')
    await model.check('acct_1', 'claude-opus-9')
    expect([first, of('acct_1')]).toEqual([
      { kind: 'failed', model: 'claude-sonnet-5', failure: 'quota_exhausted', reason: 'The provider is rate limiting this account.', attempts: 1 },
      { kind: 'not_done', model: 'claude-opus-9', problem: { kind: 'refused', status: 409, reason: 'A call of this account is running.' }, attempts: 2 },
    ])
  })

  it('sends no second check of an account while one runs, and checks another account alongside', async () => {
    const first = later()
    const { model, sent, of } = checking([first.answer, passed()])
    const run = model.check('acct_1', 'claude-sonnet-5')
    await model.check('acct_1', 'claude-opus-9')
    await model.check('acct_2', 'claude-sonnet-5')
    expect([sent.length, of('acct_1')?.kind, of('acct_2')?.kind]).toEqual([2, 'checking', 'passed'])
    first.give(passed())
    await run
    expect(of('acct_1')).toEqual({ kind: 'passed', model: 'claude-sonnet-5', made: true })
  })

  it('sends nothing before the panel has a session', async () => {
    const { model, sent, of } = checking([passed()], () => null)
    await model.check('acct_1', 'claude-sonnet-5')
    expect([sent.length, of('acct_1')]).toEqual([0, undefined])
  })

  it('leaves for the sign-in page once when a check finds that the session ended, and checks nothing more', async () => {
    const second = later()
    const { model, sent, leave, of } = checking([second.answer, noSession(), passed()])
    const run = model.check('acct_2', 'claude-sonnet-5')
    await model.check('acct_1', 'claude-sonnet-5')
    second.give(noSession())
    await run
    await model.check('acct_3', 'claude-sonnet-5')
    expect([leave.mock.calls.length, sent.length, of('acct_1')?.kind, of('acct_2')?.kind, of('acct_3')]).toEqual([1, 2, 'leaving', 'checking', undefined])
  })

  it('forgets every check for another person, and an answer that comes later changes nothing', async () => {
    const answer = later()
    const { model, refresh } = checking([answer.answer, passed()])
    const run = model.check('acct_1', 'claude-sonnet-5')
    model.reset()
    answer.give(passed())
    await run
    expect([model.checks.value.size, refresh.mock.calls.length]).toEqual([0, 0])
  })
})

// ---- the card of an account ----

const claude: Integration = { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5', 'claude-opus-9'], calls: { kind: 'allowed' } }
const bare: Integration = { id: 'bare', displayName: '', models: [], calls: { kind: 'allowed' } }
const codex: Integration = { id: 'codex', displayName: 'Codex', models: ['gpt-5.5'], calls: { kind: 'refused', refusal: 'native_unpublished' } }
const one = (integrationId: string): Owned => ({ accounts: [{ id: 'acct_1', integration: { read: true, value: integrationId } }], runtimes: [] })

const card = (checks: ChecksModel, owned: Owned = one('claude_code')) =>
  render(html`
    <section aria-labelledby="h"><h2 id="h">구독</h2><${AccountList} integrations=${[claude, bare, codex]} owned=${owned} checks=${checks} /></section>
  `).container

/** A model of checks that shows `check` for the account and counts what it is asked. */
const showing = (check: Check | undefined): ChecksModel => ({
  checks: signal(new Map(check === undefined ? [] : [['acct_1', check]])),
  check: vi.fn(() => Promise.resolve()),
  reset: vi.fn(),
})

describe('the card of an account', () => {
  const steps: ReadonlyArray<readonly [string, Check | undefined]> = [
    ['before any check', undefined],
    ['a check that runs', { kind: 'checking', model: 'claude-sonnet-5' }],
    ['a check that made a Runtime', { kind: 'passed', model: 'claude-sonnet-5', made: true }],
    ['a check of a Runtime made before', { kind: 'passed', model: 'claude-sonnet-5', made: false }],
    ['a call that did not pass', { kind: 'failed', model: 'claude-sonnet-5', failure: 'timed_out', reason: 'late', attempts: 2 }],
    ['a call that did not pass for a reason not known', { kind: 'failed', model: 'claude-sonnet-5', failure: 'unrecognised', reason: null, attempts: 1 }],
    ['a request that gave no call', { kind: 'not_done', model: 'claude-sonnet-5', problem: { kind: 'unreachable' }, attempts: 1 }],
    ['a check that found no session', { kind: 'leaving', model: 'claude-sonnet-5' }],
  ]
  const named = (...names: string[]) => steps.map(([name]) => [name, names.includes(name) ? 1 : 0])
  const count = (selector: string) => steps.map(([name, check]) => [name, card(showing(check)).querySelectorAll(selector).length])

  it.each(steps)('passes the accessibility rules %s', async (_name, check) => {
    expect(await axe(card(showing(check)))).toHaveNoViolations()
  })

  it('has one line a screen reader reads out in every step', () => {
    expect(count('.row [role=status]')).toEqual(named(...steps.map(([name]) => name)))
  })

  it('says a check that came to nothing where a screen reader announces it', () => {
    expect(count('.row [role=alert]')).toEqual(named('a call that did not pass', 'a call that did not pass for a reason not known', 'a request that gave no call'))
  })

  it('marks the button while a check runs or the browser leaves', () => {
    expect(count('.check button[aria-disabled=true]')).toEqual(named('a check that runs', 'a check that found no session'))
  })

  it('offers no check on an account whose subscription has no model to check, or whose calls the server refuses', async () => {
    for (const integrationId of ['bare', 'codex']) {
      const container = card(showing(undefined), one(integrationId))
      expect([integrationId, container.querySelectorAll('.check').length]).toEqual([integrationId, 0])
      expect(await axe(container)).toHaveNoViolations()
      cleanup()
    }
  })

  it('checks the model the person picked', () => {
    const checks = showing(undefined)
    const container = card(checks)
    const select = container.querySelector('select')
    const form = container.querySelector('form.check')
    if (select === null || form === null) throw new Error('no check in the card')
    fireEvent.change(select, { target: { value: 'claude-opus-9' } })
    fireEvent.submit(form)
    expect(checks.check).toHaveBeenCalledWith('acct_1', 'claude-opus-9')
  })

  it('sends nothing more while a check runs', () => {
    const checks = showing({ kind: 'checking', model: 'claude-sonnet-5' })
    const form = card(checks).querySelector('form.check')
    if (form === null) throw new Error('no check in the card')
    fireEvent.submit(form)
    expect(checks.check).not.toHaveBeenCalled()
  })

  it('puts a new alert on the page when a check comes to nothing again', async () => {
    const { send } = answering([failed('timed_out'), failed('timed_out'), notReady(), notReady()])
    const checks = createChecks({ send, leave: vi.fn(), token: () => 'token-1', refresh: () => Promise.resolve() })
    const container = card(checks)
    const alerts: Array<Element | null> = []
    for (let step = 0; step < 4; step += 1) {
      await act(() => checks.check('acct_1', 'claude-sonnet-5'))
      alerts.push(container.querySelector('.row [role=alert]'))
    }
    expect(alerts.every((alert) => alert !== null)).toBe(true)
    expect(alerts.slice(1).map((alert, at) => alert === alerts[at])).toEqual([false, false, false])
  })

  it('keeps the button under the focus and the line a screen reader reads out from the press to the pass', async () => {
    const answer = later()
    const { send } = answering([answer.answer])
    const checks = createChecks({ send, leave: vi.fn(), token: () => 'token-1', refresh: () => Promise.resolve() })
    const container = card(checks)
    const button = container.querySelector<HTMLButtonElement>('.check button')
    const line = container.querySelector('.row [role=status]')
    if (button === null || line === null) throw new Error('no check in the card')
    button.focus()
    const form = container.querySelector('form.check')
    if (form === null) throw new Error('no check in the card')
    await act(() => { fireEvent.submit(form) })
    const during = [document.activeElement === button, container.querySelector('.row [role=status]') === line, button.getAttribute('aria-disabled')]
    await act(async () => { answer.give(passed()); await Promise.resolve() })
    await vi.waitFor(() => { expect(checks.checks.value.get('acct_1')?.kind).toBe('passed') })
    const after = [document.activeElement === button, container.querySelector('.row [role=status]') === line, button.getAttribute('aria-disabled')]
    expect([during, after]).toEqual([[true, true, 'true'], [true, true, 'false']])
  })
})
