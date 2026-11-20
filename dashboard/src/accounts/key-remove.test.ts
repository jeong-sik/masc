// @vitest-environment happy-dom
//
// Removing a key account: what a removal sends, what the server's answer
// reads as, how the removal of each account moves, and the button in the
// card of an account. What a step says and where it puts things is not
// checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AccountList } from './account-rows'
import { createChecks } from './check'
import { createRemovals, removeAccount, removePath } from './key-remove'
import { createReplacements } from './key-replace'
import type { RemovalsModel, Removing } from './key-remove'
import { csrfHeader } from './wire'
import type { Integration, Owned, ProviderAccount, Removal, Send } from './wire'

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

/** Something that settles when the test says so. */
function later<T>(): { readonly promise: Promise<T>; readonly give: (value: T) => void } {
  let give: (value: T) => void = () => { throw new Error('it was given before it was asked for') }
  const promise = new Promise<T>((resolve) => { give = resolve })
  return { promise, give: (value) => { give(value) } }
}

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

const removed = (): Response => json(200, { provider_account_id: 'acct_key', removed: true })
const refusedAs = (status: number, code: string): Response => json(status, { error: `The server said ${code}.`, code })
const busy = (): Response => refusedAs(409, 'account_call_running')
const keyStayed = (): Response => refusedAs(503, 'key_not_removed')
const noSuchAccount = (): Response => refusedAs(404, 'unknown_account')
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

afterEach(() => {
  cleanup()
})

describe('sending a removal', () => {
  it('asks with DELETE on the path of the account, with the token of the session, no body and no other credential', async () => {
    const { send, sent } = answering([removed()])
    expect(await removeAccount(send, 'token-1', 'acct_key')).toEqual({ kind: 'removed' })
    const init: RequestInit = sent[0]?.init ?? {}
    const headers = new Headers(init.headers)
    expect([sent.map(({ path }) => path), init.method, init.credentials, headers.get(csrfHeader), headers.has('authorization'), init.body])
      .toEqual([['/api/v1/setup/accounts/key/acct_key'], 'DELETE', 'same-origin', 'token-1', false, undefined])
  })

  it('names an account in one segment of the path, whatever its id holds', () => {
    expect(removePath('a/b?c#d')).toBe('/api/v1/setup/accounts/key/a%2Fb%3Fc%23d')
  })

  it.each([
    ['unknown_account', 404], ['not_a_key_account', 400], ['account_call_running', 409], ['removal_refused', 403],
    ['removal_not_recorded', 503], ['key_not_removed', 503], ['home_not_removed', 503], ['internal_error', 500],
  ])('reads the refusal %s by its code', async (code, status) => {
    const { send } = answering([refusedAs(status, code)])
    expect(await removeAccount(send, 'token-1', 'acct_key')).toEqual({ kind: 'refused', status, code, reason: `The server said ${code}.` })
  })

  it.each([
    ['a session that ended', noSession(), { kind: 'signed_out' }],
    ['no answer', 'no answer' as const, { kind: 'unreachable' }],
    ['an answer of another route that says all is well', json(200, { provider_accounts: [] }), { kind: 'unreadable' }],
    ['an answer that says all is well and is not JSON', new Response('<html>sign in</html>', { status: 200 }), { kind: 'unreadable' }],
    ['a refusal with a code it does not know', refusedAs(409, 'volume_away'), { kind: 'refused', status: 409, code: 'unrecognised', reason: 'The server said volume_away.' }],
    ['a refusal with no code', json(403, { error: 'the request carried no token' }), { kind: 'refused', status: 403, code: 'unrecognised', reason: 'the request carried no token' }],
    ['a failure with a code it does not know', refusedAs(503, 'volume_away'), { kind: 'server_failed' }],
    ['a failure with no code', json(503, { error: 'the server is starting' }), { kind: 'server_failed' }],
    ['a failure that is not JSON', new Response('Bad Gateway', { status: 502 }), { kind: 'server_failed' }],
  ])('reads %s', async (_name, answer, asked) => {
    const { send } = answering([answer])
    expect(await removeAccount(send, 'token-1', 'acct_key')).toEqual(asked)
  })
})

/** Removals over scripted answers, and what they asked of the panel. */
function removing(answers: readonly Scripted[], token: string | null = 'token-1') {
  const { send, sent } = answering(answers)
  const leave = vi.fn()
  const refresh = vi.fn(() => Promise.resolve())
  const model = createRemovals({ send, leave, token: () => token, refresh })
  return { model, sent, leave, refresh, of: (id: string): Removing | undefined => model.removing.value.get(id) }
}

describe('the removal of an account', () => {
  it('holds the removal of an account the server removed until the subscriptions were asked for again', async () => {
    const reading = later<undefined>()
    const { send } = answering([removed()])
    const refresh = vi.fn(() => reading.promise)
    const model = createRemovals({ send, leave: vi.fn(), token: () => 'token-1', refresh })
    const run = model.remove('acct_key')
    await vi.waitFor(() => { expect(refresh).toHaveBeenCalledTimes(1) })
    const during = model.removing.value.get('acct_key')
    reading.give(undefined)
    await run
    expect([during, model.removing.value.get('acct_key')]).toEqual([{ kind: 'sending' }, { kind: 'removed', already: false }])
  })

  it('takes an account the server does not have as one that went already', async () => {
    const { model, refresh, of } = removing([noSuchAccount()])
    await model.remove('acct_key')
    expect([of('acct_key'), refresh.mock.calls.length]).toEqual([{ kind: 'removed', already: true }, 1])
  })

  it('keeps a removal the server did not start, and reads nothing again', async () => {
    const { model, refresh, of } = removing([busy(), busy()])
    await model.remove('acct_key')
    const first = of('acct_key')
    await model.remove('acct_key')
    expect([first, of('acct_key'), refresh.mock.calls.length]).toEqual([
      { kind: 'refused', status: 409, code: 'account_call_running', reason: 'The server said account_call_running.', attempts: 1 },
      { kind: 'refused', status: 409, code: 'account_call_running', reason: 'The server said account_call_running.', attempts: 2 },
      0,
    ])
  })

  it.each([
    ['key_not_removed'], ['home_not_removed'], ['removal_not_recorded'],
  ])('reads the subscriptions again after a removal that stopped at %s', async (code) => {
    const { model, refresh, of } = removing([refusedAs(503, code)])
    await model.remove('acct_key')
    expect([of('acct_key')?.kind, refresh.mock.calls.length]).toEqual(['refused', 1])
  })

  it.each([
    ['not_a_key_account', 400], ['removal_refused', 403], ['internal_error', 500], ['volume_away', 409],
  ])('reads nothing again after the refusal %s', async (code, status) => {
    const { model, refresh, of } = removing([refusedAs(status, code)])
    await model.remove('acct_key')
    expect([of('acct_key')?.kind, refresh.mock.calls.length]).toEqual(['refused', 0])
  })

  it.each([
    ['with a code it does not know', refusedAs(503, 'volume_away')],
    ['of what stands in front of the server', new Response('Bad Gateway', { status: 502 })],
  ])('takes a failure %s as one that may have removed the account', async (_name, answer) => {
    const { model, refresh, of } = removing([answer])
    await model.remove('acct_key')
    expect([of('acct_key'), refresh.mock.calls.length]).toEqual([{ kind: 'unknown', answer: 'server_failed', attempts: 1 }, 1])
  })

  it('reads the subscriptions again when no answer came, for the server may have removed the account', async () => {
    const { model, refresh, of } = removing(['no answer', 'no answer'])
    await model.remove('acct_key')
    await model.remove('acct_key')
    expect([of('acct_key'), refresh.mock.calls.length]).toEqual([{ kind: 'unknown', answer: 'none', attempts: 2 }, 2])
  })

  it('takes an answer it cannot read as one that may have removed the account', async () => {
    const { model, refresh, of } = removing([json(200, { provider_accounts: [] })])
    await model.remove('acct_key')
    expect([of('acct_key'), refresh.mock.calls.length]).toEqual([{ kind: 'unknown', answer: 'unreadable', attempts: 1 }, 1])
  })

  it('counts the removals that came to nothing in a row, whatever their end', async () => {
    const { model, of } = removing([busy(), 'no answer', keyStayed()])
    await model.remove('acct_key')
    await model.remove('acct_key')
    await model.remove('acct_key')
    expect(of('acct_key')).toMatchObject({ kind: 'refused', code: 'key_not_removed', attempts: 3 })
  })

  it('sends one request for an account whose removal runs', async () => {
    const answer = later<Response>()
    const { model, sent } = removing([answer.promise])
    const first = model.remove('acct_key')
    await model.remove('acct_key')
    answer.give(busy())
    await first
    expect(sent.length).toBe(1)
  })

  it('removes two accounts side by side', async () => {
    const one = later<Response>()
    const { model, sent, of } = removing([one.promise, busy()])
    const first = model.remove('acct_key')
    await model.remove('acct_other')
    const during = [of('acct_key')?.kind, of('acct_other')?.kind]
    one.give(keyStayed())
    await first
    expect([sent.map(({ path }) => path), during, of('acct_key')?.kind])
      .toEqual([[removePath('acct_key'), removePath('acct_other')], ['sending', 'refused'], 'refused'])
  })

  it('sends nothing before a session', async () => {
    const { model, sent, of } = removing([removed()], null)
    await model.remove('acct_key')
    expect([sent.length, of('acct_key')]).toEqual([0, undefined])
  })

  it('leaves with the page once a removal finds no session, and removes nothing after', async () => {
    const other = later<Response>()
    const { model, sent, leave, refresh, of } = removing([other.promise, noSession(), removed()])
    const first = model.remove('acct_other')
    await model.remove('acct_key')
    await model.remove('acct_third')
    other.give(removed())
    await first
    expect([of('acct_key'), of('acct_other'), of('acct_third'), leave.mock.calls.length, sent.length, refresh.mock.calls.length])
      .toEqual([{ kind: 'leaving' }, { kind: 'leaving' }, undefined, 1, 2, 0])
  })

  it('forgets every removal for another person, and an answer that comes later changes nothing', async () => {
    const answer = later<Response>()
    const { model, refresh } = removing([answer.promise])
    const run = model.remove('acct_key')
    model.reset()
    answer.give(removed())
    await run
    expect([model.removing.value.size, refresh.mock.calls.length]).toEqual([0, 0])
  })

  it('keeps nothing of an account whose list was read for another person meanwhile', async () => {
    const reading = later<undefined>()
    const { send } = answering([removed()])
    const model = createRemovals({ send, leave: vi.fn(), token: () => 'token-1', refresh: () => reading.promise })
    const run = model.remove('acct_key')
    await vi.waitFor(() => { expect(model.removing.value.get('acct_key')?.kind).toBe('sending') })
    model.reset()
    reading.give(undefined)
    await run
    expect(model.removing.value.size).toBe(0)
  })

  it('removes again for the person shown after one whose session ended', async () => {
    const { model, sent, of } = removing([noSession(), busy()])
    await model.remove('acct_key')
    model.reset()
    await model.remove('acct_9')
    expect([sent.length, of('acct_9')?.kind]).toEqual([2, 'refused'])
  })
})

// ---- the button in the card of an account ----

const claude: Integration = { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], withheld: [], calls: { kind: 'allowed' }, takesKey: true }
const keyAccount = (removal: Removal | null = null): ProviderAccount =>
  ({ id: 'acct_key', integration: 'claude_code', held: { kind: 'key', key: 'readable' }, left: removal === null ? null : { kind: 'removal', stage: removal } })
const loginAccount: ProviderAccount = { id: 'acct_login', integration: 'claude_code', held: { kind: 'login' }, left: null }
const owning = (...accounts: ProviderAccount[]): Owned => ({ accounts, runtimes: [] })

/** Checks no test here drives: a card only needs them to be there. */
const idleChecks = () =>
  createChecks({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() })

/** Replacements no test here drives: a card only needs them to be there. */
const idleReplacements = () => createReplacements({ send: () => Promise.reject(new Error('nothing is sent')), leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() })

/** The buttons of the removal in a card: the one that removes, and the one that takes the question back. */
const removeButtons = 'button[id^="remove-"]'

/** A model of removals that shows `removing` for the key account and counts what it is asked. */
const showing = (removing: Removing | undefined) => ({
  removing: signal(new Map(removing === undefined ? [] : [['acct_key', removing]])),
  remove: vi.fn(() => Promise.resolve()),
  reset: vi.fn(),
}) satisfies RemovalsModel

const list = (removals: RemovalsModel, owned: Owned) => html`
  <section aria-labelledby="h"><h2 id="h">구독</h2><${AccountList} integrations=${[claude]} owned=${owned} checks=${idleChecks()} removals=${removals} replacements=${idleReplacements()} /></section>
`
const card = (removals: RemovalsModel, owned: Owned = owning(keyAccount())) => render(list(removals, owned)).container

const buttonOf = (container: Element, id: string): HTMLButtonElement => {
  const button = container.querySelector<HTMLButtonElement>(`#${id}`)
  if (button === null) throw new Error(`no button ${id}`)
  return button
}
const removeButton = (container: Element): HTMLButtonElement => buttonOf(container, 'remove-acct_key')

describe('the remove button of an account', () => {
  const steps: ReadonlyArray<readonly [string, Removing | undefined]> = [
    ['before any removal', undefined],
    ['a removal that runs', { kind: 'sending' }],
    ['a removal the server did not start', { kind: 'refused', status: 409, code: 'account_call_running', reason: 'busy', attempts: 1 }],
    ['a removal that stopped at the key', { kind: 'refused', status: 503, code: 'key_not_removed', reason: 'stayed', attempts: 2 }],
    ['a removal refused with no code', { kind: 'refused', status: 403, code: 'unrecognised', reason: null, attempts: 1 }],
    ['a removal with no answer', { kind: 'unknown', answer: 'none', attempts: 1 }],
    ['a removal with an answer it cannot read', { kind: 'unknown', answer: 'unreadable', attempts: 2 }],
    ['a removal the server failed on with no code', { kind: 'unknown', answer: 'server_failed', attempts: 1 }],
    ['a removal the server answered, before the list says so', { kind: 'removed', already: false }],
    ['a removal that found no session', { kind: 'leaving' }],
  ]
  const named = (...names: string[]) => steps.map(([name]) => [name, names.includes(name) ? 1 : 0])
  const count = (selector: string) => steps.map(([name, removing]) => [name, card(showing(removing)).querySelectorAll(selector).length])

  it.each(steps)('passes the accessibility rules %s', async (_name, removing) => {
    expect(await axe(card(showing(removing)))).toHaveNoViolations()
  })

  it('passes the accessibility rules once it asked, and on an account a removal was left on', async () => {
    const asked = card(showing(undefined))
    fireEvent.click(removeButton(asked))
    expect(await axe(asked)).toHaveNoViolations()
    // One card of the account at a time: its ids name what its button is labelled by.
    cleanup()
    expect(await axe(card(showing(undefined), owning(keyAccount('home_not_removed'))))).toHaveNoViolations()
  })

  it('says a removal that came to nothing where a screen reader announces it', () => {
    expect(count('.row [role=alert]')).toEqual(named(
      'a removal the server did not start', 'a removal that stopped at the key', 'a removal refused with no code',
      'a removal with no answer', 'a removal with an answer it cannot read', 'a removal the server failed on with no code',
    ))
  })

  it('is on a key account, with or without a removal left on it, and not on a login account', () => {
    const container = card(showing(undefined), owning(keyAccount(), loginAccount))
    const left = card(showing(undefined), owning(keyAccount('start_given_up')))
    expect([[...container.querySelectorAll('li.row')].map((row) => row.querySelectorAll(removeButtons).length), left.querySelectorAll(removeButtons).length])
      .toEqual([[1, 0], 1])
  })

  it('asks once more before it removes', () => {
    const removals = showing(undefined)
    const container = card(removals)
    fireEvent.click(removeButton(container))
    const asked = [removals.remove.mock.calls.length, container.querySelectorAll(removeButtons).length]
    fireEvent.click(removeButton(container))
    expect([asked, removals.remove.mock.calls, container.querySelectorAll(removeButtons).length]).toEqual([[0, 2], [['acct_key']], 1])
  })

  it('takes the question back and removes nothing, with the focus back on the button', () => {
    const removals = showing(undefined)
    const container = card(removals)
    fireEvent.click(removeButton(container))
    const back = buttonOf(container, 'remove-back-acct_key')
    back.focus()
    fireEvent.click(back)
    expect([removals.remove.mock.calls.length, container.querySelectorAll(removeButtons).length, document.activeElement === removeButton(container)])
      .toEqual([0, 1, true])
  })

  it.each([
    ['a removal that runs', { kind: 'sending' }],
    ['a removal that found no session', { kind: 'leaving' }],
  ] as const)('asks nothing and removes nothing during %s', (_name, removing) => {
    const removals = showing(removing)
    const container = card(removals)
    fireEvent.click(removeButton(container))
    fireEvent.click(removeButton(container))
    expect([removals.remove.mock.calls.length, container.querySelectorAll(removeButtons).length, removeButton(container).getAttribute('aria-disabled')])
      .toEqual([0, 1, 'true'])
  })

  it('removes again after a removal that came to nothing', () => {
    const removals = showing({ kind: 'refused', status: 409, code: 'account_call_running', reason: 'busy', attempts: 1 })
    const container = card(removals)
    fireEvent.click(removeButton(container))
    fireEvent.click(removeButton(container))
    expect(removals.remove.mock.calls).toEqual([['acct_key']])
  })

  it('does not hold the button of an account the server said is gone while the list still has it', () => {
    const removals = showing({ kind: 'removed', already: true })
    const container = card(removals)
    fireEvent.click(removeButton(container))
    fireEvent.click(removeButton(container))
    expect([removals.remove.mock.calls, removeButton(container).getAttribute('aria-disabled')]).toEqual([[['acct_key']], 'false'])
  })

  it('puts a new alert on the page when a removal comes to nothing again', async () => {
    const { model } = removing([busy(), busy()])
    const container = card(model)
    await act(() => model.remove('acct_key'))
    const first = container.querySelector('[role=alert]')
    await act(() => model.remove('acct_key'))
    const second = container.querySelector('[role=alert]')
    expect([first === null, second === null, second === first]).toEqual([false, false, false])
  })

  it('draws no model and no check on an account a removal was left on, and moves a focus that was on its check to its title', () => {
    const removals = showing(undefined)
    const withModel = (account: ProviderAccount): Owned =>
      ({ accounts: [account], runtimes: [{ id: 'acct_key.claude-sonnet-5', accountId: 'acct_key', model: { read: true, value: 'claude-sonnet-5' } }] })
    const { container, rerender } = render(list(removals, withModel(keyAccount())))
    const before = [container.querySelectorAll('.models').length, container.querySelectorAll('.check').length]
    buttonOf(container, 'check-button-acct_key').focus()
    rerender(list(removals, withModel(keyAccount('key_not_removed'))))
    expect([before, container.querySelectorAll('.models').length, container.querySelectorAll('.check').length, document.activeElement === container.querySelector('#row-title-acct_key')])
      .toEqual([[1, 1], 0, 0, true])
  })

  it('stays the same button, with the focus on it, when the list comes to say a removal was left on the account', () => {
    const removals = showing(undefined)
    const { container, rerender } = render(list(removals, owning(keyAccount())))
    const before = removeButton(container)
    before.focus()
    rerender(list(removals, owning(keyAccount('key_not_removed'))))
    expect([removeButton(container) === before, document.activeElement === before, container.querySelectorAll('.check').length]).toEqual([true, true, 0])
  })
})
