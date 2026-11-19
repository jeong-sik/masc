// Replacing the key of a key account: what a replacement sends, what the
// server's answer reads as, and how the replacement of each account moves.
// The field in the card of an account has its own tests
// (key-replace-area.test.ts).
import { describe, expect, it, vi } from 'vitest'
import { createReplacements, replaceKey, replacePath } from './key-replace'
import type { Replacing } from './key-replace'
import { csrfHeader } from './wire'
import type { Send } from './wire'

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

/** A key no provider gave: the server is not asked in these tests. */
const key = 'made-up-key-one'
const otherKey = 'made-up-key-two'

const replaced = (oldKeysRemoved = true): Response => json(200, { provider_account_id: 'acct_key', old_keys_removed: oldKeysRemoved })
const refusedAs = (status: number, code: string): Response => json(status, { error: `The server said ${code}.`, code })
const busy = (): Response => refusedAs(409, 'account_call_running')
const notRecorded = (): Response => refusedAs(503, 'replacement_not_recorded')
const noSuchAccount = (): Response => refusedAs(404, 'unknown_account')
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

describe('sending a key for an account', () => {
  it('asks with PUT on the path of the account, with the token of the session, the key in the body and no other credential, and follows no redirect', async () => {
    const { send, sent } = answering([replaced()])
    expect(await replaceKey(send, 'token-1', 'acct_key', key)).toEqual({ kind: 'replaced', oldKeysRemoved: true })
    const init: RequestInit = sent[0]?.init ?? {}
    const headers = new Headers(init.headers)
    expect([sent.map(({ path }) => path), init.method, init.credentials, init.redirect, headers.get(csrfHeader), headers.has('authorization'), headers.get('content-type'), init.body])
      .toEqual([['/api/v1/setup/accounts/key/acct_key'], 'PUT', 'same-origin', 'error', 'token-1', false, 'application/json', JSON.stringify({ key })])
  })

  it('names an account in one segment of the path, whatever its id holds', () => {
    expect(replacePath('a/b?c#d')).toBe('/api/v1/setup/accounts/key/a%2Fb%3Fc%23d')
  })

  it('reads that a file of a key before stays on the server', async () => {
    const { send } = answering([replaced(false)])
    expect(await replaceKey(send, 'token-1', 'acct_key', key)).toEqual({ kind: 'replaced', oldKeysRemoved: false })
  })

  it.each([
    ['unknown_account', 404], ['not_a_key_account', 400], ['invalid_request', 400], ['not_a_key', 400], ['account_call_running', 409],
    ['removal_left', 409], ['replacement_refused', 403], ['internal_error', 500], ['files_not_reached', 503], ['replacement_not_recorded', 503], ['key_not_stored', 503],
  ])('reads the refusal %s by its code', async (code, status) => {
    const { send } = answering([refusedAs(status, code)])
    expect(await replaceKey(send, 'token-1', 'acct_key', key)).toEqual({ kind: 'refused', status, code, reason: `The server said ${code}.` })
  })

  it.each([
    ['a session that ended', noSession(), { kind: 'signed_out' }],
    ['no answer', 'no answer' as const, { kind: 'unreachable' }],
    ['an answer of another route that says all is well', json(200, { provider_accounts: [] }), { kind: 'unreadable' }],
    ['an answer that says all is well of another account', json(200, { provider_account_id: 'acct_other', old_keys_removed: true }), { kind: 'unreadable' }],
    ['an answer that says all is well and nothing of the keys before', json(200, { provider_account_id: 'acct_key' }), { kind: 'unreadable' }],
    ['an answer that says all is well and is not JSON', new Response('<html>sign in</html>', { status: 200 }), { kind: 'unreadable' }],
    ['a refusal with a code it does not know', refusedAs(409, 'volume_away'), { kind: 'refused', status: 409, code: 'unrecognised', reason: 'The server said volume_away.' }],
    ['a refusal with no code', json(403, { error: 'the request carried no token' }), { kind: 'refused', status: 403, code: 'unrecognised', reason: 'the request carried no token' }],
    ['a failure with a code it does not know', refusedAs(503, 'volume_away'), { kind: 'server_failed' }],
    // What the server answers while it cannot trust its records (RFC, 3.3).
    ['a failure with no code', json(503, { error: 'The server cannot read its accounts right now. Try again later.' }), { kind: 'server_failed' }],
    ['a failure that is not JSON', new Response('Bad Gateway', { status: 502 }), { kind: 'server_failed' }],
  ])('reads %s', async (_name, answer, asked) => {
    const { send } = answering([answer])
    expect(await replaceKey(send, 'token-1', 'acct_key', key)).toEqual(asked)
  })
})

/** Replacements over scripted answers, and what they asked of the panel. */
function replacing(answers: readonly Scripted[], token: string | null = 'token-1') {
  const { send, sent } = answering(answers)
  const leave = vi.fn()
  const refresh = vi.fn(() => Promise.resolve())
  const model = createReplacements({ send, leave, token: () => token, refresh })
  return { model, sent, leave, refresh, of: (id: string): Replacing | undefined => model.replacing.value.get(id) }
}

describe('the replacement of the key of an account', () => {
  it('sends nothing for an account with no open field, and keeps the key', async () => {
    const { model, sent, of } = replacing([])
    expect([await model.replace('acct_key', key), sent.length, of('acct_key')]).toEqual(['kept', 0, undefined])
  })

  it('sends nothing before a session, and keeps the key in the open field', async () => {
    const { model, sent, of } = replacing([], null)
    model.open('acct_key')
    expect([await model.replace('acct_key', key), sent.length, of('acct_key')]).toEqual(['kept', 0, { kind: 'open', failure: null }])
  })

  it.each([
    ['a replacement the server did', () => replaced(false), { kind: 'replaced', oldKeysRemoved: false }],
    ['an account the server does not have', noSuchAccount, { kind: 'gone' }],
  ] as const)('gives the key up once the answer is read after %s, and shows it once the subscriptions were read again', async (_name, answer, shown) => {
    const reading = later<undefined>()
    const { send } = answering([answer()])
    const refresh = vi.fn(() => reading.promise)
    const model = createReplacements({ send, leave: vi.fn(), token: () => 'token-1', refresh })
    model.open('acct_key')
    const kept = await model.replace('acct_key', key)
    const during = model.replacing.value.get('acct_key')
    reading.give(undefined)
    await vi.waitFor(() => { expect(model.replacing.value.get('acct_key')).toEqual(shown) })
    expect([kept, during, refresh.mock.calls.length]).toEqual(['dropped', { kind: 'sending', failure: null }, 1])
  })

  it('shows nothing of an answer whose subscriptions came after a reset', async () => {
    const reading = later<undefined>()
    const { send } = answering([replaced()])
    const model = createReplacements({ send, leave: vi.fn(), token: () => 'token-1', refresh: () => reading.promise })
    model.open('acct_key')
    await model.replace('acct_key', key)
    model.reset()
    reading.give(undefined)
    await new Promise((resolve) => { setTimeout(resolve, 0) })
    expect(model.replacing.value.get('acct_key')).toBeUndefined()
  })

  it('keeps an account as left behind when its subscriptions came after the session ended', async () => {
    const reading = later<undefined>()
    const { send } = answering([replaced(), noSession()])
    const model = createReplacements({ send, leave: vi.fn(), token: () => 'token-1', refresh: () => reading.promise })
    model.open('acct_key')
    model.open('acct_other')
    await model.replace('acct_key', key)
    await model.replace('acct_other', otherKey)
    reading.give(undefined)
    await new Promise((resolve) => { setTimeout(resolve, 0) })
    expect(model.replacing.value.get('acct_key')).toEqual({ kind: 'leaving' })
  })

  // The subscriptions that are asked for again never come.
  it('ends once the answer is read after a refusal that can have changed the account, without the subscriptions it asked for again', async () => {
    const { send } = answering([refusedAs(503, 'key_not_stored')])
    const refresh = vi.fn(() => later<undefined>().promise)
    const model = createReplacements({ send, leave: vi.fn(), token: () => 'token-1', refresh })
    model.open('acct_key')
    expect([await model.replace('acct_key', key), model.replacing.value.get('acct_key')?.kind, refresh.mock.calls.length]).toEqual(['kept', 'open', 1])
  })

  it('sends one key at a time for an account', async () => {
    const answer = later<Response>()
    const { model, sent } = replacing([answer.promise])
    model.open('acct_key')
    const first = model.replace('acct_key', key)
    const second = await model.replace('acct_key', otherKey)
    answer.give(replaced())
    expect([second, await first, sent.length]).toEqual(['kept', 'dropped', 1])
  })

  it('keeps the field and the key after a refusal that changed nothing, counts the refusals, and reads nothing again', async () => {
    const { model, refresh, of } = replacing([busy(), busy()])
    model.open('acct_key')
    const kept = [await model.replace('acct_key', key), await model.replace('acct_key', key)]
    expect([kept, of('acct_key'), refresh.mock.calls.length]).toEqual([
      ['kept', 'kept'],
      { kind: 'open', failure: { kind: 'refused', status: 409, code: 'account_call_running', reason: 'The server said account_call_running.', attempts: 2 } },
      0,
    ])
  })

  it.each([
    ['replacement_not_recorded', 503], ['key_not_stored', 503], ['removal_left', 409],
  ])('reads the subscriptions again after %s, which can have changed the account', async (code, status) => {
    const { model, refresh, of } = replacing([refusedAs(status, code)])
    model.open('acct_key')
    expect([await model.replace('acct_key', key), of('acct_key')?.kind, refresh.mock.calls.length]).toEqual(['kept', 'open', 1])
  })

  it.each([
    ['no answer', 'no answer' as const, 'none'],
    ['an answer it cannot read', json(200, { provider_accounts: [] }), 'unreadable'],
    ['a failure with no code of the route', json(503, { error: 'the server is starting' }), 'server_failed'],
  ] as const)('drops the key after %s, and reads the subscriptions again without waiting for them', async (_name, answer, heard) => {
    const reading = later<undefined>()
    const { send } = answering([answer])
    const refresh = vi.fn(() => reading.promise)
    const model = createReplacements({ send, leave: vi.fn(), token: () => 'token-1', refresh })
    model.open('acct_key')
    expect([await model.replace('acct_key', key), model.replacing.value.get('acct_key'), refresh.mock.calls.length])
      .toEqual(['dropped', { kind: 'open', failure: { kind: 'unknown', answer: heard, attempts: 1 } }, 1])
    reading.give(undefined)
  })

  it('takes an account the server does not have as one that went, and reads the subscriptions again', async () => {
    const { model, refresh, of } = replacing([noSuchAccount()])
    model.open('acct_key')
    expect([await model.replace('acct_key', key), of('acct_key'), refresh.mock.calls.length]).toEqual(['dropped', { kind: 'gone' }, 1])
  })

  it('leaves once the session ended, with every key on its way and every open field, and sends nothing after', async () => {
    const answer = later<Response>()
    const { model, sent, leave, of } = replacing([noSession(), answer.promise])
    model.open('acct_key')
    model.open('acct_other')
    model.open('acct_idle')
    const other = model.replace('acct_other', otherKey)
    const mine = model.replace('acct_key', key)
    // The request of `acct_other` finds the session ended while that of `acct_key` is on its way.
    const first = await other
    answer.give(replaced())
    expect([first, await mine, of('acct_key'), of('acct_other'), of('acct_idle'), leave.mock.calls.length])
      .toEqual(['dropped', 'dropped', { kind: 'leaving' }, { kind: 'leaving' }, { kind: 'leaving' }, 1])
    model.open('acct_third')
    expect([of('acct_third'), await model.replace('acct_key', key), sent.length]).toEqual([undefined, 'kept', 2])
  })

  it('opens the field again after a replacement that went through, and closes only an open one', async () => {
    const answer = later<Response>()
    const { model, of } = replacing([replaced(), answer.promise])
    model.open('acct_key')
    await model.replace('acct_key', key)
    model.open('acct_key')
    const opened = of('acct_key')
    const run = model.replace('acct_key', otherKey)
    model.close('acct_key')
    const whileSending = of('acct_key')?.kind
    answer.give(busy())
    await run
    model.close('acct_key')
    expect([opened, whileSending, of('acct_key')]).toEqual([{ kind: 'open', failure: null }, 'sending', undefined])
  })

  it('opens a field again after a reset that followed the end of a session', async () => {
    const { model, of } = replacing([noSession()])
    model.open('acct_key')
    await model.replace('acct_key', key)
    const ended = of('acct_key')
    model.reset()
    model.open('acct_key')
    expect([ended, of('acct_key')]).toEqual([{ kind: 'leaving' }, { kind: 'open', failure: null }])
  })

  it('forgets every replacement at a reset, and an answer that comes after changes nothing', async () => {
    const answer = later<Response>()
    const { model, refresh, of } = replacing([answer.promise])
    model.open('acct_key')
    const run = model.replace('acct_key', key)
    model.reset()
    answer.give(notRecorded())
    expect([await run, of('acct_key'), refresh.mock.calls.length]).toEqual(['dropped', undefined, 0])
  })
})
